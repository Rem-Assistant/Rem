# Docs

## Current Direction

| Doc | Purpose |
|-----|---------|
| [release/iteration-2-delivery-ledger.md](release/iteration-2-delivery-ledger.md) | Active Iteration 2 continuation ledger: lane contracts, open PR heads and findings, simulator/build truth, exact acceptance checks, and safe resume sequence. |
| [product/VISION.md](product/VISION.md) | Current product source-of-truth: Rem as a phone-to-Mac personal AI assistant, gateway model, connector hierarchy, remote-control architecture, engineering posture, non-goals, and open questions. |
| [product/RELAUNCH_DOGFOOD.md](product/RELAUNCH_DOGFOOD.md) | E2E App Store relaunch dogfood checklist for iOS, Mac, gateway, visual evidence, blockers, and future product tracks. |
| [ORCHESTRATION.md](ORCHESTRATION.md) | Current Codex/Symphony lifecycle rules: issue triage, dispatch readiness, visual investigation/testing, independent review, merge ownership, branch hygiene, and durable findings. |
| [architecture/2026-08-08-codebase-assessment.md](architecture/2026-08-08-codebase-assessment.md) | Dated engineering assessment of code quality, modularity, distributed-state reliability, release risk, and remediation priorities. |
| [../README.md](../README.md) | New contributor entrypoint: product summary, setup, build/test commands, workflow, and deployment pointers. |
| [CONNECTION-ANALYSIS.md](CONNECTION-ANALYSIS.md) | Current gateway connection lifecycle, failure analysis, and reliability priorities. |
| [MAC_GATEWAY_TROUBLESHOOTING.md](MAC_GATEWAY_TROUBLESHOOTING.md) | Practical Mac local gateway dogfooding and recovery notes. |
| [IOS_MAC_PARITY.md](IOS_MAC_PARITY.md) | iOS/Mac feature parity audit. Treat product priorities in this file as secondary to `product/VISION.md` when they conflict. |
| [UX-NATIVE-ALIGNMENT.md](UX-NATIVE-ALIGNMENT.md) | Settings and native UI alignment notes, including main-window vs native macOS Settings direction. |
| [PEEKABOO_SETUP.md](PEEKABOO_SETUP.md) | Peekaboo harness setup for visual testing when available. |
| [VISUAL_QA.md](VISUAL_QA.md) | Required visual evidence rules for UI-facing PRs. |
| [product/README.md](product/README.md) | Product docs index. |
| [architecture/2026-08-09-cloud-gateway-byok-contract.md](architecture/2026-08-09-cloud-gateway-byok-contract.md) | Proposed cloud-gateway BYOK ownership, credential lifecycle, security, model integration, and managed-vs-self-hosted boundary. |

## Historical Hackathon Docs

These docs remain valuable for archaeology and original implementation intent,
but they are not the current source of truth when they conflict with product,
orchestration, or deployment docs above.

| Doc | Purpose |
|-----|---------|
| [architecture/system-design.md](architecture/system-design.md) | Historical architecture reference for the original hackathon target state. |
| [architecture/hackathon-plan.md](architecture/hackathon-plan.md) | Sprint plan, milestones, epics, schedule, and early reference codebases. |
| [architecture/app-architecture.md](architecture/app-architecture.md) | Baseline conventions from the original app architecture pass. |
| `architecture/epics/` | E0-E5 epic specs for the starter template, gateway deploy, text chat, voice, first-run, and settings. |
| [architecture/shared-demo-gateway.md](architecture/shared-demo-gateway.md) | Historical shared Railway demo gateway setup. Current per-user gateway deployment should start from `deploy/openclaw-gateway/DEPLOYMENT-RUNBOOK.md`. |

Older docs may mention `VoiceAgent/Hackathon/` or `RemClaw/Hackathon/`. Current
iOS code lives under `RemClaw/Sources/`, shared code under `Shared/`, and Mac code
under `RemClawMac/Sources/`.
