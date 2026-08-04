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
        // Platform-free core: models, day-boundary time math, SQLite store, timer engine.
        .target(name: "DeyleeKit"),
        // The menu-bar app: NSStatusItem, popover panel, windows, power/idle monitors.
        .executableTarget(
            name: "Deylee",
            dependencies: ["DeyleeKit"]
        ),
        .testTarget(name: "DeyleeKitTests", dependencies: ["DeyleeKit"]),
    ]
)
