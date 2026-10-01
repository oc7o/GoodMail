// swift-tools-version: 6.1
import PackageDescription

// GRDB built against SQLCipher instead of the system SQLite.
//
// Upstream GRDB can only be combined with SQLCipher by editing its Package.swift (see the
// "GRDB+SQLCipher" comments there). This manifest is that edit, kept next to an unmodified upstream
// checkout in ./GRDB.swift (a git submodule), so no fork is needed. When bumping the submodule,
// compare the settings below with upstream's manifest.
let package = Package(
    name: "GRDBSQLCipher",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "GRDB", targets: ["GRDB"]),
    ],
    dependencies: [
        // A prebuilt xcframework published by Zetetic, the SQLCipher maintainers. Pinned on purpose.
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.19.0"),
    ],
    targets: [
        .target(
            name: "GRDBSQLCipher",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")],
            path: "GRDB.swift/Sources/GRDBSQLCipher"),
        .target(
            name: "GRDB",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .target(name: "GRDBSQLCipher"),
            ],
            path: "GRDB.swift/GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            cSettings: [.define("SQLITE_HAS_CODEC")],
            swiftSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_SNAPSHOT"),
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCipher"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
