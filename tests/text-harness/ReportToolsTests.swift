import Foundation
import PDFKit
import XCTest
import AgentRuntime
import BeanBaoTextHarness

final class ReportToolsTests: XCTestCase {
    private let source = BeanBaoResearchSource(
        url: "https://developer.apple.com/documentation/speech",
        title: "Speech | Apple Developer",
        citedText: "Recognize and transcribe speech")

    private func location() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbao-report-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return parent
    }

    private func arguments(sourceURL: String) -> PHKJSONValue {
        .object([
            "title": .string("On-device speech recognition on iOS"),
            "sections": .array([.object([
                "heading": .string("Overview"),
                "paragraphs": .array([.object([
                    "text": .string("Apple provides an API for recognizing and transcribing speech on supported devices."),
                    "source_urls": .array([.string(sourceURL)])
                ])])
            ])])
        ])
    }

    func testVerifiedCitationsRenderReadablePDF() async throws {
        let parent = try location()
        let store = try BeanBaoWorkflowStore(url: parent.appendingPathComponent("session.json"),
                                             request: "Research iOS speech")
        let evidence = BeanBaoResearchEvidence(store: store)
        try await evidence.add([source])
        let reportURL = parent.appendingPathComponent("report.json")
        let pdfURL = parent.appendingPathComponent("report.pdf")
        let compose = BeanBaoReportComposeTool(evidence: evidence, reportURL: reportURL)
        _ = try await compose.execute(arguments: arguments(sourceURL: source.url))
        let saved = await store.snapshot()
        XCTAssertEqual(saved.sources.count, 1)
        let restored = BeanBaoResearchEvidence(store: store, restored: saved.sources)
        let known = await restored.contains(source.url)
        XCTAssertTrue(known)
        let render = BeanBaoPDFRenderTool(reportURL: reportURL, pdfURL: pdfURL)
        _ = try await render.execute(arguments: .object([:]))
        let data = try Data(contentsOf: pdfURL)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        let text = pdf.string ?? ""
        XCTAssertTrue(text.contains("On-device speech recognition on iOS"))
        XCTAssertTrue(text.contains(source.url))
        let linkURLs = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
            .flatMap(\.annotations)
            .compactMap { ($0.action as? PDFActionURL)?.url?.absoluteString }
        XCTAssertTrue(linkURLs.contains(source.url), "Source URL must be clickable in the PDF")
        let attributes = try FileManager.default.attributesOfItem(atPath: pdfURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLongReportKeepsHeadingsWithBodyAndAvoidsOrphanSourcePage() throws {
        let sources = (1...14).map { number in
            BeanBaoResearchSource(
                url: "https://example.org/speech/source-\(number)",
                title: "Source \(number): On-device speech recognition, accuracy, privacy and implementation details",
                citedText: "Public technical evidence for speech recognition")
        }
        let paragraph = String(repeating:
            "On-device transcription has different model sizes, language support, accuracy and latency. ",
            count: 4)
        let headings = ["Summary", "Apple Speech", "Whisper", "Head-to-head evidence", "Recommendation"]
        let report = BeanBaoReportDocument(title: "Apple Speech vs Whisper for On-Device Dictation",
            sections: headings.map { heading in
                .init(heading: heading, paragraphs: [
                    .init(text: paragraph, sourceURLs: [sources[0].url]),
                    .init(text: paragraph, sourceURLs: [sources[1].url])
                ])
            }, sources: sources, createdAt: Date(timeIntervalSince1970: 0))
        let pdf = try XCTUnwrap(PDFDocument(data: BeanBaoReportPDFRenderer.data(for: report)))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        let pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
        XCTAssertEqual(pages.count, pdf.pageCount)
        for page in pages.dropLast() {
            let lastLine = page.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces)
            XCTAssertFalse(headings.contains(lastLine ?? ""), "A heading must not stand alone at a page foot")
            XCTAssertNotEqual(lastLine, "Sources")
        }
        XCTAssertGreaterThan(pages.last?.count ?? 0, 300,
                             "A single source must not spill onto an otherwise empty page")
        let links = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
            .flatMap(\.annotations)
            .compactMap { ($0.action as? PDFActionURL)?.url?.absoluteString }
        XCTAssertTrue(links.contains(sources[0].url))
        XCTAssertTrue(links.contains(sources[13].url))
    }

    func testShortReportKeepsFittingSourceAppendixTogether() throws {
        let sources = (1...11).map { number in
            BeanBaoResearchSource(
                url: "https://developer.example.org/reference/on-device-speech-recognition-\(number)-implementation-and-privacy",
                title: "On-device speech recognition source \(number): implementation, privacy and performance",
                citedText: "Relevant technical evidence")
        }
        let paragraph = String(repeating:
            "On-device speech recognition has different accuracy, latency and privacy tradeoffs across implementations. ",
            count: 3)
        let sections = ["Overview", "Benefits", "Constraints", "Implementation", "Caveats"]
            .enumerated().map { index, title in
                BeanBaoReportSection(heading: title, paragraphs: [
                    .init(text: paragraph, sourceURLs: [sources[index * 2].url,
                                                        sources[index * 2 + 1].url])
                ])
            }
        let report = BeanBaoReportDocument(title: "On-Device Speech Recognition: A Short Brief",
            sections: sections,
            sources: sources, createdAt: Date(timeIntervalSince1970: 0))
        let pdf = try XCTUnwrap(PDFDocument(data: BeanBaoReportPDFRenderer.data(for: report)))
        XCTAssertEqual(pdf.pageCount, 2)
        let second = try XCTUnwrap(pdf.page(at: 1)?.string)
        XCTAssertTrue(second.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("Sources"), "A source appendix that fits on one page must begin with its heading")
        let links = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
            .flatMap(\.annotations)
            .compactMap { ($0.action as? PDFActionURL)?.url?.absoluteString }
        XCTAssertEqual(Set(links), Set(sources.map(\.url)))
    }

    func testUnverifiedCitationCannotCreateReport() async throws {
        let parent = try location()
        let reportURL = parent.appendingPathComponent("report.json")
        let evidence = BeanBaoResearchEvidence()
        try await evidence.add([source])
        let compose = BeanBaoReportComposeTool(evidence: evidence, reportURL: reportURL)
        do {
            _ = try await compose.execute(arguments: arguments(sourceURL: "https://unverified.example"))
            XCTFail("An invented citation must be rejected")
        } catch BeanBaoReportError.unsupportedCitation { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path))
    }

    func testMailDraftUsesOnlyRequestedRecipientAndVerifiedPDF() async throws {
        let parent = try location()
        let pdfURL = parent.appendingPathComponent("report.pdf")
        let draftURL = parent.appendingPathComponent("mail-draft.json")
        let document = BeanBaoReportDocument(
            title: "iOS speech report",
            sections: [.init(heading: "Overview", paragraphs: [
                .init(text: "Apple provides speech recognition APIs for apps.",
                      sourceURLs: [source.url])
            ])], sources: [source], createdAt: Date())
        try BeanBaoReportPDFRenderer.data(for: document).write(to: pdfURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: pdfURL.path)
        let request = "Research iOS speech, create a PDF and email it to Test@example.com"
        let tool = BeanBaoMailDraftTool(request: request, pdfURL: pdfURL, draftURL: draftURL)
        let valid: PHKJSONValue = .object([
            "recipient": .string("Test@example.com"),
            "subject": .string("iOS speech report"),
            "body": .string("Please find the report attached.")
        ])
        _ = try await tool.execute(arguments: valid)
        let draft = try BeanBaoMailDraftTool.readDraft(at: draftURL)
        XCTAssertEqual(draft.recipient, "Test@example.com")
        XCTAssertEqual(draft.attachmentName, "report.pdf")

        let store = try BeanBaoWorkflowStore(url: parent.appendingPathComponent("session.json"),
                                             request: request)
        let unprepared = await store.snapshot()
        XCTAssertThrowsError(try BeanBaoMailDraftTool.verifyForCompletion(
            record: unprepared, folder: parent))
        _ = try await store.claim(key: "mail-prepare-test", tool: "mail_prepare",
                                  effect: .localMutation)
        try await store.finish(key: "mail-prepare-test", result: .bool(true))
        try await store.setPhase(.waitingForUser)
        let prepared = await store.snapshot()
        XCTAssertNoThrow(try BeanBaoMailDraftTool.verifyForCompletion(
            record: prepared, folder: parent))
        var unrelated = BeanBaoWorkflowRecord(request:
            "Research iOS speech and email it to other@example.com")
        unrelated.phase = .waitingForUser
        unrelated.operations = prepared.operations
        XCTAssertThrowsError(try BeanBaoMailDraftTool.verifyForCompletion(
            record: unrelated, folder: parent))

        let invented: PHKJSONValue = .object([
            "recipient": .string("other@example.com"),
            "subject": .string("iOS speech report"),
            "body": .string("Please find the report attached.")
        ])
        do {
            _ = try await tool.execute(arguments: invented)
            XCTFail("The model cannot choose a different recipient")
        } catch BeanBaoMailError.recipientNotInRequest { }
        try FileManager.default.removeItem(at: pdfURL)
        XCTAssertThrowsError(try BeanBaoMailDraftTool.verifyForCompletion(
            record: prepared, folder: parent))
    }
}
