import Foundation
import PDFKit
import XCTest
import AgentRuntime
import AgentTools
import BeanBaoTextHarness

private struct ScriptedResearchPlanner: PHKModelClient {
    let interruptAfterSearch: Bool
    let sourceURL: String

    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let completed = request.messages.filter { $0.role == .tool }.count
        return AsyncThrowingStream { continuation in
            if interruptAfterSearch && completed >= 1 {
                continuation.finish(throwing: BeanBaoClaudeError.incompleteResponse)
                return
            }
            let name: String
            let arguments: String
            switch completed {
            case 0:
                name = "web_search"
                arguments = "{\"query\":\"iOS speech recognition APIs\"}"
            case 1:
                name = "report_compose"
                let report: [String: Any] = [
                    "title": "iOS speech recognition research",
                    "sections": [["heading": "Overview", "paragraphs": [[
                        "text": "Apple documents the APIs used to recognize and transcribe speech in apps.",
                        "source_urls": [sourceURL]
                    ]]]]
                ]
                arguments = String(decoding: try! JSONSerialization.data(withJSONObject: report), as: UTF8.self)
            case 2:
                name = "pdf_render"
                arguments = "{}"
            case 3:
                name = "mail_prepare"
                arguments = "{\"recipient\":\"test@example.com\",\"subject\":\"iOS speech report\",\"body\":\"Please review the attached report.\"}"
            default:
                continuation.yield(.contentDelta("The PDF and draft are ready for review."))
                continuation.yield(.completed(.stop))
                continuation.finish()
                return
            }
            continuation.yield(.toolCallDelta(.init(index: 0, id: "tool-\(completed)",
                                                    name: name, arguments: arguments)))
            continuation.yield(.completed(.toolCalls))
            continuation.finish()
        }
    }
}

private actor SearchCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private struct ScriptedResearchAppMailPlanner: PHKModelClient {
    let sourceURL: String

    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let completed = request.messages.filter { $0.role == .tool }.count
        return AsyncThrowingStream { continuation in
            let name: String
            let arguments: String
            switch completed {
            case 0:
                name = "web_search"
                arguments = "{\"query\":\"iOS speech recognition APIs\"}"
            case 1:
                name = "report_compose"
                let report: [String: Any] = ["title": "iOS speech research",
                    "sections": [["heading": "Overview", "paragraphs": [[
                        "text": "Apple documents speech transcription APIs.",
                        "source_urls": [sourceURL]]]]]]
                arguments = String(decoding: try! JSONSerialization.data(withJSONObject: report),
                                   as: UTF8.self)
            case 2:
                name = "pdf_render"
                arguments = "{}"
            case 3:
                name = "mail_prepare"
                arguments = "{\"recipient\":\"test@example.com\",\"subject\":\"Speech report\",\"body\":\"Please review the attached report.\"}"
            case 4:
                name = "app_lookup"
                arguments = "{\"query\":\"Example Notes\"}"
            case 5:
                name = "app_prepare"
                arguments = "{\"product_id\":123456789}"
            default:
                continuation.yield(.contentDelta("All three outputs are ready for review."))
                continuation.yield(.completed(.stop))
                continuation.finish()
                return
            }
            continuation.yield(.toolCallDelta(.init(index: 0, id: "triple-\(completed)",
                                                    name: name, arguments: arguments)))
            continuation.yield(.completed(.toolCalls))
            continuation.finish()
        }
    }
}

final class ResearchWorkflowTests: XCTestCase {
    private let sourceURL = "https://developer.apple.com/documentation/speech"
    private let request = "Research iOS speech recognition, create a PDF and email it to test@example.com"

