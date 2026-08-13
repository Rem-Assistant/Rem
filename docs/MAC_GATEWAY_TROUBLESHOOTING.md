# Mac local gateway troubleshooting

Practical reference for the kinds of failures that have eaten hours during dogfooding. Add to this as new patterns surface.

## Quick state check

```bash
# 1. Are gateway processes running?
ps aux | grep openclaw-gateway | grep -v grep

# 2. Is port 18789 actually listening?
lsof -iTCP:18789 -sTCP:LISTEN

# 3. What's paired vs pending?
~/.openclaw/bin/openclaw devices list

# 4. What's in launchd's loaded services?
# Rem should not own a LaunchAgent; upstream OpenClaw may, if installed manually.
launchctl list | grep -E 'openclaw|remclaw'

# 5. What plists exist?
ls ~/Library/LaunchAgents/ | grep -E 'openclaw|remclaw'
ls /Library/LaunchAgents/ 2>/dev/null | grep -E 'openclaw|remclaw'

# 6. Recent gateway error log
tail -50 ~/.openclaw/logs/gateway.err.log
```

## Legacy duplicate LaunchAgents (fixed by #386)

Older Rem Mac builds installed their own LaunchAgent separate from upstream's. That was fixed by #386: the patched app spawns the local gateway as a child process and scrubs `app.remclaw.mac.gateway.plist` on launch.

| Plist | Owner | Purpose |
|-------|-------|---------|
| `~/Library/LaunchAgents/ai.openclaw.gateway.plist` | Upstream OpenClaw CLI install | Runs `openclaw gateway run` if you installed via `npm install -g openclaw` |
| `~/Library/LaunchAgents/app.remclaw.mac.gateway.plist` | Legacy Rem Mac app builds | Should not exist after launching a patched build; if present, it may contain stale secrets and must be scrubbed |

If a machine still has both files from an older build, both can have `KeepAlive=true`. Disabling only one means the other can keep respawning. Disable both when you need clean state:

```bash
# Disable BOTH and break the respawn loop completely:
launchctl bootout gui/$UID/ai.openclaw.gateway 2>/dev/null
launchctl bootout gui/$UID/app.remclaw.mac.gateway 2>/dev/null
launchctl disable gui/$UID/ai.openclaw.gateway 2>/dev/null
launchctl disable gui/$UID/app.remclaw.mac.gateway 2>/dev/null
mv ~/Library/LaunchAgents/ai.openclaw.gateway.plist \
   ~/Library/LaunchAgents/ai.openclaw.gateway.plist.DISABLED 2>/dev/null
mv ~/Library/LaunchAgents/app.remclaw.mac.gateway.plist \
   ~/Library/LaunchAgents/app.remclaw.mac.gateway.plist.DISABLED 2>/dev/null
pkill -9 -f openclaw
sleep 5
ps aux | grep openclaw | grep -v grep   # should be empty
```

To restore upstream background lifetime only:
```bash
mv ~/Library/LaunchAgents/ai.openclaw.gateway.plist.DISABLED \
   ~/Library/LaunchAgents/ai.openclaw.gateway.plist
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/ai.openclaw.gateway.plist
# DON'T restore app.remclaw.mac.gateway.plist — patched Rem builds do not use it.
```

## "remote bin probe timed out" — node session broken

Symptom (in `~/.openclaw/logs/gateway.err.log`):
```
[skills-remote] remote bin probe timed out (Sam's Mac mini (...)); check node connectivity
```

Repeats every 2-5 minutes. Means the **node session** from the Mac app to the gateway isn't responding to skill bin-probe RPCs even though pairing is valid.

Diagnostic: in the Mac app, look at `SharedGatewayUnavailablePanel`'s mini status — if it says `node: failed` while `operator: connected`, this is the bug.

Fix path (TBD, tracked in #361):
1. Verify node-token has correct scopes via `openclaw devices list`
2. Quit Mac app, kill all gateways, restart cleanly
3. If node session still fails, it's a code bug in `MacGatewayClient` / `NodeInvocationRouter`

## "Unreachable: Connect failed: device signature invalid"

Existing pairing has signature drift — usually after gateway restart that rotated keys.

Fix:
```bash
# Find pending request:
~/.openclaw/bin/openclaw devices list

# Approve the new pending request:
~/.openclaw/bin/openclaw devices approve <request-id>
```

If no pending request appears, the Mac app isn't even getting to the pairing handshake — check for legacy duplicate LaunchAgents above, then inspect gateway logs.

## CLI not on PATH (per-machine, since #292/PR #343)

PR #343 added the PATH export to `~/.zshrc` on CLI install — but only for NEW installs. Existing installs need either:

```bash
# Use full path:
~/.openclaw/bin/openclaw <command>

# OR add to PATH manually:
echo 'export PATH="$HOME/.openclaw/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## "device.pair.list" shows orphan operator entries

Sometimes you'll see a device with `clientId: "cli"` and just a hash for a name (e.g. `02d12...f088267e8a5a72e06`). These are orphan operator-only entries from CLI dance recoveries (see CLI-approve scenarios above).

Harmless but ugly. Remove with:
```bash
~/.openclaw/bin/openclaw devices remove <full-device-id>
```

## Half-connected state: operator works, node fails

Symptom in app: chat shows "Timed out waiting for a reply" but `Sessions` tab loads sessions fine.

Means operator session is up (sessions list works) but node session can't respond to tool calls. Either:
- Node-side scopes mismatch — re-pair via "Reset Pairing" button
- Chronic node-session bug (#361 / open in `gateway.err.log` as "remote bin probe timed out")
- Two gateways racing on port 18789 (see "Legacy duplicate LaunchAgents" above)

## "Timed out waiting for a reply" with operator + node both connected

Lifecycle events fire but no `stream=text` events follow. Means the model provider (MiniMax by default) is hung or rate-limited. Switch:

```bash
~/.openclaw/bin/openclaw models list
~/.openclaw/bin/openclaw models set <provider>   # e.g. anthropic, openai
~/.openclaw/bin/openclaw gateway restart
```

## When in doubt — pivot to cloud

User has 1+ cloud Fly gateways. If local Mac gateway is being painful:
1. Mac app → Settings → Gateway list
2. Tap a working cloud gateway (e.g. `remclaw-XXXXXXXX.fly.dev`)
3. Connect

Cloud gateway has:
- No local-LaunchAgent issues
- No port conflicts with other Mac processes
- Different bind config (always public)
- Same UI surfaces — full demo capability

## Files referenced

- `~/Library/LaunchAgents/ai.openclaw.gateway.plist` (upstream)
- `~/Library/LaunchAgents/app.remclaw.mac.gateway.plist` (legacy Rem Mac app builds only; scrubbed by patched app)
- `~/.openclaw/openclaw.json` (gateway config)
- `~/.openclaw/logs/gateway.log` + `gateway.err.log`
- `~/.openclaw/agents/main/sessions/*.jsonl` (per-run agent traces)
- `~/.openclaw/devices/paired.json` (gateway-side paired device table)

## Related issues

- #361 — dogfooding feedback master tracker
- #383 — security: plaintext secrets in LaunchAgent plist
- #384 — Mac app silently installs hidden LaunchAgent
- #293 / #350 — Mac gateway lifecycle
- #346 — local-gateway approval recovery
