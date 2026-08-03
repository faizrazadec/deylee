// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dayly",
    platforms: [.macOS(.v14)],
    products: [
        // Exposed so tools can drive the core against a real database without the app.
        .library(name: "DaylyKit", targets: ["DaylyKit"]),
    ],
    targets: [
        // Platform-free core: models, day-boundary time math, SQLite store, timer engine.
        .target(name: "DaylyKit"),
        // The menu-bar app: NSStatusItem, popover panel, windows, power/idle monitors.
        .executableTarget(
            name: "Dayly",
            dependencies: ["DaylyKit"]
        ),
        .testTarget(name: "DaylyKitTests", dependencies: ["DaylyKit"]),
    ]
)
