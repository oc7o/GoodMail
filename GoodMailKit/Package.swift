// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoodMailKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "JMAPKit", targets: ["JMAPKit"]),
        .library(name: "MailPrivacy", targets: ["MailPrivacy"]),
        .library(name: "GoodMailCore", targets: ["GoodMailCore"]),
        .library(name: "DemoAccount", targets: ["DemoAccount"]),
    ],
    targets: [
        .target(name: "JMAPKit"),
        .target(name: "MailPrivacy"),
        .testTarget(name: "MailPrivacyTests", dependencies: ["MailPrivacy"]),
        .target(name: "GoodMailCore", dependencies: ["JMAPKit"]),
        .target(name: "DemoAccount", dependencies: ["JMAPKit"]),
        .testTarget(name: "GoodMailCoreTests", dependencies: ["GoodMailCore", "DemoAccount"]),
        .testTarget(
            name: "JMAPKitTests",
            dependencies: ["JMAPKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
