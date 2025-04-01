// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "testbed",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox", from: "0.21.0"),
        .package(url: "https://github.com/Samasaur1/BencodeKit", branch: "main"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "testbed",
            dependencies: [
                .product(name: "FlyingSocks", package: "FlyingFox"),
                .product(name: "BencodeKit", package: "BencodeKit"),
            ]
        ),
    ]
)
