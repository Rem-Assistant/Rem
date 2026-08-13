import Foundation

/// Account + gateway boundary for the one browser-ended owner receipt.
///
/// Conversation keys are only meaningful inside the gateway that owns their transcript. Keeping
/// both identities in the scope lets a cold launch recover the latest ended card without allowing
/// the same key from another account or gateway to claim the retained browser.
struct BrowserEndedOwnershipScope: Codable, Equatable, Hashable, Sendable {
    let accountID: String
    let gatewayIdentity: String

    init?(accountID: String?, gatewayURL: String?) {
        guard let accountID = Self.nonEmpty(accountID),
              let gatewayURL = Self.normalizedGatewayIdentity(gatewayURL)
        else { return nil }
        self.accountID = accountID
        gatewayIdentity = gatewayURL
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func normalizedGatewayIdentity(_ rawValue: String?) -> String? {
        guard let rawValue = nonEmpty(rawValue),
              var components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased()
        else { return nil }
        components.scheme = scheme
        components.host = host
        components.query = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return components.string
    }
}

/// Pure JSON ledger for cold-launch browser-card ownership recovery.
///
/// Only the latest ended conversation key is persisted per account+gateway scope. Frames, URLs,
/// cookies, and live/run state remain memory-only. Malformed storage fails closed, and the small cap
/// prevents an account churn history from growing UserDefaults without bound.
enum BrowserEndedOwnershipLedger {
    private struct Receipt: Codable, Equatable {
        let scope: BrowserEndedOwnershipScope
        let conversationKey: String
    }

    private static let maximumReceiptCount = 16

    static func owner(for scope: BrowserEndedOwnershipScope?, in encoded: String) -> String? {
        guard let scope else { return nil }
        return decode(encoded).last(where: { $0.scope == scope })?.conversationKey
    }

    static func recording(
        owner: String?,
        for scope: BrowserEndedOwnershipScope?,
        in encoded: String
    ) -> String {
        guard let scope else { return encoded }
        var receipts = decode(encoded).filter { $0.scope != scope }
        if let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            receipts.append(Receipt(scope: scope, conversationKey: owner))
        }
        if receipts.count > maximumReceiptCount {
            receipts.removeFirst(receipts.count - maximumReceiptCount)
        }
        guard let data = try? JSONEncoder().encode(receipts),
              let result = String(data: data, encoding: .utf8)
        else { return encoded }
        return result
    }

    private static func decode(_ encoded: String) -> [Receipt] {
        guard let data = encoded.data(using: .utf8),
              let receipts = try? JSONDecoder().decode([Receipt].self, from: data)
        else { return [] }
        return receipts
    }
}
