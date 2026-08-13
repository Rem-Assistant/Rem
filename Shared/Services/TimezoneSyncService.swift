import Foundation

struct GatewayTimezoneSyncCoalescer {
    private var inFlightTargets: Set<String> = []
    private var pendingTargets: Set<String> = []

    mutating func begin(target: String) -> Bool {
        if inFlightTargets.contains(target) {
            pendingTargets.insert(target)
            return false
        }
        inFlightTargets.insert(target)
        return true
    }

    mutating func finish(target: String) -> Bool {
        inFlightTargets.remove(target)
        return pendingTargets.remove(target) != nil
    }
}

/// Best-effort capture of the DEVICE timezone to the backend so the daily-brief CRON — which
/// has no live device to read — resolves the user's LOCAL day + greeting + authoring slot
/// correctly (issue #1097). Posts `TimeZone.current.identifier` to
/// `POST /api/v1/users/timezone`, which upserts `users.timezone` (the top of the backend's
/// `resolveUserTimezone` chain).
///
/// Fire-and-forget: a failure is NON-FATAL and simply retried on the next launch/foreground/
/// sign-in. Reuses the app's authenticated HTTP client (base-URL + JWT + 401-refresh), exactly
/// like `CheckinsService` — same `#if os(iOS)` transport split, no new auth path.
///
/// Idempotent-ish: we cache the last successfully-sent tz and skip a redundant POST when it is
/// unchanged, so foregrounding repeatedly doesn't spam the endpoint. The device tz is
/// account-independent (both users on one install share the same wall clock), so the cache is
/// intentionally NOT user-scoped — a tz CHANGE (travel, DST edge, first launch) always re-posts.
///
/// NOTE: a manual account-level timezone-override SETTING is a deliberate follow-up. It would
/// write the same `users.timezone` column via the same endpoint, so this capture path needs no
/// change for it — the manual value would simply be another writer of the same column.
@MainActor
public enum TimezoneSyncService {

    private static let lastSentTimezoneKey = "rem.timezone.lastSent"
    private static var gatewaySyncCoalescer = GatewayTimezoneSyncCoalescer()

    private struct TimezoneBody: Encodable {
        let timezone: String
    }

    /// Post the current device timezone if it differs from the last one we successfully sent.
    /// Safe to call unauthenticated (it no-ops) and safe to call often. Never throws.
    public static func syncCurrentTimezone() {
        let tz = TimeZone.current.identifier
        guard !tz.isEmpty else { return }

        // Skip a redundant POST when the tz hasn't changed since the last success.
        if UserDefaults.standard.string(forKey: lastSentTimezoneKey) == tz {
            return
        }

        Task { await post(timezone: tz) }
    }

    /// Force a post regardless of the skip-cache — used right after sign-in, when a new account
    /// on this install should be (re)stamped with the device tz even if the value is unchanged.
    public static func syncCurrentTimezoneForcingRefresh() {
        let tz = TimeZone.current.identifier
        guard !tz.isEmpty else { return }
        Task { await post(timezone: tz) }
    }

    /// Reconciles timezone directly through the already paired operator session. This is the
    /// authenticated recovery path for manual/self-hosted gateways, where the backend has a gateway
    /// token but intentionally does not possess the device identity or setup password required for
    /// `operator.admin`. Cloud gateways also use it as a final client-side consistency check.
    static func syncCurrentTimezoneToGateway(
        _ gateway: any GatewaySessionProviding
    ) {
        // `skillsRequest` uses the paired operator session, which can be ready while the node leg
        // is still connecting or unreachable. Requiring aggregate node state here can permanently
        // discard the only operator-ready callback for a manual gateway.
        guard gateway.operatorReady else { return }
        let timezone = TimeZone.current.identifier
        guard !timezone.isEmpty else { return }
        let target = gateway.activeLocalGatewayURL ?? gateway.storedGatewayURL ?? "active-gateway"
        guard gatewaySyncCoalescer.begin(target: target) else { return }

        Task {
            defer {
                if gatewaySyncCoalescer.finish(target: target) {
                    // A reconnect/reset arrived while this request was using the prior operator
                    // session. Replay once after it settles so the newer live config is verified.
                    syncCurrentTimezoneToGateway(gateway)
                }
            }
            do {
                let snapshotData = try await gateway.skillsRequest(
                    method: "config.get",
                    paramsJSON: "{}",
                    timeoutSeconds: 15
                )
                let snapshot = try JSONDecoder().decode(ConfigGetResponse.self, from: snapshotData)
                // Always verify the live snapshot. A URL/timezone stamp cannot detect a reset,
                // restore, or config replacement at the same manual-gateway URL.
                if snapshot.config?.agents?.defaults?.userTimezone == timezone {
                    #if DEBUG
                    print("[Timezone] gateway userTimezone already current \(timezone)")
                    #endif
                    return
                }
                let paramsJSON = try gatewayTimezonePatchParamsJSON(
                    timezone: timezone,
                    baseHash: snapshot.patchBaseHash
                )
                _ = try await gateway.skillsRequest(
                    method: "config.patch",
                    paramsJSON: paramsJSON,
                    timeoutSeconds: 20
                )
                #if DEBUG
                print("[Timezone] synced gateway userTimezone \(timezone)")
                #endif
            } catch {
                // Best-effort: config hash races, pairing transitions, and offline gateways retry
                // on the next operator connection or foreground activation.
                #if DEBUG
                print("[Timezone] gateway sync error: \(error.localizedDescription)")
                #endif
            }
        }
    }

    static func gatewayTimezonePatchParamsJSON(
        timezone: String,
        baseHash: String?
    ) throws -> String {
        guard let baseHash, !baseHash.isEmpty else {
            throw NSError(
                domain: "TimezoneSyncService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Gateway config snapshot did not include a hash"]
            )
        }
        let patch: [String: Any] = [
            "agents": [
                "defaults": [
                    "userTimezone": timezone
                ]
            ]
        ]
        let rawData = try JSONSerialization.data(withJSONObject: patch)
        guard let raw = String(data: rawData, encoding: .utf8) else {
            throw NSError(
                domain: "TimezoneSyncService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode gateway timezone patch"]
            )
        }
        let params = ConfigPatchParams(raw: raw, baseHash: baseHash)
        let paramsData = try JSONEncoder().encode(params)
        guard let paramsJSON = String(data: paramsData, encoding: .utf8) else {
            throw NSError(
                domain: "TimezoneSyncService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode config.patch parameters"]
            )
        }
        return paramsJSON
    }

    private static func post(timezone: String) async {
        do {
            let body = try JSONEncoder().encode(TimezoneBody(timezone: timezone))
            let (_, http) = try await request(
                path: "/api/v1/users/timezone", method: "POST", body: body)
            guard (200...299).contains(http.statusCode) else {
                #if DEBUG
                print("[Timezone] sync failed — HTTP \(http.statusCode)")
                #endif
                return
            }
            UserDefaults.standard.set(timezone, forKey: lastSentTimezoneKey)
            #if DEBUG
            print("[Timezone] synced device tz \(timezone)")
            #endif
        } catch {
            // Best-effort: unauthenticated (no token yet) or a transport error just retries
            // on the next launch/foreground/sign-in. Non-fatal by design.
            #if DEBUG
            print("[Timezone] sync error: \(error.localizedDescription)")
            #endif
        }
    }

    private static func request(
        path: String,
        method: String,
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        #if os(iOS)
        return try await AuthenticatedHttpClient.request(path: path, method: method, body: body)
        #else
        return try await MacAuthenticatedHttpClient.request(path: path, method: method, body: body)
        #endif
    }
}
