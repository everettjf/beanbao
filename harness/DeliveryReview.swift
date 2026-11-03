import Foundation
import CryptoKit

public enum BeanBaoDeliveryReviewError: Error, LocalizedError, Equatable {
    case invalidCart
    case staleObservation
    case changedCart
    case approvalRequired
    case approvalExpired
    case outcomeUnconfirmed

    public var errorDescription: String? {
        switch self {
        case .invalidCart: "The cart total or required checkout details are incomplete."
        case .staleObservation: "The checkout screen must be observed again."
        case .changedCart: "The merchant, items, address, or total changed. Review the cart again."
        case .approvalRequired: "This exact cart needs fresh approval."
        case .approvalExpired: "The cart approval expired. Review it again."
        case .outcomeUnconfirmed: "The order outcome is unconfirmed. Check order history before continuing."
        }
    }
}

public struct BeanBaoDeliveryItem: Codable, Equatable, Sendable {
    public let name: String
    public let options: [String]
    public let quantity: Int
    public let lineTotalMinor: Int

    public init(name: String, options: [String], quantity: Int, lineTotalMinor: Int) {
        self.name = name
        self.options = options
        self.quantity = quantity
        self.lineTotalMinor = lineTotalMinor
    }
}

/// A checkout line that does not fit the standard tax, delivery, service, or tip fields.
/// Discounts are negative; every line remains visible in the approval snapshot.
public struct BeanBaoDeliveryAdjustment: Codable, Equatable, Sendable {
    public let name: String
    public let amountMinor: Int

    public init(name: String, amountMinor: Int) {
        self.name = name
        self.amountMinor = amountMinor
    }
}

public struct BeanBaoDeliveryCart: Codable, Equatable, Sendable {
    public let service: String
    public let merchantID: String
    public let merchantName: String
    public let items: [BeanBaoDeliveryItem]
    public let address: String
    public let currency: String
    public let subtotalMinor: Int
    public let taxMinor: Int
    public let deliveryFeeMinor: Int
    public let serviceFeeMinor: Int
    public let tipMinor: Int
    public let adjustments: [BeanBaoDeliveryAdjustment]
    public let totalMinor: Int
    public let arrivalEstimate: String?

    public init(service: String, merchantID: String, merchantName: String,
                items: [BeanBaoDeliveryItem], address: String, currency: String,
                subtotalMinor: Int, taxMinor: Int, deliveryFeeMinor: Int,
                serviceFeeMinor: Int, tipMinor: Int, totalMinor: Int,
                arrivalEstimate: String?,
                adjustments: [BeanBaoDeliveryAdjustment] = []) {
        self.service = service
        self.merchantID = merchantID
        self.merchantName = merchantName
        self.items = items
        self.address = address
        self.currency = currency
        self.subtotalMinor = subtotalMinor
        self.taxMinor = taxMinor
        self.deliveryFeeMinor = deliveryFeeMinor
        self.serviceFeeMinor = serviceFeeMinor
        self.tipMinor = tipMinor
        self.adjustments = adjustments
        self.totalMinor = totalMinor
        self.arrivalEstimate = arrivalEstimate
    }

    public func validate() throws {
        guard (2...50).contains(service.count), (1...100).contains(merchantID.count),
              (2...120).contains(merchantName.count), (5...240).contains(address.count),
              currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
              (1...20).contains(items.count),
              items.allSatisfy({ item in
                  (1...120).contains(item.name.count) && (1...50).contains(item.quantity) &&
                  item.lineTotalMinor >= 0 && item.lineTotalMinor <= 1_000_000 &&
                  item.options.count <= 20 && item.options.allSatisfy { (1...120).contains($0.count) }
              }),
              [subtotalMinor, taxMinor, deliveryFeeMinor, serviceFeeMinor, tipMinor, totalMinor]
                .allSatisfy({ $0 >= 0 && $0 <= 1_000_000 }),
              adjustments.count <= 20,
              adjustments.allSatisfy({ (2...120).contains($0.name.count) &&
                  (-1_000_000...1_000_000).contains($0.amountMinor) && $0.amountMinor != 0 }),
              (arrivalEstimate?.count ?? 0) <= 120,
              items.reduce(0, { $0 + $1.lineTotalMinor }) == subtotalMinor,
              subtotalMinor + taxMinor + deliveryFeeMinor + serviceFeeMinor + tipMinor +
                adjustments.reduce(0, { $0 + $1.amountMinor }) == totalMinor,
              totalMinor > 0 else { throw BeanBaoDeliveryReviewError.invalidCart }
    }

    public func digest() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Fields the model may extract from a visible checkout. The merchant ID is
/// deliberately absent: it comes from a previously verified store URL.
public struct BeanBaoDeliveryCheckoutDraft: Codable, Equatable, Sendable {
    public let merchantName: String
    public let items: [BeanBaoDeliveryItem]
    public let address: String
    public let currency: String
    public let subtotalMinor: Int
    public let taxMinor: Int
    public let deliveryFeeMinor: Int
    public let serviceFeeMinor: Int
    public let tipMinor: Int
    public let adjustments: [BeanBaoDeliveryAdjustment]
    public let totalMinor: Int
    public let arrivalEstimate: String?

