// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ICCCAlert",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "ICCCAlert",
            targets: ["ICCCAlert"]
        ),
    ],
    dependencies: [
        // Add Starscream for WebSocket support
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.8"),
    ],
    targets: [
        .target(
            name: "ICCCAlert",
            dependencies: ["Starscream"],
            path: "ICCCAlert"
        ),
    ]
)