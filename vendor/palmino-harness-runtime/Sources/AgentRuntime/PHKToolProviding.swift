import Foundation

public enum PHKToolExecutionMode: String, Codable, Equatable, Sendable {
    case serial
    case concurrent
}

/// The minimal tool surface required by AgentRuntime. Concrete registries,
/// governance and platform tools live in AgentTools or higher-level modules.
public protocol PHKToolProviding: Sendable {
    var definitions: [PHKToolDefinition] { get }
    func executionMode(for toolName: String) -> PHKToolExecutionMode
    func preflight(_ call: PHKToolCall) -> String?
    func execute(_ call: PHKToolCall) async -> String
}

public extension PHKToolProviding {
    func executionMode(for toolName: String) -> PHKToolExecutionMode { .serial }
    func preflight(_ call: PHKToolCall) -> String? { nil }
}
