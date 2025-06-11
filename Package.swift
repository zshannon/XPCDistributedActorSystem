// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "XPCDistributedActorSystem",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "XPCDistributedActorSystem", targets: ["XPCDistributedActorSystem"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/Semaphore", from: "0.1.0"),
        .package(url: "https://github.com/mattmassicotte/Queue", from: "0.2.1"),
        .package(
            url: "https://github.com/pointfreeco/swift-dependencies", .upToNextMajor(from: "1.9.1"),
        ),
    ],
    targets: [
        .target(
            name: "XPCDistributedActorSystem",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Queue", package: "Queue"),
                .product(name: "Semaphore", package: "Semaphore"),
            ],
        ),
        .testTarget(
            name: "XPCDistributedActorSystemTests",
            dependencies: ["XPCDistributedActorSystem"],
        ),
    ],
)

let swiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableExperimentalFeature("IsolatedAny"),
    // .enableUpcomingFeature("InferSendableFromCaptures"),
    .swiftLanguageMode(.v6),
]

for target in package.targets {
    var settings = target.swiftSettings ?? []
    settings.append(contentsOf: swiftSettings)
    target.swiftSettings = settings
}
