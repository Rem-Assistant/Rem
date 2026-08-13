# Product Docs

Current product direction for Rem. These docs should explain the product in
plain language before agents optimize individual features.

| Doc | Purpose |
|-----|---------|
| [VISION.md](VISION.md) | Product promise, surfaces, gateway model, remote-control architecture, connector hierarchy, engineering posture, non-goals, and open questions. |
| [CAPABILITIES_IA.md](CAPABILITIES_IA.md) | Decision model for Connectors, Capabilities, Skills, MCP, Connected Accounts, Gateways, and the Mac-vs-cloud capability matrix. |
| [SOURCE-TAXONOMY.md](SOURCE-TAXONOMY.md) | Signals vs mirrors vs hybrids: what a connected system is allowed to *produce*. Rem watches everything; a mirror is restricted to prose and becomes a row only when the user asks. |
| [CONNECTOR_CREDENTIALS_HANDOFF.md](CONNECTOR_CREDENTIALS_HANDOFF.md) | Checklist for the point where live provider credentials, OAuth app ids, redirect URIs, and scopes are needed from a project admin. |
| [GATEWAY_UPDATE_FLOW.md](GATEWAY_UPDATE_FLOW.md) | Safety contract for in-app gateway updates, approved targets, preflight, backup/snapshot, health checks, and rollback. |
| [SECURITY_MODEL.md](SECURITY_MODEL.md) | Trust boundaries and safety rules for Connectors, Capabilities, Skills, MCP servers, Mac-local powers, and cloud gateways. |
| [PERMISSION_LIFECYCLE.md](PERMISSION_LIFECYCLE.md) | Runtime gateway approval, iOS permission, connector permission, deterministic state, and action lifecycle rules. |
| [MAC_CAPABILITY_SCOPES.md](MAC_CAPABILITY_SCOPES.md) | Approval classes, scope rules, and action log model for Mac-local high-risk powers. |
| [SESSION_PREVIEW_CONTRACT.md](SESSION_PREVIEW_CONTRACT.md) | Product and security contract for in-app session preview: activity feed first, visual preview only after explicit consent and action logs. |
| [LOCAL_MODEL_STRATEGY.md](LOCAL_MODEL_STRATEGY.md) | Recommendation for free/local model support, BYOK, and the paid cloud gateway boundary. |
| [TYPOGRAPHY_AUDIT.md](TYPOGRAPHY_AUDIT.md) | Shared typography scale and chat/settings consistency audit for iOS and Mac surfaces. |

## Product Feedback Intake

Product feedback from the user, product agents, reviews, visual investigations,
or dogfooding must be captured before implementation. The orchestrator should
update an existing issue, create a new issue with acceptance criteria, or add a
short investigation doc when the feedback needs evidence before slicing.
Product decisions should link back to `VISION.md` when they affect direction.
