// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenInsert",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OpenInsert", targets: ["OpenInsert"])],
    targets: [
        .target(name: "OpenInsertCore", resources: [.process("Resources")]),
        .executableTarget(name: "OpenInsert", dependencies: ["OpenInsertCore"]),
        .testTarget(name: "OpenInsertCoreTests", dependencies: ["OpenInsertCore"])
    ]
)
