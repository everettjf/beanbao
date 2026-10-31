import Foundation

public enum PHKJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PHKJSONValue])
    case object([String: PHKJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PHKJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PHKJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public enum PHKMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct PHKAttachment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let mediaType: String
    public let byteCount: Int
    public let createdAt: Date
    public let extractedText: String?
    /// Stable content-addressed workspace identity. Older persisted messages
    /// decode this as nil and continue through the legacy attachment path.
    public let workspaceDigest: String?
    public var documentFolder: String?
    public var sourceURL: URL?
    /// Ephemeral bytes used to construct a multimodal provider request. They
    /// are deliberately excluded from Codable persistence and backups.
    public let transientData: Data?

    public init(
        id: UUID = UUID(),
        name: String,
        mediaType: String,
        byteCount: Int,
        createdAt: Date = Date(),
        extractedText: String? = nil,
        workspaceDigest: String? = nil,
        transientData: Data? = nil,
        documentFolder: String? = nil,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.extractedText = extractedText
        self.workspaceDigest = workspaceDigest
        self.transientData = transientData
        self.documentFolder = documentFolder
        self.sourceURL = sourceURL
    }

    public func loadingTransientData(_ data: Data) -> PHKAttachment {
        .init(
            id: id, name: name, mediaType: mediaType, byteCount: byteCount,
            createdAt: createdAt, extractedText: extractedText,
            workspaceDigest: workspaceDigest, transientData: data, documentFolder: documentFolder, sourceURL: sourceURL
        )
    }

    public func loadingExtractedText(_ text: String?) -> PHKAttachment {
        .init(
            id: id, name: name, mediaType: mediaType, byteCount: byteCount,
            createdAt: createdAt, extractedText: text,
            workspaceDigest: workspaceDigest, transientData: transientData, documentFolder: documentFolder, sourceURL: sourceURL
        )
    }

    public func removingTransientData() -> PHKAttachment {
        .init(
            id: id, name: name, mediaType: mediaType, byteCount: byteCount,
            createdAt: createdAt, extractedText: extractedText,
            workspaceDigest: workspaceDigest, documentFolder: documentFolder, sourceURL: sourceURL
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mediaType, byteCount, createdAt, extractedText, workspaceDigest, documentFolder, sourceURL
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        mediaType = try values.decode(String.self, forKey: .mediaType)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        extractedText = try values.decodeIfPresent(String.self, forKey: .extractedText)
        workspaceDigest = try values.decodeIfPresent(String.self, forKey: .workspaceDigest)
        documentFolder = try values.decodeIfPresent(String.self, forKey: .documentFolder)
        sourceURL = try values.decodeIfPresent(URL.self, forKey: .sourceURL)
        transientData = nil
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(mediaType, forKey: .mediaType)
        try values.encode(byteCount, forKey: .byteCount)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(extractedText, forKey: .extractedText)
        try values.encodeIfPresent(workspaceDigest, forKey: .workspaceDigest)
        try values.encodeIfPresent(documentFolder, forKey: .documentFolder)
        try values.encodeIfPresent(sourceURL, forKey: .sourceURL)
    }
}

public struct PHKFileMentionResolution: Equatable, Sendable {
    public let attachments: [PHKAttachment]
    public let unresolvedNames: [String]

    public init(attachments: [PHKAttachment], unresolvedNames: [String]) {
        self.attachments = attachments
        self.unresolvedNames = unresolvedNames
    }
}

/// Resolves `@filename` and `@[filename with spaces]` references against files
/// already retained by the current conversation workspace.
public enum PHKFileMentionResolver {
    public static func query(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let suffix = String(text[text.index(after: at)...])
        guard !suffix.contains(where: { $0.isNewline }) else { return nil }
        if suffix.hasPrefix("[") { return String(suffix.dropFirst()).replacingOccurrences(of: "]", with: "") }
        guard !suffix.contains(where: { $0.isWhitespace }) else { return nil }
        return suffix
    }

    public static func suggestions(
        for query: String,
        attachments: [PHKAttachment],
        limit: Int = 6
    ) -> [PHKAttachment] {
        var seen = Set<String>()
        let needle = query.lowercased()
        return attachments.filter {
            seen.insert($0.name.lowercased()).inserted &&
                (needle.isEmpty || $0.name.lowercased().contains(needle))
        }.prefix(max(0, limit)).map { $0 }
    }

    public static func resolve(_ text: String, attachments: [PHKAttachment]) -> PHKFileMentionResolution {
        let names = mentionedNames(in: text)
        var resolved: [PHKAttachment] = []
        var unresolved: [String] = []
        var seen = Set<UUID>()
        for name in names {
            if let attachment = attachments.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                if seen.insert(attachment.id).inserted { resolved.append(attachment) }
            } else if !unresolved.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                unresolved.append(name)
            }
        }
        return .init(attachments: resolved, unresolvedNames: unresolved)
    }

    private static func mentionedNames(in text: String) -> [String] {
        let pattern = #"@\[([^\]]+)\]|@([^\s@\[\]]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                if let range = Range(match.range(at: index), in: text) { return String(text[range]) }
            }
            return nil
        }
    }
}

/// Provider-neutral message content. Providers translate these blocks into
/// their wire format; storage and UI can preserve richer content without
/// depending on a provider SDK.
public enum PHKContentBlock: Codable, Equatable, Sendable {
    case text(String)
    case reasoning(String)
    case attachment(PHKAttachment)
    case toolUse(PHKToolCall)
    case toolResult(callID: String, content: String, isError: Bool)
}

