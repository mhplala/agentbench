// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentBench",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentBench", targets: ["AgentBench"])
    ],
    targets: [
        .executableTarget(
            name: "AgentBench",
            path: "Sources/AgentBench",
            linkerSettings: [
                .linkedLibrary("sqlite3")   // read cc-switch's provider DB
            ]
        )
    ]
)
