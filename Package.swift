// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OrbitSDK",
    platforms: [.iOS(.v13), .macOS(.v12)],
    products: [.library(name: "OrbitSDK", targets: ["OrbitSDK"])],
    targets: [
        .target(name: "OrbitSDK"),
        .testTarget(name: "OrbitSDKTests", dependencies: ["OrbitSDK"]),
    ],
    swiftLanguageModes: [.v5]
)
