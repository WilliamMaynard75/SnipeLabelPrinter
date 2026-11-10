// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SnipeLabelPrinter",
    platforms: [.macOS(.v14)],
    targets: [
        // libusb sources taken from DavidPhillipOster's macOS port of ptouch-print (LGPL-2.1).
        .target(
            name: "CLibUSB",
            path: "Sources/CLibUSB",
            cSettings: [.unsafeFlags(["-w"])],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "SnipeLabelPrinter",
            dependencies: ["CLibUSB"],
            path: "Sources/SnipeLabelPrinter"
        ),
    ]
)
