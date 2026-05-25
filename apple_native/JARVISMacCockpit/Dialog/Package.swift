// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JARVISDialog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JARVISDialog", targets: ["JARVISDialog"]),
    ],
    targets: [
        .target(name: "JARVISDialog"),
        .executableTarget(name: "DialogPolicyTestRunner", dependencies: ["JARVISDialog"]),
        .testTarget(name: "JARVISDialogTests", dependencies: ["JARVISDialog"]),
    ]
)
