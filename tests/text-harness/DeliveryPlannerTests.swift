import Foundation
import XCTest
import AgentRuntime
import BeanBaoTextHarness

private struct DeliveryScriptModel: PHKModelClient {
    let action: String
    let target: String
    let observationID: String
    let checkoutCartJSON: String?

    init(action: String, target: String, observationID: String,
         checkoutCartJSON: String? = nil) {
        self.action = action
        self.target = target
        self.observationID = observationID
        self.checkoutCartJSON = checkoutCartJSON
    }

    func stream(request: PHKCompletionRequest) -> AsyncThrowingStream<PHKModelEvent, Error> {
        let events: [PHKModelEvent]
        if request.messages.last?.role == .tool {
            events = [.contentDelta("One action proposed for review."), .completed(.stop)]
        } else {
            var fields: [String: Any] = ["action": action, "target": target,
                                         "observation_id": observationID]
            if let checkoutCartJSON { fields["checkout_cart_json"] = checkoutCartJSON }
            let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: fields),
                                   as: UTF8.self)
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
    private func observation(_ url: String, _ text: String,
                             selected: [String] = [],
                             available: [String] = []) -> BeanBaoUberEatsObservation {
        .init(url: URL(string: url)!, visibleText: text, bundleID: "dev.beanbao.deliverybrowser",
              observedAt: Date(), selectedOptions: selected,
              availableOptions: available)
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
        let request = "Find a rice bowl, add it to the cart, and open checkout to review the total"
        let (journal, file) = try store(request: request)
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
            ("https://www.ubereats.com/store/example/id", "View order private-page-marker",
             "open_cart", ""),
            ("https://www.ubereats.com/cart", "Go to checkout private-page-marker",
             "open_checkout", "")
        ]
        for (url, text, action, target) in pages {
            let seen = observation(url, text)
            let id = try BeanBaoDeliveryObservationContract.identifier(seen)
            let proposal = try await BeanBaoDeliveryPlanner.choose(
                request: request, observation: seen, store: journal,
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
            request: request, observation: lastPage, store: journal,
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
        let seen = observation("https://www.ubereats.com/cart", "Go to checkout")
        let id = try BeanBaoDeliveryObservationContract.identifier(seen)
        let changed = observation("https://www.ubereats.com/cart", "Go to checkout New total $27.99")
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
            try await BeanBaoDeliveryPlanner.completeReadOnlyReview(proposal, on: changed,
                                                                    store: journal)
            XCTFail("A changed page cannot complete the review")
        } catch BeanBaoDeliveryPlanError.invalidAction { }
        try await BeanBaoDeliveryPlanner.completeReadOnlyReview(proposal, on: item, store: journal)
        let saved = await journal.snapshot()
        XCTAssertEqual(saved.phase, .completed)
        XCTAssertEqual(saved.operations["delivery-review-v1-\(id)"]?.state, .completed)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self)
            .contains("private-page-marker"))
        try await BeanBaoDeliveryPlanner.completeReadOnlyReview(proposal, on: item, store: journal)
        let repeated = await journal.snapshot()
        XCTAssertEqual(repeated.operations.count, 2)
    }

    func testCartReviewCompletesOnlyFromTheSameFreshCart() async throws {
        let request = "Add Chicken Pho to cart and review the cart"
        let (journal, file) = try store(request: request)
        let cart = observation("https://www.ubereats.com/cart",
                               "Chicken Pho Rice Noodle $27.99 Go to checkout private-cart-marker")
        let id = try BeanBaoDeliveryObservationContract.identifier(cart)
        let proposal = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: cart, store: journal,
            client: DeliveryScriptModel(action: "review_cart", target: "", observationID: id),
            model: "scripted")
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            proposal, observation: observation(cart.url.absoluteString,
                "Chicken Pho $28.99 Go to checkout")))
        do {
            try await BeanBaoDeliveryPlanner.completeReadOnlyReview(
                proposal, on: observation(cart.url.absoluteString,
                    "Chicken Pho $28.99 Go to checkout"), store: journal)
            XCTFail("A changed cart cannot complete the review")
        } catch BeanBaoDeliveryPlanError.invalidAction { }
        try await BeanBaoDeliveryPlanner.completeReadOnlyReview(
            proposal, on: cart, store: journal)
        let saved = await journal.snapshot()
        XCTAssertEqual(saved.phase, .completed)
        XCTAssertEqual(saved.operations["delivery-review-v1-\(id)"]?.tool,
                       "delivery_review_cart")
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self)
            .contains("private-cart-marker"))
    }

    func testCheckoutReviewRequiresCompleteBoundSummaryAndOneShotCommit() async throws {
        let request = "Add Rice bowl to cart and open checkout to review the total"
        let (journal, file) = try store(request: request)
        let merchantKey = "delivery-execute-v1-merchant"
        _ = try await journal.claim(key: merchantKey, tool: "delivery_execute",
                                    effect: .localMutation)
        try await journal.finish(key: merchantKey, result: .object([
            "transition_verified": .bool(true), "merchant_id": .string("merchant-123")]))
        let draft = BeanBaoDeliveryCheckoutDraft(merchantName: "Example Kitchen",
            items: [.init(name: "Rice bowl", options: ["No onions"], quantity: 1,
                          lineTotalMinor: 1800)],
            address: "200 E Santa Clara St, San Jose, CA", currency: "USD",
            subtotalMinor: 1800, taxMinor: 149, deliveryFeeMinor: 350,
            serviceFeeMinor: 100, tipMinor: 100,
            adjustments: [.init(name: "Small order fee", amountMinor: 250),
                          .init(name: "Promotion", amountMinor: -100)],
            totalMinor: 2649, arrivalEstimate: nil)
        let draftJSON = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        let text = """
        Example Kitchen 1 × Rice bowl No onions $18.00
        Deliver to 200 E Santa Clara St, San Jose, CA
        Subtotal $18.00 Tax $1.49 Delivery fee $3.50 Service fee $1.00
        Small order fee $2.50 Promotion -$1.00 Tip $1.00
        Total $26.49 Place order private-checkout-marker
        """
        let checkout = observation("https://www.ubereats.com/checkout", text)
        let id = try BeanBaoDeliveryObservationContract.identifier(checkout)
        let proposal = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: checkout, store: journal,
            client: DeliveryScriptModel(action: "review_checkout", target: "",
                                        observationID: id, checkoutCartJSON: draftJSON),
            model: "scripted")
        let changed = observation(checkout.url.absoluteString,
                                  text.replacingOccurrences(of: "$26.49", with: "$28.49"))
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            proposal, observation: changed, request: request))
        do {
            try await BeanBaoDeliveryPlanner.completeReadOnlyReview(proposal,
                                                                    on: changed, store: journal)
            XCTFail("Changed total completed checkout review")
        } catch BeanBaoDeliveryPlanError.invalidAction { }
        try await BeanBaoDeliveryPlanner.completeReadOnlyReview(proposal,
                                                                on: checkout, store: journal)
        let saved = await journal.snapshot()
        XCTAssertEqual(saved.phase, .completed)
        let receipt = saved.operations["delivery-review-v1-\(id)"]
        XCTAssertEqual(receipt?.tool, "delivery_review_checkout")
        guard case .object(let fields)? = receipt?.result else {
            return XCTFail("Checkout receipt missing")
        }
        XCTAssertEqual(fields["visible_total"], .string("Total $26.49"))
        XCTAssertNotNil(fields["cart_digest"])
        let gatePath = await journal.checkoutReviewURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: gatePath.path))
        let journalText = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(journalText.contains("private-checkout-marker"))
        XCTAssertFalse(journalText.contains("Place order"))
        guard case .string(let digest)? = fields["cart_digest"] else {
            return XCTFail("Checkout digest missing")
        }
        do {
            try await BeanBaoDeliveryPlanner.beginOrderCommit(
                approvedDigest: String(repeating: "f", count: 64), on: checkout, store: journal)
            XCTFail("A different displayed digest must not authorize an order")
        } catch BeanBaoDeliveryReviewError.approvalRequired { }
        let otherScreen = observation(checkout.url.absoluteString,
            text.replacingOccurrences(of: "private-checkout-marker", with: "new checkout copy"))
        do {
            try await BeanBaoDeliveryPlanner.beginOrderCommit(
                approvedDigest: digest, on: otherScreen, store: journal)
            XCTFail("A changed checkout screen must not authorize an order")
        } catch BeanBaoDeliveryReviewError.changedCart { }
        try await BeanBaoDeliveryPlanner.beginOrderCommit(
            approvedDigest: digest, on: checkout, store: journal)
        let begun = await journal.snapshot()
        XCTAssertEqual(begun.operations["delivery-order-v1"]?.effect, .externalCommit)
        XCTAssertEqual(begun.operations["delivery-order-v1"]?.state, .running)
        let restored = try BeanBaoWorkflowStore(existingURL: file)
        let restoredRecord = await restored.snapshot()
        XCTAssertEqual(restoredRecord.phase, .needsReconciliation)
        do {
            try await BeanBaoDeliveryPlanner.beginOrderCommit(
                approvedDigest: digest, on: checkout, store: restored)
            XCTFail("An interrupted order commit must never be replayed")
        } catch BeanBaoDeliveryReviewError.approvalRequired { }
    }

    func testIncompleteCheckoutCannotBeRecorded() throws {
        let full = "Deliver to 200 E Santa Clara St Subtotal $18.00 Total $22.99 Place order"
        let url = "https://www.ubereats.com/checkout"
        XCTAssertEqual(BeanBaoUberEatsAdapter.checkoutVisibleTotal(observation(url, full)),
                       "Total $22.99")
        for text in ["Subtotal $18.00 Total $22.99 Place order",
                     "Deliver to 200 E Santa Clara St Total $22.99 Place order",
                     "Deliver to 200 E Santa Clara St Subtotal $18.00 Total $22.99 Total $23.99 Place order",
                     "Deliver to 200 E Santa Clara St Subtotal $18.00 Total $22.99"] {
            XCTAssertNil(BeanBaoUberEatsAdapter.checkoutVisibleTotal(observation(url, text)))
        }
    }

    func testModelCannotInventCheckoutAmountsOrMerchantIdentity() async throws {
        let request = "Open checkout to review the total"
        let checkout = observation("https://www.ubereats.com/checkout", """
            Example Kitchen 1 × Rice bowl $10.00
            Deliver to 200 E Santa Clara St, San Jose, CA
            Subtotal $10.00 Tax $1.00 Total $11.00 Place order
            """)
        let id = try BeanBaoDeliveryObservationContract.identifier(checkout)
        let invented = BeanBaoDeliveryCheckoutDraft(merchantName: "Example Kitchen",
            items: [.init(name: "Rice bowl", options: [], quantity: 1, lineTotalMinor: 1000)],
            address: "200 E Santa Clara St, San Jose, CA", currency: "USD",
            subtotalMinor: 1000, taxMinor: 200, deliveryFeeMinor: 0,
            serviceFeeMinor: 0, tipMinor: 0, adjustments: [],
            totalMinor: 1200, arrivalEstimate: nil)
        let json = String(decoding: try JSONEncoder().encode(invented), as: UTF8.self)
        let fields: PHKJSONValue = .object([
            "action": .string("review_checkout"), "target": .string(""),
            "observation_id": .string(id), "checkout_cart_json": .string(json)])
        let missingIdentity = BeanBaoDeliveryChooseTool(observation: checkout, request: request,
            box: BeanBaoDeliveryProposalBox())
        do {
            _ = try await missingIdentity.execute(arguments: fields)
            XCTFail("Review accepted an unverified merchant")
        } catch BeanBaoDeliveryPlanError.invalidAction { }
        let wrongAmounts = BeanBaoDeliveryChooseTool(observation: checkout, request: request,
            box: BeanBaoDeliveryProposalBox(), merchantID: "merchant-123")
        do {
            _ = try await wrongAmounts.execute(arguments: fields)
            XCTFail("Review accepted invented tax and total")
        } catch BeanBaoDeliveryPlanError.invalidAction { }
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
        let seen = observation("https://www.ubereats.com/cart", "Go to checkout")
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
        let request = "Find a rice bowl, add it to the cart, and open checkout to review the total"
        let (journal, _) = try store(request: request)
        let cart = observation("https://www.ubereats.com/cart", "Go to checkout")
        let id = try BeanBaoDeliveryObservationContract.identifier(cart)
        let proposal = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: cart, store: journal,
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
                request: request, observation: cart, store: journal,
                client: DeliveryScriptModel(action: "open_checkout", target: "", observationID: id),
                model: "scripted")
            XCTFail("Returning to the old page must not replay the old action")
        } catch BeanBaoWorkflowError.outcomeUnconfirmed { }
    }

    func testOptionSelectionRequiresRadioStateChangeOnTheSameItemPage() async throws {
        let request = "Find a rice bowl and choose Rice Noodle"
        let (journal, _) = try store(request: request)
        let url = "https://www.ubereats.com/store/example/id?mod=quickView"
        let text = "Chicken Pho Rice Noodle Ramen Noodle Add 1 to order"
        let before = observation(url, text)
        let id = try BeanBaoDeliveryObservationContract.identifier(before)
        let proposal = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: before, store: journal,
            client: DeliveryScriptModel(action: "choose_option", target: "Rice Noodle",
                                        observationID: id), model: "scripted")
        try await BeanBaoDeliveryPlanner.begin(proposal, store: journal)
        do {
            _ = try await BeanBaoDeliveryPlanner.finish(proposal, after: before, store: journal)
            XCTFail("Unselected radio state cannot prove the option was chosen")
        } catch BeanBaoDeliveryPlanError.invalidObservation { }
        let after = observation(url, text, selected: ["Rice Noodle"])
        XCTAssertNotEqual(try BeanBaoDeliveryObservationContract.identifier(before),
                          try BeanBaoDeliveryObservationContract.identifier(after))
        let page = try await BeanBaoDeliveryPlanner.finish(proposal, after: after, store: journal)
        XCTAssertEqual(page, .itemConfiguration)
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(proposal,
                                                                      observation: after))
        let saved = await journal.snapshot()
        XCTAssertEqual(saved.operations["delivery-execute-v1-\(id)"]?.state, .completed)
    }

    func testNamedOptionMustBeSelectedBeforeAddToCart() throws {
        let url = "https://www.ubereats.com/store/example/id?mod=quickView"
        let text = "Chicken Pho Rice Noodle Ramen Noodle Add 1 to order • $27.99"
        let before = observation(url, text, available: ["Rice Noodle", "Ramen Noodle"])
        let id = try BeanBaoDeliveryObservationContract.identifier(before)
        let add = BeanBaoDeliveryProposal(action: "add_to_cart", target: "", observationID: id)
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            add, observation: before,
            request: "Add Chicken Pho with Rice Noodle to the cart"))
        let choose = BeanBaoDeliveryProposal(action: "choose_option", target: "Rice Noodle",
                                             observationID: id)
        XCTAssertTrue(try BeanBaoDeliveryObservationContract.allowed(
            choose, observation: before,
            request: "Add Chicken Pho with Rice Noodle to the cart"))
        let after = observation(url, text, selected: ["Rice Noodle"],
                                available: ["Rice Noodle", "Ramen Noodle"])
        let afterID = try BeanBaoDeliveryObservationContract.identifier(after)
        let ready = BeanBaoDeliveryProposal(action: "add_to_cart", target: "",
                                            observationID: afterID)
        XCTAssertTrue(try BeanBaoDeliveryObservationContract.allowed(
            ready, observation: after,
            request: "Add Chicken Pho with Rice Noodle to the cart"))
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            choose, observation: before,
            request: "Review the options. Do not choose Rice Noodle."))
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            add, observation: before,
            request: "Find Chicken Pho. Do not add it to the cart."))
    }

    func testBrowserRejectBeforeClickClosesAttemptWithoutReplayingIt() async throws {
        let request = "Find a rice bowl and choose Rice Noodle"
        let (journal, _) = try store(request: request)
        let page = observation("https://www.ubereats.com/store/example/id?mod=quickView",
                               "Chicken Pho Rice Noodle Add 1 to order")
        let id = try BeanBaoDeliveryObservationContract.identifier(page)
        let proposal = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: page, store: journal,
            client: DeliveryScriptModel(action: "choose_option", target: "Rice Noodle",
                                        observationID: id), model: "scripted")
        try await BeanBaoDeliveryPlanner.begin(proposal, store: journal)
        try await BeanBaoDeliveryPlanner.abortBeforeClick(proposal, store: journal)
        let saved = await journal.snapshot()
        XCTAssertEqual(saved.phase, .cancelled)
        XCTAssertEqual(saved.operations["delivery-execute-v1-\(id)"]?.state, .completed)
        do {
            try await BeanBaoDeliveryPlanner.begin(proposal, store: journal)
            XCTFail("A cancelled action must not be replayed")
        } catch BeanBaoWorkflowError.outcomeUnconfirmed { }
    }

    func testSelectedItemMovesThroughCartHandoffToVerifiedCartReview() async throws {
        let request = "Add Chicken Pho with Rice Noodle to cart for review"
        let (journal, _) = try store(request: request)
        let item = observation("https://www.ubereats.com/store/phin/id?mod=quickView",
                               "Chicken Pho Rice Noodle Add 1 to order • $27.99",
                               selected: ["Rice Noodle"], available: ["Rice Noodle", "Ramen Noodle"])
        let itemID = try BeanBaoDeliveryObservationContract.identifier(item)
        let add = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: item, store: journal,
            client: DeliveryScriptModel(action: "add_to_cart", target: "", observationID: itemID),
            model: "scripted")
        try await BeanBaoDeliveryPlanner.begin(add, store: journal)
        let handoff = observation("https://www.ubereats.com/store/phin/id",
                                  "Phin & Bowl Featured items View order Phin & Bowl 1")
        let handoffPage = try await BeanBaoDeliveryPlanner.finish(add, after: handoff,
                                                                  store: journal)
        XCTAssertEqual(handoffPage, .cartHandoff)
        let handoffID = try BeanBaoDeliveryObservationContract.identifier(handoff)
        let open = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: handoff, store: journal,
            client: DeliveryScriptModel(action: "open_cart", target: "", observationID: handoffID),
            model: "scripted")
        try await BeanBaoDeliveryPlanner.begin(open, store: journal)
        let cart = observation("https://www.ubereats.com/cart",
                               "Phin & Bowl Chicken Pho Noodle choice: Rice Noodle $27.99 Go to checkout")
        let cartPage = try await BeanBaoDeliveryPlanner.finish(open, after: cart, store: journal)
        XCTAssertEqual(cartPage, .cart)
        let cartID = try BeanBaoDeliveryObservationContract.identifier(cart)
        let review = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: cart, store: journal,
            client: DeliveryScriptModel(action: "review_cart", target: "", observationID: cartID),
            model: "scripted")
        try await BeanBaoDeliveryPlanner.completeReadOnlyReview(review, on: cart, store: journal)
        let saved = await journal.snapshot()
        XCTAssertEqual(saved.phase, .completed)
    }

    func testCartHandoffIgnoresChangingMerchantCopyButNotStoreIdentity() throws {
        let first = observation("https://www.ubereats.com/store/phin/id",
                                "Phin & Bowl 11 min Featured items View order 1")
        let changedCopy = observation("https://www.ubereats.com/store/phin/id",
                                      "Phin & Bowl 12 min New promotion View order 1")
        let otherStore = observation("https://www.ubereats.com/store/other/id",
                                     "Other Kitchen Featured items View order 1")
        let id = try BeanBaoDeliveryObservationContract.identifier(first)
        XCTAssertEqual(id, try BeanBaoDeliveryObservationContract.identifier(changedCopy))
        XCTAssertTrue(try BeanBaoDeliveryObservationContract.allowed(
            .init(action: "open_cart", target: "", observationID: id),
            observation: changedCopy))
        XCTAssertFalse(try BeanBaoDeliveryObservationContract.allowed(
            .init(action: "open_cart", target: "", observationID: id),
            observation: otherStore))
    }

    func testCartReviewRejectsAChangedSelectedOption() async throws {
        let request = "Add Chicken Pho with Rice Noodle to cart for review"
        let (journal, _) = try store(request: request)
        let itemURL = "https://www.ubereats.com/store/phin/id?mod=quickView"
        let item = observation(itemURL, "Chicken Pho Rice Noodle Add 1 to order",
                               available: ["Rice Noodle", "Ramen Noodle"])
        let optionID = try BeanBaoDeliveryObservationContract.identifier(item)
        let choice = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: item, store: journal,
            client: DeliveryScriptModel(action: "choose_option", target: "Rice Noodle",
                                        observationID: optionID), model: "scripted")
        try await BeanBaoDeliveryPlanner.begin(choice, store: journal)
        let selected = observation(itemURL, "Chicken Pho Rice Noodle Add 1 to order",
                                   selected: ["Rice Noodle"],
                                   available: ["Rice Noodle", "Ramen Noodle"])
        _ = try await BeanBaoDeliveryPlanner.finish(choice, after: selected, store: journal)
        let wrongCart = observation("https://www.ubereats.com/cart",
            "Phin & Bowl Chicken Pho Noodle choice: Ramen Noodle $27.99 Go to checkout")
        let cartID = try BeanBaoDeliveryObservationContract.identifier(wrongCart)
        let review = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: wrongCart, store: journal,
            client: DeliveryScriptModel(action: "review_cart", target: "",
                                        observationID: cartID), model: "scripted")
        do {
            try await BeanBaoDeliveryPlanner.completeReadOnlyReview(review,
                on: wrongCart, store: journal)
            XCTFail("A cart with a different option must not complete")
        } catch BeanBaoDeliveryPlanError.invalidAction { }
        let saved = await journal.snapshot()
        XCTAssertNil(saved.operations["delivery-review-v1-\(cartID)"])
    }

    func testCartReviewRequiresPreviouslyOpenedMerchantAndItem() async throws {
        let request = "Add Chicken Pho from Phin & Bowl to cart for review"
        let (journal, _) = try store(request: request)
        let search = observation("https://www.ubereats.com/search?q=phin", "Phin & Bowl")
        let searchID = try BeanBaoDeliveryObservationContract.identifier(search)
        let merchantChoice = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: search, store: journal,
            client: DeliveryScriptModel(action: "open_merchant", target: "Phin & Bowl",
                                        observationID: searchID), model: "scripted")
        try await BeanBaoDeliveryPlanner.begin(merchantChoice, store: journal)
        let menu = observation("https://www.ubereats.com/store/phin/id",
                               "Phin & Bowl Featured items Chicken Pho")
        _ = try await BeanBaoDeliveryPlanner.finish(merchantChoice, after: menu, store: journal)
        let menuID = try BeanBaoDeliveryObservationContract.identifier(menu)
        let itemChoice = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: menu, store: journal,
            client: DeliveryScriptModel(action: "open_item", target: "Chicken Pho",
                                        observationID: menuID), model: "scripted")
        try await BeanBaoDeliveryPlanner.begin(itemChoice, store: journal)
        let item = observation("https://www.ubereats.com/store/phin/id?mod=quickView",
                               "Chicken Pho Add 1 to order")
        _ = try await BeanBaoDeliveryPlanner.finish(itemChoice, after: item, store: journal)
        for text in [
            "Other Kitchen Chicken Pho $27.99 Go to checkout",
            "Phin & Bowl Other Soup $27.99 Go to checkout"
        ] {
            let cart = observation("https://www.ubereats.com/cart", text)
            let id = try BeanBaoDeliveryObservationContract.identifier(cart)
            let review = try await BeanBaoDeliveryPlanner.choose(
                request: request, observation: cart, store: journal,
                client: DeliveryScriptModel(action: "review_cart", target: "",
                                            observationID: id), model: "scripted")
            do {
                try await BeanBaoDeliveryPlanner.completeReadOnlyReview(
                    review, on: cart, store: journal)
                XCTFail("The wrong merchant or item must not complete")
            } catch BeanBaoDeliveryPlanError.invalidAction { }
        }
        let correct = observation("https://www.ubereats.com/cart",
                                   "Phin & Bowl Chicken Pho $27.99 Go to checkout")
        let correctID = try BeanBaoDeliveryObservationContract.identifier(correct)
        let review = try await BeanBaoDeliveryPlanner.choose(
            request: request, observation: correct, store: journal,
            client: DeliveryScriptModel(action: "review_cart", target: "",
                                        observationID: correctID), model: "scripted")
        try await BeanBaoDeliveryPlanner.completeReadOnlyReview(
            review, on: correct, store: journal)
        let saved = await journal.snapshot()
        XCTAssertEqual(saved.phase, .completed)
    }

    func testReadOnlyRequestCannotSelectAnOptionOrAddToCart() async throws {
        let request = "Find Chicken Pho and review its options"
        let item = observation("https://www.ubereats.com/store/phin/id?mod=quickView",
            "Chicken Pho Rice Noodle Add 1 to order", available: ["Rice Noodle"])
        let id = try BeanBaoDeliveryObservationContract.identifier(item)
        for (action, target) in [("choose_option", "Rice Noodle"), ("add_to_cart", "")] {
            let (journal, _) = try store(request: request)
            do {
                _ = try await BeanBaoDeliveryPlanner.choose(request: request, observation: item,
                    store: journal,
                    client: DeliveryScriptModel(action: action, target: target, observationID: id),
                    model: "scripted")
                XCTFail("A review-only request must reject \(action)")
            } catch BeanBaoWorkflowError.completionUnverified { }
            let saved = await journal.snapshot()
            XCTAssertTrue(saved.operations.isEmpty)
        }
    }

    func testCartOnlyRequestCannotOpenCheckout() async throws {
        let request = "Add Chicken Pho to the cart for review. Do not check out."
        let (journal, _) = try store(request: request)
        let cart = observation("https://www.ubereats.com/cart",
            "Chicken Pho $27.99 Go to checkout")
        let id = try BeanBaoDeliveryObservationContract.identifier(cart)
        do {
            _ = try await BeanBaoDeliveryPlanner.choose(request: request, observation: cart,
                store: journal,
                client: DeliveryScriptModel(action: "open_checkout", target: "", observationID: id),
                model: "scripted")
            XCTFail("A cart-only request must stop at the cart")
        } catch BeanBaoWorkflowError.completionUnverified { }
        let saved = await journal.snapshot()
        XCTAssertTrue(saved.operations.isEmpty)
    }

    func testCachedProposalCannotBypassCurrentRequestScope() async throws {
        let request = "Find Chicken Pho and review its options"
        let (journal, _) = try store(request: request)
        let item = observation("https://www.ubereats.com/store/phin/id?mod=quickView",
            "Chicken Pho Add 1 to order")
        let id = try BeanBaoDeliveryObservationContract.identifier(item)
        let key = "delivery-plan-v1-\(id)"
        _ = try await journal.claim(key: key, tool: "delivery_choose", effect: .readOnly)
        try await journal.finish(key: key, result: .object([
            "action": .string("add_to_cart"), "target": .string(""),
            "observation_id": .string(id)]))
        do {
            _ = try await BeanBaoDeliveryPlanner.choose(request: request, observation: item,
                store: journal,
                client: DeliveryScriptModel(action: "add_to_cart", target: "", observationID: id),
                model: "scripted")
            XCTFail("A cached proposal needs the same current authorization check")
        } catch BeanBaoDeliveryPlanError.invalidAction { }
        do {
            try await BeanBaoDeliveryPlanner.begin(
                .init(action: "add_to_cart", target: "", observationID: id), store: journal)
            XCTFail("An old proposal cannot begin a new cart mutation")
        } catch BeanBaoDeliveryPlanError.invalidAction { }
        let saved = await journal.snapshot()
        XCTAssertNil(saved.operations["delivery-execute-v1-\(id)"])
    }
}
