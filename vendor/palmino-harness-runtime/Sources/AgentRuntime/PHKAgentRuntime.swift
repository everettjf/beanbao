import Foundation

public protocol PHKAgentTelemetry: Sendable {
    func started(source: String, name: String, detail: String, correlationID: String) async
    func finished(source: String, name: String, detail: String, result: String, outcome: String, duration: TimeInterval, correlationID: String) async
}

public struct PHKNoopAgentTelemetry: PHKAgentTelemetry {
    public init() {}
    public func started(source: String, name: String, detail: String, correlationID: String) async { }
    public func finished(source: String, name: String, detail: String, result: String, outcome: String, duration: TimeInterval, correlationID: String) async { }
}

public enum PHKAgentPhase: Equatable, Sendable {
    case idle
    case streaming(step: Int)
    case completed
    case cancelled
    case failed(message: String)
}

public struct PHKAgentSnapshot: Equatable, Sendable {
    public let messages: [PHKChatMessage]
    public let phase: PHKAgentPhase
    public let usage: PHKTokenUsage?
    public let contextTrace: ContextTrace?

    public init(
        messages: [PHKChatMessage], phase: PHKAgentPhase, usage: PHKTokenUsage?,
        contextTrace: ContextTrace? = nil
    ) {
        self.messages = messages
        self.phase = phase
        self.usage = usage
        self.contextTrace = contextTrace
    }
}

public struct PHKAgentCheckpoint: Codable, Equatable, Sendable {
    public let messages: [PHKChatMessage]
    public let usage: PHKTokenUsage?
    public let createdAt: Date
    public let contextTrace: ContextTrace?

    public init(
        messages: [PHKChatMessage], usage: PHKTokenUsage?, createdAt: Date = Date(),
        contextTrace: ContextTrace? = nil
    ) {
        self.messages = messages
        self.usage = usage
        self.createdAt = createdAt
        self.contextTrace = contextTrace
    }
}

public enum PHKAgentRuntimeError: Error, LocalizedError, Equatable {
    case emptyPrompt
    case alreadyRunning
    case nothingToRetry
    case nothingToContinue
    case retryWouldDiscardToolHistory
    case toolsDisabledDuringReplay
    case executionCheckpointFailedBeforeTools
    case executionCheckpointFailedAfterTools
    case messageNotFound(UUID)
    case messageIsNotUser(UUID)
    case stepLimitExceeded
    case toolCallLimitExceeded
    case repeatedToolCall(String)
    case modelDeadlineExceeded
    case toolDeadlineExceeded(String)
    case turnDeadlineExceeded

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt: return "Enter a message before sending."
        case .alreadyRunning: return "The agent is already responding."
        case .nothingToRetry: return "There is no previous turn to retry."
        case .nothingToContinue: return "There is no response to continue."
        case .retryWouldDiscardToolHistory: return "Later messages contain tool execution records. Keep those records and send a new message instead of rerunning this earlier turn."
        case .executionCheckpointFailedBeforeTools: return "The execution record could not be saved. No tool in this step was started. Free storage or resolve the save problem before trying again."
        case .executionCheckpointFailedAfterTools: return "The tool step finished, but its recovery record could not be saved. Check the actual result before requesting another action."
        case .toolsDisabledDuringReplay: return "This response uses existing tool results only. No operation was repeated. To request another action, send a new message."
        case .messageNotFound: return "The selected message no longer exists."
        case .messageIsNotUser: return "Only a user message can be rerun."
        case .stepLimitExceeded: return "The agent exceeded the tool step limit."
        case .toolCallLimitExceeded: return "The agent exceeded the tool call limit."
        case .repeatedToolCall(let name): return "The agent repeatedly called \(name) without making progress."
        case .modelDeadlineExceeded: return "The model request exceeded its time limit."
        case .toolDeadlineExceeded(let name): return "The \(name) tool exceeded its time limit. Its outcome is unconfirmed; check for side effects before retrying."
        case .turnDeadlineExceeded: return "The agent turn exceeded its time limit."
        }
    }
}

public struct PHKExecutionBudget: Equatable, Sendable {
    public var maximumSteps: Int
    public var maximumToolCalls: Int
    public var maximumRepeatedToolCalls: Int
    public var maximumModelRequestDuration: Duration
    public var maximumToolDuration: Duration
    public var maximumDuration: Duration
    /// Largest tool result sent to the model in one request. The full result
    /// stays in the conversation; only the request copy is shortened, so one
    /// large file read cannot exceed the model's context window.
    public var maximumToolResultRequestCharacters: Int

