import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import AgentRuntime
import AgentTools
#endif

public enum BeanBaoAppCatalogError: Error, LocalizedError {
    case invalidQuery
    case invalidResponse
    case listingNotFound
    case unsearchedListing

    public var errorDescription: String? {
        switch self {
        case .invalidQuery: "The App Store search request is invalid."
        case .invalidResponse: "The App Store catalog response is invalid."
        case .listingNotFound: "No matching App Store listing was found."
        case .unsearchedListing: "The selected listing was not returned by this search."
        }
    }
}

public struct BeanBaoAppListing: Codable, Equatable, Sendable {
    public let productID: Int64
    public let name: String
    public let developer: String
    public let bundleID: String
    public let price: Decimal
    public let currency: String
    public let country: String

    public init(productID: Int64, name: String, developer: String,
                bundleID: String, price: Decimal, currency: String, country: String) {
        self.productID = productID
        self.name = name
        self.developer = developer
        self.bundleID = bundleID
        self.price = price
        self.currency = currency
        self.country = country
    }
}

public actor BeanBaoAppCatalogEvidence {
    private var listings: [Int64: BeanBaoAppListing] = [:]
    private let storeURL: URL?
    public init() { storeURL = nil }
    public init(storeURL: URL) throws {
        self.storeURL = storeURL
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let restored = try JSONDecoder().decode([BeanBaoAppListing].self,
                from: BeanBaoWorkflowStore.readPrivateFile(storeURL))
            guard restored.count <= 50 else { throw BeanBaoAppCatalogError.invalidResponse }
            listings = Dictionary(restored.map { ($0.productID, $0) },
                                  uniquingKeysWith: { first, _ in first })
        }
    }
    public func add(_ values: [BeanBaoAppListing]) throws {
        for listing in values { listings[listing.productID] = listing }
        if let storeURL {
            guard listings.count <= 50 else { throw BeanBaoAppCatalogError.invalidResponse }
            try BeanBaoWorkflowStore.writePrivateFile(
                JSONEncoder().encode(listings.values.sorted { $0.productID < $1.productID }),
                to: storeURL)
        }
    }
    public func listing(_ id: Int64) -> BeanBaoAppListing? { listings[id] }
}

public struct BeanBaoAppCatalogClient: Sendable {
    private let transport: BeanBaoClaudeTransport
    private let country: String

    public init(country: String = Locale.current.region?.identifier ?? "US",
                transport: BeanBaoClaudeTransport? = nil) {
        self.country = country
        self.transport = transport ?? BeanBaoClaudeWorkflowClient.defaultTransport
    }

    public func search(_ query: String) async throws -> [BeanBaoAppListing] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...80).contains(term.count),
              country.range(of: "^[A-Za-z]{2}$", options: .regularExpression) != nil else {
            throw BeanBaoAppCatalogError.invalidQuery
        }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "country", value: country.uppercased()),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let url = components.url else { throw BeanBaoAppCatalogError.invalidQuery }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, status) = try await transport(request)
        guard status == 200 else { throw BeanBaoClaudeError.httpStatus(status) }
        return try Self.parse(data, country: country.uppercased())
    }

    public static func parse(_ data: Data, country: String) throws -> [BeanBaoAppListing] {
        guard data.count <= 512 * 1024,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = body["results"] as? [[String: Any]], results.count <= 50 else {
            throw BeanBaoAppCatalogError.invalidResponse
        }
        var values: [BeanBaoAppListing] = []
        var seen: Set<Int64> = []
        for item in results {
            guard item["wrapperType"] as? String == "software",
                  let product = item["trackId"] as? NSNumber,
                  let name = item["trackName"] as? String,
                  let developer = item["artistName"] as? String,
                  let bundle = item["bundleId"] as? String,
                  let price = item["price"] as? NSNumber,
                  let currency = item["currency"] as? String else { continue }
            let id = product.int64Value
            guard id > 0, id < 10_000_000_000,
                  !seen.contains(id),
                  (1...120).contains(name.count), (1...120).contains(developer.count),
                  bundle.range(of: "^[A-Za-z0-9.-]{3,180}$", options: .regularExpression) != nil,
                  price.doubleValue.isFinite, price.doubleValue >= 0,
                  price.doubleValue <= 10_000,
                  currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { continue }
            seen.insert(id)
            values.append(.init(productID: id, name: name, developer: developer,
                                bundleID: bundle, price: price.decimalValue,
                                currency: currency, country: country))
        }
        return values
    }
}

