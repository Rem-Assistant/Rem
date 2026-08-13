import Foundation

// MARK: - BYOK Provider Catalog + Credential Store (shared across iOS and macOS)

/// A provider a user can bring their own key for. Mirrors the upstream
/// `ApiKeyCredential` shape (`openclaw/src/agents/auth-profiles/types.ts`:
/// `{ type: "api_key", provider, key, displayName }`) — `id` is the upstream
/// `provider` identifier, `displayName` the human label.
struct BYOKProvider: Identifiable, Hashable {
    /// Provider identifier — matches upstream `ApiKeyCredential.provider`
    /// (`"anthropic"`, `"openai"`, `"gmi"`, `"google"`). Also the Keychain
    /// account stem: `byok.{id}.apiKey`.
    let id: String
    let displayName: String
    /// One-line provider hint shown as a row/footer subtitle.
    let detail: String
    /// SecureField placeholder for this provider's key.
    let keyPlaceholder: String

    /// Providers offered today. Ordered most-common-first, then the rest of the
    /// API-key providers OpenClaw supports natively. The `id`s match the upstream
    /// provider identifiers written into `auth-profiles.json` (see
    /// `provider-attribution.ts` endpoint classes: `anthropic-public`,
    /// `openai-public`, `google-generative-ai`, `xai-native`, `deepseek-native`,
    /// `mistral-public`, `groq-native`, `moonshot-native`, `openrouter`,
    /// `together`) — `setProviderApiKey(provider:)` writes the key under exactly
    /// this string. GMI keeps the account it already used (`byok.gmi.apiKey`),
    /// so a previously saved GMI key appears here automatically. OAuth/project
    /// providers (Vertex, Azure, Codex) are intentionally omitted — they need a
    /// project/region handshake, not a single pasted API key.
    static let catalog: [BYOKProvider] = [
        BYOKProvider(
            id: "anthropic",
            displayName: "Anthropic",
            detail: "Claude models · api.anthropic.com",
            keyPlaceholder: "Anthropic API key"
        ),
        BYOKProvider(
            id: "openai",
            displayName: "OpenAI",
            detail: "GPT models · api.openai.com",
            keyPlaceholder: "OpenAI API key"
        ),
        BYOKProvider(
            id: "google",
            displayName: "Google",
            detail: "Gemini models · generativelanguage.googleapis.com",
            keyPlaceholder: "Google AI API key"
        ),
        BYOKProvider(
            id: "xai",
            displayName: "xAI",
            detail: "Grok models · api.x.ai",
            keyPlaceholder: "xAI API key"
        ),
        BYOKProvider(
            id: "deepseek",
            displayName: "DeepSeek",
            detail: "DeepSeek Chat & Reasoner · api.deepseek.com",
            keyPlaceholder: "DeepSeek API key"
        ),
        BYOKProvider(
            id: "mistral",
            displayName: "Mistral",
            detail: "Mistral & Magistral models · api.mistral.ai",
            keyPlaceholder: "Mistral API key"
        ),
        BYOKProvider(
            id: "groq",
            displayName: "Groq",
            detail: "Fast open models · api.groq.com",
            keyPlaceholder: "Groq API key"
        ),
        BYOKProvider(
            id: "moonshot",
            displayName: "Moonshot",
            detail: "Kimi models · api.moonshot.ai",
            keyPlaceholder: "Moonshot API key"
        ),
        BYOKProvider(
            id: "openrouter",
            displayName: "OpenRouter",
            detail: "Many models, one key · openrouter.ai",
            keyPlaceholder: "OpenRouter API key"
        ),
        BYOKProvider(
            id: "together",
            displayName: "Together AI",
            detail: "Open models · api.together.xyz",
            keyPlaceholder: "Together API key"
        ),
        BYOKProvider(
            id: "gmi",
            displayName: "MiniMax",
            detail: "MiniMax models",
            keyPlaceholder: "Provider API key"
        ),
    ]

    static func provider(id: String) -> BYOKProvider? {
        catalog.first { $0.id == id }
    }
}

/// Shared façade for multi-provider BYOK keys. The one place that branches on
/// platform so the SwiftUI surface (`SharedBYOKSettingsView`) never needs `#if`
/// for secret storage.
///
/// Storage: Keychain ONLY (CLAUDE.md secrets rule), one row per provider at
/// account `byok.{provider}.apiKey` — iOS `RemCredentialStore`, Mac
/// `MacBYOKKeychain`. This extends the prior single-key (`byok.gmi.apiKey`)
/// surface to N providers without a redesign or migration.
@MainActor
enum BYOKCredentialStore {

    /// Reads the stored key for a provider (Keychain), or `nil` if none.
    static func key(for providerID: String) -> String? {
        #if os(iOS)
        return RemCredentialStore.byokKey(forProvider: providerID)
        #else
        return MacBYOKKeychain.byokKey(forProvider: providerID)
        #endif
    }

    /// Saves a key for a provider; `nil` or all-whitespace clears it.
    static func setKey(_ value: String?, for providerID: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueToStore = (trimmed?.isEmpty == false) ? trimmed : nil
        #if os(iOS)
        RemCredentialStore.setBYOKKey(valueToStore, forProvider: providerID)
        #else
        MacBYOKKeychain.setBYOKKey(valueToStore, forProvider: providerID)
        #endif
    }

    /// Whether a non-empty key is stored for a provider, without revealing it.
    static func hasKey(for providerID: String) -> Bool {
        guard let key = key(for: providerID) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Catalog providers that currently have a saved key, in catalog order.
    static var configuredProviders: [BYOKProvider] {
        BYOKProvider.catalog.filter { hasKey(for: $0.id) }
    }

    /// Catalog providers without a saved key — the menu for the "+" action.
    static var availableProviders: [BYOKProvider] {
        BYOKProvider.catalog.filter { !hasKey(for: $0.id) }
    }

    /// True when at least one provider key is saved (any-tier "unlimited").
    static var hasAnyKey: Bool {
        BYOKProvider.catalog.contains { hasKey(for: $0.id) }
    }
}
