import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
#endif

public enum PHKToolPermissionGate: Equatable, Sendable {
    case enabledOnly
    case systemPermission
    case perCall
}

public struct PHKToolPermission: Sendable {
    public let identifier: String
    public let title: String
    public let gate: PHKToolPermissionGate
    public let enabledByDefault: Bool

    public init(identifier: String, title: String, gate: PHKToolPermissionGate, enabledByDefault: Bool) {
        self.identifier = identifier
        self.title = title
        self.gate = gate
        self.enabledByDefault = enabledByDefault
    }
}

public enum PHKToolAuthorizationDecision: Equatable, Sendable {
    case allowed
    case refused(String)
    case declined(String)
}

public protocol PHKToolAuthorizationPolicy: Sendable {
    func authorize(permission: PHKToolPermission, detail: String?) async -> PHKToolAuthorizationDecision
}

public protocol PHKToolAuthorizationSummary: Sendable {
    func authorizationSummary(for arguments: PHKJSONValue) -> String?
}

public protocol PHKDynamicToolPermission: Sendable {
    func permissionGate(for arguments: PHKJSONValue) -> PHKToolPermissionGate
}

public protocol PHKToolAuditSink: Sendable {
    func started(name: String, detail: String?, correlationID: String) async
    func finished(
        name: String,
        detail: String?,
        result: String?,
        outcome: String,
        duration: TimeInterval,
        correlationID: String
    ) async
}

public struct PHKNoopToolAuditSink: PHKToolAuditSink {
    public init() {}
    public func started(name: String, detail: String?, correlationID: String) async {}
    public func finished(
        name: String, detail: String?, result: String?, outcome: String,
        duration: TimeInterval, correlationID: String
    ) async {}
}

public struct PHKGovernedTool: PHKNativeTool {
    public let definition: PHKToolDefinition
    public var executionMode: PHKToolExecutionMode { tool.executionMode }
    private let tool: any PHKNativeTool
    private let permission: PHKToolPermission
    private let authorization: any PHKToolAuthorizationPolicy
    private let audit: any PHKToolAuditSink

    public init(
        _ tool: any PHKNativeTool,
        permission: PHKToolPermission,
        authorization: any PHKToolAuthorizationPolicy,
        audit: any PHKToolAuditSink = PHKNoopToolAuditSink()
    ) {
        self.tool = tool
        self.permission = permission
        self.authorization = authorization
        self.audit = audit
        definition = tool.definition
    }

    public func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue {
        let correlationID = UUID().uuidString
        let detail = Self.argumentSummary(arguments)
        let clock = ContinuousClock()
        let startedAt = clock.now
        await audit.started(name: permission.identifier, detail: detail, correlationID: correlationID)

        let gate = (tool as? any PHKDynamicToolPermission)?.permissionGate(for: arguments) ?? permission.gate
        let effectivePermission = PHKToolPermission(
            identifier: permission.identifier,
            title: permission.title,
            gate: gate,
            enabledByDefault: permission.enabledByDefault
        )
        let summary = (tool as? any PHKToolAuthorizationSummary)?.authorizationSummary(for: arguments) ?? detail
        // A person reading an approval prompt must not run down the tool or
        // turn deadline.
        let decision = await PHKDeadlineClock.excludingUserWait {
            await authorization.authorize(permission: effectivePermission, detail: summary)
        }
        switch decision {
        case .allowed:
            break
        case .refused(let message):
            await finish(outcome: "refused", result: nil, startedAt: startedAt, detail: detail, correlationID: correlationID)
            throw PHKToolError.disabled(message)
        case .declined(let message):
            await finish(outcome: "declined", result: nil, startedAt: startedAt, detail: detail, correlationID: correlationID)
            throw PHKToolError.permissionDenied(message)
        }

        do {
            let value = try await tool.execute(arguments: arguments)
            await finish(
                outcome: "ok",
                result: Self.resultShape(value),
                startedAt: startedAt,
                detail: detail,
                correlationID: correlationID
            )
            return value
        } catch {
            await finish(outcome: "error", result: nil, startedAt: startedAt, detail: detail, correlationID: correlationID)
            throw error
        }
    }

    private func finish(
        outcome: String,
        result: String?,
        startedAt: ContinuousClock.Instant,
        detail: String?,
        correlationID: String
    ) async {
        let duration = startedAt.duration(to: ContinuousClock().now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        await audit.finished(
            name: permission.identifier,
            detail: detail,
            result: result,
            outcome: outcome,
            duration: seconds,
            correlationID: correlationID
        )
    }

    private static func argumentSummary(_ value: PHKJSONValue) -> String? {
        guard case .object(let object) = value, !object.isEmpty else { return nil }
        return "\(object.count) argument field(s): \(object.keys.sorted().joined(separator: ", "))"
    }

    private static func resultShape(_ value: PHKJSONValue) -> String {
        switch value {
        case .object(let object): return "object with \(object.count) field(s)"
        case .array(let array): return "array with \(array.count) item(s)"
        case .string(let string): return "text with \(string.count) character(s)"
        case .number: return "number"
        case .bool: return "boolean"
        case .null: return "empty"
        }
    }
}
