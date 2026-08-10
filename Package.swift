// swift-tools-version: 6.0
import PackageDescription

// Sparkle is a macOS framework, and this manifest is read on Linux too — the server
// package depends on this one for DeyleeKit, so `swift package resolve` inside the API's
// container evaluates everything declared here. A binary target pointing at a macOS
// XCFramework fails outright there ("does not contain a binary artifact"), and copying
// the framework into a Linux image to satisfy a manifest that will never build the app
// would be worse. So the app's updater exists only where an app can run.
#if os(macOS)
    let sparkleTargets: [Target] = [
        // Vendored as its XCFramework rather than fetched.
        //
        // A `binaryTarget` with a *path* resolves nothing over the network, so the root
        // package still builds with the Command Line Tools alone and still works with no
        // internet — the same reason SQLCipher is vendored rather than depended on.
        //
        // The distribution's dSYMs are 15 MB of symbols for Sparkle's own crashes,
        // needed neither to build nor to run, so they are stripped and the manifest's
        // reference to them removed. Updating Sparkle means repeating both.
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle.xcframework")
    ]
    let appDependencies: [Target.Dependency] = ["DeyleeKit", "Sparkle"]
#else
    let sparkleTargets: [Target] = []
    let appDependencies: [Target.Dependency] = ["DeyleeKit"]
#endif

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
            dependencies: appDependencies
        ),
        .testTarget(name: "DeyleeKitTests", dependencies: ["DeyleeKit"]),
    ] + sparkleTargets
)
