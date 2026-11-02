import Foundation
import CoreGraphics
import CoreText
#if SWIFT_PACKAGE
import AgentRuntime
import AgentTools
#endif

public enum BeanBaoPDFError: Error, LocalizedError {
    case renderFailed
    case tooManyPages

    public var errorDescription: String? {
        switch self {
        case .renderFailed: "The PDF could not be rendered or verified."
        case .tooManyPages: "The report exceeds the PDF page limit."
        }
    }
}

public enum BeanBaoReportPDFRenderer {
    public static func data(for document: BeanBaoReportDocument) throws -> Data {
        let content = NSMutableAttributedString(string: "")
        let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 23, nil)
        let headingFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil)
        let bodyFont = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        func append(_ text: String, font: CTFont) {
            content.append(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]))
        }
        append(document.title + "\n\n", font: titleFont)
        let date = DateFormatter.localizedString(from: document.createdAt,
                                                 dateStyle: .medium, timeStyle: .none)
        append("Prepared by BeanBao · \(date)\n\n", font: bodyFont)
        let sourceNumbers = Dictionary(document.sources.enumerated().map { ($0.element.url, $0.offset + 1) },
                                       uniquingKeysWith: { first, _ in first })
        for section in document.sections {
            append(section.heading + "\n", font: headingFont)
            for paragraph in section.paragraphs {
                let references = paragraph.sourceURLs.compactMap { sourceNumbers[$0] }
                    .map { "[\($0)]" }.joined(separator: " ")
                append(paragraph.text + " " + references + "\n\n", font: bodyFont)
            }
            append("\n", font: bodyFont)
        }
        append("Sources\n", font: headingFont)
        for (index, source) in document.sources.enumerated() {
            append("[\(index + 1)] \(source.title)\n\(source.url)\n\n", font: bodyFont)
        }

        let mutable = CFDataCreateMutable(nil, 0)!
        guard let consumer = CGDataConsumer(data: mutable) else { throw BeanBaoPDFError.renderFailed }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info = [kCGPDFContextTitle: document.title,
                    kCGPDFContextCreator: "BeanBao"] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else {
            throw BeanBaoPDFError.renderFailed
        }
        let framesetter = CTFramesetterCreateWithAttributedString(content)
        let path = CGPath(rect: CGRect(x: 48, y: 52, width: 516, height: 688), transform: nil)
        var index = 0
        var pages = 0
        while index < content.length {
            guard pages < 40 else { throw BeanBaoPDFError.tooManyPages }
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: index, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard visible.length > 0 else { throw BeanBaoPDFError.renderFailed }
            index += visible.length
            pages += 1
        }
        context.closePDF()
        let data = mutable as Data
        guard data.count >= 100,
              let provider = CGDataProvider(data: data as CFData),
              let verified = CGPDFDocument(provider), verified.numberOfPages == pages else {
            throw BeanBaoPDFError.renderFailed
        }
        return data
    }
}

public struct BeanBaoPDFRenderTool: PHKNativeTool {
    public let definition = PHKToolDefinition(
        name: "pdf_render", description: "Render the previously verified report as a PDF on this device.",
        parameters: .object(["type": .string("object"), "properties": .object([:]),
                             "additionalProperties": .bool(false)]))
    private let reportURL: URL
    private let pdfURL: URL

    public init(reportURL: URL, pdfURL: URL) {
        self.reportURL = reportURL
        self.pdfURL = pdfURL
    }

    public func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue {
        guard case .object(let fields) = arguments, fields.isEmpty else {
            throw BeanBaoReportError.invalidStructure
        }
        let report = try BeanBaoReportComposeTool.readReport(at: reportURL)
        let data = try BeanBaoReportPDFRenderer.data(for: report)
        try BeanBaoWorkflowStore.writePrivateFile(data, to: pdfURL)
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else {
            throw BeanBaoPDFError.renderFailed
        }
        return .object(["pdf_ready": .bool(true),
                        "pages": .number(Double(document.numberOfPages)),
                        "bytes": .number(Double(data.count))])
    }
}
