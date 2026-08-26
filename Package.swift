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
    dependencies: [
        // SwiftTerm 的 LocalProcessTerminalView 基于 forkpty 提供真实交互式 PTY。
        // 固定版本，避免发布构建在未审查的上游更新后发生行为漂移。
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        .target(
            name: "DSHDesktopCore",
            path: "Sources/DSHDesktopCore"
        ),
        .executableTarget(
            name: "DSHDesktopApp",
            dependencies: [
                "DSHDesktopCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/DSHDesktopApp"
        ),
        .executableTarget(
            name: "DSHDesktopVerification",
            dependencies: [
                "DSHDesktopCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/DSHDesktopVerification"
        ),
    ]
)
