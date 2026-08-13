-- 038_create_suggestion_dismissals.sql
--
-- Durable dismissals for suggested tasks (WS2, doc 38 §4/§6).
--
-- Suggestions themselves are DERIVED on the fly from signals we already have (overdue tasks,
-- calendar events, …) — they are never stored. A dismissal, by contrast, MUST be durable: a
-- suggestion the user waved away must never come back, or the feature is a nag (doc 38 §6). We
-- persist only the dismissal, keyed by the stable `suggestion_key` the deriver emits
-- (e.g. "cal:<eventId>", "overdue:<taskId>"). GET /suggestions filters these out.

CREATE TABLE IF NOT EXISTS suggestion_dismissals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- Stable identity of the dismissed suggestion, produced by the deriver from its source
  -- signal (source-prefixed, e.g. "cal:<eventId>" / "overdue:<taskId>"). Opaque to this table.
  suggestion_key TEXT NOT NULL,
  dismissed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- One dismissal per (user, suggestion). Re-dismissing is an idempotent no-op (ON CONFLICT).
  -- This composite UNIQUE also serves the only read pattern — the deriver's NOT-IN subquery
  -- filtering on user_id — via its leading column, so no separate (user_id) index is needed.
  UNIQUE (user_id, suggestion_key)
);
