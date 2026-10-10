import Foundation
import RemChatUI

/// The one send path for an ordinary chat composer, shared by `SharedRemChatView` and the iOS
/// design-system adapter (`Rem/Sources/DesignSystemAdapter/RemChatScreenAdapter.swift`).
///
/// Extracted verbatim from `SharedRemChatView.sendIfReady()` so both surfaces gate and dispatch a
/// message identically: provider-evidence and in-flight gates (`ChatComposerSendPolicy.canSend`),
/// the request-quota gate, the synchronous payload snapshot (including the Cloud browser directive),
/// model-selection repair inside `RemChatViewModel.send(modelSelectionID:message:attachments:)`, and
/// the quota slot that is consumed only after repair and every local dispatch guard succeed.
///
/// View-local state (browser chip revision, streaming handoff cache, scroll anchoring) stays in the
/// caller: it runs that in `onAccepted`, which fires exactly once, at dispatch acceptance.
enum ChatSendCoordinator {
    /// The user-authorized payload, captured synchronously at Send. Model repair and quota can both
    /// suspend; anything typed meanwhile belongs to the next draft.
    struct Request {
        let modelSelectionID: String
        let message: String
        let attachments: [RemPendingAttachment]
        /// True when this send carries the Cloud browser directive and therefore consumes the chip.
        let consumesBrowserCapability: Bool
    }

    /// The model the next send must run on. Unknown provider evidence keeps the requested selection
    /// so `RemChatViewModel` can repair it authoritatively.
    static func effectiveModelSelectionID(
        viewModel: RemChatViewModel,
        providerEvidence: RuntimeProviderAuthEvidence
    ) -> String {
        guard providerEvidence.canReconcileExplicitSelection(
            viewModel.modelSelectionID
        ) else {
            return viewModel.modelSelectionID
        }
        return ModelPickerPolicy.effectiveSelectionID(
            requestedSelectionID: viewModel.modelSelectionID,
            models: viewModel.modelChoices,
            catalogCompleteness: viewModel.modelCatalogCompleteness,
            runtimeConfiguredProviderIDs: providerEvidence.effectiveProviderIDs ?? [],
            defaultModelLabel: viewModel.defaultModelLabel
        )
    }

    /// Send is enabled when the VM would allow it OR the cloud-browser chip is attached — the chip is
    /// content in its own right (it injects a directive on send), so it can send with an empty field.
    static func canSend(
        viewModel: RemChatViewModel,
        providerEvidence: RuntimeProviderAuthEvidence,
        browserCapabilityAttached: Bool
    ) -> Bool {
        let selectionID = effectiveModelSelectionID(
            viewModel: viewModel,
            providerEvidence: providerEvidence
        )
        return ChatComposerSendPolicy.canSend(
            input: viewModel.input,
            hasAuthoritativeProviderEvidence:
                providerEvidence.canReconcileExplicitSelection(selectionID),
            // Upstream OpenClaw keeps its default chat usable independently of `models.list`.
            // Rem's additional auth-evidence RPC is required only when honoring an explicit
            // provider choice; an older/local upstream gateway that lacks that RPC must not
            // strand Automatic chat.
            requiresProviderEvidence:
                selectionID != RemChatViewModel.defaultModelSelectionID,
            isPreparingSend: viewModel.isPreparingSend,
            viewModelCanSend: viewModel.canSend,
            browserCapabilityAttached: browserCapabilityAttached)
    }

    /// Session commands are control-plane input and never need request quota.
    static func hasRequiredQuota(viewModel: RemChatViewModel, hasQuota: Bool) -> Bool {
        ChatComposerSendPolicy.hasRequiredQuota(input: viewModel.input, hasQuota: hasQuota)
    }

    /// Applies the composer gates and captures the full user-authorized payload. Returns nil when the
    /// composer must not send now. `hasQuota` is evaluated only after the composer gate passes.
    ///
    /// Do not mutate the live composer here: TextField may still be committing, and any edit made
    /// during preparation belongs to the next draft.
    static func prepare(
        viewModel: RemChatViewModel,
        providerEvidence: RuntimeProviderAuthEvidence,
        browserCapabilityAttached: Bool,
        hasQuota: () -> Bool
    ) -> Request? {
        guard canSend(
            viewModel: viewModel,
            providerEvidence: providerEvidence,
            browserCapabilityAttached: browserCapabilityAttached
        ) else { return nil }
        guard hasRequiredQuota(viewModel: viewModel, hasQuota: hasQuota()) else { return nil }

        // A session command remains exact control-plane input. Do not wrap it in the browser
        // directive or consume a newly attached browser chip.
        let consumesBrowserCapability = browserCapabilityAttached
            && !ChatComposerSendPolicy.isSessionCommand(viewModel.input)
        let message = consumesBrowserCapability
            ? BrowserDirective.wrapChipSend(userText: viewModel.input)
            : viewModel.input
        return Request(
            modelSelectionID: effectiveModelSelectionID(
                viewModel: viewModel,
                providerEvidence: providerEvidence
            ),
            message: message,
            attachments: viewModel.attachments,
            consumesBrowserCapability: consumesBrowserCapability
        )
    }

    /// Hands `request` to the view model. Call it in the same synchronous callback as `prepare`:
    /// deferring through another Task would let a queued picker mutation or TextField commit run
    /// first, changing the model/thinking snapshot or making the old payload own a newer composer
    /// revision.
    ///
    /// Model reconciliation owns the first network phase. Quota and composer state change exactly
    /// once, only after that repair and all local dispatch guards succeed; otherwise a rejected
    /// reset/health check would charge the user. `onAccepted` runs at that dispatch boundary.
    static func dispatch(
        _ request: Request,
        viewModel: RemChatViewModel,
        consumeSendSlot: (@MainActor () async -> Bool)?,
        onAccepted: @escaping @MainActor () -> Void
    ) {
        viewModel.send(
            modelSelectionID: request.modelSelectionID,
            message: request.message,
            attachments: request.attachments
        ) {
            if let consumeSendSlot {
                let ok = await consumeSendSlot()
                guard ok else { return false }
            }
            onAccepted()
            return true
        }
    }
}