    public init(
        maximumSteps: Int = 8,
        maximumToolCalls: Int = 24,
        maximumRepeatedToolCalls: Int = 3,
        maximumModelRequestDuration: Duration = .seconds(90),
        maximumToolDuration: Duration = .seconds(60),
        maximumDuration: Duration = .seconds(180),
        maximumToolResultRequestCharacters: Int = 48_000
    ) {
        self.maximumToolResultRequestCharacters = max(1_000, maximumToolResultRequestCharacters)
        self.maximumSteps = max(1, maximumSteps)
        self.maximumToolCalls = max(1, maximumToolCalls)
        self.maximumRepeatedToolCalls = max(1, maximumRepeatedToolCalls)
        self.maximumModelRequestDuration = max(.milliseconds(1), maximumModelRequestDuration)
        self.maximumToolDuration = max(.milliseconds(1), maximumToolDuration)
        self.maximumDuration = max(.milliseconds(1), maximumDuration)
    }
}

public struct PHKContextPolicy: Equatable, Sendable {
    public var maximumEstimatedTokens: Int

    public init(maximumEstimatedTokens: Int = 32_000) {
        self.maximumEstimatedTokens = maximumEstimatedTokens
    }

    public func messagesForRequest(_ messages: [PHKChatMessage], systemPrompt: String?) -> [PHKChatMessage] {
        let system = systemPrompt.flatMap { $0.isEmpty ? nil : PHKChatMessage(role: .system, content: $0) }
        let budget = max(1_000, maximumEstimatedTokens - estimatedTokens(system))
        let groups = turnGroups(messages)
        var selected: [[PHKChatMessage]] = []
        var used = 0
        for group in groups.reversed() {
            let cost = group.reduce(0) { $0 + estimatedTokens($1) }
            if !selected.isEmpty, used + cost > budget { break }
            selected.append(group)
            used += cost
        }
        let history = selected.reversed().flatMap { $0 }.map { $0.includingAttachmentPreviews() }
        return system.map { [$0] + history } ?? history
    }

    public func estimatedTokenCount(_ messages: [PHKChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimatedTokens($1) }
    }

    private func turnGroups(_ messages: [PHKChatMessage]) -> [[PHKChatMessage]] {
        var groups: [[PHKChatMessage]] = []
        for message in messages {
            if message.role == .user || groups.isEmpty { groups.append([message]) }
            else { groups[groups.count - 1].append(message) }
        }
        return groups
    }

    private func estimatedTokens(_ message: PHKChatMessage?) -> Int {
        guard let message else { return 0 }
        let contentCharacters = message.content?.count ?? 0
        let reasoningCharacters = message.reasoningContent?.count ?? 0
        let toolCharacters = message.toolCalls.reduce(into: 0) { count, call in
            count += call.name.count
            count += call.arguments.count
        }
        let attachmentCharacters = message.attachments.reduce(into: 0) { count, attachment in
            count += attachment.name.count
            count += attachment.extractedText?.count ?? 0
        }
        let characters = contentCharacters
            + reasoningCharacters
            + toolCharacters
            + attachmentCharacters
        return max(4, (characters + 3) / 4 + 8)
    }
}

extension PHKContextPolicy: AgentContextPreparing {
    public func prepare(messages: [ChatMessage], systemPrompt: String?) async throws -> ContextPreparation {
        let request = messagesForRequest(messages, systemPrompt: systemPrompt)
        return ContextPreparation(
            persistedMessages: messages,
            requestMessages: request,
            trace: .init(
                originalMessageCount: messages.count,
                requestMessageCount: request.count,
                estimatedInputTokens: estimatedTokenCount(request),
                compacted: false
            )
        )
    }
}

