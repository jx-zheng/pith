// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PithCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PithCore", targets: ["PithCore"])
    ],
    targets: [
        .target(
            name: "PithCore",
            path: "Sources/PithCore"
        ),
        .testTarget(
            name: "PithCoreTests",
            dependencies: ["PithCore"],
            path: "Tests/PithCoreTests"
        )
    ]
)
