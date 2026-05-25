// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JARVISPromptInjectionAdversarial",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PromptInjectionRunner", targets: ["PromptInjectionRunner"]),
    ],
    dependencies: [
        .package(path: "../../../../JARVISMacCockpit/Dialog"),
    ],
    targets: [
        .executableTarget(
            name: "PromptInjectionRunner",
            dependencies: [.product(name: "JARVISDialog", package: "Dialog")],
            path: "Sources/PromptInjectionRunner"
        ),
    ]
)
