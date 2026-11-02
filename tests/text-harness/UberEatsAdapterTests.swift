import Foundation
import XCTest
import BeanBaoTextHarness

final class UberEatsAdapterTests: XCTestCase {
    private let now = Date()

    private func observed(_ url: String, _ text: String,
                          bundle: String = "dev.beanbao.deliverybrowser") -> BeanBaoUberEatsObservation {
        BeanBaoUberEatsObservation(url: URL(string: url)!, visibleText: text,
                                   bundleID: bundle, observedAt: now)
    }

    private func cart(total: Int = 2649) -> BeanBaoDeliveryCart {
        BeanBaoDeliveryCart(service: "Uber Eats", merchantID: "03c1d15f-5897-57df-b474-ff988be2386a",
            merchantName: "Example Kitchen",
            items: [.init(name: "Rice bowl", options: ["No onions"], quantity: 1,
                          lineTotalMinor: 1800)],
            address: "200 E Santa Clara St, San Jose, CA", currency: "USD",
            subtotalMinor: 1800, taxMinor: 149, deliveryFeeMinor: 350,
            serviceFeeMinor: 100, tipMinor: 100, totalMinor: total,
            arrivalEstimate: "30–40 minutes",
            adjustments: [.init(name: "Small order fee", amountMinor: 250),
                          .init(name: "Promotion", amountMinor: -100)])
    }

    private let checkout = """
        Example Kitchen
        Rice bowl No onions $18.00
        Deliver to 200 E Santa Clara St, San Jose, CA
        Subtotal $18.00 Tax $1.49 Delivery fee $3.50 Service fee $1.00
        Small order fee $2.50 Promotion -$1.00 Tip $1.00 Total $26.49
        Place order
        """

    func testPublicMenuCartAndLoginTransitionAreDistinct() {
        XCTAssertEqual(BeanBaoUberEatsAdapter.page(observed("https://www.ubereats.com/feed", "Search Uber Eats")), .feed)
        XCTAssertEqual(BeanBaoUberEatsAdapter.page(observed("https://www.ubereats.com/search-suggestions", "Search Uber Eats")), .searchSuggestions)
        XCTAssertEqual(BeanBaoUberEatsAdapter.page(observed("https://www.ubereats.com/store/example/id", "Search Uber Eats")), .merchant)
        XCTAssertEqual(BeanBaoUberEatsAdapter.page(observed("https://www.ubereats.com/store/rice-junky/id", "Search Featured items CC Chicken Bowl")), .merchant)
        XCTAssertEqual(BeanBaoUberEatsAdapter.page(observed("https://www.ubereats.com/store/example/id?mod=quickView", "Add 1 to order")), .itemConfiguration)
        XCTAssertEqual(BeanBaoUberEatsAdapter.page(observed("https://www.ubereats.com/store/example/id", "Go to checkout")), .cart)
        XCTAssertEqual(BeanBaoUberEatsAdapter.page(observed("https://auth.uber.com/v2/?next_url=checkout", "Enter phone number or email")), .loginRequired)
        XCTAssertEqual(BeanBaoUberEatsAdapter.page(observed("https://www.ubereats.com.evil.example/checkout", checkout)), .unsupported)
    }

    func testOnlyCompleteCheckoutSnapshotProducesReviewEvidence() async throws {
        let observation = observed("https://www.ubereats.com/checkout", checkout)
        let evidence = try BeanBaoUberEatsAdapter.checkoutEvidence(observation, cart: cart())
        XCTAssertEqual(evidence.bundleID, "dev.beanbao.deliverybrowser")
        XCTAssertEqual(evidence.checkoutFingerprint.count, 64)

        let gate = BeanBaoDeliveryReviewGate()
        let digest = try await gate.present(cart(), evidence: evidence, now: now)
        let approval = try await gate.approve(digest: digest, now: now)
        try await gate.beginCommit(cart(), evidence: evidence, approval: approval, now: now)
    }

    func testLoginMenuAndChangedCheckoutCannotBeApproved() throws {
        for observation in [
            observed("https://auth.uber.com/v2/", checkout),
            observed("https://www.ubereats.com/store/example/id", checkout),
            observed("https://www.ubereats.com/checkout", checkout, bundle: "dev.beanbao.app"),
            observed("https://www.ubereats.com/checkout", checkout, bundle: "com.apple.mobilesafari"),
            observed("https://www.ubereats.com/checkout", checkout.replacingOccurrences(of: "Total $26.49", with: "Total $27.49")),
            observed("https://www.ubereats.com/checkout", checkout.replacingOccurrences(of: "200 E Santa Clara St", with: "201 E Santa Clara St"))
        ] {
            XCTAssertThrowsError(try BeanBaoUberEatsAdapter.checkoutEvidence(observation, cart: cart()))
        }
    }

    func testAgentEntryReturnsOnlyBoundedPageStatus() throws {
        let snapshot: [String: Any] = [
            "url": "https://www.ubereats.com/store/example/id",
            "visible_text": "Go to checkout",
            "bundle_id": "dev.beanbao.deliverybrowser",
            "observed_at": Date().timeIntervalSince1970
        ]
        let input = String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)
        let pointer = input.withCString { BBUberEatsClassifySnapshot($0) }
        XCTAssertNotNil(pointer)
        defer { free(pointer) }
        let response = String(cString: try XCTUnwrap(pointer))
        XCTAssertEqual(response, "{\"ok\":true,\"page\":\"cart\",\"adapter_version\":1}")
        XCTAssertFalse(response.contains("checkout"))

        var impersonated = snapshot
        impersonated["bundle_id"] = "dev.beanbao.app"
        let rejectedInput = String(decoding: try JSONSerialization.data(withJSONObject: impersonated), as: UTF8.self)
        let rejected = rejectedInput.withCString { BBUberEatsClassifySnapshot($0) }
        defer { free(rejected) }
        XCTAssertTrue(String(cString: try XCTUnwrap(rejected)).contains("Invalid delivery snapshot"))

        let old = "{\"url\":\"https://www.ubereats.com/checkout\",\"visible_text\":\"Place order\",\"bundle_id\":\"dev.beanbao.deliverybrowser\",\"observed_at\":0}"
        let stale = old.withCString { BBUberEatsClassifySnapshot($0) }
        defer { free(stale) }
        XCTAssertTrue(String(cString: try XCTUnwrap(stale)).contains("Delivery page changed"))
    }
}
