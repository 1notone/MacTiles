// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacTiles",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacTiles", targets: ["MacTiles"])
    ],
    targets: [
        .executableTarget(
            name: "MacTiles",
            path: "Sources/MacTiles",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("QuickLookThumbnailing")
            ]
        ),
        .testTarget(
            name: "MacTilesTests",
            dependencies: ["MacTiles"],
            path: "Tests/MacTilesTests"
        )
    ]
)
