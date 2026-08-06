// swift-tools-version: 6.0
import PackageDescription

// The sync API.
//
// Deliberately a separate package from the app at the repository root. That one
// builds with the Command Line Tools and nothing else — no network, no resolution
// step — and it is worth keeping that way: Hummingbird, JWTKit and PostgresNIO
// pull in NIO and swift-crypto, none of which a menu-bar app has any use for.
//
// DeyleeKit arrives by path rather than by version. The whole point of the server
// being Swift is that the day-boundary maths, the overlap rules and the midnight
// split are the *same code* the Mac app runs, not a port of it that drifts.
//
// The `name:` on that path dependency is not decoration. Without it SwiftPM derives
// a path dependency's identity from the *directory name*, which makes resolution
// depend on what the checkout happens to be called: it broke the moment a container
// copied the tree to /src, and it would break again the day this folder is renamed
// to match the app. Naming it pins the identity to something the manifest controls.
let package = Package(
    name: "DeyleeServer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Deylee", path: ".."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    ],
    targets: [
        .executableTarget(
            name: "DeyleeAPI",
            dependencies: [
                .product(name: "DeyleeKit", package: "Deylee"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .testTarget(
            name: "DeyleeAPITests",
            dependencies: [
                "DeyleeAPI",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
