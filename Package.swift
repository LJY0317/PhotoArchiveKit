// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoArchiveKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PhotoArchiveCore", targets: ["PhotoArchiveCore"]),
        .executable(name: "photoarchive", targets: ["photoarchive"]),
        .executable(name: "photoarchive-review", targets: ["photoarchive-review"]),
        .executable(name: "photoarchive-selftest", targets: ["photoarchive-selftest"]),
        .executable(name: "photoarchive-bisync-selftest", targets: ["photoarchive-bisync-selftest"])
    ],
    targets: [
        .target(
            name: "PhotoArchiveCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ImageIO")
            ]
        ),
        .executableTarget(
            name: "photoarchive",
            dependencies: ["PhotoArchiveCore"]
        ),
        .executableTarget(
            name: "photoarchive-review",
            dependencies: ["PhotoArchiveCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuickLookThumbnailing")
            ]
        ),
        .executableTarget(
            name: "photoarchive-selftest",
            dependencies: ["PhotoArchiveCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "photoarchive-bisync-selftest",
            dependencies: ["PhotoArchiveCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ImageIO")
            ]
        )
    ]
)