    private func fixture() throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbao-research-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (folder, folder.appendingPathComponent("session.json"))
    }

    private func searchResponse() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "stop_reason": "end_turn", "content": [
                ["type": "web_search_tool_result", "content": [[
                    "type": "web_search_result", "url": sourceURL,
                    "title": "Speech | Apple Developer", "encrypted_content": "opaque"
                ]]],
                ["type": "text", "text": "Apple documents speech recognition APIs.",
                 "citations": [["type": "web_search_result_location", "url": sourceURL,
                                "title": "Speech | Apple Developer",
                                "cited_text": "Recognize and transcribe speech"]]
                ]
            ]
        ])
    }

    private func makeSession(folder: URL, store: BeanBaoWorkflowStore,
                             counter: SearchCounter,
                             interruptAfterSearch: Bool) async throws -> BeanBaoWorkflowSession {
        let saved = await store.snapshot()
        let evidence = BeanBaoResearchEvidence(store: store, restored: saved.sources)
        let response = try searchResponse()
        let webClient = BeanBaoClaudeWebSearch(model: "claude-test", apiKey: "placeholder") { _ in
            await counter.increment()
            return (response, 200)
        }
        let search = BeanBaoWebSearchTool(client: webClient, evidence: evidence)
        let reportURL = folder.appendingPathComponent("report.json")
        let pdfURL = folder.appendingPathComponent("report.pdf")
        let draftURL = folder.appendingPathComponent("mail-draft.json")
        let compose = BeanBaoReportComposeTool(evidence: evidence, reportURL: reportURL)
        let pdf = BeanBaoPDFRenderTool(reportURL: reportURL, pdfURL: pdfURL)
        let mail = BeanBaoMailDraftTool(request: request, pdfURL: pdfURL, draftURL: draftURL)
        let tools: [any PHKNativeTool] = [
            BeanBaoGuardedWorkflowTool(definition: search.definition, effect: .readOnly,
                                       store: store, operation: search.execute),
            BeanBaoGuardedWorkflowTool(definition: compose.definition, effect: .localMutation,
                                       store: store, operation: compose.execute),
            BeanBaoGuardedWorkflowTool(definition: pdf.definition, effect: .localMutation,
                                       store: store, operation: pdf.execute),
            BeanBaoGuardedWorkflowTool(definition: mail.definition, effect: .localMutation,
                                       store: store, operation: mail.execute)
        ]
        return await BeanBaoWorkflowSession(
            store: store,
            client: ScriptedResearchPlanner(interruptAfterSearch: interruptAfterSearch,
                                             sourceURL: sourceURL),
            model: "scripted", systemPrompt: "Research with cited tools",
            tools: tools, completionCheck: {
                (try? BeanBaoMailDraftTool.readDraft(at: draftURL)) != nil &&
                (try? Data(contentsOf: pdfURL)).flatMap(PDFDocument.init(data:))?.pageCount ?? 0 > 0
            }, successPhase: .waitingForUser)
    }

    func testFourStepResearchCreatesPDFAndEmailDraft() async throws {
        let (folder, url) = try fixture()
        let store = try BeanBaoWorkflowStore(url: url, request: request)
        let counter = SearchCounter()
        let session = try await makeSession(folder: folder, store: store, counter: counter,
                                            interruptAfterSearch: false)
        _ = try await session.run(request)
        let saved = await store.snapshot()
        XCTAssertEqual(saved.phase, .waitingForUser)
        XCTAssertEqual(saved.operations.count, 4)
        XCTAssertEqual(saved.sources.map(\.url), [sourceURL])
        let pdf = try XCTUnwrap(PDFDocument(url: folder.appendingPathComponent("report.pdf")))
        XCTAssertTrue((pdf.string ?? "").contains(sourceURL))
        let draft = try BeanBaoMailDraftTool.readDraft(at: folder.appendingPathComponent("mail-draft.json"))
        XCTAssertEqual(draft.recipient, "test@example.com")
        let searches = await counter.value()
        XCTAssertEqual(searches, 1)
    }

    func testInterruptedResearchResumesWithoutRepeatingCompletedSearch() async throws {
        let (folder, url) = try fixture()
        let store = try BeanBaoWorkflowStore(url: url, request: request)
        let counter = SearchCounter()
        let interrupted = try await makeSession(folder: folder, store: store,
                                                counter: counter, interruptAfterSearch: true)
        do {
            _ = try await interrupted.run(request)
            XCTFail("The first model turn should be interrupted")
        } catch BeanBaoClaudeError.incompleteResponse { }
        let before = await store.snapshot()
        XCTAssertEqual(before.sources.count, 1)
        XCTAssertNotNil(before.checkpoint)

        let restored = try BeanBaoWorkflowStore(url: url, request: request)
        let resumed = try await makeSession(folder: folder, store: restored,
                                            counter: counter, interruptAfterSearch: false)
        _ = try await resumed.resume()
        let after = await restored.snapshot()
        XCTAssertEqual(after.phase, .waitingForUser)
        XCTAssertEqual(after.operations.count, 4)
        let searches = await counter.value()
        XCTAssertEqual(searches, 1)
    }

    func testPalminoCreatesPDFDraftAndAppListingInOneSession() async throws {
        let (folder, url) = try fixture()
        let request = "Research iOS speech, create a PDF, prepare an email to test@example.com, then find app Example Notes"
        XCTAssertEqual(BeanBaoCompositeRequest.appQuery(request), "Example Notes")
        let store = try BeanBaoWorkflowStore(url: url, request: request)
        let evidence = BeanBaoResearchEvidence(store: store)
        let response = try searchResponse()
        let webClient = BeanBaoClaudeWebSearch(model: "claude-test", apiKey: "placeholder") { _ in
            (response, 200)
        }
        let search = BeanBaoWebSearchTool(client: webClient, evidence: evidence)
        let reportURL = folder.appendingPathComponent("report.json")
        let pdfURL = folder.appendingPathComponent("report.pdf")
        let draftURL = folder.appendingPathComponent("mail-draft.json")
        let candidateURL = folder.appendingPathComponent("app-candidate.json")
        let compose = BeanBaoReportComposeTool(evidence: evidence, reportURL: reportURL)
        let pdf = BeanBaoPDFRenderTool(reportURL: reportURL, pdfURL: pdfURL)
        let mail = BeanBaoMailDraftTool(request: request, pdfURL: pdfURL, draftURL: draftURL)
        let catalogResponse = try JSONSerialization.data(withJSONObject: ["results": [[
            "wrapperType": "software", "trackId": 123456789,
            "trackName": "Example Notes", "artistName": "Example Studio",
            "bundleId": "com.example.notes", "price": 0, "currency": "USD"
        ]]])
        let catalog = try BeanBaoAppCatalogEvidence(
            storeURL: folder.appendingPathComponent("app-search.json"))
        let lookup = BeanBaoAppSearchTool(client: BeanBaoAppCatalogClient(country: "US") { _ in
            (catalogResponse, 200)
        }, evidence: catalog)
        let prepare = BeanBaoAppPrepareTool(evidence: catalog, outputURL: candidateURL)
        let tools: [any PHKNativeTool] = [
            BeanBaoGuardedWorkflowTool(definition: search.definition, effect: .readOnly,
                                       store: store, operation: search.execute),
            BeanBaoGuardedWorkflowTool(definition: compose.definition, effect: .localMutation,
                                       store: store, operation: compose.execute),
            BeanBaoGuardedWorkflowTool(definition: pdf.definition, effect: .localMutation,
                                       store: store, operation: pdf.execute),
            BeanBaoGuardedWorkflowTool(definition: mail.definition, effect: .localMutation,
                                       store: store, operation: mail.execute),
            BeanBaoGuardedWorkflowTool(definition: lookup.definition, effect: .readOnly,
                                       store: store, operation: lookup.execute),
            BeanBaoGuardedWorkflowTool(definition: prepare.definition, effect: .localMutation,
                                       store: store, operation: prepare.execute)
        ]
        let session = await BeanBaoWorkflowSession(store: store,
            client: ScriptedResearchAppMailPlanner(sourceURL: sourceURL),
            model: "scripted", systemPrompt: "Create all three outputs", tools: tools,
            completionCheck: {
                (try? BeanBaoMailDraftTool.readDraft(at: draftURL)) != nil &&
                (try? BeanBaoAppPrepareTool.read(at: candidateURL)) != nil &&
                (try? Data(contentsOf: pdfURL)).flatMap(PDFDocument.init(data:))?.pageCount ?? 0 > 0
            }, successPhase: .waitingForUser)
        _ = try await session.run(request)
        let saved = await store.snapshot()
        XCTAssertEqual(saved.phase, .waitingForUser)
        XCTAssertEqual(saved.operations.values.filter { $0.state == .completed }.count, 6)
        XCTAssertEqual(try BeanBaoMailDraftTool.readDraft(at: draftURL).recipient,
                       "test@example.com")
        XCTAssertEqual(try BeanBaoAppPrepareTool.read(at: candidateURL).bundleID,
                       "com.example.notes")
        try await store.markAppInstalled(bundleID: "com.example.notes")
        let waiting = await store.snapshot()
        XCTAssertEqual(waiting.phase, .waitingForUser)
        try await store.markMailQueued()
        let done = await store.snapshot()
        XCTAssertEqual(done.phase, .completed)
    }
}
