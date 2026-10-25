// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClashDashKit",
    platforms: [.iOS("18.0"), .macOS(.v14)],
    products: [.library(name: "ClashDashKit", targets: ["ClashDashKit"])],
    dependencies: [.package(path: "../../Vendor/Yams")],
    targets: [
        .target(name: "ClashDashKit", dependencies: ["Yams"]),
        .testTarget(name: "ClashDashKitTests", dependencies: ["ClashDashKit"])
    ]
)
