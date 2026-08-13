import '../crypto-polyfill.js'; // MUST be first — installs globalThis.crypto before the Composio SDK loads
/**
 * Daily check-ins — the founder's simplified routines. At each enabled global check-in
 * time (morning / midday / night, per user, in the user's own timezone) this script
 * builds the user's Daily Brief over ALL their tasks (brief.service.gatherBrief) and,
 * only after the canonical artifact is visibly delivered to Today, fires ONE push
 * (push.service.sendPush) that opens and reads that exact conversation. There are no
 * per-task schedules and no per-routine prompts — agent instructions live on the tasks
 * and connectors are global; the only schedule is the three `user_checkins` rows.
 *
 * Schedule (Railway cron): run every 15 minutes — cron expression
 * "(slash)15 * * * *" (slash = the literal "/"), i.e. at :00/:15/:30/:45 — running
 * `npm run checkins:run` each tick. A 15-minute cadence is safe because due-ness is
 * idempotent per local day: isDailyRoutineDue only fires once per local date (it checks
 * last_run_at's local Y-M-D), so re-running within the same hour never double-sends a
 * check-in. The interval just bounds how soon after the delivery hour a check-in fires.
 *
 * Mirrors src/scripts/run-routines.ts (due-filter + per-user isolation) and
 * src/scripts/run-digests.ts (per-user never-throw batch). This is an artifact-first
 * notification: a gateway/cache failure cannot announce a brief that the user cannot open.
 *
 * A slot that fails is deliberately left un-stamped so the next tick retries, bounded by a durable
 * per-local-day attempt counter (migration 115) rather than by the clock — see
 * CHECKIN_MAX_DELIVERY_ATTEMPTS.
 *
 * See migrations 027 / 115 (user_checkins) and checkin.service.ts.
 */

import { fileURLToPath } from 'node:url';
import type { PoolClient } from 'pg';
import '../config/env.js';
import { pool } from '../db/pool.js';
import {
  listEnabledCheckins,
  recordCheckinAttempt,
  stampCheckinRun,
  type CheckinSetting,
  type CheckinSettingWithUser,
  type CheckinSlot,
} from '../services/checkin.service.js';
import { isDailyRoutineDue, localParts } from '../services/routine-schedule.js';
import { gatherBrief, type DailyBrief } from '../services/brief.service.js';
import { collectGmailBriefInput, type BriefInputSnapshot } from '../services/brief-input.service.js';
import {
  composioActiveAccountSource,
  composioGmailBriefAdapter,
} from '../services/composio.service.js';
import {
  authorBriefForUser,
  briefSlotRank,
  conversationSessionKey,
  isBriefAuthoringEnabled,
  isPermanentGatewaySkip,
  localBriefDate,
  readAuthoredBriefDelivery,
  type AuthoredBriefDelivery,
  type BriefAuthoringResult,
  type TimeOfDay,
} from '../services/brief-authoring.service.js';
import {
  isRetryablePushResult,
  sendPush,
  type PushPayload,
  type PushSendResult,
} from '../services/push.service.js';

/** Deep link the push opens — the app fetches, anchors, and reads the newest Today artifact. */
export const CHECKIN_DEEP_LINK = 'remclaw://brief/listen';
export const CHECKIN_NOTIFICATION_THREAD = 'rem-daily-brief';
export const CHECKIN_AUTHORING_SLOTS: Record<CheckinSlot, TimeOfDay> = {
  morning: 'morning',
  midday: 'afternoon',
  night: 'evening',
};

/**
 * Is a check-in due now, in the user's timezone? Reuses the routines resolver: due once
 * the local delivery hour is reached and it has not already run this local day (the
 * last_run_at idempotency stamp). Pure — pass `now`/`lastRunAt` for deterministic tests.
 */
export function isCheckinDue(
  checkin: CheckinSetting,
  now: Date,
  lastRunAt: Date | null,
): boolean {
  if (!checkin.enabled) return false;
  return isDailyRoutineDue(
    {
      deliveryHour: checkin.deliveryHour,
      deliveryMinute: checkin.deliveryMinute,
      timezone: checkin.timezone,
      enabled: checkin.enabled,
    },
    now,
    lastRunAt,
  );
}

