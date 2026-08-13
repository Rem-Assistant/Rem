-- 039_create_channel_signals.sql
--
-- Connected-source SIGNALS for suggested tasks (WS2, doc 38 §4 — tier-2).
--
-- A "signal" is an external event from a source the user connected (Gmail, WhatsApp, Discord, …)
-- that MIGHT imply work. The deriver turns each into an attributed suggestion ("Reply to Ada —
-- Gmail, 2h ago"); the user accepts (→ a real task) or dismisses (durable, via
-- suggestion_dismissals, keyed "gmail:<signalId>").
--
-- This table is the SEAM between the two workstreams (doc 38 §4): WS1's gateway `message_received`
-- hook INGESTS rows here (POST /api/v1/suggestions/signals); WS2 (this lane) CONSUMES them in the
-- deriver. Building the consumer against a seeded row proves the path end-to-end before WS1 lands
-- the real inbound hook — WS2 does not build the hook.

CREATE TABLE IF NOT EXISTS channel_signals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- The connected source: 'gmail' | 'whatsapp' | 'discord' | …. Opaque to this table.
  source TEXT NOT NULL,
  -- Stable per-source reference (the message id, thread id, …) — makes ingest idempotent AND is
  -- the durable identity behind the dismissal key "<source>:<id>". NOT the display attribution.
  source_ref TEXT NOT NULL,
  -- Who/what it's from, for the attribution line ("Ada", "Ada Lovelace <ada@…>"). Display text.
  sender TEXT,
  -- The human text the deriver reasons over / shows ("Ada asked if you're free Friday").
  summary TEXT NOT NULL,
  -- Optional precomputed task title. When null the deriver falls back to "Reply to <sender>".
  suggested_title TEXT,
  -- When the underlying event happened (drives the "· 2h ago" age). Defaults to ingest time.
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- One signal per (user, source, source_ref): re-ingesting the same message is an idempotent
  -- no-op (ON CONFLICT), and this composite serves the deriver's per-user read via its lead column.
  UNIQUE (user_id, source, source_ref)
);
