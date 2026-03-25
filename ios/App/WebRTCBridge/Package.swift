// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WebRTCBridge",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "WebRTCBridge", targets: ["WebRTCBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/webrtc-sdk/Specs.git", exact: "144.7559.01")
    ],
    targets: [
        .target(
            name: "WebRTCBridge",
            dependencies: [
                .product(name: "WebRTC", package: "Specs")
            ]
        )
    ]
)
