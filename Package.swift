// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenInsert",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OpenInsert", targets: ["OpenInsert"])],
    targets: [
        .target(name: "OpenInsertCore"),
        .executableTarget(name: "OpenInsert", dependencies: ["OpenInsertCore"]),
        .testTarget(name: "OpenInsertCoreTests", dependencies: ["OpenInsertCore"])
    ]
)
