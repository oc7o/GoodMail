// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "GoodMailKit",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "JMAPKit", targets: ["JMAPKit"]),
        .library(name: "MailPrivacy", targets: ["MailPrivacy"]),
        .library(name: "MailCompose", targets: ["MailCompose"]),
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
        .testTarget(
            name: "JMAPKitTests",
            dependencies: ["JMAPKit"],
            resources: [.copy("Fixtures")]
        ),
        .target(name: "MailPrivacy"),
        .testTarget(name: "MailPrivacyTests", dependencies: ["MailPrivacy"]),
        // The message being written: rich text, the HTML and text it becomes, replies and forwards.
        // It imports SwiftUI because the editor's text attributes (fonts, colors) are SwiftUI's.
        .target(name: "MailCompose", dependencies: ["JMAPKit", "MailPrivacy"]),
        .testTarget(name: "MailComposeTests", dependencies: ["MailCompose", "JMAPKit", "MailPrivacy"]),
        .target(name: "MailStore", dependencies: ["JMAPKit", .product(name: "GRDB", package: "GRDBSQLCipher")]),
        .testTarget(name: "MailStoreTests", dependencies: ["MailStore"]),
        .target(name: "GoodMailCore", dependencies: ["JMAPKit", "MailStore", "MailPrivacy", "MailCompose"]),
        .testTarget(
            name: "GoodMailCoreTests",
            dependencies: ["GoodMailCore", "MailStore", "MailPrivacy", "MailCompose", "DemoAccount"]
        ),
        .target(name: "DemoAccount", dependencies: ["JMAPKit"]),
        .testTarget(name: "DemoAccountTests", dependencies: ["DemoAccount", "JMAPKit"]),
    ]
)
