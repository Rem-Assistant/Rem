-- 118_add_signal_relevance.sql
--
-- RELEVANCE VERDICTS on connected-source signals.
--
-- WHY. Every `channel_signals` row became a suggestion. Nothing judged whether it deserved to be
-- one, and `suggestions.service.ts` titled it with a string template (`'Reply to ' || sender`).
-- The first live suggestion the founder saw was "Reply to Deploybot <alerts@example-ci.test>" for
-- a deployment-crash alert. Nobody replies to a robot, and the real action ("look at the rem-canary
-- deploy") is not a reply at all.
--
-- WHERE THE JUDGMENT LIVES: AT INGEST, recorded here. See the header of
-- `signal-relevance.service.ts` for the full argument. The short version is that the alternative —
-- judging inside `deriveSuggestions` — puts a model call on a user-facing GET that runs on every
-- agenda refresh, and re-judges the same unchanged rows forever. Judging at ingest is one batched
-- call per cron tick over only the rows that are actually unjudged.
--
-- The usual objection to ingest-time judgment is that the policy can no longer change without a
-- backfill. `relevance_policy` removes that objection: bumping the policy version in code makes
-- every row's stored verdict stale by definition, and the next tick re-judges it. The backfill is
-- automatic and incremental rather than a manual migration.
--
-- FAIL-OPEN IS THE POINT. Every column here is NULLABLE and NULL means "not judged". The deriver
-- suppresses a row only on an explicit 'drop'. A model outage, a timeout, a malformed completion,
-- or a brand-new row that no tick has reached yet therefore SURFACES, unjudged. Losing a real
-- signal is worse than showing a mediocre one, and a schema whose default state is "hidden" would
-- silently eat the user's mail the first time the classifier had a bad day.

ALTER TABLE channel_signals
  -- 'act'  — worth doing something about; `relevance_title` names the outcome.
  -- 'drop' — no action a person would take. The ONLY value that hides a row.
  -- NULL   — not judged (yet, or the judgment failed). Surfaces. See FAIL-OPEN above.
  ADD COLUMN IF NOT EXISTS relevance_decision TEXT
    CHECK (relevance_decision IN ('act', 'drop')),

  -- The nameable OUTCOME (doc 19 taxonomy): "Reply to the recruiter about the Staff role", never
  -- the raw event and never a bare template. Only meaningful when decision = 'act'.
  ADD COLUMN IF NOT EXISTS relevance_title TEXT,

  -- Policy identity the verdict was produced under. A row whose stored policy differs from the
  -- code's current policy counts as UNJUDGED and is re-judged on the next tick.
  ADD COLUMN IF NOT EXISTS relevance_policy TEXT,

  -- Observability only. Never used to decide anything — a stale verdict is invalidated by
  -- `relevance_policy` or by a content change, not by age.
  ADD COLUMN IF NOT EXISTS relevance_judged_at TIMESTAMPTZ;

-- The judge's work queue: unjudged rows for one user, newest first.
--
-- Partial on `relevance_decision IS NULL` because that is the only set the judge reads and it is
-- the small tail of the table in the steady state (the poller re-reads a rolling 24h window every
-- 15 minutes, so almost every row it sees is already judged). A full index would be mostly dead
-- weight. Rows stale by POLICY are not in this index; they are a rare, deliberate, operator-driven
-- event (a policy bump), and eating one sequential scan per user then is the right trade against
-- carrying a wider index on every write forever.
CREATE INDEX IF NOT EXISTS idx_channel_signals_unjudged
  ON channel_signals (user_id, received_at DESC)
  WHERE relevance_decision IS NULL;
