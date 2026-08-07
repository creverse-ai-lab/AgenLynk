// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ACPMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ACPMonitor", targets: ["ACPMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "ACPMonitor",
            path: "Sources/ACPMonitor"
        )
    ]
)
