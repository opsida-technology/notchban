// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "notchban",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "NotchbanCore"),
        .executableTarget(name: "notchban", dependencies: ["NotchbanCore"]),
        .testTarget(name: "NotchbanCoreTests", dependencies: ["NotchbanCore"]),
    ]
)