public actor PHKAgentRuntime {
    private let client: any PHKModelClient
    private let model: String
    private let systemPrompt: String?
    private let systemPromptProvider: (@Sendable () async throws -> String?)?
    private let toolRegistry: (any PHKToolProviding)?
    private let executionBudget: PHKExecutionBudget
    private let contextPolicy: PHKContextPolicy
    private let executionCheckpointSink: (any PHKExecutionCheckpointPersisting)?
    private let contextManager: any AgentContextPreparing
    private let telemetry: any PHKAgentTelemetry
    private var messages: [PHKChatMessage]
    private var phase: PHKAgentPhase = .idle
    private var usage: PHKTokenUsage?
    private var contextTrace: ContextTrace?
    private var isRunning = false
    private var pendingSteering: [PHKChatMessage] = []
    private var pendingToolReceipts: [PHKChatMessage] = []
    private var checkpointWriteTask: Task<Void, Error>?

    /// Accepted amendments apply before the next planning step. A tool already
    /// executing may finish; accepting an amendment never promises rollback.
    public func steer(_ text: String, messageID: UUID) -> Bool {
        guard isRunning, case .streaming = phase, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !messages.contains(where: { $0.id == messageID }), !pendingSteering.contains(where: { $0.id == messageID }) else { return true }
        pendingSteering.append(.init(id: messageID, role: .user, content: text))
        return true
    }

    private func applyPendingSteering() {
        messages.append(contentsOf: pendingSteering)
        pendingSteering.removeAll()
    }
    private var lastStreamingPublishAt: ContinuousClock.Instant?
    private var observers: [UUID: AsyncStream<PHKAgentSnapshot>.Continuation] = [:]

    public init(
        client: any PHKModelClient,
        model: String,
        systemPrompt: String? = nil,
        systemPromptProvider: (@Sendable () async throws -> String?)? = nil,
        messages: [PHKChatMessage] = [],
        checkpoint: PHKAgentCheckpoint? = nil,
        toolRegistry: (any PHKToolProviding)? = nil,
        maximumSteps: Int = 8,
        executionBudget: PHKExecutionBudget? = nil,
        contextPolicy: PHKContextPolicy = .init(),
        contextManager: (any AgentContextPreparing)? = nil,
        telemetry: any PHKAgentTelemetry = PHKNoopAgentTelemetry(),
        executionCheckpointSink: (any PHKExecutionCheckpointPersisting)? = nil
    ) {
        self.client = client
        self.model = model
        self.systemPrompt = systemPrompt
        self.systemPromptProvider = systemPromptProvider
        self.messages = checkpoint?.messages ?? messages
        self.usage = checkpoint?.usage
        self.contextTrace = checkpoint?.contextTrace
        self.toolRegistry = toolRegistry
        self.executionBudget = executionBudget ?? .init(maximumSteps: maximumSteps)
        self.contextPolicy = contextPolicy
        self.contextManager = contextManager ?? contextPolicy
        self.telemetry = telemetry
        self.executionCheckpointSink = executionCheckpointSink
    }

    public func snapshot() -> PHKAgentSnapshot {
        PHKAgentSnapshot(messages: messages, phase: phase, usage: usage, contextTrace: contextTrace)
    }

    public func checkpoint() -> PHKAgentCheckpoint {
        PHKAgentCheckpoint(messages: messages, usage: usage, contextTrace: contextTrace)
    }

    public func updates() -> AsyncStream<PHKAgentSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeObserver(id) }
            }
        }
    }

    @discardableResult
    public func compactContext() async throws -> PHKAgentSnapshot {
        guard !isRunning else { throw PHKAgentRuntimeError.alreadyRunning }
        let prompt = try await resolvedSystemPrompt()
        let preparation = try await contextManager.compact(messages: messages, systemPrompt: prompt)
        messages = preparation.persistedMessages
        contextTrace = preparation.trace
        publish()
        return snapshot()
    }

    @discardableResult
    public func send(_ prompt: String, attachments: [PHKAttachment] = [], messageID: UUID = UUID()) async throws -> PHKAgentSnapshot {
        guard !isRunning else { throw PHKAgentRuntimeError.alreadyRunning }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty else { throw PHKAgentRuntimeError.emptyPrompt }
        let content = prompt.isEmpty ? "Please review the attached file(s)." : prompt
        guard !messages.contains(where: { $0.id == messageID }) else { throw PHKAgentRuntimeError.alreadyRunning }
        messages.append(.init(id: messageID, role: .user, content: content, attachments: attachments))
        return try await generateResponse()
    }

    @discardableResult
    public func retryLastTurn() async throws -> PHKAgentSnapshot {
        guard !isRunning else { throw PHKAgentRuntimeError.alreadyRunning }
        guard let index = messages.lastIndex(where: { $0.role == .user }) else { throw PHKAgentRuntimeError.nothingToRetry }
        return try await retryResponse(at: index)
    }

    @discardableResult
    public func retryTurn(messageID: UUID) async throws -> PHKAgentSnapshot {
        guard !isRunning else { throw PHKAgentRuntimeError.alreadyRunning }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            throw PHKAgentRuntimeError.messageNotFound(messageID)
        }
        guard messages[index].role == .user else {
            throw PHKAgentRuntimeError.messageIsNotUser(messageID)
        }
        return try await retryResponse(at: index)
    }

    private func retryResponse(at index: Int) async throws -> PHKAgentSnapshot {
        let nextTurn = messages.indices.first { $0 > index && messages[$0].role == .user } ?? messages.endIndex
        // Rewinding an earlier turn must not erase evidence of later operations.
        guard !messages[nextTurn...].contains(where: { !$0.toolCalls.isEmpty || $0.role == .tool }) else {
            throw PHKAgentRuntimeError.retryWouldDiscardToolHistory
        }
        let lastToolRecord = (index..<nextTurn).last { !messages[$0].toolCalls.isEmpty || messages[$0].role == .tool }
        messages = Array(messages.prefix(through: lastToolRecord ?? index))
        if lastToolRecord != nil { resolveInterruptedToolCalls() }
        usage = nil
        contextTrace = nil
        publish()
        return try await generateResponse(allowTools: lastToolRecord == nil)
    }

    @discardableResult
    public func deleteMessages(after messageID: UUID) throws -> PHKAgentSnapshot {
        guard !isRunning else { throw PHKAgentRuntimeError.alreadyRunning }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            throw PHKAgentRuntimeError.messageNotFound(messageID)
        }
        messages = Array(messages.prefix(through: index))
        usage = nil
        contextTrace = nil
        phase = .idle
        publish()
        return snapshot()
    }

    @discardableResult
    public func continueResponse() async throws -> PHKAgentSnapshot {
        guard !isRunning else { throw PHKAgentRuntimeError.alreadyRunning }
        guard messages.contains(where: { $0.role == .assistant }) else {
            throw PHKAgentRuntimeError.nothingToContinue
        }
        let lastUser = messages.lastIndex(where: { $0.role == .user }) ?? messages.startIndex
        let hasToolHistory = messages[lastUser...].contains { !$0.toolCalls.isEmpty || $0.role == .tool }
        resolveInterruptedToolCalls()
        return try await generateResponse(allowTools: !hasToolHistory)
    }

    private func generateResponse(allowTools: Bool = true) async throws -> PHKAgentSnapshot {
        let duration = executionBudget.maximumDuration
        // Time spent waiting for the user to approve a tool does not count.
        let clock = PHKDeadlineClock()
        return try await withThrowingTaskGroup(of: PHKAgentSnapshot.self) { group in
            group.addTask {
                try await PHKDeadlineClock.$current.withValue(clock) {
                    try await self.generateResponseBody(allowTools: allowTools)
                }
            }
            group.addTask {
                try await clock.sleep(untilWorkElapsed: duration)
                throw PHKAgentRuntimeError.turnDeadlineExceeded
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw PHKAgentRuntimeError.turnDeadlineExceeded
            }
            return result
        }
    }

    private func generateResponseBody(allowTools: Bool) async throws -> PHKAgentSnapshot {
        let toolRegistry = allowTools ? self.toolRegistry : nil
        guard !isRunning else { throw PHKAgentRuntimeError.alreadyRunning }
        isRunning = true
        checkpointWriteTask = nil
        defer { isRunning = false; applyPendingSteering(); publish() }
        // History restored from an older build (1.0.22 persisted truncated
        // tool calls) or an abrupt exit may hold unpaired calls anywhere, not
        // only in the newest assistant message. Providers reject the whole
        // request for any of them, so repair before every turn.
        repairUnpairedToolCalls()
        usage = nil
        lastStreamingPublishAt = nil
        let turnID = UUID().uuidString
        let turnClock = ContinuousClock()
        let turnStartedAt = turnClock.now
        let attachmentCount = messages.reduce(0) { $0 + $1.attachments.count }
        let turnDetail = "history_messages=\(messages.count) attachments=\(attachmentCount)"
        await telemetry.started(source: "turn", name: "native.turn", detail: turnDetail, correlationID: turnID)
        var completedSteps = 0
        var executedToolCalls = 0
        var repeatedCalls: [String: (result: String, count: Int)] = [:]
        do {
            for step in 1...executionBudget.maximumSteps {
                applyPendingSteering()
                completedSteps = step
                var assistantIndex = messages.count
                messages.append(.init(role: .assistant))
                phase = .streaming(step: step)
                publish()

                var prompt = try await resolvedSystemPrompt()
                if !allowTools {
                    prompt = (prompt ?? "") + "\nThis is a response-only retry or continuation of a turn with recorded tool calls. Explain the existing results without repeating operations. Tools are disabled for this response. An interrupted or unconfirmed result does not establish success or failure; explain the uncertainty and ask the user to check the destination before requesting a new action. Do not say that any operation was executed again."
                }
                let preparation = try await contextManager.prepare(
                    messages: Array(messages.dropLast()), systemPrompt: prompt
                )
                if preparation.persistedMessages != Array(messages.dropLast()) {
                    let pendingAssistant = messages[assistantIndex]
                    messages = preparation.persistedMessages + [pendingAssistant]
                    assistantIndex = preparation.persistedMessages.count
                }
                contextTrace = preparation.trace
                var requestMessages = Self.limitingToolResults(
                    preparation.requestMessages, to: executionBudget.maximumToolResultRequestCharacters
                )
                let modelID = "\(turnID)-model-\(step)"
                let modelClock = ContinuousClock()
                let modelStartedAt = modelClock.now
                let modelDetail = "step=\(step) messages=\(requestMessages.count) tools=\(toolRegistry?.definitions.count ?? 0)"
                await telemetry.started(source: "model", name: "model.stream", detail: modelDetail, correlationID: modelID)
                var stream = StreamState()
                var shrankForContext = false
                do {
                    while true {
                        do {
                            try await streamModelResponse(.init(
                                model: model,
                                messages: requestMessages,
                                tools: toolRegistry?.definitions ?? [],
                                deadline: executionBudget.maximumModelRequestDuration
                            ), into: assistantIndex, state: &stream, clock: modelClock)
                            break
                        } catch {
                            // A context-window rejection arrives before any
                            // output. Retry once with much smaller tool results
                            // rather than failing every later attempt the same way.
                            guard stream.firstEventAt == nil, !shrankForContext, !(error is CancellationError),
                                  Self.indicatesContextOverflow(error, requestMessages: requestMessages) else { throw error }
                            shrankForContext = true
                            requestMessages = Self.limitingToolResults(
                                requestMessages, to: max(1_000, executionBudget.maximumToolResultRequestCharacters / 6)
                            )
                        }
                    }
                    let firstEventAt = stream.firstEventAt
                    let finishReason = stream.finishReason
                    let firstTokenMS = firstEventAt.map { Self.milliseconds(modelStartedAt.duration(to: $0)) } ?? -1
                    let result = "finish=\(finishReason?.rawValue ?? "stream_end") first_event_ms=\(firstTokenMS) prompt_tokens=\(usage?.promptTokens ?? 0) completion_tokens=\(usage?.completionTokens ?? 0)"
                    await telemetry.finished(source: "model", name: "model.stream", detail: modelDetail, result: result, outcome: "ok", duration: Self.seconds(modelStartedAt.duration(to: modelClock.now)), correlationID: modelID)
                } catch {
                    await telemetry.finished(source: "model", name: "model.stream", detail: modelDetail, result: "error=\(Self.errorCategory(error))", outcome: error is CancellationError ? "cancelled" : "error", duration: Self.seconds(modelStartedAt.duration(to: modelClock.now)), correlationID: modelID)
                    if (error as? URLError)?.code == .timedOut { throw PHKAgentRuntimeError.modelDeadlineExceeded }
                    throw error
                }
                try Task.checkCancellation()

                let calls = messages[assistantIndex].toolCalls
                if !pendingSteering.isEmpty {
                    // Preserve call/result pairing, but do not execute a plan
                    // generated before the newly accepted user constraints.
                    for call in calls {
                        messages.append(.init(role: .tool,
                            content: "Not executed: a newer user amendment requires replanning.", toolCallID: call.id))
                    }
                    continue
                }
                if !allowTools && !calls.isEmpty {
                    throw PHKAgentRuntimeError.toolsDisabledDuringReplay
                }
                let finishReason = stream.finishReason
                guard finishReason == .toolCalls, !calls.isEmpty, let toolRegistry else {
                    if !calls.isEmpty {
                        // A stream that ends for any other reason (length,
                        // stop, a bare [DONE]) may carry incomplete arguments.
                        // Never execute them, but keep call/result pairing or
                        // every later request is rejected by the provider.
                        resolveInterruptedToolCalls(message: "Not executed: the model response ended (\(finishReason?.rawValue ?? "stream_end")) before the tool call was complete.")
                    }
                    if executedToolCalls > 0 {
                        do { try await saveExecutionCheckpoint(checkpoint()) }
                        catch { throw PHKAgentRuntimeError.executionCheckpointFailedAfterTools }
                        if !pendingSteering.isEmpty { continue }
                    }
                    phase = .completed
                    publish()
                    await finishTurn(id: turnID, detail: turnDetail, outcome: "ok", steps: completedSteps, startedAt: turnStartedAt)
                    return snapshot()
                }
                guard executedToolCalls + calls.count <= executionBudget.maximumToolCalls else {
                    throw PHKAgentRuntimeError.toolCallLimitExceeded
                }
                executedToolCalls += calls.count

                var executable: [(Int, PHKToolCall)] = []
                for (index, call) in calls.enumerated() {
                    if let error = toolRegistry.preflight(call) {
                        let result = Self.toolErrorEnvelope(error)
                        messages.append(.init(
                            role: .tool,
                            content: result,
                            toolCallID: call.id,
                            blocks: [.toolResult(callID: call.id, content: error, isError: true)]
                        ))
                        try Self.recordToolOutcome(
                            call: call, result: result, history: &repeatedCalls,
                            limit: executionBudget.maximumRepeatedToolCalls
                        )
                    } else {
                        executable.append((index, call))
                    }
                }

                if !executable.isEmpty {
                    do { try await saveExecutionCheckpoint(checkpoint()) }
                    catch { throw PHKAgentRuntimeError.executionCheckpointFailedBeforeTools }
                    // Cancellation while saving must not fall through to tools.
                    try Task.checkCancellation()
                }
                if !pendingSteering.isEmpty {
                    for (_, call) in executable {
                        messages.append(.init(role: .tool, content: "Not executed: a newer user amendment requires replanning.", toolCallID: call.id))
                    }
                    continue
                }
                let results = try await executeTools(executable, with: toolRegistry)
                let receiptByCall = Dictionary(pendingToolReceipts.compactMap { receipt in
                    receipt.toolCallID.map { ($0, receipt) }
                }, uniquingKeysWith: { first, _ in first })
                messages.append(contentsOf: results.sorted(by: { $0.0 < $1.0 }).compactMap { receiptByCall[$0.1.id] })
                pendingToolReceipts.removeAll()
                for (_, call, result) in results.sorted(by: { $0.0 < $1.0 }) {
                    try Self.recordToolOutcome(
                        call: call, result: result, history: &repeatedCalls,
                        limit: executionBudget.maximumRepeatedToolCalls
                    )
                }
                publish()
            }
            throw PHKAgentRuntimeError.stepLimitExceeded
        } catch is CancellationError {
            messages.append(contentsOf: pendingToolReceipts); pendingToolReceipts.removeAll()
            resolveInterruptedToolCalls()
            phase = .cancelled
            publish()
            await finishTurn(id: turnID, detail: turnDetail, outcome: "cancelled", steps: completedSteps, startedAt: turnStartedAt, error: "cancelled")
            throw CancellationError()
        } catch {
            messages.append(contentsOf: pendingToolReceipts); pendingToolReceipts.removeAll()
            if error as? PHKAgentRuntimeError == .toolsDisabledDuringReplay {
                resolveInterruptedToolCalls(message: "No tool was executed. Tools are disabled during response-only replay.")
            } else if error as? PHKAgentRuntimeError == .executionCheckpointFailedBeforeTools {
                resolveInterruptedToolCalls(message: "No tool in this step was executed because its execution record could not be saved.")
            } else {
                resolveInterruptedToolCalls()
            }
            phase = .failed(message: error.localizedDescription)
            publish()
            await finishTurn(id: turnID, detail: turnDetail, outcome: "error", steps: completedSteps, startedAt: turnStartedAt, error: Self.errorCategory(error))
            throw error
        }
    }

    /// Inserts a not-executed result directly after the tool results of every
    /// assistant message whose calls are not all answered. Results must follow
    /// their assistant message, so appending at the end is not enough when a
    /// later turn exists.
    private func repairUnpairedToolCalls() {
        var repaired: [PHKChatMessage] = []
        repaired.reserveCapacity(messages.count)
        var index = messages.startIndex
        var changed = false
        while index < messages.endIndex {
            let message = messages[index]
            repaired.append(message)
            index += 1
            guard message.role == .assistant, !message.toolCalls.isEmpty else { continue }
            var answered = Set<String>()
            while index < messages.endIndex, messages[index].role == .tool {
                if let id = messages[index].toolCallID { answered.insert(id) }
                repaired.append(messages[index])
                index += 1
            }
            let result = Self.toolErrorEnvelope("Not executed: this tool call was interrupted in an earlier session. Its outcome is unconfirmed.")
            for call in message.toolCalls where !answered.contains(call.id) {
                changed = true
                repaired.append(.init(role: .tool, content: result, toolCallID: call.id,
                                      blocks: [.toolResult(callID: call.id, content: result, isError: true)]))
            }
        }
        if changed { messages = repaired }
    }

    /// A provider requires one result for every emitted tool call, even when
    /// execution was interrupted. Do not imply that a side effect was undone.
    private func resolveInterruptedToolCalls(message: String = "Tool execution interrupted. Its outcome is unconfirmed; check for side effects before retrying.") {
        guard let index = messages.lastIndex(where: { $0.role == .assistant }),
              !messages[index].toolCalls.isEmpty else { return }
        let answered = Set(messages.suffix(from: index + 1).compactMap(\.toolCallID))
        let result = Self.toolErrorEnvelope(message)
        for call in messages[index].toolCalls where !answered.contains(call.id) {
            messages.append(.init(role: .tool, content: result, toolCallID: call.id,
                                  blocks: [.toolResult(callID: call.id, content: result, isError: true)]))
        }
    }

    private struct StreamState {
        var firstEventAt: ContinuousClock.Instant?
        var toolCallFragments: [Int: ToolCallFragment] = [:]
        var finishReason: PHKFinishReason?
    }

    private func streamModelResponse(
        _ request: PHKCompletionRequest, into assistantIndex: Int,
        state: inout StreamState, clock: ContinuousClock
    ) async throws {
        for try await event in client.stream(request: request) {
            try Task.checkCancellation()
            if state.firstEventAt == nil { state.firstEventAt = clock.now }
            let forcePublish: Bool
            switch event {
            case .reasoningDelta(let text):
                forcePublish = false
                messages[assistantIndex].appendReasoning(text)
            case .contentDelta(let text):
                forcePublish = false
                messages[assistantIndex].appendContent(text)
            case .toolCallDelta(let delta):
                forcePublish = false
                var fragment = state.toolCallFragments[delta.index] ?? ToolCallFragment()
                fragment.id += delta.id ?? ""
                fragment.name += delta.name ?? ""
                fragment.arguments += delta.arguments ?? ""
                state.toolCallFragments[delta.index] = fragment
                let fragments = state.toolCallFragments
                let assembledCalls: [PHKToolCall] = fragments.keys.sorted().compactMap { index -> PHKToolCall? in
                    guard let value = fragments[index], !value.id.isEmpty, !value.name.isEmpty else {
                        return nil
                    }
                    return PHKToolCall(id: value.id, name: value.name, arguments: value.arguments)
                }
                messages[assistantIndex].replaceToolCalls(assembledCalls)
            case .usage(let value):
                forcePublish = true
                usage = value
            case .completed(let reason):
                forcePublish = true
                state.finishReason = reason
            }
            publishStreaming(force: forcePublish)
        }
    }

    static func limitingToolResults(_ messages: [PHKChatMessage], to limit: Int) -> [PHKChatMessage] {
        messages.map { message in
            guard message.role == .tool, let content = message.content, content.count > limit else { return message }
            let head = content.prefix(limit * 3 / 4)
            let tail = content.suffix(limit / 4)
            var shortened = message
            shortened.content = "\(head)\n…[\(content.count - head.count - tail.count) characters omitted to fit the model context. The full result is saved; request a narrower range if more detail is needed.]…\n\(tail)"
            return shortened
        }
    }

    static func indicatesContextOverflow(_ error: Error, requestMessages: [PHKChatMessage]) -> Bool {
        let text = (String(describing: error) + " " + error.localizedDescription).lowercased()
        let phrases = ["context_length", "context length", "maximum context", "context window", "too many tokens",
                       "prompt is too long", "reduce the length", "token limit", "maximum tokens"]
        if phrases.contains(where: text.contains) { return true }
        // Routers may reduce the body to a status category. Treat a bare 400
        // as overflow only for a request large enough to plausibly be one.
        let size = requestMessages.reduce(0) { $0 + ($1.content?.count ?? 0) }
        return size > 60_000 && (text.contains("http_400") || text.contains("http 400"))
    }

    private func resolvedSystemPrompt() async throws -> String? {
        if let systemPromptProvider { return try await systemPromptProvider() }
        return systemPrompt
    }

    private func executeTools(
        _ calls: [(Int, PHKToolCall)],
        with registry: any PHKToolProviding
    ) async throws -> [(Int, PHKToolCall, String)] {
        var results: [(Int, PHKToolCall, String)] = []
        var concurrentBatch: [(Int, PHKToolCall)] = []

        for (index, call) in calls {
            if registry.executionMode(for: call.name) == .concurrent {
                concurrentBatch.append((index, call))
                continue
            }
            if !concurrentBatch.isEmpty {
                let batch = concurrentBatch
                concurrentBatch.removeAll(keepingCapacity: true)
                results.append(contentsOf: try await executeConcurrent(
                    batch, with: registry, deadline: executionBudget.maximumToolDuration
                ))
            }
            let output = try await Self.executeTool(call, with: registry, deadline: executionBudget.maximumToolDuration)
            try await retainToolReceipt(call: call, result: output)
            results.append((index, call, output))
        }
        if !concurrentBatch.isEmpty {
            results.append(contentsOf: try await executeConcurrent(concurrentBatch, with: registry, deadline: executionBudget.maximumToolDuration))
        }
        return results
    }

    private func executeConcurrent(
        _ calls: [(Int, PHKToolCall)],
        with registry: any PHKToolProviding,
        deadline: Duration
    ) async throws -> [(Int, PHKToolCall, String)] {
        try await withThrowingTaskGroup(of: (Int, PHKToolCall, String).self) { group in
            for (index, call) in calls {
                group.addTask {
                    let output = try await Self.executeTool(call, with: registry, deadline: deadline)
                    try await self.retainToolReceipt(call: call, result: output)
                    return (index, call, output)
                }
            }
            var values: [(Int, PHKToolCall, String)] = []
            for try await value in group { values.append(value) }
            return values
        }
    }

    private func retainToolReceipt(call: PHKToolCall, result: String) async throws {
        pendingToolReceipts.append(.init(role: .tool, content: result, toolCallID: call.id))
        let durable = PHKAgentCheckpoint(messages: messages + pendingToolReceipts, usage: usage, contextTrace: contextTrace)
        do { try await saveExecutionCheckpoint(durable) }
        catch { throw PHKAgentRuntimeError.executionCheckpointFailedAfterTools }
    }

    private func saveExecutionCheckpoint(_ checkpoint: PHKAgentCheckpoint) async throws {
        guard let sink = executionCheckpointSink else { return }
        let previous = checkpointWriteTask
        let write = Task {
            try await previous?.value
            try await sink.saveExecutionCheckpoint(checkpoint)
        }
        checkpointWriteTask = write
        // Do not let a stuck sink hold the turn past cancellation or forever.
        try await PHKDeadline.run(limit: .seconds(30), onTimeout: { CheckpointWriteTimedOut() }) {
            try await write.value
        }
    }

    private struct CheckpointWriteTimedOut: Error {}

    private static func executeTool(
        _ call: PHKToolCall,
        with registry: any PHKToolProviding,
        deadline: Duration
    ) async throws -> String {
        do {
            // Returns at the deadline even when a tool ignores cancellation.
            return try await PHKDeadline.run(
                limit: deadline,
                onTimeout: { PHKAgentRuntimeError.toolDeadlineExceeded(call.name) }
            ) {
                await registry.execute(call)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return toolErrorEnvelope(error.localizedDescription)
        }
    }

    private static func toolErrorEnvelope(_ message: String) -> String {
        guard let data = try? JSONEncoder().encode(PHKJSONValue.object([
            "ok": .bool(false), "error": .string(message)
        ])) else { return "{\"ok\":false,\"error\":\"Invalid tool call.\"}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func recordToolOutcome(
        call: PHKToolCall,
        result: String,
        history: inout [String: (result: String, count: Int)],
        limit: Int
    ) throws {
        let signature = call.name + "\n" + canonicalToolOutcome(call.arguments)
        let normalizedResult = canonicalToolOutcome(result)
        let previous = history[signature]
        let count = previous?.result == normalizedResult ? (previous?.count ?? 0) + 1 : 1
        history[signature] = (normalizedResult, count)
        if count >= limit { throw PHKAgentRuntimeError.repeatedToolCall(call.name) }
    }

    private static func canonicalToolOutcome(_ result: String) -> String {
        guard let data = result.data(using: .utf8),
              let value = try? JSONDecoder().decode(PHKJSONValue.self, from: data) else {
            return result
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let normalized = try? encoder.encode(value) else { return result }
        return String(decoding: normalized, as: UTF8.self)
    }

    private func finishTurn(
        id: String, detail: String, outcome: String, steps: Int,
        startedAt: ContinuousClock.Instant, error: String? = nil
    ) async {
        var result = "steps=\(steps) total_tokens=\(usage?.totalTokens ?? 0)"
        if let error { result += " error=\(error)" }
        await telemetry.finished(
            source: "turn", name: "native.turn", detail: detail, result: result,
            outcome: outcome, duration: Self.seconds(startedAt.duration(to: ContinuousClock().now)), correlationID: id
        )
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((seconds(duration) * 1_000).rounded())
    }

    public static func errorCategory(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? any PHKAgentErrorCategorizing { return error.agentErrorCategory }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "offline"
            case .timedOut: return "network_timeout"
            case .cancelled: return "cancelled"
            default: return "network_\(error.code.rawValue)"
            }
        }
        if error is PHKAgentRuntimeError { return "runtime_error" }
        return "internal_error"
    }

    private func publish() {
        let value = snapshot()
        for continuation in observers.values { continuation.yield(value) }
    }

    /// Streaming providers can deliver hundreds of tiny deltas per second.
    /// Updating SwiftUI and copying the message array for every fragment wastes
    /// CPU and battery; 30 Hz remains visually smooth while terminal events are
    /// always delivered immediately.
    private func publishStreaming(force: Bool) {
        let clock = ContinuousClock()
        let now = clock.now
        if !force, let lastStreamingPublishAt,
           lastStreamingPublishAt.duration(to: now) < .milliseconds(33) { return }
        self.lastStreamingPublishAt = now
        publish()
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

private struct ToolCallFragment {
    var id = ""
    var name = ""
    var arguments = ""
}
