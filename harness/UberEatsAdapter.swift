import Foundation
import CryptoKit

public enum BeanBaoUberEatsPage: Equatable, Sendable {
    case feed
    case searchSuggestions
    case search
    case merchant
    case itemConfiguration
    case cartHandoff
    case cart
    case loginRequired
    case checkout
    case unsupported
}

public enum BeanBaoUberEatsAdapterError: Error, Equatable, Sendable {
    case unsupportedPage
    case loginRequired
    case incompleteCheckout
}

/// One observation from the active browser. The caller must obtain URL and visible
/// text from the same foreground screen; model output is never an observation.
public struct BeanBaoUberEatsObservation: Sendable {
    public let url: URL
    public let visibleText: String
    public let selectedOptions: [String]
    public let availableOptions: [String]
    public let bundleID: String
    public let observedAt: Date

    public init(url: URL, visibleText: String, bundleID: String, observedAt: Date,
                selectedOptions: [String] = [], availableOptions: [String] = []) {
        self.url = url
        self.visibleText = visibleText
        self.selectedOptions = selectedOptions
        self.availableOptions = availableOptions
        self.bundleID = bundleID
        self.observedAt = observedAt
    }
}

func beanBaoSelectedOptions(_ fields: [String: Any]) -> [String]? {
    guard let value = fields["selected_options"] else { return [] }
    guard let labels = value as? [String], labels.count <= 30,
          labels.allSatisfy({ (1...120).contains($0.count) &&
              $0.rangeOfCharacter(from: .newlines) == nil }) else { return nil }
    return labels
}

func beanBaoAvailableOptions(_ fields: [String: Any]) -> [String]? {
    guard let value = fields["available_options"] else { return [] }
    guard let labels = value as? [String], labels.count <= 60,
          labels.allSatisfy({ (1...120).contains($0.count) &&
              $0.rangeOfCharacter(from: .newlines) == nil }) else { return nil }
    return labels
}

/// Versioned screen contract for the first delivery site. Unrecognized screens
/// stop the workflow; the adapter does not infer a payable total from a menu.
public enum BeanBaoUberEatsAdapter {
    public static let version = 3

    public static func page(_ observation: BeanBaoUberEatsObservation) -> BeanBaoUberEatsPage {
        guard observation.url.scheme?.lowercased() == "https",
              let host = observation.url.host?.lowercased() else { return .unsupported }
        if host == "auth.uber.com" && observation.url.path.hasPrefix("/v2") {
            return .loginRequired
        }
        guard host == "www.ubereats.com" else { return .unsupported }
        let path = observation.url.path
        if path == "/feed" || path == "/" { return .feed }
        if path == "/search-suggestions" { return .searchSuggestions }
        if path == "/search" { return .search }
        if path == "/cart" || path == "/cart/" {
            return observation.visibleText.contains("Go to checkout") ? .cart : .unsupported
        }
        if path == "/checkout" || path == "/checkout/" { return .checkout }
        guard path.hasPrefix("/store/") else { return .unsupported }
        let text = observation.visibleText
        if text.range(of: "Add \\d+ to order", options: .regularExpression) != nil {
            return .itemConfiguration
        }
        if text.contains("View order") { return .cartHandoff }
        return text.contains("Search Uber Eats") || text.contains("Featured items") ?
            .merchant : .unsupported
    }

