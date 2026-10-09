// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "GoodMailKit",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "JMAPKit", targets: ["JMAPKit"]),
        .library(name: "MailPrivacy", targets: ["MailPrivacy"]),
        .library(name: "MailStore", targets: ["MailStore"]),
        .library(name: "GoodMailCore", targets: ["GoodMailCore"]),
        .library(name: "DemoAccount", targets: ["DemoAccount"]),
    ],
    dependencies: [
        // GRDB built against SQLCipher; see the manifest there for why this is a local package.
        .package(path: "../Vendor/GRDBSQLCipher"),
    ],
    targets: [
        .target(name: "JMAPKit"),
        .target(name: "MailPrivacy"),
        .testTarget(name: "MailPrivacyTests", dependencies: ["MailPrivacy"]),
        .target(name: "MailStore", dependencies: ["JMAPKit", .product(name: "GRDB", package: "GRDBSQLCipher")]),
        .testTarget(name: "MailStoreTests", dependencies: ["MailStore"]),
        .target(name: "GoodMailCore", dependencies: ["JMAPKit", "MailStore"]),
        .target(name: "DemoAccount", dependencies: ["JMAPKit"]),
        .testTarget(name: "GoodMailCoreTests", dependencies: ["GoodMailCore", "MailStore", "DemoAccount"]),
        .testTarget(
            name: "JMAPKitTests",
            dependencies: ["JMAPKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
