// swift-tools-version: 6.1
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
        .package(url: "https://github.com/zshannon/SwiftyXPC", from: "0.6.2"),
        .package(url: "https://github.com/apple/swift-testing", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "XPCDistributedActorSystem",
            dependencies: [
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
            ],
        ),
        .testTarget(
            name: "XPCDistributedActorSystemTests",
            dependencies: [
                "XPCDistributedActorSystem",
                .product(name: "Testing", package: "swift-testing"),
            ],
        ),
    ],
)
