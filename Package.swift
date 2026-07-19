// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DeskBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeskBar", targets: ["DeskBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.5.2")
    ],
    targets: [
        .executableTarget(
            name: "DeskBar",
            dependencies: [
                .product(name: "Lottie", package: "lottie-spm")
            ]
        ),
        .testTarget(name: "DeskBarTests", dependencies: ["DeskBar"])
    ]
)
