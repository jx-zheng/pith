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
    ] + pithEngineTargets()
)

/// App/Engine imports AppKit, so `swift test` on Linux builds PithCore only.
/// On macOS the engine target and its tests are part of the package.
func pithEngineTargets() -> [Target] {
    #if os(macOS)
    return [
        .target(
            name: "PithEngine",
            dependencies: ["PithCore"],
            path: "App/Engine",
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Quartz")
            ]
        ),
        .testTarget(
            name: "PithEngineTests",
            dependencies: ["PithEngine", "PithCore"],
            path: "Tests/PithEngineTests"
        )
    ]
    #else
    return []
    #endif
}
