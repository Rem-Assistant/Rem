import Foundation

/// Legacy native Settings window titles that should be hidden after routing to
/// the canonical in-app Settings surface.
public enum MacNativeSettingsTab {
    /// Stable identifier previously used by the technical native Settings
    /// fallback window.
    ///
    /// The visible Rem Settings surface lives in the main app window. Current
    /// builds no longer declare a native Settings scene, but older/restored
    /// windows may still need to be hidden after route handoff.
    public static let fallbackWindowIdentifier = "rem.native-settings-fallback"

    public static let legacyWindowTitles: Set<String> = [
        "Settings",
        "General",
        "Permissions",
        "Backup",
        "About",
    ]
}
