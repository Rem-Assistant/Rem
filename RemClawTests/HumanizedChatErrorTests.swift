import Foundation
import Testing
@testable import RemClaw

/// Follow-up to PR #1123: `SharedRemChatView.humanizedChatError` must only show
/// the "Couldn't reach Rem — reconnecting…" copy for a genuine gateway-transport
/// failure — not for an outbound socket error surfaced by a tool/agent call while
/// the gateway is healthy.
///
/// The ambiguous tokens `socket` / `econn` / `handshake` are common in Node tool
/// code hitting third-party APIs ("socket hang up", "ECONNRESET", "SSL handshake
/// failed"), so they only count as a connection problem when the message also
/// carries a gateway-transport marker OpenClawKit's own transport layer prepends
/// (`GatewayChannel.wrap`: "gateway connect", "connect to gateway @ wss://…",
/// "gateway send …", "gateway receive", "gateway reconnect").
struct HumanizedChatErrorTests {

    private let reconnecting = "Couldn't reach Rem — reconnecting…"
    private let waking = "Rem is waking up — this takes a few seconds. Try again in a moment."

    // MARK: - The bug: healthy-gateway tool errors must pass through

    @Test func socketHangUpFromToolPassesThrough() {
        // The motivating case: a tool's outbound fetch fails while the gateway is fine.
        let raw = "Error: socket hang up"
        #expect(SharedRemChatView.humanizedChatError(raw) == raw)
        #expect(SharedRemChatView.humanizedChatError(raw) != reconnecting)
    }

    @Test func econnresetFromToolPassesThrough() {
        let raw = "request to https://api.example.com failed, reason: read ECONNRESET"
        #expect(SharedRemChatView.humanizedChatError(raw) == raw)
        #expect(SharedRemChatView.humanizedChatError(raw) != reconnecting)
    }

    @Test func econnrefusedFromToolPassesThroughInsteadOfWaking() {
        // Previously matched `wakingSignals` standalone and was mislabeled "waking up".
        let raw = "connect ECONNREFUSED 127.0.0.1:5432"
        let humanized = SharedRemChatView.humanizedChatError(raw)
        #expect(humanized == raw)
        #expect(humanized != waking)
        #expect(humanized != reconnecting)
    }

    @Test func sslHandshakeFailedFromToolPassesThrough() {
        let raw = "SSL handshake failed: certificate has expired"
        #expect(SharedRemChatView.humanizedChatError(raw) == raw)
        #expect(SharedRemChatView.humanizedChatError(raw) != reconnecting)
    }

    // MARK: - Real gateway-transport failures still get the friendly copy

    @Test func gatewayConnectHandshakeStillReconnects() {
        // Real connect-time transport error carries the "connect to gateway @ wss://" prefix.
        let raw = "connect to gateway @ wss://remclaw-abcd1234.fly.dev/: TLS handshake failed"
        #expect(SharedRemChatView.humanizedChatError(raw) == reconnecting)
    }

    @Test func gatewaySendSocketStillReconnects() {
        // Mid-session send failure: "socket" anchored by the "gateway send" context prefix,
        // with no wss:// URL — exercises the marker beyond the URL tokens. ("socket hang up"
        // deliberately avoids "not connected"/"connection lost", which the disconnectedSignals
        // classifier catches first with its own friendly copy.)
        let raw = "gateway send chat.send: socket hang up"
        #expect(SharedRemChatView.humanizedChatError(raw) == reconnecting)
    }

    @Test func gatewayReceiveEconnStillReconnects() {
        let raw = "gateway receive: read ECONNRESET"
        #expect(SharedRemChatView.humanizedChatError(raw) == reconnecting)
    }

    @Test func gatewayReconnectHandshakeIsAnchoredNotShortCircuited() {
        // Exercises the `handshake` token AND the `gateway reconnect` marker THROUGH the
        // anchor: unlike a "connect to gateway @ wss://…" string (which returns early at
        // strongConnectSignals), this reaches isGatewayTransportWireError — so it guards
        // against a future removal of either "handshake" or "gateway reconnect".
        let raw = "gateway reconnect: SSL handshake failed"
        #expect(SharedRemChatView.humanizedChatError(raw) == reconnecting)
    }

    // MARK: - #1123 wins stay intact

    @Test func gatewayUrlStillMapsToFriendlyCopyInProd() {
        let raw = "gateway connect: connect to gateway @ wss://remclaw-xxxx.fly.dev/: There was a bad response"
        #expect(SharedRemChatView.humanizedChatError(raw) == reconnecting)
    }

    @Test func developerBuildShowsRawWireText() {
        // showRawDetail == true (dev/staging) always passes the raw text through for debugging.
        let raw = "connect to gateway @ wss://remclaw-xxxx.fly.dev/: TLS handshake failed"
        #expect(SharedRemChatView.humanizedChatError(raw, showRawDetail: true) == raw)
    }

    @Test func developerBuildShowsRawToolSocketError() {
        let raw = "Error: socket hang up"
        #expect(SharedRemChatView.humanizedChatError(raw, showRawDetail: true) == raw)
    }

    // MARK: - Regression guards for the other classifiers (unchanged behavior)

    @Test func healthPreflightStillMapsToWaking() {
        #expect(SharedRemChatView.humanizedChatError("Gateway health not OK; cannot send") == waking)
    }

    @Test func unknownAgentMessagePassesThrough() {
        let raw = "That event does not exist in your calendar."
        #expect(SharedRemChatView.humanizedChatError(raw) == raw)
    }
}