public struct BeanBaoAppSearchTool: PHKNativeTool {
    public let definition = PHKToolDefinition(
        name: "app_lookup", description: "Search official App Store listings by app name. Returns name, developer, product ID, bundle ID, and price for user review.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["query": .object(["type": .string("string")])]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false)
        ]))
    private let client: BeanBaoAppCatalogClient
    private let evidence: BeanBaoAppCatalogEvidence

    public init(client: BeanBaoAppCatalogClient, evidence: BeanBaoAppCatalogEvidence) {
        self.client = client
        self.evidence = evidence
    }

    public func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue {
        guard case .object(let fields) = arguments,
              case .string(let query)? = fields["query"] else {
            throw BeanBaoAppCatalogError.invalidQuery
        }
        let results = try await client.search(query)
        guard !results.isEmpty else { throw BeanBaoAppCatalogError.listingNotFound }
        try await evidence.add(results)
        return .object(["candidates": .array(results.map { item in
            .object(["product_id": .number(Double(item.productID)),
                     "name": .string(item.name), "developer": .string(item.developer),
                     "bundle_id": .string(item.bundleID),
                     "price": .string(NSDecimalNumber(decimal: item.price).stringValue),
                     "currency": .string(item.currency)])
        })])
    }
}

public struct BeanBaoAppPrepareTool: PHKNativeTool {
    public let definition = PHKToolDefinition(
        name: "app_prepare", description: "Save one exact searched App Store listing for the user to review before opening StoreKit. Does not install anything.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["product_id": .object(["type": .string("integer")])]),
            "required": .array([.string("product_id")]),
            "additionalProperties": .bool(false)
        ]))
    private let evidence: BeanBaoAppCatalogEvidence
    private let outputURL: URL

    public init(evidence: BeanBaoAppCatalogEvidence, outputURL: URL) {
        self.evidence = evidence
        self.outputURL = outputURL
    }

    public func execute(arguments: PHKJSONValue) async throws -> PHKJSONValue {
        guard case .object(let fields) = arguments,
              case .number(let raw)? = fields["product_id"], raw.isFinite,
              raw.rounded() == raw, raw > 0, raw < 10_000_000_000,
              let listing = await evidence.listing(Int64(raw)) else {
            throw BeanBaoAppCatalogError.unsearchedListing
        }
        try BeanBaoWorkflowStore.writePrivateFile(JSONEncoder().encode(listing), to: outputURL)
        return .object(["candidate_ready": .bool(true),
                        "product_id": .number(Double(listing.productID)),
                        "bundle_id": .string(listing.bundleID)])
    }

    public static func read(at url: URL) throws -> BeanBaoAppListing {
        try JSONDecoder().decode(BeanBaoAppListing.self,
                                 from: BeanBaoWorkflowStore.readPrivateFile(url))
    }

    /// The App Store callback may finish only this prepared listing. A
    /// research-plus-app session must also keep its completed PDF artifact.
    public static func verifyForCompletion(record: BeanBaoWorkflowRecord,
                                           folder: URL, bundleID: String) throws {
        guard record.phase == .waitingForUser,
              record.operations.values.contains(where: {
                  $0.tool == "app_prepare" && $0.state == .completed
              }) else { throw BeanBaoAppCatalogError.unsearchedListing }
        let listing = try read(at: folder.appendingPathComponent("app-candidate.json"))
        guard listing.bundleID == bundleID else {
            throw BeanBaoAppCatalogError.unsearchedListing
        }
        if BeanBaoCompositeRequest.appQuery(record.request) != nil {
            guard record.operations.values.contains(where: {
                    $0.tool == "pdf_render" && $0.state == .completed
                  }),
                  let data = try? BeanBaoWorkflowStore.readPrivateFile(
                    folder.appendingPathComponent("report.pdf")),
                  let provider = CGDataProvider(data: data as CFData),
                  let pdf = CGPDFDocument(provider), pdf.numberOfPages > 0 else {
                throw BeanBaoWorkflowError.completionUnverified
            }
        }
    }
}
