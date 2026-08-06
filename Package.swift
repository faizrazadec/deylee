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
        // SQLite's C API on platforms that do not ship it as a Swift module.
        // Apple's SDKs have `SQLite3`; Linux has only the C library, and the server
        // imports this package for the time and overlap rules it must enforce.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        // Platform-free core: models, day-boundary time math, SQLite store, timer engine.
        .target(name: "DeyleeKit", dependencies: ["CSQLite"]),
        // The menu-bar app: NSStatusItem, popover panel, windows, power/idle monitors.
        .executableTarget(
            name: "Deylee",
            dependencies: ["DeyleeKit"]
        ),
        .testTarget(name: "DeyleeKitTests", dependencies: ["DeyleeKit"]),
    ]
)
