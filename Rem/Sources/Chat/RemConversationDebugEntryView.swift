#if DEBUG
import SwiftUI

/// DEBUG-only reachable entry to the Rem-owned conversation path — ordinary chat that runs against
/// Rem's own `/api/v1/conversations` API (no OpenClaw gateway) and renders/acts on task-update
/// proposals. It creates a fresh conversation via the live authenticated service, then hands it to
/// `RemConversationView`. This makes the Rem conversation path reachable in-app for internal use;
/// it is auth-gated (a signed-in session is required to reach the backend). The default chat surface
/// still routes through the gateway — swapping that is a separate, runtime-verified step.
struct RemConversationDebugEntryView: View {
    @State private var viewModel: RemConversationViewModel?
    @State private var errorText: String?
    private let service = RemConversationApiService()

    var body: some View {
        Group {
            if let viewModel {
                RemConversationView(viewModel: viewModel)
            } else if let errorText {
                ContentUnavailableView(
                    "Couldn’t start a conversation",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorText)
                )
            } else {
                ProgressView("Starting…")
            }
        }
        .navigationTitle("Rem Conversation")
        .task { await start() }
    }

    private func start() async {
        guard viewModel == nil else { return }
        do {
            let conversation = try await service.createConversation(title: "Debug conversation")
            viewModel = RemConversationViewModel(conversationId: conversation.id, service: service)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
#endif
