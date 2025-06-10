// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "XPCDistributedActorSystem",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "XPCDistributedActorSystem", targets: ["XPCDistributedActorSystem"]),
    ],
    dependencies: [
        .package(url: "https://github.com/zshannon/SwiftyXPC", from: "0.6.2")
    ],
    targets: [
        .target(
            name: "XPCDistributedActorSystem",
            dependencies: [
                .product(name: "SwiftyXPC", package: "SwiftyXPC")
            ]
        ),
    ]
)
