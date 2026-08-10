// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ACPMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ACPMonitor", targets: ["ACPMonitor"]),
        .executable(name: "LynkPet", targets: ["LynkPet"])
    ],
    targets: [
        .executableTarget(
            name: "ACPMonitor",
            path: "Sources/ACPMonitor"
        ),
        .executableTarget(
            name: "LynkPet",
            path: "Sources/LynkPet",
            resources: [.process("Resources")]
        )
    ]
)
