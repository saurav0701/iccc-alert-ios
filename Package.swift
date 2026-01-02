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
            targets: ["ICCCAlert"]),
    ],
    dependencies: [
        // WebRTC from Google
        .package(url: "https://github.com/stasel/WebRTC.git", .upToNextMajor(from: "114.0.0"))
    ],
    targets: [
        .target(
            name: "ICCCAlert",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ]
        )
    ]
)