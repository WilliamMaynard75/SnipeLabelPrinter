import AppKit
import SwiftUI

struct SnipeLabelApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Snipe-IT Label Printer") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}

/// Command-line modes, handy for testing without the window:
///   --render in.pdf out.png   render a label to the 1-bit image that would print
///   --status                  show what the printer reports
///   --print in.pdf...         print labels as one chained job
///   --tag 90167 out.png       fetch a label from Snipe-IT and render it
func runCommandLine(_ args: [String]) -> Int32? {
    guard let mode = args.first, mode.hasPrefix("--") else { return nil }
    do {
        switch mode {
        case "--render" where args.count == 3:
            let pdf = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            let bitmap = try LabelRenderer.render(pdf: pdf, options: RenderOptions())
            try bitmap.writePNG(to: URL(fileURLWithPath: args[2]))
            print("\(bitmap.width) x \(bitmap.height) dots, \(String(format: "%.1f", bitmap.lengthMM)) mm")
        case "--tag" where args.count == 3:
            let client = try SnipeITClient.fromSettings()
            let (tag, pdf) = try waitFor { try await client.label(for: args[1]) }
            let bitmap = try LabelRenderer.render(pdf: pdf, options: RenderOptions())
            try bitmap.writePNG(to: URL(fileURLWithPath: args[2]))
            print("\(tag): \(LabelRenderer.pageCount(of: pdf)) page(s), \(bitmap.width) x \(bitmap.height) dots")
        case "--status":
            let status = try PTouchPrinter.withPrinter { try $0.status() }
            print(status.summary)
            print(status.raw.map { String(format: "%02x", $0) }.joined(separator: " "))
        case "--print" where args.count >= 2:
            let labels = try args.dropFirst().map {
                try LabelRenderer.render(pdf: Data(contentsOf: URL(fileURLWithPath: $0)), options: RenderOptions())
            }
            let job = MonoBitmap.chain(labels, gap: MonoBitmap.dots(mm: 2), cutMarks: true)!
                .padded(trailing: MonoBitmap.dots(mm: 20))
            try PTouchPrinter.withPrinter { try $0.print(job) }
            print("Sent \(job.width) lines (\(String(format: "%.0f", job.lengthMM)) mm)")
        default:
            print("usage: SnipeLabelPrinter [--render in.pdf out.png | --status | --print in.pdf... | --tag TAG out.png]")
            return 2
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

/// Blocks the command-line run until async work finishes.
func waitFor<T>(_ work: @escaping () async throws -> T) throws -> T {
    var result: Result<T, Error>!
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try result.get()
}

// Xcode passes -NSDocumentRevisionsDebugMode etc.; only our own "--" flags trigger CLI mode.
if let code = runCommandLine(Array(CommandLine.arguments.dropFirst())) {
    exit(code)
}
NSApplication.shared.setActivationPolicy(.regular)
SnipeLabelApp.main()