/**
 * How many delivery ATTEMPTS one slot gets in a local day before it is consumed.
 *
 * Several delivery outcomes deliberately do NOT stamp `last_run_at`, so the slot stays due and the
 * next cron tick retries (see `deliverCheckin`). That is right for a *transient* failure and wrong
 * for a persistent one: with a 15-minute cron and no bound, a slot that can never succeed retries
 * for the rest of the local day, and every retry re-runs `authorBriefForUser` — a fresh brief
 * authored every 15 minutes, burning model quota and re-notifying whenever a push finally lands.
 *
 * That is #1279, observed live on staging: a midday slot enabled at 14:52 was still reported
 * "1 due now" at 15:30 and 15:45 with `last_run_at` NULL, while other accounts' slots stamped
 * normally the same day.
 *
 * 5 attempts ≈ the 60 minutes the first fix (#1284) aimed at, at the 15-minute cron cadence, but
 * measured in tries rather than on the clock. The distinction is not cosmetic: a wall-clock bound
 * asks "how late is it?", and the honest answer to "has this slot already been tried today?" was
 * simply not in the data — `last_run_at` is NULL both for never-attempted and for attempted-and-
 * failed, because failing is exactly what does not stamp. So any clock proxy spends the budget
 * before attempt #1 whenever the first attempt happens late (cron outage, redeploy gap, a slot
 * enabled hours after its own delivery time). The counter cannot: it advances only when an attempt
 * actually happens. Persisted per local day in `user_checkins.attempt_count` / `attempt_day`
 * (migration 115) so it survives restarts, redeploys and concurrent workers — none of which an
 * in-process counter would.
 */
export const CHECKIN_MAX_DELIVERY_ATTEMPTS = 5;

/**
 * What actually happened to one slot this tick.
 *
 * `outcome` exists because the previous summary line counted every non-throwing return as
 * `delivered`, so a slot that delivered nothing, stamped nothing, and would retry forever logged
 * `delivered=1 failed=0` — indistinguishable from success. That misreporting is a large part of why
 * #1279 went unnoticed; the counter has to distinguish "consumed" from "will run again".
 */
export type CheckinOutcome = 'stamped' | 'retrying' | 'gave_up' | 'not_due';

export interface CheckinDeliveryResult {
  pushed: number;
  artifactDelivered: boolean;
  outcome: CheckinOutcome;
}

/**
 * Minutes elapsed since this slot's scheduled local time today. Negative before the slot is due.
 * Pure; uses the same local-parts resolver as the due-check so both agree on "today".
 *
 * NOT part of the retry decision any more (that is `CHECKIN_MAX_DELIVERY_ATTEMPTS`) — it is
 * lateness *context* on the give-up line, which is the difference between "failed fast at its own
 * delivery time" and "burned its budget hours later while recovering from an outage". Two very
 * different pages to open at 3am.
 */
export function minutesSinceScheduled(checkin: CheckinSetting, now: Date): number {
  const nowLocal = localParts(now, checkin.timezone);
  const scheduledMinutes = checkin.deliveryHour * 60 + (checkin.deliveryMinute ?? 0);
  return nowLocal.hour * 60 + nowLocal.minute - scheduledMinutes;
}

/**
 * Filter a batch of enabled check-ins down to the ones due now. Exported so the
 * due-filter loop is unit-testable without a database.
 */
export function selectDueCheckins(
  checkins: CheckinSettingWithUser[],
  now: Date,
): CheckinSettingWithUser[] {
  return checkins
    .filter((c) => {
      const lastRunAt = c.lastRunAt ? new Date(c.lastRunAt) : null;
      return isCheckinDue(c, now, lastRunAt);
    })
    // A worker recovering after an outage may see several overdue slots for one account. Process
    // old-to-new so the final canonical pointer and same-collapse-ID alert are always the newest.
    // The database cache upsert independently fences overlapping workers against backward moves.
    .sort((left, right) =>
      briefSlotRank(CHECKIN_AUTHORING_SLOTS[left.slot])
        - briefSlotRank(CHECKIN_AUTHORING_SLOTS[right.slot])
    );
}

