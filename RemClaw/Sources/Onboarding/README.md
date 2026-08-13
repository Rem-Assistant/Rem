# Onboarding (iOS)

> What a new user sees on first launch: sign in with Apple or Google, restore or
> deploy a personal gateway, accept the AI data-sharing terms before deploying a
> new gateway, and read a short post-setup activation screen after that new
> gateway is ready. Returning users skip straight to the app once credentials
> and gateway state are restored.

Current first-launch flow: sign-in → existing gateway restore or new-gateway AI
data-sharing consent → gateway deployment → post-setup activation.

## Key Files

| File | Purpose |
|------|---------|
| `OnboardingFlow.swift` | Main orchestrator: sign-in step (Apple/Google buttons, returning user detection), new-gateway AI data-sharing consent, gateway deployment/restore step (progress bar with phase indicators, elapsed time, retry on failure), and post-setup activation after a fresh deploy. Polls `POST /api/v1/deploy` then `GET /api/v1/deploy/status` every 1s when a new cloud gateway is being provisioned. |
| `LaunchScreenView.swift` | Splash screen shown on app startup. States: splash → connecting (provider-aware gateway copy) → failed (contextual retry) → ready. Adaptive scaling based on device size. |
| `LaunchRecoveryCopyFixtureView.swift` | DEBUG-only screenshot fixture for provider-aware launch and disconnected-banner recovery states. Launch with `--rem-launch-recovery-copy-fixture`; add `--rem-launch-recovery-banner-section` for a banner-only capture. |
| `TaskCollaborationFixtureView.swift` | DEBUG-only screenshot fixture hosting the shared comment thread (`TaskCommentsThread`) with a `MockTaskCommentService` (no auth/backend). Launch with `--rem-collaboration-fixture`; add `--rem-collaboration-empty` for the empty-state capture. Mac counterpart: `MacTaskCollaborationFixtureView`. |
| `CloudGatewayDeployFixtureView` | DEBUG-only screenshot fixture for cloud gateway deploy, repair, and approval recovery states. Launch with `--rem-cloud-deploy-fixture`; add `--rem-cloud-deploy-progress-fixture`, `--rem-cloud-repair-progress-fixture`, or `--rem-cloud-deploy-approval-fixture` for single-state captures. |
| `AIDataSharingConsentView.swift` | Explicit consent for third-party data sharing (App Store 5.1.1). Uses a concise privacy-first screen with Bevel-style Terms/Privacy list rows, account-data deletion copy, and one bottom primary CTA. The Privacy row points users to details about the AI model provider (MiniMax, served via GMI, by default), optional voice services, and gateway state before consent. It is shown from `OnboardingFlow` only when a signed-in user is about to deploy a new gateway; screenshot fixture launches with `--rem-ai-data-sharing-consent-fixture`. |
| `PostSetupActivationView.swift` | Dedicated post-setup value/trust screen for Wave 2. Uses a paged how-to flow for chat capture, Lock Screen access, and gateway status/control. Prompt examples live in the first empty chat instead of this education screen. It is shown from `OnboardingFlow` only after fresh gateway deployment, with completion stored in `@AppStorage("rem.hasSeenPostSetupActivation.v1")`; screenshot fixture launches with `--rem-post-setup-nux-fixture`. |
| `FirstUseHintPopoverFixtureView` | DEBUG-only screenshot fixture for the anchored first-use chat hint. Launch with `--rem-first-use-hint-fixture`. |

## Flow Sequence

```
RemClawApp
  → LaunchScreenView (splash)
  → ContentView (gate-keeper)
      → OnboardingFlow (sign-in + gateway restore)
          → AIDataSharingConsentView (new gateway deploy only)
          → deploy progress
          → PostSetupActivationView (after new gateway deploy only)
      → RemMainTabView (actual app)
```

## Patterns & Conventions

- **State machines**: `OnboardingFlow.Step` (signIn/dataSharingConsent/deploying/postSetupActivation), `LaunchScreenView.State` (splash/connecting/failed/ready), `OnboardingPhaseInfo.State` (pending/active/done/failed).
- **Deploy polling**: `pollStatus()` hits `/api/v1/deploy/status` every 1s with phase-aware progress display (creating → deploying → configuring → finishing) when a new gateway is being provisioned.
- **Time-based sublabels**: Dynamic messages during "Configuring Server" phase rotate based on elapsed time to keep users informed.
- **Returning user detection**: Checks Keychain for existing credentials (survives app reinstall) and shows "Continue as [Name]" flow.
- **Launch recovery scope (#284)**: The launch screen should explain the selected gateway's recovery state, allow retry, allow continuing into backend-synced app surfaces, and route users to connection review when trust/network state needs attention. It should not become a full gateway switcher or silently move Mac-local actions to cloud. Gateway switching belongs in Gateway Detail or contextual chat/gateway recovery surfaces where users can compare capabilities and understand which gateway owns Mac-local work.
- **Post-setup NUX scope (#761)**: Keep returning-user restore focused on getting back into the app. Product education lives after fresh gateway setup in a paged `PostSetupActivationView`; `RemMainTabView` anchors the first-use chat hint to the New Chat control, and the first empty chat owns example prompts.
- **Spring animations**: Asymmetric slide/opacity transitions between steps with spring (response: 0.45, dampingFraction: 0.85).
- **Shared components**: Uses `SignInButton`, `PermissionChecker`, `SettingsIcon`, `LegalDocumentView`, `OnboardingLogoView`.

## Current Notes

- The cloud gateway path is Fly-first for user gateways, with backend/Railway
  metadata and deployment orchestration. The managed deployment tooling is
  operated separately and is not part of this repo (see the Open-Core Boundary
  in the top-level `README.md`).
- Gateway connection recovery and pairing states are still actively dogfooded.
  Do not treat old hackathon docs as definitive for onboarding copy or failure
  handling.
