import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
import AgentTools
#endif

public enum BeanBaoReportError: Error, LocalizedError, Equatable {
    case invalidStructure
    case unsupportedCitation(String)
    case missingReport

    public var errorDescription: String? {
        switch self {
        case .invalidStructure: "The report structure is invalid."
        case .unsupportedCitation(let url): "The report cites an unverified source: \(url)"
        case .missingReport: "No verified report is available."
        }
    }
}

public struct BeanBaoReportParagraph: Codable, Sendable {
    public let text: String
    public let sourceURLs: [String]

    public init(text: String, sourceURLs: [String]) {
        self.text = text
        self.sourceURLs = sourceURLs
    }
}

public struct BeanBaoReportSection: Codable, Sendable {
    public let heading: String
    public let paragraphs: [BeanBaoReportParagraph]

    public init(heading: String, paragraphs: [BeanBaoReportParagraph]) {
        self.heading = heading
        self.paragraphs = paragraphs
    }
}

public struct BeanBaoReportDocument: Codable, Sendable {
    public let title: String
    public let sections: [BeanBaoReportSection]
    public let sources: [BeanBaoResearchSource]
    public let createdAt: Date

    public init(title: String, sections: [BeanBaoReportSection],
                sources: [BeanBaoResearchSource], createdAt: Date) {
        self.title = title
        self.sections = sections
        self.sources = sources
        self.createdAt = createdAt
    }
}

public struct BeanBaoReportComposeTool: PHKNativeTool {
    public let definition = PHKToolDefinition(
        name: "report_compose", description: "Save a structured research report. Every paragraph must cite one or more exact, unmodified URLs returned by web_search. Copy each URL verbatim; do not rewrite its case, path, suffix, or query.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "sections": .object(["type": .string("array"), "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "heading": .object(["type": .string("string")]),
                        "paragraphs": .object(["type": .string("array"), "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "text": .object(["type": .string("string")]),
                                "source_urls": .object(["type": .string("array"), "items": .object([
                                    "type": .string("string")
                                ])])
                            ]),
                            "required": .array([.string("text"), .string("source_urls")]),
                            "additionalProperties": .bool(false)
                        ])])
                    ]),
                    "required": .array([.string("heading"), .string("paragraphs")]),
                    "additionalProperties": .bool(false)
                ])])
            ]),
            "required": .array([.string("title"), .string("sections")]),
            "additionalProperties": .bool(false)
        ]))

    private let evidence: BeanBaoResearchEvidence
    private let reportURL: URL

    public init(evidence: BeanBaoResearchEvidence, reportURL: URL) {
        self.evidence = evidence
        self.reportURL = reportURL
    }

    public func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue {
        guard case .object(let fields) = arguments,
              case .string(let title)? = fields["title"],
              title.count >= 4, title.count <= 160,
              case .array(let entries)? = fields["sections"],
              entries.count >= 1, entries.count <= 12 else {
            throw BeanBaoReportError.invalidStructure
        }
        let known = Dictionary((await evidence.all()).map { ($0.url, $0) },
                               uniquingKeysWith: { first, _ in first })
        var used: Set<String> = []
        var sections: [BeanBaoReportSection] = []
        var characters = title.count
        for entry in entries {
            guard case .object(let section) = entry,
                  case .string(let heading)? = section["heading"],
                  heading.count >= 2, heading.count <= 120,
                  case .array(let items)? = section["paragraphs"],
                  items.count >= 1, items.count <= 10 else {
                throw BeanBaoReportError.invalidStructure
            }
            characters += heading.count
            var paragraphs: [BeanBaoReportParagraph] = []
            for item in items {
                guard case .object(let paragraph) = item,
                      case .string(let text)? = paragraph["text"],
                      text.count >= 10, text.count <= 1800,
                      case .array(let citations)? = paragraph["source_urls"],
                      citations.count >= 1, citations.count <= 5 else {
                    throw BeanBaoReportError.invalidStructure
                }
                var urls: [String] = []
                for citation in citations {
                    guard case .string(let url) = citation else {
                        throw BeanBaoReportError.invalidStructure
                    }
                    guard known[url] != nil else { throw BeanBaoReportError.unsupportedCitation(url) }
                    if !urls.contains(url) { urls.append(url) }
                    used.insert(url)
                }
                characters += text.count
                guard characters <= 30_000 else { throw BeanBaoReportError.invalidStructure }
                paragraphs.append(.init(text: text, sourceURLs: urls))
            }
            sections.append(.init(heading: heading, paragraphs: paragraphs))
        }
        let document = BeanBaoReportDocument(
            title: title, sections: sections,
            sources: used.sorted().compactMap { known[$0] }, createdAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try BeanBaoWorkflowStore.writePrivateFile(encoder.encode(document), to: reportURL)
        return .object(["report_ready": .bool(true),
                        "sections": .number(Double(sections.count)),
                        "sources": .number(Double(used.count))])
    }

    public static func readReport(at url: URL) throws -> BeanBaoReportDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BeanBaoReportError.missingReport
        }
        return try JSONDecoder().decode(BeanBaoReportDocument.self,
                                        from: BeanBaoWorkflowStore.readPrivateFile(url))
    }
}
