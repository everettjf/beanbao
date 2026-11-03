import Foundation
import CryptoKit
#if SWIFT_PACKAGE
import AgentRuntime
import AgentTools
#endif

public enum BeanBaoWorkflowError: Error, LocalizedError, Equatable {
    case invalidRecord
    case unsafeStorage
    case outcomeUnconfirmed(String)
    case approvalRequired(String)
    case completionUnverified

    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "The saved workflow is invalid."
        case .unsafeStorage: "Workflow storage is unavailable or has unsafe permissions."
        case .outcomeUnconfirmed(let name): "The outcome of \(name) is unconfirmed. Review it before continuing."
        case .approvalRequired(let name): "The \(name) operation requires fresh user approval."
        case .completionUnverified: "The workflow result could not be verified."
        }
    }
}

public enum BeanBaoWorkflowEffect: String, Codable, Sendable {
    case readOnly
    case localMutation
    case externalCommit
}

public enum BeanBaoWorkflowPhase: String, Codable, Sendable {
    case planned
    case running
    case waitingForUser
    case completed
    case failed
    case cancelled
    case needsReconciliation
}

public struct BeanBaoWorkflowOperation: Codable, Sendable {
    public enum State: String, Codable, Sendable { case running, completed, failed, needsReconciliation }
    public let tool: String
    public let effect: BeanBaoWorkflowEffect
    public var state: State
    public var result: PHKJSONValue?
    public var updatedAt: Date
}

public struct BeanBaoWorkflowRecord: Codable, Sendable {
    public let id: UUID
    public let request: String
    public var phase: BeanBaoWorkflowPhase
    public var checkpoint: PHKAgentCheckpoint?
    public var researchPlan: BeanBaoResearchPlan?
    public var operations: [String: BeanBaoWorkflowOperation]
    public var sources: [BeanBaoResearchSource]
    public var mailQueuedAt: Date?
    public var installedAppBundleID: String?
    public var updatedAt: Date

    public var hasUnresolvedMutation: Bool {
        operations.values.contains {
            $0.effect != .readOnly &&
                ($0.state == .running || $0.state == .needsReconciliation)
        }
    }

    public init(id: UUID = UUID(), request: String) {
        self.id = id
        self.request = request
        self.phase = .planned
        self.checkpoint = nil
        self.researchPlan = nil
        self.operations = [:]
        self.sources = []
        self.mailQueuedAt = nil
        self.installedAppBundleID = nil
        self.updatedAt = Date()
    }
}

