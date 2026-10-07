// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SumiPaint",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "DrawingCore", targets: ["DrawingCore"])],
    dependencies: [],
    targets: [
        .target(name: "DrawingCore"),
        .testTarget(name: "DrawingCoreTests", dependencies: ["DrawingCore"])
    ]
)
