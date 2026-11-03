import Foundation
import XCTest
import AgentRuntime
import BeanBaoTextHarness

private struct ScriptedPlanClient: PHKModelClient {
    let arguments: String

    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        AsyncThrowingStream { continuation in
            XCTAssertEqual(request.tools.map(\.name), ["propose_research_plan"])
            continuation.yield(.toolCallDelta(.init(index: 0, id: "plan-1",
                                                    name: "propose_research_plan",
                                                    arguments: arguments)))
            continuation.yield(.completed(.toolCalls))
            continuation.finish()
        }
    }
}

final class ResearchTaskPlannerTests: XCTestCase {
    private let request = "Please research on-device speech recognition, make a PDF, prepare an email draft to test@example.com, and get the Pages app"

    private func proposal(mail: String = "test@example.com", app: String = "Pages",
                          install: Bool = true, unsupported: Bool = false) -> String {
        let object: [String: Any] = ["mail_recipient": mail, "app_query": app,
                                     "installation_requested": install,
                                     "unsupported": unsupported]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testNaturalRequestPlansAllThreeOutputs() async throws {
        let plan = try await BeanBaoResearchTaskPlanner.plan(
            request: request, model: "test", client: ScriptedPlanClient(arguments: proposal()))
        XCTAssertEqual(plan, BeanBaoResearchPlan(mailRecipient: "test@example.com",
                                                  appQuery: "Pages", installationRequested: true))
    }

    func testOmittedOrInventedStepsFailBeforeExecution() async {
        for arguments in [proposal(mail: ""), proposal(app: ""),
                          proposal(app: "Slack"), proposal(install: false),
                          proposal(unsupported: true)] {
            do {
                _ = try await BeanBaoResearchTaskPlanner.plan(
                    request: request, model: "test",
                    client: ScriptedPlanClient(arguments: arguments))
                XCTFail("Accepted a plan that changed the user's request")
            } catch { }
        }
    }

    func testFindingResearchSourcesDoesNotRequireApp() throws {
        let text = "Research on-device speech recognition, find current sources, and make a PDF"
        try BeanBaoResearchTaskPlanner.validate(
            BeanBaoResearchPlan(mailRecipient: nil, appQuery: nil,
                                installationRequested: false), request: text)
    }

    func testUnsupportedActionsCannotBeSmuggledIntoResearch() throws {
        let plan = BeanBaoResearchPlan(mailRecipient: nil, appQuery: nil,
                                       installationRequested: false)
        for text in ["Research iOS speech, make a PDF, and order food",
                     "Research iOS speech, make a PDF, and open Settings",
                     "Do not research iOS speech or make a PDF"] {
            XCTAssertThrowsError(try BeanBaoResearchTaskPlanner.validate(plan, request: text))
        }
    }

    func testAppTargetMustFollowItsAction() throws {
        let wrong = "Research Pages integration, make a PDF, then install Slack"
        XCTAssertThrowsError(try BeanBaoResearchTaskPlanner.validate(
            BeanBaoResearchPlan(mailRecipient: nil, appQuery: "Pages",
                                installationRequested: true), request: wrong))
    }

    func testTwoAppTargetsCannotCollapseIntoOne() throws {
        let plan = BeanBaoResearchPlan(mailRecipient: nil, appQuery: "Pages",
                                       installationRequested: true)
        for request in ["Research iOS speech, make a PDF, then install Pages and download Numbers",
                        "Research iOS speech, make a PDF, then install Pages and Numbers"] {
            XCTAssertThrowsError(try BeanBaoResearchTaskPlanner.validate(plan, request: request))
        }
    }

    func testPlanSurvivesSessionReload() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbao-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("session.json")
        let id = UUID()
        let store = try BeanBaoWorkflowStore(url: path, request: request, id: id)
        let plan = BeanBaoResearchPlan(mailRecipient: "test@example.com",
                                       appQuery: "Pages", installationRequested: true)
        try await store.saveResearchPlan(plan)
        let restored = try BeanBaoWorkflowStore(url: path, request: request, id: id)
        let snapshot = await restored.snapshot()
        XCTAssertEqual(snapshot.researchPlan, plan)
    }
}
