import Foundation

/// Typed shape of `openclaw qr --json` output. Mirrors
/// `openclaw/src/cli/qr-cli.ts:223-230`. We only depend on `setupCode`; the
/// other fields are kept as documentation that upstream emits them, in case
/// future flows want to surface `gatewayUrl` / `auth` / `urlSource` to the UI.
nonisolated struct PairableSetupCodePayload: Decodable, Equatable {
    let setupCode: String
    let gatewayUrl: String?
    let auth: String?
    let urlSource: String?

    nonisolated static func decode(_ data: Data) -> Result<Self, Error> {
        do {
            return .success(try JSONDecoder().decode(Self.self, from: data))
        } catch {
            return .failure(error)
        }
    }
}
