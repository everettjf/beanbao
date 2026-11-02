import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
import AgentTools
#endif

#if os(iOS)
@_silgen_name("BBWorkflowClaudeConfigJSON")
private func BBAppStoreClaudeConfigJSON() -> UnsafeMutablePointer<CChar>?
@_silgen_name("BBBridgeFreeJSON")
private func BBFreeAppStoreConfig(_ pointer: UnsafeMutablePointer<CChar>)

private final class AppStoreOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var success = false
    func set(_ value: Bool) { lock.lock(); success = value; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return success }
}

@_cdecl("BBMarkAppStoreInstalled")
public func BBMarkAppStoreInstalled(_ idPointer: UnsafePointer<CChar>?,
                                    _ bundlePointer: UnsafePointer<CChar>?) -> Int32 {
    guard let idPointer, let bundlePointer,
          let id = UUID(uuidString: String(cString: idPointer)) else { return 2 }
    let bundle = String(cString: bundlePointer)
    let folder = URL(fileURLWithPath: "/var/mobile/Library/Application Support/BeanBao/workflows",
                     isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    let result = AppStoreOutcome()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let store = try BeanBaoWorkflowStore(existingURL: folder.appendingPathComponent("session.json"))
            let saved = await store.snapshot()
            let listing = try BeanBaoAppPrepareTool.read(at: folder.appendingPathComponent("app-candidate.json"))
            guard saved.id == id, saved.phase == .waitingForUser,
                  listing.bundleID == bundle else { done.signal(); return }
            try await store.setPhase(.completed)
            result.set(true)
        } catch { }
        done.signal()
    }
    return done.wait(timeout: .now() + .seconds(10)) == .success && result.get() ? 0 : 1
}

@_cdecl("BBRunHarnessAppStore")
public func BBRunHarnessAppStore(_ taskPointer: UnsafePointer<CChar>?,
                                 _ idPointer: UnsafePointer<CChar>?) -> Int32 {
    guard let taskPointer, let idPointer,
          let id = UUID(uuidString: String(cString: idPointer)),
          let configPointer = BBAppStoreClaudeConfigJSON() else { return 2 }
    defer { BBFreeAppStoreConfig(configPointer) }
    let task = String(cString: taskPointer)
    let data = Data(String(cString: configPointer).utf8)
    guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let model = config["model"], let key = config["key"],
          !model.isEmpty, !key.isEmpty else { return 2 }
    let outcome = AppStoreOutcome()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        outcome.set((try? await runAppStoreWorkflow(task: task, id: id,
                                                    model: model, key: key)) != nil)
        done.signal()
    }
    guard done.wait(timeout: .now() + .seconds(600)) == .success,
          outcome.get() else {
        fputs("App Store lookup incomplete\n", stderr)
        return 1
    }
    fputs("BB_INTENT=AppStoreReview\n", stdout)
    fputs("App Store listing ready for review\n", stdout)
    return 0
}

private func runAppStoreWorkflow(task: String, id: UUID, model: String,
                                 key: String) async throws {
    let root = URL(fileURLWithPath: "/var/mobile/Library/Application Support/BeanBao/workflows",
                   isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    var rootInfo = stat()
    guard lstat(root.path, &rootInfo) == 0,
          (rootInfo.st_mode & S_IFMT) == S_IFDIR,
          rootInfo.st_uid == getuid(), rootInfo.st_mode & 0o077 == 0 else {
        throw BeanBaoWorkflowError.unsafeStorage
    }
    let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
    let store = try BeanBaoWorkflowStore(url: folder.appendingPathComponent("session.json"),
                                         request: task, id: id)
    let evidence = try BeanBaoAppCatalogEvidence(storeURL: folder.appendingPathComponent("app-search.json"))
    let candidateURL = folder.appendingPathComponent("app-candidate.json")
    let search = BeanBaoAppSearchTool(client: .init(), evidence: evidence)
    let prepare = BeanBaoAppPrepareTool(evidence: evidence, outputURL: candidateURL)
    let tools: [any PHKNativeTool] = [
        BeanBaoGuardedWorkflowTool(definition: search.definition, effect: .readOnly,
                                   store: store, operation: search.execute),
        BeanBaoGuardedWorkflowTool(definition: prepare.definition, effect: .localMutation,
                                   store: store, operation: prepare.execute)
    ]
    let system = """
    You are BeanBao's App Store listing assistant. The user asked to find or install an app. Use app_lookup to search Apple's App Store catalog, then app_prepare to save the single best candidate only when its name and developer fit the request. If results are ambiguous, ask for clarification rather than selecting one. The selected listing is displayed for user review before opening StoreKit. Do not claim it was installed. Do not call any purchase or install action; none is available.
    """
    let saved = await store.snapshot()
    let session = await BeanBaoWorkflowSession(store: store,
        client: BeanBaoClaudeWorkflowClient(apiKey: key), model: model,
        systemPrompt: system, tools: tools,
        completionCheck: {
            guard let candidate = try? BeanBaoAppPrepareTool.read(at: candidateURL) else { return false }
            return candidate.productID > 0 && candidate.bundleID.count >= 3
        }, successPhase: .waitingForUser,
        budget: .init(maximumSteps: 8, maximumToolCalls: 6,
                      maximumModelRequestDuration: .seconds(90),
                      maximumToolDuration: .seconds(40), maximumDuration: .seconds(300)))
    if saved.checkpoint == nil { _ = try await session.run(task) }
    else { _ = try await session.resume() }
}
#endif
