import CLibUSB
import Foundation

enum PrinterError: LocalizedError {
    case notFound
    case editorLiteMode
    case usb(String, Int32)
    case badStatus(String)
    case printerReportsError(String)
    case tooWide(Int, Int)

    var errorDescription: String? {
        switch self {
        case .notFound:
            "No PT-P700 found on USB. Check the cable and that the printer is on."
        case .editorLiteMode:
            "The printer is in Editor Lite mode. Hold the PLite button until the green light goes off, then try again."
        case let .usb(what, code):
            "USB \(what) failed: \(String(cString: libusb_error_name(code)))"
        case let .badStatus(detail):
            "Unexpected status reply from the printer (\(detail))."
        case let .printerReportsError(detail):
            "The printer reports: \(detail)"
        case let .tooWide(image, tape):
            "Label is \(image) dots tall but the tape only fits \(tape)."
        }
    }
}

struct PrinterStatus {
    let raw: [UInt8]

    var mediaWidthMM: Int { Int(raw[10]) }
    var errorCode: UInt16 { UInt16(raw[8]) | UInt16(raw[9]) << 8 }

    /// Printable dots across the tape, from ptouch-print's table (180 dpi).
    var tapeDots: Int? {
        [6: 32, 9: 52, 12: 76, 18: 120, 24: 128, 36: 192][mediaWidthMM]
    }

    /// Error bits in bytes 8 and 9 of the status reply. These names follow Brother's P-touch raster
    /// command references from memory and haven't been checked against the PT-P700 document;
    /// unknown bits fall back to the raw code.
    var errorMessages: [String] {
        let bits1: [(UInt8, String)] = [(0x01, "no tape"), (0x02, "end of tape"), (0x04, "cutter jam"),
                                        (0x08, "batteries weak"), (0x40, "wrong power adapter")]
        let bits2: [(UInt8, String)] = [(0x01, "wrong tape"), (0x10, "cover open"), (0x20, "overheating")]
        var messages = bits1.filter { raw[8] & $0.0 != 0 }.map(\.1) + bits2.filter { raw[9] & $0.0 != 0 }.map(\.1)
        if errorCode != 0 && messages.isEmpty {
            messages.append(String(format: "error 0x%04x", errorCode))
        }
        return messages
    }

    var summary: String {
        let tape = mediaWidthMM == 0 ? "no tape" : "\(mediaWidthMM) mm tape"
        let errors = errorMessages
        return errors.isEmpty ? "Ready, \(tape)" : "\(tape): \(errors.joined(separator: ", "))"
    }
}

/// Talks to a Brother PT-P700 over USB with the same command sequence ptouch-print uses,
/// which is known to work with this printer.
final class PTouchPrinter {
    private static let vendorID: UInt16 = 0x04f9
    private static let p700: UInt16 = 0x2061
    private static let p700EditorLite: UInt16 = 0x2064
    private static let outEndpoint: UInt8 = 0x02
    private static let inEndpoint: UInt8 = 0x81
    private static let timeoutMS: UInt32 = 5000

    private var context: OpaquePointer?
    private var handle: OpaquePointer?

    /// Opens the printer, runs `body`, and always releases the USB device afterwards.
    static func withPrinter<T>(_ body: (PTouchPrinter) throws -> T) throws -> T {
        let printer = PTouchPrinter()
        defer { printer.close() }
        try printer.open()
        return try body(printer)
    }

    private func open() throws {
        var r = libusb_init(&context)
        guard r == 0 else { throw PrinterError.usb("init", r) }

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        guard count >= 0, let list else { throw PrinterError.usb("device list", Int32(count)) }
        defer { libusb_free_device_list(list, 1) }

        var found: OpaquePointer?
        for i in 0..<Int(count) {
            guard let dev = list[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0, desc.idVendor == Self.vendorID else { continue }
            if desc.idProduct == Self.p700EditorLite { throw PrinterError.editorLiteMode }
            if desc.idProduct == Self.p700 { found = dev; break }
        }
        guard let found else { throw PrinterError.notFound }

        r = libusb_open(found, &handle)
        guard r == 0 else { throw PrinterError.usb("open", r) }
        if libusb_kernel_driver_active(handle, 0) == 1 {
            libusb_detach_kernel_driver(handle, 0)
        }
        r = libusb_claim_interface(handle, 0)
        guard r == 0 else { throw PrinterError.usb("claim interface", r) }
    }

    private func close() {
        if let handle {
            libusb_release_interface(handle, 0)
            libusb_close(handle)
        }
        if let context { libusb_exit(context) }
        handle = nil
        context = nil
    }

    private func send(_ bytes: [UInt8]) throws {
        var data = bytes
        var sent: Int32 = 0
        let r = libusb_bulk_transfer(handle, Self.outEndpoint, &data, Int32(data.count), &sent, Self.timeoutMS)
        guard r == 0 else { throw PrinterError.usb("write", r) }
        guard sent == data.count else { throw PrinterError.badStatus("short write \(sent)/\(data.count)") }
    }

    /// ESC @ (initialize), then ESC i S (status request); the reply is 32 bytes starting 80 20.
    func status() throws -> PrinterStatus {
        try send([0x1b, 0x40])
        try send([0x1b, 0x69, 0x53])
        var buf = [UInt8](repeating: 0, count: 32)
        for _ in 0..<10 {
            var got: Int32 = 0
            let r = libusb_bulk_transfer(handle, Self.inEndpoint, &buf, 32, &got, 500)
            if r == LIBUSB_ERROR_TIMEOUT.rawValue || (r == 0 && got == 0) {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            guard r == 0 else { throw PrinterError.usb("read", r) }
            guard got == 32, buf[0] == 0x80, buf[1] == 0x20 else {
                throw PrinterError.badStatus(buf.prefix(Int(got)).map { String(format: "%02x", $0) }.joined(separator: " "))
            }
            return PrinterStatus(raw: buf)
        }
        throw PrinterError.badStatus("no reply")
    }

    /// Prints one bitmap as a single job and cuts at the end.
    func print(_ bitmap: MonoBitmap) throws {
        let status = try status()
        guard status.errorMessages.isEmpty else { throw PrinterError.printerReportsError(status.errorMessages.joined(separator: ", ")) }
        if let dots = status.tapeDots, dots < MonoBitmap.headDots {
            // Narrower tape: make sure no ink falls outside the centered printable band.
            let margin = (MonoBitmap.headDots - dots) / 2
            for y in 0..<bitmap.height where y < margin || y >= bitmap.height - margin {
                if (0..<bitmap.width).contains(where: { bitmap[$0, y] }) {
                    throw PrinterError.tooWide(bitmap.height - 2 * margin, dots)
                }
            }
        }

        try send([0x4d, 0x02])              // M 02: PackBits compression on
        try send([0x1b, 0x69, 0x61, 0x01])  // ESC i a 01: raster mode
        for x in 0..<bitmap.width {
            let line = bitmap.rasterLine(column: x)
            // G nL nH, then one literal PackBits run (count-1) holding all 16 bytes.
            try send([0x47, UInt8(line.count + 1), 0x00, UInt8(line.count - 1)] + line)
        }
        try send([0x1a])                    // print and feed/cut
    }
}