public struct PHKModelCapabilities: Codable, Equatable, Sendable {
    public var supportsReasoning: Bool
    public var supportsToolCalling: Bool
    public var supportsImages: Bool
    public var contextWindow: Int

    public init(
        supportsReasoning: Bool = true,
        supportsToolCalling: Bool = true,
        supportsImages: Bool = false,
        contextWindow: Int = 64_000
    ) {
        self.supportsReasoning = supportsReasoning
        self.supportsToolCalling = supportsToolCalling
        self.supportsImages = supportsImages
        self.contextWindow = contextWindow
    }

    public static let deepSeek = PHKModelCapabilities(
        supportsReasoning: true,
        supportsToolCalling: true,
        supportsImages: false,
        contextWindow: 64_000
    )
}

public struct PHKToolCall: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct PHKChatMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let role: PHKMessageRole
    public var content: String?
    public var reasoningContent: String?
    public var toolCalls: [PHKToolCall]
    public var toolCallID: String?
    public var attachments: [PHKAttachment]
    public var blocks: [PHKContentBlock]

    public init(
        id: UUID = UUID(),
        role: PHKMessageRole,
        content: String? = nil,
        reasoningContent: String? = nil,
        toolCalls: [PHKToolCall] = [],
        toolCallID: String? = nil,
        attachments: [PHKAttachment] = [],
        blocks: [PHKContentBlock]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.attachments = attachments
        self.blocks = blocks ?? Self.makeBlocks(
            role: role, content: content, reasoningContent: reasoningContent,
            toolCalls: toolCalls, toolCallID: toolCallID, attachments: attachments
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, toolCalls, toolCallID, attachments, blocks
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(PHKMessageRole.self, forKey: .role)
        content = try values.decodeIfPresent(String.self, forKey: .content)
        reasoningContent = try values.decodeIfPresent(String.self, forKey: .reasoningContent)
        toolCalls = try values.decodeIfPresent([PHKToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try values.decodeIfPresent(String.self, forKey: .toolCallID)
        attachments = try values.decodeIfPresent([PHKAttachment].self, forKey: .attachments) ?? []
        blocks = try values.decodeIfPresent([PHKContentBlock].self, forKey: .blocks) ?? Self.makeBlocks(
            role: role, content: content, reasoningContent: reasoningContent,
            toolCalls: toolCalls, toolCallID: toolCallID, attachments: attachments
        )
    }

    public mutating func appendContent(_ value: String) {
        content = (content ?? "") + value
        if case .text(let existing)? = blocks.last {
            blocks[blocks.count - 1] = .text(existing + value)
        } else {
            blocks.append(.text(value))
        }
    }

    public mutating func appendReasoning(_ value: String) {
        reasoningContent = (reasoningContent ?? "") + value
        if case .reasoning(let existing)? = blocks.last {
            blocks[blocks.count - 1] = .reasoning(existing + value)
        } else {
            blocks.append(.reasoning(value))
        }
    }

    public mutating func replaceToolCalls(_ values: [PHKToolCall]) {
        toolCalls = values
        blocks.removeAll {
            if case .toolUse = $0 { return true }
            return false
        }
        blocks.append(contentsOf: values.map(PHKContentBlock.toolUse))
    }

    private static func makeBlocks(
        role: PHKMessageRole, content: String?, reasoningContent: String?,
        toolCalls: [PHKToolCall], toolCallID: String?, attachments: [PHKAttachment]
    ) -> [PHKContentBlock] {
        var result: [PHKContentBlock] = []
        if let reasoningContent, !reasoningContent.isEmpty { result.append(.reasoning(reasoningContent)) }
        if let content, !content.isEmpty {
            if role == .tool, let toolCallID {
                result.append(.toolResult(callID: toolCallID, content: content, isError: false))
            } else {
                result.append(.text(content))
            }
        }
        result.append(contentsOf: attachments.map(PHKContentBlock.attachment))
        result.append(contentsOf: toolCalls.map(PHKContentBlock.toolUse))
        return result
    }
}

public struct PHKToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let parameters: PHKJSONValue

    public init(name: String, description: String, parameters: PHKJSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct PHKCompletionRequest: Equatable, Sendable {
    public let model: String
    public let messages: [PHKChatMessage]
    public let tools: [PHKToolDefinition]
    public let temperature: Double?
    public let deadline: Duration?

    public init(
        model: String,
        messages: [PHKChatMessage],
        tools: [PHKToolDefinition] = [],
        temperature: Double? = nil,
        deadline: Duration? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.deadline = deadline
    }
}

public enum PHKFinishReason: String, Codable, Equatable, Sendable {
    case stop
    case toolCalls = "tool_calls"
    case length
    case contentFilter = "content_filter"
    case unknown
}

public struct PHKTokenUsage: Codable, Equatable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public struct PHKToolCallDelta: Equatable, Sendable {
    public let index: Int
    public let id: String?
    public let name: String?
    public let arguments: String?

    public init(index: Int, id: String?, name: String?, arguments: String?) {
        self.index = index
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum PHKModelEvent: Equatable, Sendable {
    case reasoningDelta(String)
    case contentDelta(String)
    case toolCallDelta(PHKToolCallDelta)
    case usage(PHKTokenUsage)
    case completed(PHKFinishReason)
}

public protocol PHKModelClient: Sendable {
    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error>
}

/// Lets providers expose a stable, privacy-safe error category without making
/// AgentRuntime depend on a concrete transport implementation.
public protocol PHKAgentErrorCategorizing: Error {
    var agentErrorCategory: String { get }
}
