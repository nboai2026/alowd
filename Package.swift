// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Alowd",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlowdCore", targets: ["AlowdCore"]),
        .executable(name: "AlowdApp", targets: ["AlowdApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "AlowdCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        .executableTarget(
            name: "AlowdApp",
            dependencies: ["AlowdCore"]
        ),
        .testTarget(
            name: "AlowdCoreTests",
            dependencies: ["AlowdCore"]
        )
    ]
)
