import Foundation
import XCTest
import AgentRuntime
import BeanBaoTextHarness

private struct DeliveryScriptModel: PHKModelClient {
    let action: String
    let target: String
    let observationID: String

    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let events: [PHKModelEvent]
        if request.messages.last?.role == .tool {
            events = [.contentDelta("One action proposed for review."), .completed(.stop)]
        } else {
            let arguments = "{\"action\":\"\(action)\",\"target\":\"\(target)\",\"observation_id\":\"\(observationID)\"}"
            events = [.toolCallDelta(.init(index: 0, id: "delivery-proposal", name: "delivery_choose",
                                           arguments: arguments)), .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

final class DeliveryPlannerTests: XCTestCase {
    private func observation(_ url: String, _ text: String) -> BeanBaoUberEatsObservation {
        .init(url: URL(string: url)!, visibleText: text, bundleID: "dev.beanbao.deliverybrowser",
              observedAt: Date())
    }

    private func store(request: String = "Find a rice bowl") throws -> (BeanBaoWorkflowStore, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbao-delivery-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("session.json")
        return (try BeanBaoWorkflowStore(url: url, request: request), url)
    }

    func testPalminoChoosesSeveralPageBoundActionsWithoutSavingPageText() async throws {
        let (journal, file) = try store()
        let pages: [(String, String, String, String)] = [
            ("https://www.ubereats.com/feed", "Search Uber Eats private-page-marker",
             "open_search", ""),
            ("https://www.ubereats.com/search-suggestions", "Search Uber Eats private-page-marker",
             "search", "rice bowl"),
            ("https://www.ubereats.com/search?q=rice", "Example Kitchen private-page-marker",
             "open_merchant", "Example Kitchen"),
            ("https://www.ubereats.com/store/example/id", "Search Uber Eats Rice bowl private-page-marker",
             "open_item", "Rice bowl"),
            ("https://www.ubereats.com/store/example/id?mod=quickView", "Rice bowl Add 1 to order private-page-marker",
             "add_to_cart", ""),
            ("https://www.ubereats.com/store/example/id", "Go to checkout private-page-marker",
             "open_checkout", "")
        ]
        for (url, text, action, target) in pages {
            let seen = observation(url, text)
            let id = try BeanBaoDeliveryObservationContract.identifier(seen)
            let proposal = try await BeanBaoDeliveryPlanner.choose(
                request: "Find a rice bowl", observation: seen, store: journal,
                client: DeliveryScriptModel(action: action, target: target, observationID: id),
                model: "scripted")
            XCTAssertEqual(proposal, .init(action: action, target: target, observationID: id))
            let saved = await journal.snapshot()
            XCTAssertEqual(saved.phase, .waitingForUser)
        }
        let data = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-page-marker"))
        let saved = await journal.snapshot()
        XCTAssertEqual(saved.operations.count, pages.count)
        XCTAssertNil(saved.checkpoint)
        let last = pages.last!
        let lastPage = observation(last.0, last.1)
        let cached = try await BeanBaoDeliveryPlanner.choose(
            request: "Find a rice bowl", observation: lastPage, store: journal,
            client: DeliveryScriptModel(action: "place_order", target: "", observationID: "wrong"),
            model: "scripted")
        XCTAssertEqual(cached.action, "open_checkout")
        do {
            _ = try await BeanBaoDeliveryPlanner.choose(
                request: "Find a different meal", observation: lastPage, store: journal,
                client: DeliveryScriptModel(action: "place_order", target: "", observationID: "wrong"),
                model: "scripted")
            XCTFail("A different user request cannot reuse a saved proposal")
        } catch BeanBaoWorkflowError.invalidRecord { }
    }

    func testChangedPageAndOrderPlacementAreRejectedBeforeBrowserAction() async throws {
        let seen = observation("https://www.ubereats.com/store/example/id", "Go to checkout")
        let id = try BeanBaoDeliveryObservationContract.identifier(seen)
        let changed = observation("https://www.ubereats.com/store/example/id", "Go to checkout New total $27.99")
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            .init(action: "open_checkout", target: "", observationID: id),
            observation: changed))
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            .init(action: "place_order", target: "", observationID: id),
            observation: seen))
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            .init(action: "open_item", target: "Secret item", observationID: id),
            observation: seen))

        let (journal, _) = try store()
        do {
            _ = try await BeanBaoDeliveryPlanner.choose(
                request: "Find a rice bowl", observation: seen, store: journal,
                client: DeliveryScriptModel(action: "place_order", target: "", observationID: id),
                model: "scripted")
            XCTFail("The model cannot create a purchase action")
        } catch { }
        let saved = await journal.snapshot()
        XCTAssertTrue(saved.operations.isEmpty)
        XCTAssertEqual(saved.phase, .failed)
    }

    func testModelCanFinishReviewOnlyRequestAtFreshItemOptions() async throws {
        let (journal, file) = try store(request: "Find Chicken Pho and review its options")
        let item = observation("https://www.ubereats.com/store/example/id?mod=quickView",
                               "Chicken Pho Rice Noodle Egg Noodle Add 1 to order private-page-marker")
        let id = try BeanBaoDeliveryObservationContract.identifier(item)
        let proposal = try await BeanBaoDeliveryPlanner.choose(
            request: "Find Chicken Pho and review its options", observation: item, store: journal,
            client: DeliveryScriptModel(action: "review_options", target: "", observationID: id),
            model: "scripted")
        XCTAssertEqual(proposal.action, "review_options")
        let changed = observation(item.url.absoluteString,
                                  "Chicken Pho Egg Noodle Add 1 to order")
        do {
            try await BeanBaoDeliveryPlanner.completeOptionsReview(proposal, on: changed,
                                                                   store: journal)
            XCTFail("A changed page cannot complete the review")
        } catch BeanBaoDeliveryPlanError.invalidAction { }
        try await BeanBaoDeliveryPlanner.completeOptionsReview(proposal, on: item, store: journal)
        let saved = await journal.snapshot()
        XCTAssertEqual(saved.phase, .completed)
        XCTAssertEqual(saved.operations["delivery-review-v1-\(id)"]?.state, .completed)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self)
            .contains("private-page-marker"))
        try await BeanBaoDeliveryPlanner.completeOptionsReview(proposal, on: item, store: journal)
        let repeated = await journal.snapshot()
        XCTAssertEqual(repeated.operations.count, 2)
    }

    func testFeedMustOpenSearchBeforeSubmittingAQuery() throws {
        let feed = observation("https://www.ubereats.com/feed", "Search Uber Eats")
        let feedID = try BeanBaoDeliveryObservationContract.identifier(feed)
        XCTAssertTrue(try BeanBaoDeliveryObservationContract.allowed(
            .init(action: "open_search", target: "", observationID: feedID),
            observation: feed))
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            .init(action: "search", target: "rice bowl", observationID: feedID),
            observation: feed))
        let input = observation("https://www.ubereats.com/search-suggestions", "Search Uber Eats")
        let inputID = try BeanBaoDeliveryObservationContract.identifier(input)
        XCTAssertTrue(try BeanBaoDeliveryObservationContract.allowed(
            .init(action: "search", target: "rice bowl", observationID: inputID),
            observation: input))
    }

    func testLoginAndStalePagesCannotBePlanned() throws {
        let login = observation("https://auth.uber.com/v2/", "Enter phone number")
        XCTAssertThrowsError(try BeanBaoDeliveryObservationContract.identifier(login))
        let old = BeanBaoUberEatsObservation(
            url: URL(string: "https://www.ubereats.com/feed")!, visibleText: "Search Uber Eats",
            bundleID: "dev.beanbao.deliverybrowser", observedAt: Date(timeIntervalSinceNow: -30))
        XCTAssertThrowsError(try BeanBaoDeliveryObservationContract.identifier(old))
    }

    func testActionReceiptRequiresTheSameFreshVisiblePage() throws {
        let seen = observation("https://www.ubereats.com/store/example/id", "Go to checkout")
        let id = try BeanBaoDeliveryObservationContract.identifier(seen)
        let proposal = BeanBaoDeliveryProposal(action: "open_checkout", target: "",
                                                observationID: id)
        let action = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)
        func receipt(_ text: String) throws -> [String: Any] {
            let snapshot: [String: Any] = [
                "url": seen.url.absoluteString, "visible_text": text,
                "bundle_id": seen.bundleID,
                "observed_at": Date().timeIntervalSince1970
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: snapshot),
                              as: UTF8.self)
            let pointer = json.withCString { snapshotPointer in
                action.withCString { actionPointer in
                    BBUberEatsValidateAction(snapshotPointer, actionPointer)
                }
            }
            defer { free(pointer) }
            return try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(String(cString: XCTUnwrap(pointer)).utf8)) as? [String: Any])
        }
        XCTAssertEqual(try receipt("Go to checkout")["valid"] as? Bool, true)
        XCTAssertEqual(try receipt("Go to checkout Total $99.99")["valid"] as? Bool, false)
    }

    func testCartMutationNeedsOneDurableAttemptAndVerifiedNextPage() async throws {
        let (journal, _) = try store()
        let cart = observation("https://www.ubereats.com/store/example/id", "Go to checkout")
        let id = try BeanBaoDeliveryObservationContract.identifier(cart)
        let proposal = try await BeanBaoDeliveryPlanner.choose(
            request: "Find a rice bowl", observation: cart, store: journal,
            client: DeliveryScriptModel(action: "open_checkout", target: "", observationID: id),
            model: "scripted")
        try await BeanBaoDeliveryPlanner.begin(proposal, store: journal)
        do {
            try await BeanBaoDeliveryPlanner.begin(proposal, store: journal)
            XCTFail("A possibly clicked step cannot run twice")
        } catch BeanBaoWorkflowError.outcomeUnconfirmed { }
        let wrong = observation("https://www.ubereats.com/search", "Restaurant results")
        do {
            _ = try await BeanBaoDeliveryPlanner.finish(proposal, after: wrong, store: journal)
            XCTFail("A search page cannot prove checkout navigation")
        } catch BeanBaoDeliveryPlanError.invalidObservation { }
        let checkout = observation("https://www.ubereats.com/checkout", "Place order Total $30.00")
        let confirmedPage = try await BeanBaoDeliveryPlanner.finish(
            proposal, after: checkout, store: journal)
        XCTAssertEqual(confirmedPage, .checkout)
        let saved = await journal.snapshot()
        XCTAssertEqual(saved.phase, .waitingForUser)
        XCTAssertEqual(saved.operations["delivery-execute-v1-\(id)"]?.state, .completed)
        do {
            _ = try await BeanBaoDeliveryPlanner.choose(
                request: "Find a rice bowl", observation: cart, store: journal,
                client: DeliveryScriptModel(action: "open_checkout", target: "", observationID: id),
                model: "scripted")
            XCTFail("Returning to the old page must not replay the old action")
        } catch BeanBaoWorkflowError.outcomeUnconfirmed { }
    }
}
