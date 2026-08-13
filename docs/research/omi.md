# OMI (BasedHardware/omi) — research note

**Source:** https://github.com/BasedHardware/omi — open-source personal AI memory product. Wearable-first.

## What it is

A "remembers everything" personal AI: continuously captures audio (and on Mac, screen) via wearable hardware (necklace, glasses) or desktop apps. Real-time transcription, summarization, AI chat with full memory of captured content. MIT-licensed.

## Stack at a glance

- **macOS app**: Swift + SwiftUI frontend, **Rust backend embedded in-process**, BLE for wearable pairing
- **Backend (cloud)**: Python / FastAPI, Firebase Firestore, Redis, Deepgram (STT), GPU-based VAD + speaker diarization
- **Mobile**: Flutter (cross-platform iOS + Android)
- **Firmware**: ESP32-S3 for the Glass

## Borrowable patterns for Rem

| Pattern | Where it fits | Borrowable? |
|---|---|---|
| Embedded Rust backend in Mac app for fast local processing | Local inference path (transcription, summarization) without round-tripping to gateway | **Maybe later** — when local-only inference becomes a perf goal |
| BLE pairing UX | Different transport than ours (we use Bonjour LAN), but similar UX flow | **Worth a code-read** when implementing #306 |
| Continuous-capture model (screen + audio) | Different paradigm from Rem's request-response | **Not a direct port** — but raises the question: should Rem have an ambient-context mode? |
| Memory-first chat | Rem chat is roughly stateless per-session; OMI persists everything | **Mostly orthogonal** — but session history persistence is a gap we glossed over |

## Strategic positioning vs Rem

- **OMI** = memory ("remember things for me")
- **Rem** = action ("do things on my behalf")

Complementary products, not competitors. Worth knowing, not worth pivoting toward.

## What we'd actually steal

If/when we pull anything from OMI, the highest-leverage targets are:
1. **Their Mac app's chat UI implementation** — they ship a working Mac SwiftUI chat. When we work on #305 (Mac chat parity), 30 minutes reading their layout patterns may save us hours of guessing.
2. **Their pairing flow code** — BLE not Bonjour, but the state machine for pair/approve/recover is the same shape.
3. **Their Rust-in-Swift integration** — if we ever embed local inference, this is a reference for how the FFI layer is structured.

## Status

Research note only — no roadmap issue filed. Per 2026-04-20 strategy decision.