/** Human title for each slot's push. */
const SLOT_TITLES: Record<CheckinSlot, string> = {
  morning: 'Your morning brief is ready',
  midday: 'Your midday brief is ready',
  night: 'Your evening brief is ready',
};

/**
 * Build the push from the delivered canonical artifact. Its summary is the same prose authority
 * Agenda and Today use; deterministic bucket copy can disagree while a replacement is landing.
 * `collapseId` + `threadId` make newer briefs replace/group older notifications, while taps always
 * resolve forward to the newest delivered artifact rather than narrating stale payload prose.
 */
export function buildCheckinPush(
  slot: CheckinSlot,
  artifact: AuthoredBriefDelivery,
  briefDate: string,
  accountId: string,
): PushPayload {
  // The lock screen is not an authenticated surface. Tapping resolves the account-bound canonical
  // artifact, so keep notification prose neutral even while account ownership is changing.
  const body = 'Tap to hear what needs your attention.';
  return {
    title: SLOT_TITLES[slot],
    body,
    collapseId: CHECKIN_NOTIFICATION_THREAD,
    threadId: CHECKIN_NOTIFICATION_THREAD,
    data: {
      type: 'daily_brief',
      accountId,
      slot,
      briefDate,
      deepLink: CHECKIN_DEEP_LINK,
    },
  };
}

export function canNotifyForAuthoringResult(
  result: BriefAuthoringResult,
  slot: CheckinSlot,
): boolean {
  return result.status === 'authored'
    || (
      result.status === 'skipped_slot'
      && result.reason === `already_authored_${CHECKIN_AUTHORING_SLOTS[slot]}`
    );
}

export type MonotonicBriefPushResult =
  | { status: 'sent'; results: PushSendResult[] }
  | { status: 'superseded' | 'artifact_unavailable'; results: [] };

/**
 * Serialize the irreversible APNs side effect per account across local days and hold it until the
 * result is classified. The durable slot makes a late older worker fail closed after a newer send;
 * holding the row lock through `send` guarantees that an older accepted alert cannot arrive after
 * a newer one merely because two cron processes overlapped.
 */
