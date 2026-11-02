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

        let invented: PHKJSONValue = .object([
            "recipient": .string("other@example.com"),
            "subject": .string("iOS speech report"),
            "body": .string("Please find the report attached.")
        ])
        do {
            _ = try await tool.execute(arguments: invented)
            XCTFail("The model cannot choose a different recipient")
        } catch BeanBaoMailError.recipientNotInRequest { }
    }
}
