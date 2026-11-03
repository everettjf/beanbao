import Foundation

/// A research PDF may be combined with one App Store listing and an addressed
/// email draft. The original request remains the session identity.
public enum BeanBaoCompositeRequest {
    public static func appQuery(_ request: String) -> String? {
        let pattern = #"\b(?:and|then)\s+find\s+(?:the\s+)?app\s+([A-Za-z0-9][A-Za-z0-9 .&'-]{1,79})\s*[.!?]?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern,
                                                        options: [.caseInsensitive]),
              let match = expression.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
              let full = Range(match.range, in: request),
              let capture = Range(match.range(at: 1), in: request) else { return nil }
        let research = request[..<full.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = research.lowercased()
        guard (lower.hasPrefix("research ") || lower.hasPrefix("investigate ")),
              lower.contains("pdf"),
              lower.range(of: #"\b(?:install|download|order|buy|purchase|pay|delete|remove|open|launch|post|share|change|edit|set|update|toggle|enable|disable|turn|call|navigate|route)\b"#,
                          options: .regularExpression) == nil,
              lower.range(of: #"\b(?:and|then|also)\s+(?:send\s+(?:a\s+)?(?:message|text)|message)\b"#,
                          options: .regularExpression) == nil else { return nil }
        let asksForMail = lower.range(of: #"\b(?:send|email|mail)\b"#,
                                         options: .regularExpression) != nil
        if asksForMail && BeanBaoMailDraftTool.requestRecipients(research).isEmpty { return nil }
        let query = request[capture].trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let queryLower = query.lowercased()
        guard (2...80).contains(query.count),
              !queryLower.contains(" and "), !queryLower.contains(" then "),
              !query.contains("\n") else { return nil }
        return query
    }
}
