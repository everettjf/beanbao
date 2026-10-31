import Foundation
#if SWIFT_PACKAGE
import AgentRuntime
#endif

public actor FileToolResultOffloader: ToolResultOffloading {
    private let directory: URL
    private let encoder: JSONEncoder

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("PalminoHarnessKit/ToolResults", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    public func store(_ value: JSONValue, suggestedName: String) async throws -> JSONValue {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        return .object([
            "identifier": .string(id.uuidString),
            "name": .string(suggestedName),
            "media_type": .string("application/json"),
            "bytes": .number(Double(data.count)),
            "url": .string(url.absoluteString)
        ])
    }
}
