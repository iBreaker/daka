// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Daka",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "daka", targets: ["Daka"])
    ],
    targets: [
        .target(
            name: "DakaCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "Daka",
            dependencies: ["DakaCore"]
        ),
        .testTarget(
            name: "DakaCoreTests",
            dependencies: ["DakaCore"]
        )
    ]
)
