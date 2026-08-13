-- Recover how many times each task has ALREADY been asked about, from the brief history.
--
-- WHY THIS EXISTS
-- ---------------
-- Migration 116 added `brief_surface_count` so a task can go stale after being raised
-- BRIEF_STALE_THRESHOLD (3) times without the user acting. It starts every task at 0, which means
-- a user who has been nagged about the same task for a month still has to sit through three MORE
-- briefs before it stops. The founder's actual words: "the same three tasks that I never closed
-- when I expected the agent to be smart enough to drop it."
--
-- That history is not lost — it is sitting in `daily_brief_artifacts.markdown`. Measured on
-- staging before writing this, against one real account. The titles below are synthetic stand-ins
-- of the same shape as what we measured; the COUNTS are the real result:
--
--   Check emails and update on latest recruiter opportunities   13 briefs
--   Catch up with family members                                13
--   Attend community event                                      13
--   File visa paperwork                                         13
--   Jordan Reyes' birthday                                       0
--
-- Exactly the four tasks they complained about, and the one they did not. So this is a RECOVERY of
-- a fact the schema failed to record, not an invented number.
--
-- MATCHING IS DELIBERATELY CONSERVATIVE
-- -------------------------------------
-- Substring matching a task title against brief prose can false-positive on short or generic
-- titles ("Call", "Email"). Guards, all of which must hold:
--   * title at least 12 characters — long enough to be distinctive in prose
--   * only OPEN tasks (pending/in_progress) — a finished task's count is irrelevant
--   * only tasks created before this migration — new tasks must earn their count honestly
--   * the count is CAPPED at the threshold, so a backfill can never push a task further past
--     "stale" than a real surfacing would, and can never look like more evidence than it is
--
-- A task that is skipped here simply starts at 0 and behaves exactly as 116 intended. Under-
-- counting is safe; over-counting nags-by-omission, which is the bug we are fixing.
--
-- STALENESS IS STAMPED HERE, NOT DERIVED
-- --------------------------------------
-- 116 stamps `stale_at` at the moment the counter crosses the threshold rather than computing
-- `count >= threshold` at read time. So the backfill has to stamp it too, or these tasks would
-- carry a qualifying count and never actually be treated as stale.
--
-- REVERSIBLE. To undo entirely:
--   UPDATE tasks SET brief_surface_count = 0, brief_last_surfaced_at = NULL, stale_at = NULL
--    WHERE stale_at IS NOT NULL AND brief_last_surfaced_at IS NULL;
-- (`brief_last_surfaced_at` is intentionally left NULL by this migration — see below — so that
-- predicate isolates exactly the rows written here.)

BEGIN;

WITH surfacing_counts AS (
  SELECT
    t.id AS task_id,
    COUNT(a.id) AS times_surfaced
  FROM tasks t
  JOIN daily_brief_artifacts a
    ON a.user_id = t.user_id
   AND a.markdown IS NOT NULL
   AND a.markdown ILIKE '%' || t.title || '%'
  WHERE t.status IN ('pending', 'in_progress')
    AND length(btrim(t.title)) >= 12
    AND t.created_at < NOW()
  GROUP BY t.id
)
UPDATE tasks t
   SET brief_surface_count = LEAST(sc.times_surfaced, 3),
       -- `brief_last_surfaced_at` stays NULL on purpose. We know these briefs happened but not
       -- which one was last for THIS task, and inventing a timestamp would make a reconstructed
       -- fact indistinguishable from an observed one. It also gives the revert above an exact
       -- predicate for the rows this migration touched.
       stale_at = CASE
                    WHEN sc.times_surfaced >= 3 THEN COALESCE(t.stale_at, NOW())
                    ELSE t.stale_at
                  END
  FROM surfacing_counts sc
 WHERE t.id = sc.task_id
   AND t.brief_surface_count = 0
   AND t.stale_at IS NULL;

COMMIT;
