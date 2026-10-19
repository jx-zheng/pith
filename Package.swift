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
        // The app's headless conversion code (App/Engine), compiled a second time as a
        // module so the integration suite exercises exactly what Pith.app runs.
        // The app target compiles these same files directly; it does not link this module.
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
            name: "PithCoreTests",
            dependencies: ["PithCore"],
            path: "Tests/PithCoreTests"
        ),
        .testTarget(
            name: "PithEngineTests",
            dependencies: ["PithEngine", "PithCore"],
            path: "Tests/PithEngineTests"
        )
    ]
)
