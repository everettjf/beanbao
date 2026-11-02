import Foundation
import XCTest
import BeanBaoTextHarness

final class DeliveryReviewTests: XCTestCase {
    private func cart(address: String = "123 Test Street, San Jose, CA",
                      tip: Int = 100, total: Int? = nil,
                      merchant: String = "Example Kitchen",
                      adjustments: [BeanBaoDeliveryAdjustment] = []) -> BeanBaoDeliveryCart {
        BeanBaoDeliveryCart(service: "Example Delivery", merchantID: "merchant-123",
            merchantName: merchant,
            items: [.init(name: "Rice bowl", options: ["No onions"], quantity: 1,
                          lineTotalMinor: 1800)], address: address, currency: "USD",
            subtotalMinor: 1800, taxMinor: 149, deliveryFeeMinor: 350,
            serviceFeeMinor: 100, tipMinor: tip,
            totalMinor: total ?? 2399 + tip + adjustments.reduce(0, { $0 + $1.amountMinor }),
            arrivalEstimate: "30–40 minutes", adjustments: adjustments)
    }

    func testReviewRequiresFreshExactCartAndOneCommitAttempt() async throws {
        let gate = BeanBaoDeliveryReviewGate()
        let now = Date()
        let evidence = BeanBaoDeliveryScreenEvidence(bundleID: "com.example.delivery",
            checkoutFingerprint: String(repeating: "a", count: 64), observedAt: now)
        let digest = try await gate.present(cart(), evidence: evidence, now: now)
        let approval = try await gate.approve(digest: digest, now: now)
        try await gate.beginCommit(cart(), evidence: evidence, approval: approval, now: now)
        do {
            try await gate.beginCommit(cart(), evidence: evidence, approval: approval, now: now)
            XCTFail("A second order placement attempt must be blocked")
        } catch BeanBaoDeliveryReviewError.outcomeUnconfirmed { }
        do {
            _ = try await gate.present(cart(), evidence: evidence, now: now)
            XCTFail("An uncertain placement cannot be reset by reopening review")
        } catch BeanBaoDeliveryReviewError.outcomeUnconfirmed { }
    }

    func testChangedAddressPriceMerchantOrScreenInvalidatesApproval() async throws {
        let now = Date()
        let evidence = BeanBaoDeliveryScreenEvidence(bundleID: "com.example.delivery",
            checkoutFingerprint: String(repeating: "a", count: 64), observedAt: now)
        for changed in [cart(address: "456 Other Street, San Jose, CA"),
                        cart(tip: 200),
                        cart(merchant: "Other Kitchen")] {
            let gate = BeanBaoDeliveryReviewGate()
            let digest = try await gate.present(cart(), evidence: evidence, now: now)
            let approval = try await gate.approve(digest: digest, now: now)
            do {
                try await gate.beginCommit(changed, evidence: evidence, approval: approval, now: now)
                XCTFail("Changed cart must invalidate approval")
            } catch BeanBaoDeliveryReviewError.changedCart { }
        }
        let changedPrice = cart(total: 2599)
        do { try changedPrice.validate(); XCTFail("Inconsistent total must be rejected") }
        catch BeanBaoDeliveryReviewError.invalidCart { }
        let gate = BeanBaoDeliveryReviewGate()
        let digest = try await gate.present(cart(), evidence: evidence, now: now)
        let approval = try await gate.approve(digest: digest, now: now)
        let changedScreen = BeanBaoDeliveryScreenEvidence(bundleID: "com.example.delivery",
            checkoutFingerprint: String(repeating: "b", count: 64), observedAt: now)
        do {
            try await gate.beginCommit(cart(), evidence: changedScreen, approval: approval, now: now)
            XCTFail("A changed checkout screen must invalidate approval")
        } catch BeanBaoDeliveryReviewError.changedCart { }
    }

    func testStaleObservationAndExpiredApprovalAreRejected() async throws {
        let gate = BeanBaoDeliveryReviewGate()
        let now = Date()
        let stale = BeanBaoDeliveryScreenEvidence(bundleID: "com.example.delivery",
            checkoutFingerprint: String(repeating: "a", count: 64), observedAt: now.addingTimeInterval(-30))
        do {
            _ = try await gate.present(cart(), evidence: stale, now: now)
            XCTFail("Stale screen evidence must not be shown as current")
        } catch BeanBaoDeliveryReviewError.staleObservation { }
        let current = BeanBaoDeliveryScreenEvidence(bundleID: "com.example.delivery",
            checkoutFingerprint: String(repeating: "a", count: 64), observedAt: now)
        let digest = try await gate.present(cart(), evidence: current, now: now)
        do {
            _ = try await gate.approve(digest: digest, now: now.addingTimeInterval(121))
            XCTFail("Old cart approval must expire")
        } catch BeanBaoDeliveryReviewError.approvalExpired { }
    }

    func testUncertainOrderAttemptSurvivesProcessRestart() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbao-delivery-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("delivery-review.json")
        let now = Date()
        let evidence = BeanBaoDeliveryScreenEvidence(bundleID: "com.example.delivery",
            checkoutFingerprint: String(repeating: "a", count: 64), observedAt: now)
        let original = try BeanBaoDeliveryReviewGate(journalURL: url)
        let digest = try await original.present(cart(), evidence: evidence, now: now)
        let approval = try await original.approve(digest: digest, now: now)
        try await original.beginCommit(cart(), evidence: evidence, approval: approval, now: now)
        let resumed = try BeanBaoDeliveryReviewGate(journalURL: url)
        do {
            _ = try await resumed.present(cart(), evidence: evidence, now: now)
            XCTFail("An interrupted order attempt must require reconciliation")
        } catch BeanBaoDeliveryReviewError.outcomeUnconfirmed { }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAdditionalFeeAndDiscountArePartOfExactApproval() async throws {
        let original = cart(adjustments: [
            .init(name: "Small order fee", amountMinor: 250),
            .init(name: "Promotion", amountMinor: -100)
        ])
        try original.validate()
        XCTAssertEqual(original.totalMinor, 2649)

        let now = Date()
        let evidence = BeanBaoDeliveryScreenEvidence(bundleID: "com.example.delivery",
            checkoutFingerprint: String(repeating: "a", count: 64), observedAt: now)
        let gate = BeanBaoDeliveryReviewGate()
        let digest = try await gate.present(original, evidence: evidence, now: now)
        let approval = try await gate.approve(digest: digest, now: now)
        let changedFee = cart(adjustments: [
            .init(name: "Small order fee", amountMinor: 300),
            .init(name: "Promotion", amountMinor: -100)
        ])
        do {
            try await gate.beginCommit(changedFee, evidence: evidence, approval: approval, now: now)
            XCTFail("A changed additional fee must invalidate approval")
        } catch BeanBaoDeliveryReviewError.changedCart { }

        let hiddenFee = cart(total: 2649)
        do {
            try hiddenFee.validate()
            XCTFail("A total with an undisclosed fee must be rejected")
        } catch BeanBaoDeliveryReviewError.invalidCart { }
    }
}
