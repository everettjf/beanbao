#if SWIFT_PACKAGE
import AgentRuntime
#endif

enum JSONSchemaValidator {
    static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "arguments") -> String? {
        guard case .object(let rules) = schema else { return nil }
        if case .array(let allowed)? = rules["enum"], !allowed.contains(value) {
            return "\(path) must be one of the allowed values."
        }
        if case .string(let expected)? = rules["type"], !matches(value, type: expected) {
            if path == "arguments", expected == "object" { return "Tool arguments must be a JSON object." }
            return "\(path) must be \(article(expected)) \(expected)."
        }
        switch value {
        case .object(let object):
            if case .array(let required)? = rules["required"] {
                let names = required.compactMap { if case .string(let name) = $0 { name } else { nil } }
                let missing = names.filter { object[$0] == nil }.sorted()
                if !missing.isEmpty { return "Missing required argument(s): \(missing.joined(separator: ", "))." }
            }
            if case .object(let properties)? = rules["properties"] {
                for key in properties.keys.sorted() {
                    if let child = object[key], let childSchema = properties[key],
                       let error = validate(child, against: childSchema, path: "\(path).\(key)") { return error }
                }
            }
        case .array(let values):
            if let itemSchema = rules["items"] {
                for (index, child) in values.enumerated() {
                    if let error = validate(child, against: itemSchema, path: "\(path)[\(index)]") { return error }
                }
            }
        default: break
        }
        return nil
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string),
             ("number", .number), ("integer", .number), ("boolean", .bool), ("null", .null): return true
        default: return false
        }
    }

    private static func article(_ value: String) -> String {
        value.first.map { "aeiou".contains($0.lowercased()) } == true ? "an" : "a"
    }
}
