// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DSHDesktopCore", targets: ["DSHDesktopCore"]),
        .executable(name: "DSHDesktop", targets: ["DSHDesktopApp"]),
        .executable(name: "DSHDesktopVerification", targets: ["DSHDesktopVerification"]),
    ],
    targets: [
        .target(
            name: "DSHDesktopCore",
            path: "Sources/DSHDesktopCore"
        ),
        .executableTarget(
            name: "DSHDesktopApp",
            dependencies: ["DSHDesktopCore"],
            path: "Sources/DSHDesktopApp"
        ),
        .executableTarget(
            name: "DSHDesktopVerification",
            dependencies: ["DSHDesktopCore"],
            path: "Sources/DSHDesktopVerification"
        ),
    ]
)
