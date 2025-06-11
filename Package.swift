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
        .package(url: "https://github.com/apple/swift-testing", from: "0.4.0"),
        .package(url: "https://github.com/groue/Semaphore", from: "0.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", .upToNextMajor(from: "1.9.1")),
        .package(url: "https://github.com/zshannon/SwiftyXPC", from: "0.6.2"),
    ],
    targets: [
        .target(
            name: "XPCDistributedActorSystem",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Semaphore", package: "Semaphore"),
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
