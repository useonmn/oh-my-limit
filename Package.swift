// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OhMyLimit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OhMyLimit", targets: ["OhMyLimit"]),
        .library(name: "OhMyLimitCore", targets: ["OhMyLimitCore"]),
    ],
    targets: [
        .target(name: "OhMyLimitCore", exclude: ["AGENTS.md"]),
        .executableTarget(name: "OhMyLimit", dependencies: ["OhMyLimitCore"]),
        .testTarget(name: "OhMyLimitCoreTests", dependencies: ["OhMyLimitCore"], exclude: ["AGENTS.md"]),
    ]
)
