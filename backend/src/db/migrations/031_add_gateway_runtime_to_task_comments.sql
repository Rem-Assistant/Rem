-- Add 'gateway' to the set of runtimes a task comment may be attributed to.
--
-- Background: the orchestrator sweep (#922) runs a ready task AUTONOMOUSLY through the
-- user's own OpenClaw GATEWAY (Move-2 / gateway-agent.service.ts) — a distinct runtime
-- from the GMI AgentBox path ('agentbox') and the on-device runtimes ('local_mac' /
-- 'local_ios'). Its Activity comment must record WHICH runtime acted, so it stamps
-- runtime = 'gateway'.
--
-- Migration 015 created the CHECK constraint inline on the column with the system name
-- `task_comments_runtime_check`, allowing only ('agentbox', 'local_mac', 'local_ios').
-- Without this widening, the sweep's INSERT throws a constraint violation AFTER the task
-- status was already applied — a silent status mutation with no comment and no Undo
-- record. We drop and re-add the constraint widened. Idempotent + additive: safe to
-- re-run. Mirrors migration 021's drop/re-add-widened pattern for proposed_status.

ALTER TABLE task_comments
    DROP CONSTRAINT IF EXISTS task_comments_runtime_check;

ALTER TABLE task_comments
    ADD CONSTRAINT task_comments_runtime_check
    CHECK (
        runtime IS NULL
        OR runtime IN ('agentbox', 'local_mac', 'local_ios', 'gateway')
    );
