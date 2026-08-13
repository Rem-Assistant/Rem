-- 122 — the judge's RECOMMENDED TIME for a signal-derived task.
--
-- A task's `start_date` IS its timeblock (there is no separate block entity). Migration 118 gave
-- the relevance judge somewhere to record WHAT to do about a signal (`relevance_title`); this
-- gives it somewhere to record WHEN. Accepting the suggestion then creates the task already
-- scheduled instead of untimed.
--
-- Nullable, and null is the ordinary case: a judge that cannot justify a specific time omits it,
-- and the reader falls back to the pre-existing "later today" behaviour. See
-- `services/suggested-time.ts` for the plausibility rule this column's values must satisfy — the
-- rule is enforced in TypeScript on both write and read rather than as a CHECK, because two of its
-- four clauses ("still in the future", "inside the horizon") are relative to the reading instant
-- and cannot be expressed as a row constraint.
--
-- No index: this column is only ever read alongside the row it sits on, by the same
-- `deriveSuggestions` query that already filters on (user_id, relevance_decision).
ALTER TABLE channel_signals
  ADD COLUMN IF NOT EXISTS relevance_start_at TIMESTAMPTZ;

COMMENT ON COLUMN channel_signals.relevance_start_at IS
  'Judge-recommended start for the task this signal implies. NULL = no recommendation; the '
  'reader falls back to "later today". Cleared with the other relevance_* columns when the '
  'signal''s content changes, because a time decided about different text is not about this one.';
