import SwiftUI

/// SwiftUI environment value that exposes the app-wide
/// `LocalGatewayManager` instance to deeply-nested shared views.
///
/// Injected once at the Mac app root (`RemClawMacApp`) so any view —
/// including `SharedGatewayListView` in the cross-platform layer — can
/// reach the live local-gateway state without prop-drilling. iOS doesn't
/// have a local gateway and never reads this key.
private struct LocalGatewayKey: EnvironmentKey {
    static let defaultValue: LocalGatewayManager? = nil
}

extension EnvironmentValues {
    var localGateway: LocalGatewayManager? {
        get { self[LocalGatewayKey.self] }
        set { self[LocalGatewayKey.self] = newValue }
    }
}
