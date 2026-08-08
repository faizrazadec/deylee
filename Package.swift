// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Deylee",
    platforms: [.macOS(.v14)],
    products: [
        // Exposed so tools can drive the core against a real database without the app.
        .library(name: "DeyleeKit", targets: ["DeyleeKit"]),
    ],
    targets: [
        // SQLCipher, vendored as its amalgamation and compiled here rather than
        // linked from the system. Apple's SQLite3 cannot encrypt, so the store's
        // key would have nowhere to go; SQLCipher is the standard encrypted build
        // of the same engine. Vendored, not a package dependency, so the root still
        // resolves nothing and builds with the Command Line Tools alone.
        //
        // The codec is turned on only where the store actually lives — the Apple
        // platforms, backed by CommonCrypto, which the SDK already carries. On Linux
        // the identical source compiles as plain SQLite: the server imports DeyleeKit
        // for the time and overlap rules, never to open a store, so encrypting a file
        // it never writes would only cost it a libcrypto dependency. The invariants
        // that must match across platforms are the time maths, not the storage layer.
        //
        // NDEBUG regardless: a SwiftPM debug build leaves C `assert()` live, but
        // SQLite guards the helper functions those asserts call behind SQLITE_DEBUG,
        // so with asserts on and SQLITE_DEBUG off the amalgamation calls functions it
        // never declared. Disabling the asserts is what a release build does anyway;
        // SQLite's internal asserts are for SQLite's own developers, never us.
        .target(
            name: "CSQLCipher",
            cSettings: [
                .define("SQLITE_TEMP_STORE", to: "2"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("NDEBUG"),
                .define("SQLITE_HAS_CODEC", .when(platforms: [.macOS, .iOS])),
                .define("SQLCIPHER_CRYPTO_CC", .when(platforms: [.macOS, .iOS])),
            ],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS, .iOS])),
            ]
        ),
        // Platform-free core: models, day-boundary time math, SQLite store, timer engine.
        .target(name: "DeyleeKit", dependencies: ["CSQLCipher"]),
        // The menu-bar app: NSStatusItem, popover panel, windows, power/idle monitors.
        .executableTarget(
            name: "Deylee",
            dependencies: ["DeyleeKit"]
        ),
        .testTarget(name: "DeyleeKitTests", dependencies: ["DeyleeKit"]),
    ]
)