export async function sendBriefPushMonotonically(
  userId: string,
  briefDate: string,
  slot: TimeOfDay,
  send: () => Promise<PushSendResult[]>,
  connect: () => Promise<PoolClient> = () => pool.connect(),
): Promise<MonotonicBriefPushResult> {
  const client = await connect();
  let transactionOpen = false;
  try {
    await client.query('BEGIN');
    transactionOpen = true;
    await client.query(
      `INSERT INTO daily_brief_notification_fences (user_id)
       VALUES ($1::uuid)
       ON CONFLICT (user_id) DO NOTHING`,
      [userId],
    );
    const fence = await client.query<{
      latest_brief_date: string | null;
      latest_slot: TimeOfDay | null;
    }>(
      `SELECT latest_brief_date::text, latest_slot
         FROM daily_brief_notification_fences
        WHERE user_id = $1::uuid
        FOR UPDATE`,
      [userId],
    );
    const latestBriefDate = fence.rows[0]?.latest_brief_date ?? null;
    const latestSlot = fence.rows[0]?.latest_slot ?? null;
    if (latestBriefDate && (
      latestBriefDate > briefDate
      || (
        latestBriefDate === briefDate
        && latestSlot !== null
        && briefSlotRank(latestSlot) >= briefSlotRank(slot)
      )
    )) {
      await client.query('COMMIT');
      transactionOpen = false;
      return { status: 'superseded', results: [] };
    }

    // Re-read the canonical pointer after acquiring the notification fence. A worker may have read
    // an older delivered artifact before a newer process won this lock.
    const canonical = await client.query<{ authored_slot: TimeOfDay; delivered: boolean }>(
      `SELECT b.authored_slot,
              EXISTS (
                SELECT 1
                  FROM daily_brief_artifacts a
                  JOIN daily_brief_artifact_deliveries d
                    ON d.artifact_id = a.id
                   AND d.artifact_revision = a.revision
                   AND d.session_key = 'rem-orchestrator'
                   AND d.state = 'delivered'
                 WHERE a.user_id = b.user_id
                   AND a.brief_date = b.brief_date
                   AND a.authored_slot = b.authored_slot
                   AND a.source = 'gateway'
                   AND a.markdown = b.markdown
              ) AS delivered
         FROM daily_briefs b
        WHERE b.user_id = $1::uuid AND b.brief_date = $2::date
          AND b.source = 'gateway'
        LIMIT 1`,
      [userId, briefDate],
    );
    const current = canonical.rows[0];
    if (current && briefSlotRank(current.authored_slot) > briefSlotRank(slot)) {
      await client.query('COMMIT');
      transactionOpen = false;
      return { status: 'superseded', results: [] };
    }
    if (!current || current.authored_slot !== slot || !current.delivered) {
      await client.query('COMMIT');
      transactionOpen = false;
      return { status: 'artifact_unavailable', results: [] };
    }

    const results = await send();
    const acceptedPushCount = results.filter((result) => result.ok).length;
    const hasRetryableDestination = results.some(isRetryablePushResult);
    if (acceptedPushCount > 0 || !hasRetryableDestination) {
      await client.query(
        `UPDATE daily_brief_notification_fences
            SET latest_brief_date = $2::date, latest_slot = $3,
                last_notified_at = NOW(), updated_at = NOW()
          WHERE user_id = $1::uuid`,
        [userId, briefDate, slot],
      );
    }
    await client.query('COMMIT');
    transactionOpen = false;
    return { status: 'sent', results };
  } catch (error) {
    if (transactionOpen) await client.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}

interface CheckinDeliveryDependencies {
  gatherBrief: typeof gatherBrief;
  authorBriefForUser: typeof authorBriefForUser;
  isBriefAuthoringEnabled: typeof isBriefAuthoringEnabled;
  readAuthoredBriefDelivery: typeof readAuthoredBriefDelivery;
  sendPush: typeof sendPush;
  sendBriefPushMonotonically: typeof sendBriefPushMonotonically;
  stampCheckinRun: typeof stampCheckinRun;
  recordCheckinAttempt: typeof recordCheckinAttempt;
  collectBriefInput?: (userId: string, now: Date) => Promise<BriefInputSnapshot>;
}

const defaultDeliveryDependencies: CheckinDeliveryDependencies = {
  gatherBrief,
  authorBriefForUser,
  isBriefAuthoringEnabled,
  readAuthoredBriefDelivery,
  sendPush,
  sendBriefPushMonotonically,
  stampCheckinRun,
  recordCheckinAttempt,
  // One toolkit-generic account source, shared with the signal ingester. The runner asks it for
  // `gmailSignalDescriptor.toolkitSlug`; nothing here pins Gmail by hand any more.
  collectBriefInput: (userId, now) => collectGmailBriefInput(
    userId,
    now,
    composioActiveAccountSource,
    composioGmailBriefAdapter,
  ),
};

/**
 * Deliver one due check-in: build the user's brief, push it, stamp last_run_at. Never
 * throws — a single user's failure is logged and the batch continues (mirrors
 * run-digests.ts per-user isolation). Returns the slot's source-of-truth result.
 */
export async function deliverCheckin(
  checkin: CheckinSettingWithUser,
  now: Date,
  dependencies: CheckinDeliveryDependencies = defaultDeliveryDependencies,
): Promise<CheckinDeliveryResult> {
  // Defense in depth: this function may be called directly in tests/repairs, but connector reads
  // are authorized only by an enabled check-in that is due at this instant.
  const lastRunAt = checkin.lastRunAt ? new Date(checkin.lastRunAt) : null;
  if (!isCheckinDue(checkin, now, lastRunAt)) {
    return { pushed: 0, artifactDelivered: false, outcome: 'not_due' };
  }

  // The user's LOCAL day owns the attempt budget — the same day the brief artifact is keyed on, so
  // a slot at 23:50 that fails does not silently inherit yesterday's spent budget at 00:05.
  const localDay = localBriefDate(now, checkin.timezone);

  /**
   * Consume the slot: stamp it (which also clears the counter) so it stops being due today.
   *
   * `attempts` is the durable count this tick just recorded, so the give-up line reports HOW MANY
   * tries were actually spent — the number the wall-clock version could not produce, and the one an
   * operator needs to tell "failed once, hard" from "burned the whole budget".
   */
  const consume = async (
    branch: string,
    artifactDelivered: boolean,
    attempts: number | null,
  ): Promise<CheckinDeliveryResult> => {
    if (checkin.id) await dependencies.stampCheckinRun(checkin.id, now);
    console.warn(
      `[checkins] slot ${checkin.slot} user ${checkin.userId} GAVE UP on attempt ` +
        `${attempts ?? '?'} of ${CHECKIN_MAX_DELIVERY_ATTEMPTS} ` +
        `(${minutesSinceScheduled(checkin, now)}m past schedule) at branch=${branch}; ` +
        'consumed so it stops re-authoring',
    );
    return { pushed: 0, artifactDelivered, outcome: 'gave_up' };
  };

  /** Record this tick as an attempt against the local day. Null when there is no row to count on. */
  const recordAttempt = async (): Promise<number | null> => (
    // A slot with no row (id null) is not in `user_checkins` at all, so `listEnabledCheckins` can
    // never hand it back and no loop is possible; there is nothing to count and nothing to bound.
    checkin.id ? dependencies.recordCheckinAttempt(checkin.id, localDay) : null
  );

  /**
   * A delivery outcome that is worth retrying on the next tick — UNLESS this slot has already spent
   * its attempt budget for the local day, in which case consume it so the schedule converges
   * (#1279/#1285).
   *
   * Without the bound, a persistent failure re-authors a brand-new brief every 15 minutes for the
   * rest of the local day. Every branch that reaches here is logged, because the pre-fix code
   * returned silently and the runaway had no log line at all — which is precisely why it survived
   * long enough to reach a user's device. The give-up line reports the attempt COUNT, which is the
   * number an operator actually needs and which a wall-clock bound could not produce.
   *
   * The recorded attempt is durable and atomic (see `recordCheckinAttempt`), so the budget is not
   * reset by a cron restart, a redeploy, or a second worker on the same tick.
   */
  const retryOrConsume = async (
    branch: string,
    artifactDelivered = false,
  ): Promise<CheckinDeliveryResult> => {
    const attempts = await recordAttempt();
    if (attempts !== null && attempts >= CHECKIN_MAX_DELIVERY_ATTEMPTS) {
      return consume(branch, artifactDelivered, attempts);
    }
    console.log(
      `[checkins] slot ${checkin.slot} user ${checkin.userId} will retry next tick ` +
        `(attempt ${attempts ?? 'uncounted'}/${CHECKIN_MAX_DELIVERY_ATTEMPTS}, branch=${branch})`,
    );
    return { pushed: 0, artifactDelivered, outcome: 'retrying' };
  };

  // A fleet flag that cannot author must not collect connector data.
  if (!dependencies.isBriefAuthoringEnabled()) {
    if (checkin.id) await dependencies.stampCheckinRun(checkin.id, now);
    return { pushed: 0, artifactDelivered: false, outcome: 'stamped' };
  }

  // Scope the buckets to the user's LOCAL day (the check-in already carries their IANA tz),
  // so an evening check-in's counts describe TODAY, not tomorrow's UTC window.
  const brief = await dependencies.gatherBrief(checkin.userId, now, checkin.timezone);

  const authored = await dependencies.authorBriefForUser(checkin.userId, now, {
    brief,
    collectInput: dependencies.collectBriefInput
      ? () => dependencies.collectBriefInput!(checkin.userId, now)
      : undefined,
    timezone: checkin.timezone,
    requestedSlot: CHECKIN_AUTHORING_SLOTS[checkin.slot],
  });
  if (authored.status === 'skipped_slot' && authored.reason?.startsWith('superseded_by_')) {
    // A newer slot already owns Today. This historical trigger can never become current again, so
    // consume it without a push instead of retrying forever or replacing the newer notification.
    if (checkin.id) await dependencies.stampCheckinRun(checkin.id, now);
    return { pushed: 0, artifactDelivered: false, outcome: 'stamped' };
  }
  // An empty snapshot is a successful no-op for this scheduled slot, not a transient delivery
  // failure. Consume it so work that appears hours later does not produce a stale morning brief.
  if (authored.status === 'empty') {
    if (checkin.id) await dependencies.stampCheckinRun(checkin.id, now);
    return { pushed: 0, artifactDelivered: false, outcome: 'stamped' };
  }
  if (!canNotifyForAuthoringResult(authored, checkin.slot)) {
    // EVERY not-notifiable outcome keeps its attempts, including `no_gateway`.
    //
    // An earlier revision short-circuited `no_gateway` as permanent, on the reasoning that it is
    // "provably unchanged by waiting". That premise is false for the case Codex raised on #1292:
    // a user whose gateway is still being PROVISIONED when their first check-in fires reports
    // `no_gateway`, and consuming the slot loses their first-ever brief silently. Provisioning
    // takes ~30-100s (or <30s from the warm pool); the attempt budget covers it comfortably.
    //
    // The cost of retrying is also smaller than that revision assumed: `skipped_gateway` means
    // authoring was SKIPPED, so a retry is a cheap no-op, not "five authoring runs".
    //
    // With no reason short-circuiting, the budget is the single bound. That is the correctness
    // property #1285 exists for; a per-reason denylist was a second classifier that could only
    // ever delete recovery paths. `isPermanentGatewaySkip` is left in place for callers that
    // want the distinction for logging, but it no longer decides whether a slot is consumed.
    return retryOrConsume(`authoring_not_notifiable:${authored.status}`);
  }

  const briefDate = localBriefDate(now, checkin.timezone);
  const sessionKey = conversationSessionKey(now, checkin.timezone);
  const artifact = await dependencies.readAuthoredBriefDelivery(
    checkin.userId,
    briefDate,
    sessionKey,
  );
  if (!artifact?.delivered) {
    return retryOrConsume('artifact_not_delivered');
  }

  const expectedAuthoredSlot = CHECKIN_AUTHORING_SLOTS[checkin.slot];
  if (artifact.authoredSlot !== expectedAuthoredSlot) {
    // The canonical pointer has advanced to a different slot while this older trigger was
    // retrying (for example, morning APNs failed and the afternoon brief has since landed).
    // Consume the superseded trigger without sending stale prose under the wrong slot title.
    if (checkin.id) await dependencies.stampCheckinRun(checkin.id, now);
    return { pushed: 0, artifactDelivered: false, outcome: 'stamped' };
  }

  const payload = buildCheckinPush(checkin.slot, artifact, briefDate, checkin.userId);
  const notification = await dependencies.sendBriefPushMonotonically(
    checkin.userId,
    briefDate,
    expectedAuthoredSlot,
    () => dependencies.sendPush(checkin.userId, payload),
  );
  if (notification.status === 'superseded') {
    if (checkin.id) await dependencies.stampCheckinRun(checkin.id, now);
    return { pushed: 0, artifactDelivered: false, outcome: 'stamped' };
  }
  if (notification.status === 'artifact_unavailable') {
    return retryOrConsume('artifact_unavailable');
  }
  const results = notification.results;
  const acceptedPushCount = results.filter((result) => result.ok).length;
  const hasRetryableDestination = results.some(isRetryablePushResult);
  // An empty result or an all-terminal result means there is no destination worth retrying.
  // Preserve the schedule only when at least one transport/throttle/server failure may recover;
  // the push service removes token-specific terminal rows from the registry independently.
  if (acceptedPushCount === 0 && hasRetryableDestination) {
    // The artifact IS durably delivered here — only the push failed. Retrying re-authors a whole
    // new brief, which is why this branch must be bounded rather than left open-ended (#1279).
    return retryOrConsume('push_not_accepted', true);
  }
  if (checkin.id) await dependencies.stampCheckinRun(checkin.id, now);
  return {
    pushed: acceptedPushCount,
    artifactDelivered: true,
    outcome: 'stamped',
  };
}

async function main() {
  const now = new Date();
  console.log(`[checkins] starting at ${now.toISOString()}`);

  const enabled = await listEnabledCheckins();
  const due = selectDueCheckins(enabled, now);
  console.log(`[checkins] ${enabled.length} enabled, ${due.length} due now`);

  let ok = 0;
  let failed = 0;
  let pushed = 0;

  // Counted separately on purpose. The old line reported every non-throwing return as `delivered`,
  // so a slot stuck in the retry-forever loop of #1279 logged `delivered=1 failed=0` and looked
  // like success. `retrying` is the number that matters operationally: if it stays non-zero across
  // consecutive ticks, something is not converging.
  let stamped = 0;
  let retrying = 0;
  let gaveUp = 0;
  let artifacts = 0;

  for (const checkin of due) {
    try {
      const result = await deliverCheckin(checkin, now);
      pushed += result.pushed;
      if (result.artifactDelivered) artifacts++;
      if (result.outcome === 'stamped') stamped++;
      else if (result.outcome === 'retrying') retrying++;
      else if (result.outcome === 'gave_up') gaveUp++;
      ok++;
    } catch (err) {
      failed++;
      console.error(
        `[checkins] user ${checkin.userId} slot ${checkin.slot} failed:`,
        (err as Error).message,
      );
      // A THROW is the fifth non-stamping exit, and the most expensive one: it happens AFTER
      // authoring, so an un-bounded throwing slot re-authors a brand-new brief every 15 minutes —
      // the exact #1279 symptom, through a path the in-function bound never sees (a statement
      // timeout in readAuthoredBriefDelivery, or pool exhaustion in sendBriefPushMonotonically,
      // which rethrows by design). Bound it with the SAME durable counter: a throw is an attempt.
      //
      // A throw raised by `stampCheckinRun` inside `deliverCheckin` is the one path that records
      // two attempts for one tick. That only happens on a branch that had already decided to
      // consume the slot and failed to, so counting it twice can only make the bound converge
      // sooner — the safe direction.
      try {
        const attempts = checkin.id
          ? await recordCheckinAttempt(checkin.id, localBriefDate(now, checkin.timezone))
          : null;
        if (attempts !== null && attempts >= CHECKIN_MAX_DELIVERY_ATTEMPTS) {
          if (checkin.id) await stampCheckinRun(checkin.id, now);
          gaveUp++;
          console.warn(
            `[checkins] slot ${checkin.slot} user ${checkin.userId} GAVE UP after ${attempts} ` +
              `attempt(s) (limit ${CHECKIN_MAX_DELIVERY_ATTEMPTS}) ending in a throw; ` +
              'consumed so it stops re-authoring',
          );
        }
      } catch (stampErr) {
        // If even the counter/stamp write fails the row genuinely cannot be updated right now;
        // retrying is then correct, and the next tick re-attempts the same bookkeeping.
        console.error(
          `[checkins] user ${checkin.userId} slot ${checkin.slot} give-up bookkeeping failed:`,
          (stampErr as Error).message,
        );
      }
    }
  }

  console.log(
    `[checkins] done — processed=${ok} consumed=${stamped} retrying=${retrying} ` +
      `gaveUp=${gaveUp} artifactsDelivered=${artifacts} pushedDevices=${pushed} failed=${failed}`,
  );
  process.exit(failed > 0 && ok === 0 ? 1 : 0);
}

// Only run the batch when invoked directly (`tsx daily-checkins.ts`). Importing this
// module in tests pulls in the pure due-filter helpers without opening a DB connection.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error('[checkins] fatal error:', err);
    process.exit(1);
  });
}
