// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WakeMemoryAgentSample",
    products: [
        .library(name: "WakeMemoryAgentCore", targets: ["WakeMemoryAgentCore"]),
        .executable(name: "WakeMemoryDemo", targets: ["WakeMemoryDemo"])
    ],
    targets: [
        .target(name: "WakeMemoryAgentCore"),
        .executableTarget(name: "WakeMemoryDemo", dependencies: ["WakeMemoryAgentCore"]),
        .testTarget(name: "WakeMemoryAgentCoreTests", dependencies: ["WakeMemoryAgentCore"])
    ]
)
