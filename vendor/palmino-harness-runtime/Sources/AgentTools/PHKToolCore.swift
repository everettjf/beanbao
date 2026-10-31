import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
#endif

public enum PHKToolError: Error, LocalizedError, Equatable, Sendable, PHKAgentErrorCategorizing {
    case unknownTool(String)
    case invalidArguments(String)
    case disabled(String)
    case permissionDenied(String)
    case executionFailed(String)
    case resultTooLarge(Int, Int)
    case stepLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)"
        case .invalidArguments(let message): return "Invalid tool arguments: \(message)"
        case .disabled(let message): return message
        case .permissionDenied(let message): return message
        case .executionFailed(let message): return message
        case .resultTooLarge(let actual, let limit): return "Tool result is too large (\(actual) bytes; limit \(limit))."
        case .stepLimitExceeded: return "The agent exceeded the tool step limit."
        }
    }

    public var agentErrorCategory: String { "tool_error" }
}

public protocol PHKNativeTool: Sendable {
    var definition: PHKToolDefinition { get }
    var executionMode: PHKToolExecutionMode { get }
    func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue
}

public extension PHKNativeTool {
    var executionMode: PHKToolExecutionMode { .serial }
}

/// A tool whose definition can appear or disappear as a runtime dependency
/// becomes healthy. Availability is intentionally synchronous because model
/// requests read tool definitions synchronously; hosts update the shared state
/// after their asynchronous health checks complete.
public protocol PHKConditionalToolAvailability: Sendable {
    var isToolAvailable: Bool { get }
    var toolUnavailableReason: String { get }
}

public struct PHKAvailabilityGatedTool: PHKNativeTool, PHKConditionalToolAvailability {
    public let definition: PHKToolDefinition
    public var executionMode: PHKToolExecutionMode { tool.executionMode }
    public var isToolAvailable: Bool { availability() }
    public let toolUnavailableReason: String

    private let tool: any PHKNativeTool
    private let availability: @Sendable () -> Bool

    public init(
        _ tool: any PHKNativeTool,
        unavailableReason: String,
        isAvailable: @escaping @Sendable () -> Bool
    ) {
        self.tool = tool
        self.definition = tool.definition
        self.toolUnavailableReason = unavailableReason
        self.availability = isAvailable
    }

    public func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue {
        guard isToolAvailable else { throw PHKToolError.disabled(toolUnavailableReason) }
        return try await tool.execute(arguments: arguments)
    }
}

public final class PHKToolRegistry: @unchecked Sendable, PHKToolProviding {
    private let lock = NSLock()
    private var tools: [String: any PHKNativeTool]
    private let resultPolicy: ToolResultPolicy
    private let resultOffloader: (any ToolResultOffloading)?

    public init(
        _ tools: [any PHKNativeTool] = [],
        resultPolicy: ToolResultPolicy = .init(),
        resultOffloader: (any ToolResultOffloading)? = nil
    ) {
        self.tools = Dictionary(tools.map { ($0.definition.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.resultPolicy = resultPolicy
        self.resultOffloader = resultOffloader
    }

    public var definitions: [PHKToolDefinition] {
        lock.withLock {
            tools.values.filter(Self.isAvailable).map(\.definition).sorted { $0.name < $1.name }
        }
    }

    public func executionMode(for toolName: String) -> PHKToolExecutionMode {
        lock.withLock { tools[toolName]?.executionMode ?? .serial }
    }

    public func preflight(_ call: PHKToolCall) -> String? {
        guard let tool = lock.withLock({ tools[call.name] }) else {
            return "Unknown tool: \(call.name)"
        }
        if let conditional = tool as? any PHKConditionalToolAvailability,
           !conditional.isToolAvailable {
            return conditional.toolUnavailableReason
        }
        do {
            let arguments = try decodeArguments(call.arguments)
            return JSONSchemaValidator.validate(arguments, against: tool.definition.parameters)
        } catch {
            return error.localizedDescription
        }
    }

    public func replaceTools(withPrefix prefix: String, with replacements: [any PHKNativeTool]) {
        lock.withLock {
            tools = tools.filter { !$0.key.hasPrefix(prefix) }
            for tool in replacements { tools[tool.definition.name] = tool }
        }
    }

    public func execute(_ call: PHKToolCall) async -> String {
        let tool = lock.withLock { tools[call.name] }
        guard let tool else {
            return encodeError(PHKToolError.unknownTool(call.name))
        }
        if let conditional = tool as? any PHKConditionalToolAvailability,
           !conditional.isToolAvailable {
            return encodeError(PHKToolError.disabled(conditional.toolUnavailableReason))
        }
        do {
            let arguments = try decodeArguments(call.arguments)
            let result = resultPolicy.redact(try await tool.execute(arguments: arguments))
            let envelope: PHKJSONValue = .object(["ok": .bool(true), "result": result])
            let data = try JSONEncoder().encode(envelope)
            guard data.count > resultPolicy.maximumInlineBytes else {
                return String(decoding: data, as: UTF8.self)
            }
            guard let resultOffloader else {
                return encodeError(PHKToolError.resultTooLarge(data.count, resultPolicy.maximumInlineBytes))
            }
            let reference = try await resultOffloader.store(result, suggestedName: "\(call.name)-result.json")
            return encode([
                "ok": .bool(true),
                "result": .object(["offloaded": .bool(true), "reference": reference])
            ])
        } catch {
            let redactedError = resultPolicy.redact(.object([
                "message": .string(error.localizedDescription)
            ]))
            let envelope: PHKJSONValue = .object([
                "ok": .bool(false), "error": redactedError
            ])
            if let data = try? JSONEncoder().encode(envelope),
               data.count > resultPolicy.maximumInlineBytes,
               let resultOffloader,
               let reference = try? await resultOffloader.store(
                   redactedError, suggestedName: "\(call.name)-error.json"
               ) {
                return encode([
                    "ok": .bool(false),
                    "error": .string("Tool failed; the full diagnostic was stored as an artifact."),
                    "error_reference": reference
                ])
            }
            return encodeError(error)
        }
    }

    private func decodeArguments(_ encoded: String) throws -> PHKJSONValue {
        if encoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .object([:]) }
        guard let data = encoded.data(using: .utf8) else {
            throw PHKToolError.invalidArguments("Arguments are not UTF-8.")
        }
        do {
            return try JSONDecoder().decode(PHKJSONValue.self, from: data)
        } catch {
            throw PHKToolError.invalidArguments("Expected a JSON value.")
        }
    }

    private static func isAvailable(_ tool: any PHKNativeTool) -> Bool {
        (tool as? any PHKConditionalToolAvailability)?.isToolAvailable ?? true
    }

    private func encodeError(_ error: Error) -> String {
        encode(["ok": .bool(false), "error": .string(error.localizedDescription)])
    }

    private func encode(_ object: [String: PHKJSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(PHKJSONValue.object(object)) else {
            return "{\"ok\":false,\"error\":\"Could not encode tool result.\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
