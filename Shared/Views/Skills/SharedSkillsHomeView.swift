import SwiftUI

// MARK: - Shared Skills Home View
//
// App Store-style combined surface with two tabs:
//   - Installed: existing skills.status + skills.update UI (enable / disable).
//   - Browse:    new ClawHub search + install UI.
//
// Uses a segmented picker that swaps the body. Single NavigationLink entry
// point from Gateway detail; each tab owns its own RPCs.
//
// Generic over `GatewaySessionProviding` so iOS and Mac share a single
// implementation with no `#if` splits.

struct SharedSkillsHomeView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway
    var connectorDestination: ((SkillConnectorProvider) -> AnyView)? = nil

    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Manage"
        case browse = "Browse"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .installed

    var body: some View {
        VStack(spacing: 0) {
            Picker("Skills", selection: $tab) {
                ForEach(Tab.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            switch tab {
            case .installed:
                SharedSkillsSettingsView(
                    gateway: gateway,
                    connectorDestination: connectorDestination
                )
            case .browse:
                SharedSkillBrowseView(gateway: gateway)
            }
        }
        .accessibilityIdentifier("shared-skills-home")
    }
}

#if DEBUG
#Preview("Skills Home — Connected Gateway") {
    NavigationStack {
        SharedSkillsHomeView(
            gateway: PreviewGatewaySession(scenario: .cloudConnected)
        )
        .navigationTitle("Capabilities")
    }
}

#Preview("Skills Home — Gateway Unreachable") {
    NavigationStack {
        SharedSkillsHomeView(
            gateway: PreviewGatewaySession(scenario: .cloudUnreachable)
        )
        .navigationTitle("Capabilities")
    }
}
#endif
