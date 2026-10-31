import Foundation

public struct ContextTrace: Codable, Equatable, Sendable {
    public let originalMessageCount: Int
    public let requestMessageCount: Int
    public let estimatedInputTokens: Int
    public let compacted: Bool
    public let markerID: UUID?

    public init(
        originalMessageCount: Int,
        requestMessageCount: Int,
        estimatedInputTokens: Int,
        compacted: Bool,
        markerID: UUID? = nil
    ) {
        self.originalMessageCount = originalMessageCount
        self.requestMessageCount = requestMessageCount
        self.estimatedInputTokens = estimatedInputTokens
        self.compacted = compacted
        self.markerID = markerID
    }
}

public struct ContextPreparation: Equatable, Sendable {
    public let persistedMessages: [ChatMessage]
    public let requestMessages: [ChatMessage]
    public let trace: ContextTrace

    public init(persistedMessages: [ChatMessage], requestMessages: [ChatMessage], trace: ContextTrace) {
        self.persistedMessages = persistedMessages
        self.requestMessages = requestMessages
        self.trace = trace
    }
}

public protocol AgentContextPreparing: Sendable {
    func prepare(messages: [ChatMessage], systemPrompt: String?) async throws -> ContextPreparation
    func compact(messages: [ChatMessage], systemPrompt: String?) async throws -> ContextPreparation
}

public extension AgentContextPreparing {
    func compact(messages: [ChatMessage], systemPrompt: String?) async throws -> ContextPreparation {
        try await prepare(messages: messages, systemPrompt: systemPrompt)
    }
}

public extension PHKChatMessage {
    /// Expands document previews only in outbound model messages. Keep the
    /// original message in persisted history so later turns do not duplicate text.
    func includingAttachmentPreviews() -> PHKChatMessage {
        guard role == .user, !attachments.isEmpty else { return self }
        var value = self
        let sections = attachments.map { attachment in
            var section = "[Attachment: \(attachment.name); id=\(attachment.id.uuidString); type=\(attachment.mediaType); bytes=\(attachment.byteCount)]"
            if let text = attachment.extractedText { section += "\n\(text)\n[End attachment]" }
            else { section += "\n[Binary attachment; use an available file or Linux tool if its contents are needed.]" }
            return section
        }
        value.content = ([content ?? ""] + sections).joined(separator: "\n\n")
        return value
    }
}

/// Hosts that need crash recovery must durably retain each checkpoint before
/// returning. This sink is awaited before tool side effects and after results.
/// Streaming UI persistence alone is not a substitute for this ordering barrier.
public protocol PHKExecutionCheckpointPersisting: Sendable {
    func saveExecutionCheckpoint(_ checkpoint: PHKAgentCheckpoint) async throws
}
