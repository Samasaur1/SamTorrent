// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SamTorrent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SamTorrent", targets: ["BasicClient"])
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox", from: "0.21.0"),
        .package(url: "https://github.com/Samasaur1/BencodeKit", branch: "main"),
        .package(url: "https://github.com/onevcat/Rainbow", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "3.0.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "BasicClient",
            dependencies: [
                "SamTorrent",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ]
        ),
        .target(
            name: "SamTorrent",
            dependencies: [
                .product(name: "FlyingSocks", package: "FlyingFox"),
                .product(name: "BencodeKit", package: "BencodeKit"),
                .product(name: "Rainbow", package: "Rainbow"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "SamTorrentTests",
            dependencies: [
                "SamTorrent"
            ],
        ),
    ]
)
