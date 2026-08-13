-- One authored headline per Daily Brief artifact.
--
-- WHY A COLUMN AND NOT A RENDER-TIME PARSE: two surfaces show a title for the same brief — the
-- Agenda summary card and the orchestrator chat. Before this migration the card synthesized a
-- clock-based greeting ("Good morning") while the chat showed whatever heading the authoring turn
-- happened to put on line 1 ("The Day"). Two derivations, two strings, one artifact. The headline
-- is now part of the authored contract next to `summary`, written once by the artifact lease
-- holder, so every surface renders the same value and none of them re-derives it.
--
-- BACKFILL: artifacts authored before this migration have no headline field, but many already
-- open with an ATX heading. Lift that heading — and ONLY that heading — into the column, using the
-- same rule `extractBriefHeadline()` applies in brief-authoring.service.ts (first non-blank line,
-- 1-3 leading `#`, emphasis markers stripped). A brief whose first line is prose backfills to NULL
-- on purpose: clients keep their existing per-surface fallback, so no artifact renders worse than
-- it did before this migration.
ALTER TABLE daily_brief_artifacts
    ADD COLUMN IF NOT EXISTS headline VARCHAR(120);

UPDATE daily_brief_artifacts
   SET headline = NULLIF(
         BTRIM(
           LEFT(
             REGEXP_REPLACE(
               SUBSTRING(BTRIM(markdown) FROM '^#{1,3}[ \t]+([^\n\r]+)'),
               '[*_`#]', '', 'g'
             ),
             120
           )
         ),
         ''
       )
 WHERE headline IS NULL
   AND markdown IS NOT NULL
   AND BTRIM(markdown) ~ '^#{1,3}[ \t]+';
