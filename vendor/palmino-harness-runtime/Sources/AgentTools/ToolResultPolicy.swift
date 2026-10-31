import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
#endif

public protocol ToolResultOffloading: Sendable {
    func store(_ value: JSONValue, suggestedName: String) async throws -> JSONValue
}

public struct ToolResultPolicy: Sendable, Equatable {
    public var maximumInlineBytes: Int
    public var sensitiveKeys: Set<String>

    public init(
        maximumInlineBytes: Int = 256 * 1_024,
        sensitiveKeys: Set<String> = ["authorization", "api_key", "apikey", "password", "secret", "token"]
    ) {
        self.maximumInlineBytes = max(256, maximumInlineBytes)
        self.sensitiveKeys = Set(sensitiveKeys.map(Self.normalize))
    }

    public func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let values): return .array(values.map(redact))
        case .object(let object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { key, child in
                let replacement: JSONValue = sensitiveKeys.contains(Self.normalize(key))
                    ? .string("[REDACTED]") : redact(child)
                return (key, replacement)
            }))
        default: return value
        }
    }

    private static func normalize(_ key: String) -> String {
        key.lowercased().filter(\.isLetter)
    }
}