/// Serializes PHK execution barriers and tool receipts to one private file.
/// A pending mutating operation is deliberately not retried after a crash.
public actor BeanBaoWorkflowStore: PHKExecutionCheckpointPersisting {
    private let url: URL
    private var record: BeanBaoWorkflowRecord

    public init(url: URL, request: String, id: UUID = UUID()) throws {
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BeanBaoWorkflowError.invalidRecord
        }
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Self.readPrivateFile(url)
            let saved = try JSONDecoder().decode(BeanBaoWorkflowRecord.self, from: data)
            guard saved.request == request else { throw BeanBaoWorkflowError.invalidRecord }
            record = try Self.reconcileUncertainSavedRecord(saved, at: url)
        } else {
            record = BeanBaoWorkflowRecord(id: id, request: request)
        }
    }

    public init(existingURL: URL) throws {
        self.url = existingURL
        let data = try Self.readPrivateFile(existingURL)
        let saved = try JSONDecoder().decode(BeanBaoWorkflowRecord.self, from: data)
        record = try Self.reconcileUncertainSavedRecord(saved, at: existingURL)
    }

    public func snapshot() -> BeanBaoWorkflowRecord { record }

    public func checkoutReviewURL() -> URL {
        url.deletingLastPathComponent().appendingPathComponent("checkout-review.json")
    }

    public func saveExecutionCheckpoint(_ checkpoint: PHKAgentCheckpoint) async throws {
        try mutate {
            $0.checkpoint = checkpoint
            if $0.phase == .planned { $0.phase = .running }
        }
    }

    public func setPhase(_ phase: BeanBaoWorkflowPhase) throws {
        try mutate { $0.phase = phase }
    }

    public func saveResearchPlan(_ plan: BeanBaoResearchPlan) throws {
        try BeanBaoResearchTaskPlanner.validate(plan, request: record.request)
        try mutate {
            guard $0.researchPlan == nil else { throw BeanBaoWorkflowError.invalidRecord }
            $0.researchPlan = plan
        }
    }

    public func markMailQueued() throws {
        try mutate {
            guard $0.phase == .waitingForUser, !$0.hasUnresolvedMutation,
                  $0.operations.values.contains(where: {
                      $0.tool == "mail_prepare" && $0.state == .completed
                  }) else { throw BeanBaoWorkflowError.completionUnverified }
            $0.mailQueuedAt = Date()
            let appPending = $0.operations.values.contains(where: {
                $0.tool == "app_prepare" && $0.state == .completed
            }) && $0.installedAppBundleID == nil
            $0.phase = appPending ? .waitingForUser : .completed
        }
    }

    public func markAppInstalled(bundleID: String) throws {
        try mutate {
            guard $0.phase == .waitingForUser, !$0.hasUnresolvedMutation,
                  !bundleID.isEmpty,
                  $0.operations.values.contains(where: {
                      $0.tool == "app_prepare" && $0.state == .completed
                  }) else { throw BeanBaoWorkflowError.completionUnverified }
            $0.installedAppBundleID = bundleID
            let mailPending = $0.operations.values.contains(where: {
                $0.tool == "mail_prepare" && $0.state == .completed
            }) && $0.mailQueuedAt == nil
            $0.phase = mailPending ? .waitingForUser : .completed
        }
    }

    public func addSources(_ values: [BeanBaoResearchSource]) throws {
        try mutate {
            var byURL = Dictionary($0.sources.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
            for source in values { byURL[source.url] = source }
            guard byURL.count <= 60 else { throw BeanBaoWorkflowError.invalidRecord }
            $0.sources = byURL.values.sorted { $0.url < $1.url }
        }
    }

    public enum Claim: Sendable { case execute, cached(PHKJSONValue) }

    public func claim(key: String, tool: String, effect: BeanBaoWorkflowEffect) throws -> Claim {
        guard !key.isEmpty, !tool.isEmpty else { throw BeanBaoWorkflowError.invalidRecord }
        guard !record.hasUnresolvedMutation else {
            throw BeanBaoWorkflowError.outcomeUnconfirmed("workflow")
        }
        if let existing = record.operations[key] {
            guard existing.tool == tool, existing.effect == effect else {
                throw BeanBaoWorkflowError.invalidRecord
            }
            if existing.state == .completed, let result = existing.result {
                return .cached(result)
            }
            if effect != .readOnly && existing.state != .failed {
                throw BeanBaoWorkflowError.outcomeUnconfirmed(tool)
            }
        }
        try mutate {
            $0.operations[key] = .init(tool: tool, effect: effect, state: .running,
                                      result: nil, updatedAt: Date())
            $0.phase = .running
        }
        return .execute
    }

    public func finish(key: String, result: PHKJSONValue) throws {
        try mutate {
            guard var operation = $0.operations[key], operation.state == .running else {
                throw BeanBaoWorkflowError.invalidRecord
            }
            operation.state = .completed
            operation.result = result
            operation.updatedAt = Date()
            $0.operations[key] = operation
        }
    }

    public func fail(key: String, definitelyNoEffect: Bool = false) throws {
        try mutate {
            guard var operation = $0.operations[key], operation.state == .running else {
                throw BeanBaoWorkflowError.invalidRecord
            }
            operation.state = operation.effect == .readOnly || definitelyNoEffect ?
                .failed : .needsReconciliation
            operation.updatedAt = Date()
            $0.operations[key] = operation
            if operation.state == .needsReconciliation { $0.phase = .needsReconciliation }
        }
    }

    public func assertSafeToRun() throws {
        guard !record.hasUnresolvedMutation else {
            throw BeanBaoWorkflowError.outcomeUnconfirmed("workflow")
        }
    }

    public func assertSafeToComplete() throws {
        try assertSafeToRun()
        guard !record.operations.values.contains(where: { $0.state == .running }) else {
            throw BeanBaoWorkflowError.completionUnverified
        }
    }

    private static func reconcileUncertainSavedRecord(_ saved: BeanBaoWorkflowRecord,
                                                       at url: URL) throws -> BeanBaoWorkflowRecord {
        guard saved.hasUnresolvedMutation && saved.phase != .needsReconciliation else {
            return saved
        }
        var repaired = saved
        repaired.phase = .needsReconciliation
        repaired.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writePrivateFile(encoder.encode(repaired), to: url)
        return repaired
    }

    private func mutate(_ edit: (inout BeanBaoWorkflowRecord) throws -> Void) throws {
        var next = record
        try edit(&next)
        next.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        try Self.writePrivateFile(data, to: url)
        record = next
    }

    static func readPrivateFile(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw BeanBaoWorkflowError.unsafeStorage }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
              metadata.st_size >= 0, metadata.st_size <= 4 * 1024 * 1024 else {
            throw BeanBaoWorkflowError.unsafeStorage
        }
        var data = Data(count: Int(metadata.st_size))
        let count = data.count
        let complete = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return count == 0 }
            var offset = 0
            while offset < count {
                let n = read(fd, base.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard complete else { throw BeanBaoWorkflowError.unsafeStorage }
        return data
    }

    static func writePrivateFile(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var directory = stat()
        guard lstat(parent.path, &directory) == 0, (directory.st_mode & S_IFMT) == S_IFDIR,
              directory.st_uid == getuid(), directory.st_mode & 0o077 == 0 else {
            throw BeanBaoWorkflowError.unsafeStorage
        }
        let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BeanBaoWorkflowError.unsafeStorage }
        var committed = false
        defer {
            close(fd)
            if !committed { unlink(temporary.path) }
        }
        let written = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let n = write(fd, base.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard written, fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw BeanBaoWorkflowError.unsafeStorage
        }
        committed = true
        let directoryFD = open(parent.path, O_RDONLY)
        if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
    }
}

