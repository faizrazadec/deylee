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
// Note the package identity below: for a path dependency SwiftPM derives it from
// the *directory name*, not from the `name:` in the manifest it points at. The
// repository directory is still `dayly.faizraza.me`, so that is the identity here.
// Renaming the directory will break resolution with an "unknown package" error
// naming the new one, and this line is what needs to change.
let package = Package(
    name: "DeyleeServer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    ],
    targets: [
        .executableTarget(
            name: "DeyleeAPI",
            dependencies: [
                .product(name: "DeyleeKit", package: "dayly.faizraza.me"),
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
