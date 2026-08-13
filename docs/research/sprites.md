# Sprites (sprites.dev) — research note

**Source:** https://docs.sprites.dev — pitched to us by Fly.io.

## What it is

Hardware-isolated, persistent Linux microVMs built for agentic workloads. A Fly product. Designed to replace the usual "spin up a container per task" pattern for AI agents that need state between runs.

## Concrete capabilities

- **Per-workload microVM** with hardware isolation (not container-level)
- **Persistent ext4 filesystem** — survives between runs; backed up to durable object storage when idle
- **Memory persistence + checkpoints** — wakes from hibernation rather than cold-starting
- **Instant resume** when a request hits an idle Sprite
- **Per-Sprite HTTP URL** for service exposure
- **Full Linux** — install any tools (`apt`, `npm`, custom binaries)
- **Per-second billing while running, free when idle**

## What it does NOT include

- **No browser / GUI by default.** You can `apt install chromium` since it's full Linux, but it isn't a "give your AI a browser" product like Browserbase / Anchor.dev.
- **No display server** out of the box.
- **No Apple ecosystem** anything (obvious — it's Linux).

## Relevance to Rem

Sprites is a potential **runtime replacement for our Fly Machines deployment of cloud gateways**. Same shape (Linux box per user), different economics + DX:

| Concern | Today (Fly Machines) | Sprites |
|---|---|---|
| Cost when idle | Pay per machine-hour | Free |
| Cold start | ~30s (per-app deploy time) | Instant resume |
| State between sessions | Need volume mount | Native ext4 persistence |
| Skill cache, model warmth | Lost on restart | Survives |
| Browser for screen tasks | Same gap as Sprites | Same gap |

The win for Rem's "1 gateway per user" model is the idle-free pricing — most users sit idle most of the time.

The browser/screen gap is **not** solved by Sprites. Cloud-only computer-use still requires either (a) the Mac path, (b) installing a headless browser into the Sprite (DIY), or (c) a browser-as-a-service (Browserbase / Anchor / similar).

## When this becomes actionable

Don't migrate prematurely. Triggers that would justify evaluation:
- Cloud gateway hosting bill becomes meaningful
- Cold-start latency on first-deploy becomes a UX issue
- Multi-region or persistence demands grow

Until then: keep using Fly Machines, file as research-only.

## Status

Research note only — no roadmap issue filed. Per 2026-04-20 strategy decision.