    public static func checkoutEvidence(_ observation: BeanBaoUberEatsObservation,
                                        cart: BeanBaoDeliveryCart) throws -> BeanBaoDeliveryScreenEvidence {
        switch page(observation) {
        case .loginRequired: throw BeanBaoUberEatsAdapterError.loginRequired
        case .checkout: break
        default: throw BeanBaoUberEatsAdapterError.unsupportedPage
        }
        try cart.validate()
        guard cart.service == "Uber Eats",
              observation.bundleID == "dev.beanbao.deliverybrowser" else {
            throw BeanBaoUberEatsAdapterError.incompleteCheckout
        }
        let text = observation.visibleText.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ").lowercased()
        var required = [cart.merchantName, cart.address,
                        "subtotal \(money(cart.subtotalMinor, currency: cart.currency))"]
        for item in cart.items {
            required.append(item.name)
            required.append(money(item.lineTotalMinor, currency: cart.currency))
            required.append(contentsOf: item.options)
        }
        let standardCharges: [(String, Int)] = [
            ("tax", cart.taxMinor), ("delivery fee", cart.deliveryFeeMinor),
            ("service fee", cart.serviceFeeMinor), ("tip", cart.tipMinor)
        ]
        for (name, amount) in standardCharges where amount != 0 {
            required.append("\(name) \(money(amount, currency: cart.currency))")
        }
        for adjustment in cart.adjustments {
            required.append("\(adjustment.name) \(money(adjustment.amountMinor, currency: cart.currency))")
        }
        let totalLine = "total \(money(cart.totalMinor, currency: cart.currency))"
        guard required.allSatisfy({ text.contains($0.lowercased()) }),
              text.contains("place order"),
              (text.hasPrefix(totalLine) || text.contains(" \(totalLine)")),
              cart.currency == "USD" else {
            throw BeanBaoUberEatsAdapterError.incompleteCheckout
        }
        let fingerprintInput = "v\(version)\n\(observation.url.absoluteString)\n\(text)"
        let fingerprint = SHA256.hash(data: Data(fingerprintInput.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return .init(bundleID: observation.bundleID,
                     checkoutFingerprint: fingerprint, observedAt: observation.observedAt)
    }

    private static func money(_ minor: Int, currency: String) -> String {
        // The first adapter is for Uber Eats in the US. Unknown currencies
        // require a separate formatter and screen contract before approval.
        guard currency == "USD" else { return "<unsupported-currency>" }
        return minor < 0 ? String(format: "-$%d.%02d", -minor / 100, -minor % 100) :
            String(format: "$%d.%02d", minor / 100, minor % 100)
    }
}

/// Foundation-only entry used by the mobile Agent's local socket. It returns
/// a small classification receipt; the page body never enters Activity logs.
@_cdecl("BBUberEatsClassifySnapshot")
public func BBUberEatsClassifySnapshot(_ pointer: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let pointer, strlen(pointer) <= 65_536,
          let fields = try? JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any],
          let urlString = fields["url"] as? String, let url = URL(string: urlString),
          let visibleText = fields["visible_text"] as? String, visibleText.count <= 20_000,
          let selectedOptions = beanBaoSelectedOptions(fields),
          let availableOptions = beanBaoAvailableOptions(fields),
          let bundleID = fields["bundle_id"] as? String, bundleID == "dev.beanbao.deliverybrowser",
          let timestamp = fields["observed_at"] as? NSNumber else {
        return "{\"ok\":false,\"error\":\"Invalid delivery snapshot\"}".withCString { strdup($0) }
    }
    let now = Date()
    let observedAt = Date(timeIntervalSince1970: timestamp.doubleValue)
    guard observedAt <= now, now.timeIntervalSince(observedAt) <= 15 else {
        return "{\"ok\":false,\"error\":\"Delivery page changed; check again\"}".withCString { strdup($0) }
    }
    let observation = BeanBaoUberEatsObservation(url: url, visibleText: visibleText,
        bundleID: bundleID, observedAt: observedAt, selectedOptions: selectedOptions,
        availableOptions: availableOptions)
    let page: String
    switch BeanBaoUberEatsAdapter.page(observation) {
    case .feed: page = "feed"
    case .searchSuggestions: page = "search_suggestions"
    case .search: page = "search"
    case .merchant: page = "merchant"
    case .itemConfiguration: page = "item_configuration"
    case .cartHandoff: page = "cart_handoff"
    case .cart: page = "cart"
    case .loginRequired: page = "login_required"
    case .checkout: page = "checkout"
    case .unsupported: page = "unsupported"
    }
    return "{\"ok\":true,\"page\":\"\(page)\",\"adapter_version\":\(BeanBaoUberEatsAdapter.version)}".withCString { strdup($0) }
}
