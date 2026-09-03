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
        .executable(name: "photoarchive-selftest", targets: ["photoarchive-selftest"])
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
            name: "photoarchive-selftest",
            dependencies: ["PhotoArchiveCore"]
        )
    ]
)