/// The key is derived from the exact tool name and canonical arguments, not a
/// model-supplied ID. A duplicate call returns its saved result after success.
public struct BeanBaoGuardedWorkflowTool: PHKNativeTool {
    public let definition: PHKToolDefinition
    public let executionMode: PHKToolExecutionMode = .serial
    private let effect: BeanBaoWorkflowEffect
    private let store: BeanBaoWorkflowStore
    private let approval: (@Sendable (PHKJSONValue) async throws -> Bool)?
    private let operation: @Sendable (PHKJSONValue) async throws -> PHKJSONValue

    /// These exact errors are thrown before the named tool writes its output.
    /// Any storage, rendering, or unknown error remains an uncertain mutation.
    private func definitelyNoEffect(_ error: Error) -> Bool {
        switch definition.name {
        case "report_compose":
            if let failure = error as? BeanBaoReportError {
                switch failure {
                case .invalidStructure, .unsupportedCitation: return true
                case .missingReport: return false
                }
            }
        case "pdf_render":
            if let failure = error as? BeanBaoPDFError,
               case .tooManyPages = failure { return true }
            if let failure = error as? BeanBaoReportError {
                switch failure {
                case .invalidStructure, .missingReport: return true
                case .unsupportedCitation: return false
                }
            }
        case "mail_prepare":
            if let failure = error as? BeanBaoMailError {
                switch failure {
                case .recipientNotInRequest, .attachmentMissing: return true
                case .invalidDraft: return false
                }
            }
        case "app_prepare":
            if let failure = error as? BeanBaoAppCatalogError,
               case .unsearchedListing = failure { return true }
        default: break
        }
        return false
    }

