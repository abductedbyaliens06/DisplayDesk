// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "DisplayDesk",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "DisplayDesk", targets: ["DisplayDesk"])],
    dependencies: [.package(url: "https://github.com/taketaku/MacBrightnessKit.git", exact: "0.1.0")],
    targets: [
        .target(name: "DisplayDeskCore"),
        .executableTarget(name: "DisplayDesk", dependencies: ["DisplayDeskCore", .product(name: "MacBrightnessKit", package: "MacBrightnessKit")]),
        .testTarget(name: "DisplayDeskCoreTests", dependencies: ["DisplayDeskCore"])
    ],
    swiftLanguageModes: [.v6]
)
