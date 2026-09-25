// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "local_peer_connections",
    platforms: [
        .iOS("12.0"),
    ],
    products: [
        .library(name: "local-peer-connections", targets: ["local_peer_connections"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "local_peer_connections",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
        ),
    ]
)
