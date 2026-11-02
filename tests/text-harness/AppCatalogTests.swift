import Foundation
import XCTest
import AgentRuntime
import AgentTools
import BeanBaoTextHarness

private struct ScriptedAppStorePlanner: PHKModelClient {
    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let completed = request.messages.filter { $0.role == .tool }.count
        return AsyncThrowingStream { continuation in
            if completed >= 2 {
                continuation.yield(.contentDelta("The listing is ready for user review."))
                continuation.yield(.completed(.stop))
            } else {
                let name = completed == 0 ? "app_lookup" : "app_prepare"
                let arguments = completed == 0 ?
                    "{\"query\":\"Example Notes\"}" : "{\"product_id\":123456789}"
                continuation.yield(.toolCallDelta(.init(index: 0, id: "app-\(completed)",
                                                        name: name, arguments: arguments)))
                continuation.yield(.completed(.toolCalls))
            }
            continuation.finish()
        }
    }
}

final class AppCatalogTests: XCTestCase {
    func testSearchAndPrepareRequireExactCatalogIdentity() async throws {
        let response: [String: Any] = ["results": [[
            "wrapperType": "software", "trackId": 123456789,
            "trackName": "Example Notes", "artistName": "Example Studio",
            "bundleId": "com.example.notes", "price": 0, "currency": "USD"
        ]]]
        let data = try JSONSerialization.data(withJSONObject: response)
        let client = BeanBaoAppCatalogClient(country: "US", transport: { request in
            XCTAssertEqual(request.url?.host, "itunes.apple.com")
            XCTAssertEqual(request.url?.path, "/search")
            XCTAssertTrue(request.url?.absoluteString.contains("term=Example%20Notes") == true)
            return (data, 200)
        })
        let evidence = BeanBaoAppCatalogEvidence()
        let search = BeanBaoAppSearchTool(client: client, evidence: evidence)
        _ = try await search.execute(arguments: .object(["query": .string("Example Notes")]))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbao-app-catalog-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("app-candidate.json")
        let prepare = BeanBaoAppPrepareTool(evidence: evidence, outputURL: output)
        do {
            _ = try await prepare.execute(arguments: .object(["product_id": .number(987654321)]))
            XCTFail("A listing invented by the model must not be saved")
        } catch BeanBaoAppCatalogError.unsearchedListing { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        _ = try await prepare.execute(arguments: .object(["product_id": .number(123456789)]))
        let saved = try BeanBaoAppPrepareTool.read(at: output)
        XCTAssertEqual(saved.name, "Example Notes")
        XCTAssertEqual(saved.developer, "Example Studio")
        XCTAssertEqual(saved.bundleID, "com.example.notes")
        XCTAssertEqual(saved.productID, 123456789)
        let uiObject = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        XCTAssertTrue(uiObject?["price"] is NSNumber,
                      "The Objective-C review screen must receive a numeric price")
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testInvalidCatalogRowsAreDiscarded() throws {
        let response: [String: Any] = ["results": [
            ["wrapperType": "software", "trackId": 1, "trackName": "Paid App",
             "artistName": "Studio", "bundleId": "com.studio.paid", "price": 3.99,
             "currency": "USD"],
            ["wrapperType": "software", "trackId": 2, "trackName": "Fake",
             "artistName": "Bad", "bundleId": "invalid bundle", "price": 0,
             "currency": "USD"],
            ["wrapperType": "music", "trackId": 3, "trackName": "Song",
             "artistName": "Singer", "bundleId": "com.singer.song", "price": 0,
             "currency": "USD"]
        ]]
        let data = try JSONSerialization.data(withJSONObject: response)
        let listings = try BeanBaoAppCatalogClient.parse(data, country: "US")
        XCTAssertEqual(listings.count, 1)
        XCTAssertEqual(listings.first?.productID, 1)
        XCTAssertEqual(listings.first?.price, Decimal(string: "3.99"))
    }

    func testSearchEvidenceSurvivesInterruptedWorkflow() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbao-app-evidence-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("app-search.json")
        let first = try BeanBaoAppCatalogEvidence(storeURL: url)
        let listing = BeanBaoAppListing(productID: 123456789, name: "Example Notes",
                                       developer: "Example Studio", bundleID: "com.example.notes",
                                       price: 0, currency: "USD", country: "US")
        try await first.add([listing])
        let resumed = try BeanBaoAppCatalogEvidence(storeURL: url)
        let saved = await resumed.listing(123456789)
        XCTAssertEqual(saved, listing)
        let prepare = BeanBaoAppPrepareTool(evidence: resumed,
                                            outputURL: folder.appendingPathComponent("app-candidate.json"))
        _ = try await prepare.execute(arguments: .object(["product_id": .number(123456789)]))
        XCTAssertEqual(try BeanBaoAppPrepareTool.read(at: folder.appendingPathComponent("app-candidate.json")),
                       listing)
    }

    func testPalminoAppStoreHandoffStopsForUserReview() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbao-app-flow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try BeanBaoWorkflowStore(url: folder.appendingPathComponent("session.json"),
                                             request: "Install Example Notes")
        let evidence = try BeanBaoAppCatalogEvidence(storeURL: folder.appendingPathComponent("app-search.json"))
        let data = try JSONSerialization.data(withJSONObject: ["results": [[
            "wrapperType": "software", "trackId": 123456789,
            "trackName": "Example Notes", "artistName": "Example Studio",
            "bundleId": "com.example.notes", "price": 0, "currency": "USD"
        ]]])
        let search = BeanBaoAppSearchTool(
            client: .init(country: "US", transport: { _ in (data, 200) }), evidence: evidence)
        let candidateURL = folder.appendingPathComponent("app-candidate.json")
        let prepare = BeanBaoAppPrepareTool(evidence: evidence, outputURL: candidateURL)
        let tools: [any PHKNativeTool] = [
            BeanBaoGuardedWorkflowTool(definition: search.definition, effect: .readOnly,
                                       store: store, operation: search.execute),
            BeanBaoGuardedWorkflowTool(definition: prepare.definition, effect: .localMutation,
                                       store: store, operation: prepare.execute)
        ]
        let session = await BeanBaoWorkflowSession(store: store, client: ScriptedAppStorePlanner(),
            model: "scripted", systemPrompt: "Search then prepare", tools: tools,
            completionCheck: { (try? BeanBaoAppPrepareTool.read(at: candidateURL)) != nil },
            successPhase: .waitingForUser)
        _ = try await session.run("Install Example Notes")
        let saved = await store.snapshot()
        XCTAssertEqual(saved.phase, .waitingForUser)
        XCTAssertEqual(saved.operations.count, 2)
        XCTAssertEqual(try BeanBaoAppPrepareTool.read(at: candidateURL).developer, "Example Studio")
    }
}
