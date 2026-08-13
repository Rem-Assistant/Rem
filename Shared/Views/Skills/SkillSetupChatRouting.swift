import SwiftUI

struct SkillSetupChatRequest: Equatable {
    let skillName: String
    let skillKey: String
    let missingSummary: String
    let requirementTitle: String?
    let requirementDetail: String?
    /// When set, this text is used verbatim as the chat prompt instead of the skill-derived
    /// template. Lets non-skill setup flows (e.g. Channels connect) reuse the same chat-routing
    /// mechanism without a backing `SkillEntry` (see #929 / channels connect).
    private let promptOverride: String?
    /// App-Store-style verb for this capability — "Connect" when it needs an
    /// account/credential, "Install" when it only needs a tool on the machine.
    /// See `SkillEntry.setupActionLabel`.
    let actionLabel: String
    /// What the capability actually needs, used to pick the prompt's steps. `nil` for the
    /// direct-prompt variant, which carries its own text.
    private let setupKind: SkillSetupKind?

    init(skill: SkillEntry, primaryRequirement: SkillRequirementDisplayRow? = nil) {
        self.skillName = skill.name ?? skill.skillKey
        self.skillKey = skill.skillKey
        self.missingSummary = skill.missingShortLabel
        self.requirementTitle = primaryRequirement?.title
        self.requirementDetail = primaryRequirement?.detail
        self.promptOverride = nil
        self.actionLabel = skill.setupActionLabel
        self.setupKind = skill.setupKind
    }

    /// Direct-prompt variant for setup flows that aren't backed by a `SkillEntry` — the caller
    /// supplies the exact composer text. Used by Channels connect so tapping Connect opens chat
    /// pre-typed with e.g. "connect WhatsApp", mirroring the capabilities install row (#929).
    init(prompt: String, name: String, key: String) {
        self.skillName = name
        self.skillKey = key
        self.missingSummary = ""
        self.requirementTitle = nil
        self.requirementDetail = nil
        self.promptOverride = prompt
        self.actionLabel = ""
        self.setupKind = nil
    }

    /// The composer text that seeds the setup chat.
    ///
    /// This used to be a single terse line ("Connect WhatsApp" / "Install ffmpeg"), on the
    /// assumption that the key/status/requirement context reached the agent out of band via
    /// this struct. It doesn't: the host only ever reads `prompt` and drops the rest on the
    /// floor (`ContentView.openSkillSetupChat` seeds `ChatDestination(prefill:)` and nothing
    /// else), so the agent saw two words with no gateway context and guessed — which is how
    /// "Connect WhatsApp" turned into a monologue about runtimes. The prompt is the only
    /// channel to the agent, so the context it needs has to be *in* the prompt.
    /// The ask is always "get this capability ready", with `setupKind` choosing only the *steps*.
    /// A capability can be blocked on several things at once (`goplaces` needs both a binary and
    /// an API key), and `setupKind` reports just the highest-precedence one — so a prompt built
    /// as "set up the credentials for X" can end up quoting an unrelated install blocker. Asking
    /// for the end state instead of one named sub-task stays true whatever the row says.
    var prompt: String {
        if let promptOverride { return promptOverride }
        guard let setupKind else { return "\(actionLabel) \(skillName)" }
        return """
        Get my "\(skillName)" capability (skill key: \(skillKey)) ready to use.\
        \(requirementClause) \(Self.steps(for: setupKind)) Then re-check the skill's \
        requirements and confirm it's ready.
        """
    }

    private static func steps(for kind: SkillSetupKind) -> String {
        switch kind {
        case .connectAccount(let providers):
            return """
            It needs my \(list(providers.map(\.displayName))) account authorized — walk me \
            through that step by step.
            """
        case .credential(let env):
            return """
            It needs these credential values: \(list(env)). Tell me where to get each one; when \
            I paste them, configure them on your gateway. Don't echo the values back into the chat.
            """
        case .installTool:
            return """
            Check what's actually missing on your runtime and install it there. Don't restart \
            the gateway.
            """
        }
    }

    /// The blocker the UI showed, quoted back so the agent starts where the user did instead of
    /// rediscovering it. Prefers the specific requirement row, falling back to the short summary.
    /// Both are rendered as *quoted UI text* rather than dropped into a sentence of our own —
    /// `missingShortLabel` is an imperative ("Install op"), so "it's blocked: Install op" reads
    /// as an instruction rather than a description.
    private var requirementClause: String {
        let rowParts = [requirementTitle, requirementDetail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let shown = rowParts.isEmpty
            ? missingSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            : rowParts.joined(separator: " — ")
        guard !shown.isEmpty else { return "" }
        return " The capability list shows: \(shown)."
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return "\(items.dropLast().joined(separator: ", ")), and \(items[items.count - 1])"
        }
    }
}

private struct OpenSkillSetupChatKey: EnvironmentKey {
    static let defaultValue: ((SkillSetupChatRequest) -> Void)? = nil
}

extension EnvironmentValues {
    var openSkillSetupChat: ((SkillSetupChatRequest) -> Void)? {
        get { self[OpenSkillSetupChatKey.self] }
        set { self[OpenSkillSetupChatKey.self] = newValue }
    }
}
