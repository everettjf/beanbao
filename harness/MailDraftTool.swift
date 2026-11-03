import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import AgentRuntime
import AgentTools
#endif

public enum BeanBaoMailError: Error, LocalizedError, Equatable {
    case recipientNotInRequest
    case invalidDraft
    case attachmentMissing

    public var errorDescription: String? {
        switch self {
        case .recipientNotInRequest: "The email recipient was not specified in the request."
        case .invalidDraft: "The email draft is invalid."
        case .attachmentMissing: "The verified PDF attachment is missing."
        }
    }
}

public struct BeanBaoMailDraft: Codable, Sendable {
    public let recipient: String
    public let subject: String
    public let body: String
    public let attachmentName: String
    public let createdAt: Date
}

public struct BeanBaoMailDraftTool: PHKNativeTool {
    public let definition = PHKToolDefinition(
        name: "mail_prepare", description: "Prepare, but do not send, an email with the verified PDF attached. The recipient must appear exactly in the user's request.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "recipient": .object(["type": .string("string")]),
                "subject": .object(["type": .string("string")]),
                "body": .object(["type": .string("string")])
            ]),
            "required": .array([.string("recipient"), .string("subject"), .string("body")]),
            "additionalProperties": .bool(false)
        ]))
    private let request: String
    private let pdfURL: URL
    private let draftURL: URL

    public init(request: String, pdfURL: URL, draftURL: URL) {
        self.request = request
        self.pdfURL = pdfURL
        self.draftURL = draftURL
    }

    public func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue {
        guard case .object(let fields) = arguments,
              case .string(let recipient)? = fields["recipient"],
              case .string(let subject)? = fields["subject"],
              case .string(let body)? = fields["body"],
              subject.count >= 3, subject.count <= 140,
              body.count >= 3, body.count <= 3000,
              recipient.count <= 254,
              Self.requestRecipients(request).contains(recipient.lowercased()) else {
            throw BeanBaoMailError.recipientNotInRequest
        }
        guard let data = try? BeanBaoWorkflowStore.readPrivateFile(pdfURL),
              let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider), pdf.numberOfPages > 0 else {
            throw BeanBaoMailError.attachmentMissing
        }
        let draft = BeanBaoMailDraft(recipient: recipient, subject: subject,
                                     body: body, attachmentName: "report.pdf",
                                     createdAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try BeanBaoWorkflowStore.writePrivateFile(encoder.encode(draft), to: draftURL)
        return .object(["draft_ready": .bool(true),
                        "recipient": .string(recipient),
                        "attachment": .string("report.pdf")])
    }

    public static func requestRecipients(_ request: String) -> Set<String> {
        let pattern = "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: .caseInsensitive) else { return [] }
        let range = NSRange(request.startIndex..<request.endIndex, in: request)
        return Set(regex.matches(in: request, range: range).compactMap { match in
            Range(match.range, in: request).map { String(request[$0]).lowercased() }
        })
    }

    public static func readDraft(at url: URL) throws -> BeanBaoMailDraft {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BeanBaoMailError.invalidDraft
        }
        let draft = try JSONDecoder().decode(BeanBaoMailDraft.self,
                                             from: BeanBaoWorkflowStore.readPrivateFile(url))
        guard requestRecipients(draft.recipient).contains(draft.recipient.lowercased()),
              draft.attachmentName == "report.pdf" else { throw BeanBaoMailError.invalidDraft }
        return draft
    }

    /// A Mail composer callback may complete only the research session that
    /// actually prepared this draft and its verified PDF attachment.
    public static func verifyForCompletion(record: BeanBaoWorkflowRecord,
                                           folder: URL) throws {
        guard record.phase == .waitingForUser,
              record.operations.values.contains(where: {
                  $0.tool == "mail_prepare" && $0.state == .completed
              }) else { throw BeanBaoMailError.invalidDraft }
        let draft = try readDraft(at: folder.appendingPathComponent("mail-draft.json"))
        guard requestRecipients(record.request).contains(draft.recipient.lowercased()),
              !draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = try? BeanBaoWorkflowStore.readPrivateFile(
                  folder.appendingPathComponent("report.pdf")),
              let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider), pdf.numberOfPages > 0 else {
            throw BeanBaoMailError.invalidDraft
        }
    }
}
