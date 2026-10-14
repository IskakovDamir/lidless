// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lidless",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Lidless", targets: ["Lidless"]),
        .executable(name: "lidlessd", targets: ["lidlessd"])
    ],
    targets: [
        .target(name: "LidlessCore"),
        .executableTarget(name: "lidlessd", dependencies: ["LidlessCore"]),
        .executableTarget(name: "Lidless", dependencies: ["LidlessCore"]),
        .testTarget(name: "LidlessCoreTests", dependencies: ["LidlessCore"])
    ]
)
