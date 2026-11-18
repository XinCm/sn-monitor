// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sn-monitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "sn-monitor", targets: ["SNMonitorApp"]),
        .executable(name: "snctl", targets: ["snctl"]),
        .library(name: "SNMonitorCore", targets: ["SNMonitorCore"]),
    ],
    targets: [
        .target(
            name: "SNMonitorCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "SNMonitorApp",
            dependencies: ["SNMonitorCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "snctl",
            dependencies: ["SNMonitorCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "SNMonitorCoreTests",
            dependencies: ["SNMonitorCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
