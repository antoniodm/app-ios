// swift-tools-version:5.9
import PackageDescription

// Wrapper locale per webrtc-sdk 144.7559.01 (H.265).
// Necessario perché il Package.swift upstream usa .visionOS(.v26)
// che richiede PackageDescription 6.2, incompatibile con swift-tools-version:5.9.
let package = Package(
    name: "WebRTC",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .macCatalyst(.v14),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "WebRTC", targets: ["WebRTC"]),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/webrtc-sdk/Specs/releases/download/144.7559.01/WebRTC.xcframework.zip",
            checksum: "d35084c018a846067d6176b8714bcc4fe21f461249c0e9c62b761b5bd17aa8c7"
        ),
    ]
)