    public init(merchantName: String, items: [BeanBaoDeliveryItem], address: String,
                currency: String, subtotalMinor: Int, taxMinor: Int,
                deliveryFeeMinor: Int, serviceFeeMinor: Int, tipMinor: Int,
                adjustments: [BeanBaoDeliveryAdjustment], totalMinor: Int,
                arrivalEstimate: String?) {
        self.merchantName = merchantName
        self.items = items
        self.address = address
        self.currency = currency
        self.subtotalMinor = subtotalMinor
        self.taxMinor = taxMinor
        self.deliveryFeeMinor = deliveryFeeMinor
        self.serviceFeeMinor = serviceFeeMinor
        self.tipMinor = tipMinor
        self.adjustments = adjustments
        self.totalMinor = totalMinor
        self.arrivalEstimate = arrivalEstimate
    }

    public func cart(merchantID: String) -> BeanBaoDeliveryCart {
        BeanBaoDeliveryCart(service: "Uber Eats", merchantID: merchantID,
            merchantName: merchantName, items: items, address: address,
            currency: currency, subtotalMinor: subtotalMinor, taxMinor: taxMinor,
            deliveryFeeMinor: deliveryFeeMinor, serviceFeeMinor: serviceFeeMinor,
            tipMinor: tipMinor, totalMinor: totalMinor,
            arrivalEstimate: arrivalEstimate, adjustments: adjustments)
    }
}

public struct BeanBaoDeliveryScreenEvidence: Codable, Equatable, Sendable {
    public let bundleID: String
    public let checkoutFingerprint: String
    public let observedAt: Date

    public init(bundleID: String, checkoutFingerprint: String, observedAt: Date) {
        self.bundleID = bundleID
        self.checkoutFingerprint = checkoutFingerprint
        self.observedAt = observedAt
    }
}

/// The adapter must re-observe the real checkout screen before each transition.
/// An accepted cart never authorizes a changed address, amount, merchant, or UI.
public actor BeanBaoDeliveryReviewGate {
    private struct Review: Codable {
        let digest: String
        let evidence: BeanBaoDeliveryScreenEvidence
        let expiresAt: Date
        var approval: UUID?
        var commitStarted: Bool
    }
    private var current: Review?
    private let journalURL: URL?

    public init() { journalURL = nil }
    public init(journalURL: URL) throws {
        self.journalURL = journalURL
        if FileManager.default.fileExists(atPath: journalURL.path) {
            current = try JSONDecoder().decode(Review.self,
                from: BeanBaoWorkflowStore.readPrivateFile(journalURL))
        }
    }

    private func save(_ review: Review) throws {
        if let journalURL {
            try BeanBaoWorkflowStore.writePrivateFile(JSONEncoder().encode(review), to: journalURL)
        }
        current = review
    }

    public func present(_ cart: BeanBaoDeliveryCart,
                        evidence: BeanBaoDeliveryScreenEvidence,
                        now: Date = Date()) throws -> String {
        if current?.commitStarted == true { throw BeanBaoDeliveryReviewError.outcomeUnconfirmed }
        guard !evidence.bundleID.isEmpty,
              evidence.checkoutFingerprint.range(of: "^[a-f0-9]{64}$",
                                                   options: .regularExpression) != nil,
              evidence.observedAt <= now, now.timeIntervalSince(evidence.observedAt) <= 15 else {
            throw BeanBaoDeliveryReviewError.staleObservation
        }
        let digest = try cart.digest()
        try save(Review(digest: digest, evidence: evidence,
                        expiresAt: now.addingTimeInterval(120),
                        approval: nil, commitStarted: false))
        return digest
    }

    public func approve(_ cart: BeanBaoDeliveryCart,
                        evidence: BeanBaoDeliveryScreenEvidence,
                        now: Date = Date()) throws -> UUID {
        guard var review = current else { throw BeanBaoDeliveryReviewError.approvalRequired }
        guard now <= review.expiresAt else { throw BeanBaoDeliveryReviewError.approvalExpired }
        guard !review.commitStarted else { throw BeanBaoDeliveryReviewError.outcomeUnconfirmed }
        guard evidence.observedAt <= now,
              now.timeIntervalSince(evidence.observedAt) <= 15 else {
            throw BeanBaoDeliveryReviewError.staleObservation
        }
        guard review.digest == (try cart.digest()),
              review.evidence.bundleID == evidence.bundleID,
              review.evidence.checkoutFingerprint == evidence.checkoutFingerprint else {
            review.approval = nil
            try save(review)
            throw BeanBaoDeliveryReviewError.changedCart
        }
        let approval = UUID()
        review.approval = approval
        try save(review)
        return approval
    }

    public func beginCommit(_ cart: BeanBaoDeliveryCart,
                            evidence: BeanBaoDeliveryScreenEvidence,
                            approval: UUID, now: Date = Date()) throws {
        guard var review = current, let granted = review.approval,
              granted == approval else { throw BeanBaoDeliveryReviewError.approvalRequired }
        guard !review.commitStarted else { throw BeanBaoDeliveryReviewError.outcomeUnconfirmed }
        guard now <= review.expiresAt else { throw BeanBaoDeliveryReviewError.approvalExpired }
        guard evidence.observedAt <= now,
              now.timeIntervalSince(evidence.observedAt) <= 15 else {
            throw BeanBaoDeliveryReviewError.staleObservation
        }
        guard evidence.bundleID == review.evidence.bundleID,
              evidence.checkoutFingerprint == review.evidence.checkoutFingerprint,
              try cart.digest() == review.digest else {
            review.approval = nil
            try save(review)
            throw BeanBaoDeliveryReviewError.changedCart
        }
        review.commitStarted = true
        try save(review)
    }
}
