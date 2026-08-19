// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanqieZhong",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FanqieZhong", targets: ["FanqieZhong"])
    ],
    targets: [
        .executableTarget(name: "FanqieZhong"),
        .testTarget(name: "FanqieZhongTests", dependencies: ["FanqieZhong"])
    ]
)
