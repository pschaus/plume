// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Plume",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Plume", targets: ["Plume"])
    ],
    targets: [
        .executableTarget(
            name: "Plume",
            path: "Sources"
        )
    ]
)
