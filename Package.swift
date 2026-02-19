// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "USBHostKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "USBHostKit", targets: ["USBHostKit"])],
    dependencies: [/*add-as-needed*/],
    targets: [
        .target(
            name: "USBHostKit",
            dependencies: [/*add-as-needed*/],
            path: "Sources/USBHostKit",
            swiftSettings: [.define("USB_HOST_KIT")],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("IOUSBHost")]
        ),
        .testTarget(
            name: "USBHostKitTests",
            dependencies: ["USBHostKit"],
            path: "Tests/USBHostKitTests"
        )
    ]
)
