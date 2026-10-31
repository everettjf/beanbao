/// A JSON value used by model providers, tools, and persistence adapters.
public typealias JSONValue = PHKJSONValue
public typealias MessageRole = PHKMessageRole
public typealias Attachment = PHKAttachment
public typealias ContentBlock = PHKContentBlock
public typealias ModelCapabilities = PHKModelCapabilities
public typealias ToolCall = PHKToolCall
public typealias ChatMessage = PHKChatMessage
public typealias ToolDefinition = PHKToolDefinition
public typealias CompletionRequest = PHKCompletionRequest
public typealias FinishReason = PHKFinishReason
public typealias TokenUsage = PHKTokenUsage
public typealias ToolCallDelta = PHKToolCallDelta
public typealias ModelEvent = PHKModelEvent
public typealias ModelProvider = PHKModelClient
public typealias AgentErrorCategorizing = PHKAgentErrorCategorizing
public typealias AgentTelemetry = PHKAgentTelemetry
public typealias NoopAgentTelemetry = PHKNoopAgentTelemetry
public typealias AgentPhase = PHKAgentPhase
public typealias AgentSnapshot = PHKAgentSnapshot
public typealias AgentCheckpoint = PHKAgentCheckpoint
public typealias AgentRuntimeError = PHKAgentRuntimeError
public typealias ExecutionBudget = PHKExecutionBudget
public typealias ContextPolicy = PHKContextPolicy

/// A model-neutral, streaming agent runtime with bounded tool execution.
public typealias HarnessAgent = PHKAgentRuntime
public typealias ToolProviding = PHKToolProviding
public typealias ToolExecutionMode = PHKToolExecutionMode