    public init(definition: PHKToolDefinition, effect: BeanBaoWorkflowEffect,
                store: BeanBaoWorkflowStore,
                approval: (@Sendable (PHKJSONValue) async throws -> Bool)? = nil,
                operation: @escaping @Sendable (PHKJSONValue) async throws -> PHKJSONValue) {
        self.definition = definition
        self.effect = effect
        self.store = store
        self.approval = approval
        self.operation = operation
    }

    public func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(arguments)
        let digest = SHA256.hash(data: Data(definition.name.utf8) + encoded)
        let key = digest.map { String(format: "%02x", $0) }.joined()
        if effect == .externalCommit {
            guard let approval, try await approval(arguments) else {
                throw BeanBaoWorkflowError.approvalRequired(definition.name)
            }
        }
        switch try await store.claim(key: key, tool: definition.name, effect: effect) {
        case .cached(let result): return result
        case .execute: break
        }
        do {
            let result = try await operation(arguments)
            try await store.finish(key: key, result: result)
            return result
        } catch {
            try? await store.fail(key: key, definitelyNoEffect: definitelyNoEffect(error))
            throw error
        }
    }
}

/// Uses Palmino's actual model/tool loop. The host supplies provider transport,
/// available tools, and approval policy; restoring an interrupted turn starts a
/// new turn so earlier tool receipts remain in the model's context.
public final class BeanBaoWorkflowSession: @unchecked Sendable {
    public let store: BeanBaoWorkflowStore
    private let runtime: PHKAgentRuntime
    private let completionCheck: @Sendable () async throws -> Bool
    private let successPhase: BeanBaoWorkflowPhase

    public init(store: BeanBaoWorkflowStore, client: any PHKModelClient, model: String,
                systemPrompt: String, tools: [any PHKNativeTool],
                completionCheck: @escaping @Sendable () async throws -> Bool,
                successPhase: BeanBaoWorkflowPhase = .completed,
                budget: PHKExecutionBudget = .init(maximumSteps: 24, maximumToolCalls: 40,
                                                    maximumDuration: .seconds(900))) async {
        self.store = store
        self.completionCheck = completionCheck
        self.successPhase = successPhase
        let saved = await store.snapshot()
        runtime = PHKAgentRuntime(client: client, model: model, systemPrompt: systemPrompt,
                                  checkpoint: saved.checkpoint,
                                  toolRegistry: PHKToolRegistry(tools),
                                  executionBudget: budget,
                                  executionCheckpointSink: store)
    }

    public func run(_ request: String) async throws -> PHKAgentSnapshot {
        try await store.assertSafeToRun()
        try await store.setPhase(.running)
        do {
            let output = try await runtime.send(request)
            try await store.saveExecutionCheckpoint(await runtime.checkpoint())
            guard try await completionCheck() else { throw BeanBaoWorkflowError.completionUnverified }
            try await store.assertSafeToComplete()
            try await store.setPhase(successPhase)
            return output
        } catch {
            let current = await store.snapshot()
            if current.hasUnresolvedMutation {
                try? await store.setPhase(.needsReconciliation)
            } else if current.phase != .needsReconciliation {
                try? await store.setPhase(.failed)
            }
            throw error
        }
    }

    public func resume() async throws -> PHKAgentSnapshot {
        let saved = await store.snapshot()
        guard saved.checkpoint != nil else { throw BeanBaoWorkflowError.invalidRecord }
        guard saved.phase != .completed && saved.phase != .waitingForUser else {
            throw BeanBaoWorkflowError.invalidRecord
        }
        guard saved.phase != .needsReconciliation else {
            throw BeanBaoWorkflowError.outcomeUnconfirmed("workflow")
        }
        return try await run("Resume the previously interrupted workflow. Check saved tool results and the current state before taking another action.")
    }
}
