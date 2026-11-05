// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BuildRemoto",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BuildRemoto", path: "Sources")
    ]
)
