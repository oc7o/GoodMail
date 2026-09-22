// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoodMailKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "JMAPKit", targets: ["JMAPKit"]),
    ],
    targets: [
        .target(name: "JMAPKit"),
        .testTarget(
            name: "JMAPKitTests",
            dependencies: ["JMAPKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
