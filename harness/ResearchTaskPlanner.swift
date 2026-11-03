import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
#endif

public enum BeanBaoResearchPlanningError: Error, Equatable {
    case invalidRequest
    case invalidProposal
    case unsupportedRequest
}

/// A model proposes which existing capabilities the workflow needs. The
/// original user text, not the proposal, remains the authority for targets.
public struct BeanBaoResearchPlan: Codable, Equatable, Sendable {
    public let mailRecipient: String?
    public let appQuery: String?
    public let installationRequested: Bool

    public init(mailRecipient: String?, appQuery: String?, installationRequested: Bool) {
        self.mailRecipient = mailRecipient
        self.appQuery = appQuery
        self.installationRequested = installationRequested
    }
}

public enum BeanBaoResearchTaskPlanner {
    private struct Proposal: Decodable {
        let mail_recipient: String
        let app_query: String
        let installation_requested: Bool
        let unsupported: Bool
    }

    private static let definition = PHKToolDefinition(
        name: "propose_research_plan",
        description: "Classify the complete user request before any research or device action. List every requested output. Never invent a recipient or app name.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "mail_recipient": .object(["type": .string("string")]),
                "app_query": .object(["type": .string("string")]),
                "installation_requested": .object(["type": .string("boolean")]),
                "unsupported": .object(["type": .string("boolean")])
            ]),
            "required": .array([.string("mail_recipient"), .string("app_query"),
                                 .string("installation_requested"), .string("unsupported")]),
            "additionalProperties": .bool(false)
        ]))

    public static func plan(request: String, model: String,
                            client: any PHKModelClient) async throws -> BeanBaoResearchPlan {
        let system = """
        You are BeanBao's planning classifier, not its executor. The available workflow can research a topic, make a sourced PDF, optionally prepare an email draft, and optionally look up one App Store app for review or installation. An addressed request to email the PDF is staged as a draft for the user's review; it is not sent automatically. It cannot silently install, place an order, purchase, open another app, or perform unrelated actions. Return exactly one propose_research_plan tool call. Use empty strings for outputs that were not requested. Copy an email address and the complete named app phrase exactly from the user's text; keep brand words such as Apple in Apple Mail, but omit a trailing "app" or "by Developer" qualifier. Set installation_requested only if the user asked to obtain or install the app. Set unsupported true for a negated, ambiguous, or extra unsupported action. Do not claim any task is done.
        """
        let completion = PHKCompletionRequest(model: model, messages: [
            PHKChatMessage(role: .system, content: system),
            PHKChatMessage(role: .user, content: request)
        ], tools: [definition], deadline: .seconds(90))
        var calls: [PHKToolCallDelta] = []
        var finish: PHKFinishReason?
        for try await event in client.stream(request: completion) {
            switch event {
            case .toolCallDelta(let call): calls.append(call)
            case .completed(let reason): finish = reason
            default: break
            }
        }
        guard finish == .toolCalls, calls.count == 1,
              calls[0].name == definition.name,
              let arguments = calls[0].arguments?.data(using: .utf8),
              arguments.count <= 4096,
              let proposal = try? JSONDecoder().decode(Proposal.self, from: arguments),
              !proposal.unsupported else { throw BeanBaoResearchPlanningError.invalidProposal }
        let recipient = proposal.mail_recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = proposal.app_query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = BeanBaoResearchPlan(mailRecipient: recipient.isEmpty ? nil : recipient,
            appQuery: app.isEmpty ? nil : app,
            installationRequested: proposal.installation_requested)
        try validate(result, request: request)
        return result
    }

    public static func validate(_ plan: BeanBaoResearchPlan,
                                request: String) throws {
        guard (12...220).contains(request.count), !request.contains("\n"),
              matches(request, #"\b(?:research|investigate|compare|analy[sz]e|study|survey|explore)\b|\blook into\b|调研|研究|比较|分析"#),
              request.localizedCaseInsensitiveContains("pdf") else {
            throw BeanBaoResearchPlanningError.invalidRequest
        }
        guard !matches(request, #"\b(?:do not|don't|never)\b|不要|请别|别"#),
              !matches(request, #"(?:^\s*|[,;&.]\s*|\b(?:and|then|also)\s+)(?:order|buy|purchase|pay|delete|remove|open|launch|post|share|change|edit|set|update|toggle|enable|disable|turn|call|navigate|route|message|send\s+(?:a\s+)?(?:message|text))\b"#),
              !matches(request, #"并(?:下单|购买|付款|删除|打开|发送消息)|然后(?:下单|购买|付款|删除|打开|发送消息)"#) else {
            throw BeanBaoResearchPlanningError.unsupportedRequest
        }
        let recipients = BeanBaoMailDraftTool.requestRecipients(request)
        if recipients.isEmpty {
            guard plan.mailRecipient == nil,
                  !matches(request, #"\b(?:email|mail|send\s+(?:an?\s+)?email)\b|邮件"#) else {
                throw BeanBaoResearchPlanningError.invalidProposal
            }
        } else {
            guard recipients.count == 1,
                  let recipient = plan.mailRecipient?.lowercased(),
                  recipients.contains(recipient) else {
                throw BeanBaoResearchPlanningError.invalidProposal
            }
        }
        // Require an app-shaped action, so ordinary research phrases such as
        // "find sources" cannot be mistaken for an App Store request.
        let appIntent = matches(request, #"\b(?:install|download)\s+(?:the\s+)?(?:app\s+)?[A-Za-z0-9]|\b(?:find|get|look\s+up)\s+(?:the\s+)?app\s+|\b(?:find|get|look\s+up)\s+(?:the\s+)?[A-Za-z0-9][A-Za-z0-9 .&'-]{1,55}\s+(?:app|(?:on|in)\s+the\s+App\s+Store)\b|\b(?:and|then|also)\s+get\s+(?:the\s+)?[A-Z][A-Za-z0-9'-]{1,40}\b|查找应用|安装应用|下载应用"#)
        if let query = plan.appQuery {
            let lower = query.lowercased()
            let escaped = NSRegularExpression.escapedPattern(for: query)
            guard appIntent, (2...80).contains(query.count),
                  !lower.contains(" and "), !lower.contains(" then "),
                  !query.contains("\n"),
                  request.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                  appActionTargets(query, in: request),
                  appActionCount(in: request) == 1,
                  !matches(request, #"\b(?:install|download|find|get)\s+(?:the\s+)?(?:app\s+)?"# +
                           escaped + #"\s+and\s+(?:the\s+)?[A-Z][A-Za-z0-9'-]+"#) else {
                throw BeanBaoResearchPlanningError.invalidProposal
            }
            let installIntent = matches(request, #"\b(?:install|download)\s+(?:the\s+)?(?:app\s+)?[A-Za-z0-9]|\bget\s+(?:the\s+)?app\s+|\b(?:and|then|also)\s+get\s+(?:the\s+)?[A-Z][A-Za-z0-9'-]{1,40}\b|安装应用|下载应用"#)
            guard plan.installationRequested == installIntent else {
                throw BeanBaoResearchPlanningError.invalidProposal
            }
        } else {
            guard !appIntent, !plan.installationRequested else {
                throw BeanBaoResearchPlanningError.invalidProposal
            }
        }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func appActionTargets(_ query: String, in request: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: query)
        let pattern = #"\b(?:install|download|find|get|look\s+up)\s+(?:the\s+)?(?:app\s+)?"# +
            escaped + #"(?:\s+app)?(?:\s+by\s+[A-Za-z][A-Za-z0-9 .&'-]{0,60}?)?(?:\s+(?:on|in)\s+(?:the\s+)?App\s+Store)?\s*(?:[,.;!?]|$|\band\b|\bthen\b)"#
        return matches(request, pattern)
    }

    public static func developerQualifier(appQuery: String, request: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: appQuery)
        let pattern = #"\b(?:install|download|find|get|look\s+up)\s+(?:the\s+)?(?:app\s+)?"# +
            escaped + #"(?:\s+app)?\s+by\s+([A-Za-z][A-Za-z0-9 .&'-]{0,60}?)(?=\s*(?:[,;!?]|$|\band\b|\bthen\b))"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: request,
                  range: NSRange(request.startIndex..., in: request)),
              let range = Range(match.range(at: 1), in: request) else { return nil }
        let value = request[range].trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return value.isEmpty ? nil : value
    }

    private static func appActionCount(in request: String) -> Int {
        let pattern = #"\b(?:and|then|also)\s+get\s+(?:the\s+)?[A-Z][A-Za-z0-9'-]{1,40}\b|\b(?:install|download)\s+(?:the\s+)?(?:app\s+)?[A-Za-z0-9]|\b(?:find|get|look\s+up)\s+(?:the\s+)?app\s+|\b(?:find|get|look\s+up)\s+(?:the\s+)?[A-Za-z0-9][A-Za-z0-9 .&'-]{1,55}\s+(?:app|(?:on|in)\s+the\s+App\s+Store)\b|查找应用|安装应用|下载应用"#
        guard let expression = try? NSRegularExpression(pattern: pattern,
                                                         options: .caseInsensitive) else { return 0 }
        return expression.numberOfMatches(in: request, range: NSRange(request.startIndex..., in: request))
    }
}
