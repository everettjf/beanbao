// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BeanBaoTextHarness",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "BeanBaoTextHarness", targets: ["BeanBaoTextHarness"])],
    targets: [
        .target(name: "AgentRuntime", path: "vendor/palmino-harness-runtime/Sources/AgentRuntime"),
        .target(name: "BeanBaoTextHarness", dependencies: ["AgentRuntime"], path: "harness"),
        .testTarget(name: "BeanBaoTextHarnessTests", dependencies: ["BeanBaoTextHarness", "AgentRuntime"], path: "tests/text-harness")
    ]
)
