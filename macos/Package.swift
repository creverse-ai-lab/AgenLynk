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
        // Contract-level code both executables must agree on byte-for-byte.
        .target(
            name: "ACPShared",
            path: "Sources/ACPShared"
        ),
        // Artwork both executables draw: the ACP mark and the mascot.
        .target(
            name: "LynkArt",
            path: "Sources/LynkArt"
        ),
        .executableTarget(
            name: "ACPMonitor",
            dependencies: ["ACPShared", "LynkArt"],
            path: "Sources/ACPMonitor"
        ),
        .executableTarget(
            name: "LynkPet",
            dependencies: ["ACPShared", "LynkArt"],
            path: "Sources/LynkPet",
            resources: [.process("Resources")]
        )
    ]
)
