// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BeanBaoTextHarness",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "BeanBaoTextHarness", targets: ["BeanBaoTextHarness"])],
    targets: [
        .target(name: "AgentRuntime", path: "vendor/palmino-harness-runtime/Sources/AgentRuntime"),
        .target(name: "AgentTools", dependencies: ["AgentRuntime"], path: "vendor/palmino-harness-runtime/Sources/AgentTools"),
        .target(name: "BeanBaoTextHarness", dependencies: ["AgentRuntime", "AgentTools"], path: "harness"),
        .testTarget(name: "BeanBaoTextHarnessTests", dependencies: ["BeanBaoTextHarness", "AgentRuntime", "AgentTools"], path: "tests/text-harness")
    ]
)
