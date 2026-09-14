import Testing
import Foundation
import SwiftUI
@testable import Rem

/// Regression coverage for #1342 PART 1 — the positive scheme allowlist that `AssistantMarkdownView`
/// applies to every tappable link before it can reach the system's `openURL`.
///
/// The exploit (measured in #1341): an assistant/tool turn emits
/// `[Connect](remclaw://connect?url=…&token=…)`, SwiftUI's `Text` linkifies the custom scheme, and a
/// tap dispatches it into the app's own `onOpenURL`, silently repointing the gateway. These tests
/// assert the policy REFUSES to dispatch that scheme (and every non-handoff scheme) while keeping
/// the four external-app-handoff schemes.
///
/// RED proof: make `AssistantMarkdownLinkPolicy.allowsDispatch` `return true` (a denylist that
/// enumerates nothing, i.e. the pre-fix behavior) — `rejectsGatewayRepointScheme`,
/// `rejectsUnknownAndDangerousSchemes`, `schemelessURLIsRejected`, and
/// `parserLinkifiesRepointSchemeButPolicyRefusesDispatch` fail. GREEN: with the allowlist, all pass.
@Suite("Assistant markdown link scheme allowlist (#1342)")
struct AssistantMarkdownLinkPolicyTests {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("test URL did not parse: \(string)")
        }
        return url
    }

    /// The exact sink from #1341: a gateway repoint behind an innocuous label.
    @Test func rejectsGatewayRepointScheme() {
        #expect(AssistantMarkdownLinkPolicy.allowsDispatch(
            to: url("remclaw://connect?url=https://evil.example&token=STOLEN")) == false)
    }

    /// Positive allowlist: everything not on the list is refused, including a custom scheme that
    /// re-introduces the machine-readable payload (`add-task`), a voice control link, and the
    /// `javascript:` row from the probe that a denylist would never have thought to enumerate.
    @Test func rejectsUnknownAndDangerousSchemes() {
        for raw in [
            "remclaw://add-task?title=T&date=D",
            "remclaw://voice/start",
            "javascript:alert(document.cookie)",
            "file:///etc/passwd",
            "ftp://example.com/x",
            "data:text/html,<script>alert(1)</script>",
            "someunregisteredscheme://do-a-thing",
        ] {
            #expect(AssistantMarkdownLinkPolicy.allowsDispatch(to: url(raw)) == false,
                    "\(raw) must be refused")
        }
    }

    /// The four external-app-handoff schemes survive — they leave our process for an app with its
    /// own confirmation UI. Case-insensitive, so an upper/mixed-case scheme is still permitted.
    @Test func permitsExternalHandoffSchemes() {
        for raw in [
            "https://example.com/x?a=1",
            "http://example.com",
            "HTTPS://EXAMPLE.COM/x",
            "MailTo:a@b.com",
            "mailto:a@b.com?subject=Hi",
            "tel:+15551234",
            "TEL:+15551234",
        ] {
            #expect(AssistantMarkdownLinkPolicy.allowsDispatch(to: url(raw)) == true,
                    "\(raw) must be permitted")
        }
    }

    /// A scheme-less (relative) URL has no external destination and must fail closed.
    @Test func schemelessURLIsRejected() {
        #expect(AssistantMarkdownLinkPolicy.allowsDispatch(to: url("/relative/path")) == false)
    }

    /// Ties the policy back to the actual vulnerability. Foundation's markdown parser — the family
    /// SwiftUI's `LocalizedStringKey` uses, run here with the same inline-only options — DOES attach
    /// a `.link` carrying the custom scheme and the intact `url=`/`token=` payload. The policy is the
    /// thing that refuses to hand that link to `openURL`.
    @Test func parserLinkifiesRepointSchemeButPolicyRefusesDispatch() throws {
        let markdown = "[Connect](remclaw://connect?url=https://evil.example&token=STOLEN)"
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = try AttributedString(markdown: markdown, options: options)

        let linkedURLs = attributed.runs.compactMap { $0.link }
        // Precondition of the bug: the parser linkifies the custom scheme with its payload intact.
        let repointLinks = linkedURLs.filter { $0.scheme?.lowercased() == "remclaw" }
        #expect(!repointLinks.isEmpty, "parser should still linkify the custom scheme (the vuln)")

        // The fix: every such link is refused dispatch.
        for link in repointLinks {
            #expect(AssistantMarkdownLinkPolicy.allowsDispatch(to: link) == false)
            // And the dangerous payload really is riding on it (documents what was at stake).
            let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.contains(where: { $0.name == "token" }) == true)
        }
    }
}
