// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Trimmer",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Trimmer", targets: ["Trimmer"])],
    targets: [
        .target(name: "TrimmerCore"),
        .executableTarget(name: "Trimmer", dependencies: ["TrimmerCore"]),
        .testTarget(name: "TrimmerCoreTests", dependencies: ["TrimmerCore"]),
        .testTarget(name: "TrimmerTests", dependencies: ["Trimmer", "TrimmerCore"])
    ]
)
