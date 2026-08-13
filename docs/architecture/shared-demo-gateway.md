# Shared demo gateway (hackathon)

> Historical reference. This shared Railway demo setup is not the current Rem
> deployment source of truth. Managed backend and Fly gateway rollout is operated
> separately and is not part of this repo (see the Open-Core Boundary in the
> top-level `README.md`). Start with `README.md`, `docs/README.md`, and
> `docs/product/VISION.md` for current product context.

One OpenClaw gateway runs on Railway using the team’s Anthropic API key. Demo users connect to it (dashboard or Rem app) and chat without providing their own key.

## Who configures it

One person (e.g. devops or lead) sets Railway variables and runs the one-time setup. Everyone else uses the same gateway URL and token to connect.

## Required Railway settings

1. **Public networking**  
   Enable HTTP proxy, port **8080**.

2. **Volume**  
   Attach a volume mounted at **`/data`** (required for config and state).

3. **Variables** (set on the service)

   | Variable | Required | Description |
   |----------|----------|-------------|
   | `SETUP_PASSWORD` | Yes | Password for `/setup`. Pick a secret and share only with people who may need to change gateway config. |
   | `ANTHROPIC_API_KEY` | Yes (for shared demo) | Team’s Anthropic API key. All chat usage bills to this key. |
   | `PORT` | Yes | `8080` (must match Public Networking). |
   | `OPENCLAW_STATE_DIR` | Recommended | `/data/.openclaw` |
   | `OPENCLAW_WORKSPACE_DIR` | Recommended | `/data/workspace` |
   | `OPENCLAW_GATEWAY_TOKEN` | Optional | If unset, a token is generated and stored under the state dir. |

## One-time setup (after deploy)

1. Open **`https://<your-railway-domain>/setup`** in a browser.
2. Enter **`SETUP_PASSWORD`**.
3. Leave both **Venice** and **Anthropic** key fields **empty** (the server uses `ANTHROPIC_API_KEY` from Railway).
4. Click **Run onboarding**. Wait until it finishes.
5. If the dashboard shows “pairing required”:
   - Open the dashboard in another tab: `https://<your-railway-domain>/` (or the Control UI path).
   - Back in `/setup`, click **List pending devices**, copy the **requestId** from the “Pending requests” section.
   - Paste it into **Request ID** and click **Approve device**. Reload the dashboard.
6. On the setup page you’ll see the **gateway URL** and a **QR code**. These are the credentials for the Rem app and for sharing with the team.

## Sharing with the team

- **Gateway URL**: `https://<your-railway-domain>` (same as the setup host).
- **Gateway token**: Shown on the setup page after onboarding (and in the QR payload). Share this securely (e.g. team channel or 1Password). Anyone with the URL + token can connect the Rem app or dashboard.
- **Dashboard**: Users open the gateway URL, enter the token when prompted (or use a tokenized link), then approve their device once if they see “pairing required.”

Users do **not** need an Anthropic (or any other) API key; the shared gateway uses the key set in Railway.

## If something goes wrong

- **Chat stuck on loading**  
  Usually means no LLM was configured. In `/setup`, click **Reset setup**, then **Run onboarding** again (with `ANTHROPIC_API_KEY` set in Railway, leave the key fields blank).

- **“Pairing required” (1008)**  
  The browser or app must be approved as a device. Use **List pending devices** in `/setup`, copy the **requestId** from “Pending requests,” then **Approve device**. Reload the dashboard or reconnect the app.

- **Need to change the API key**  
  Update `ANTHROPIC_API_KEY` in Railway, then in `/setup` click **Reset setup** and **Run onboarding** again (leave key fields blank to use the new env value).

## Optional: use your own key

To run a **separate** gateway with a personal API key, deploy again (e.g. new Railway service or new project) and set **your** `ANTHROPIC_API_KEY` there. Or, on the same shared deploy, a teammate with `/setup` access can paste their Anthropic key in the “Anthropic API key” field before clicking Run onboarding — that overrides the Railway env for that run (use sparingly; it replaces the shared key for everyone until the next reset).

## Reference

- Deploy details: managed cloud infrastructure is operated separately and is not part of this repo (see the Open-Core Boundary in the top-level `README.md`).
- System design: [system-design.md](system-design.md)
