import { pool } from '../db/pool.js';
import { isValidTimezone } from './brief-authoring.service.js';

/**
 * User-profile writes that aren't part of the auth handshake itself.
 *
 * Today this is just the DEVICE timezone the app persists best-effort on launch/foreground/
 * login (issue #1097). The value lands in `users.timezone` (migration 101) and becomes the
 * top of `resolveUserTimezone`'s chain, so the daily brief cron — which has no live device to
 * read — picks the right local day + greeting + authoring slot for the user.
 */

/** Outcome of a timezone write, so the route can pick the right status code. */
export type UpdateUserTimezoneResult =
  | { ok: true; timezone: string }
  | { ok: false; reason: 'invalid' };

/**
 * Persist the user's IANA device timezone. Validates against the SAME `isValidTimezone` rule
 * the read path trusts (rejects junk like "not/a/zone" or an empty string) and, only on a
 * valid value, upserts it onto the user row. Invalid input is REJECTED (returns
 * `{ ok:false }`) rather than stored — the caller returns 400, never a 500. A DB error
 * propagates to the caller's try/catch. Idempotent: writing the same tz twice is a no-op.
 */
export async function updateUserTimezone(
  userId: string,
  rawTimezone: unknown,
): Promise<UpdateUserTimezoneResult> {
  const tz = typeof rawTimezone === 'string' ? rawTimezone.trim() : '';
  if (!tz || !isValidTimezone(tz)) {
    return { ok: false, reason: 'invalid' };
  }
  await pool.query(`UPDATE users SET timezone = $2 WHERE id = $1::uuid`, [userId, tz]);
  return { ok: true, timezone: tz };
}

/**
 * How stale `users.last_active_at` must be before a stamp actually writes a row. This
 * throttles the write cost of `touchUserActive`: the UPDATE statement still runs on every
 * authenticated request (a cheap primary-key lookup), but the row is only re-written at
 * most once per this window per user, so a burst of requests during an active session does
 * not amplify into a burst of writes. It's well under the keep-warm activity window (N=15m
 * in run-keepwarm.ts) so a user who's active stays inside the select even at the coarsest
 * stamp cadence.
 */
export const LAST_ACTIVE_STAMP_THROTTLE = '2 minutes';

/**
 * Record that a user just interacted with the app by bumping `users.last_active_at` — the
 * "recently active" signal the gateway keep-warm cron keys on (migration 102).
 *
 * Called fire-and-forget from `requireJwt` on every authenticated request, so it must be
 * cheap and never block or fail the request:
 *   - Conditional in SQL (`... < NOW() - INTERVAL`) so most calls no-op at the row level
 *     (see LAST_ACTIVE_STAMP_THROTTLE) — write amplification is bounded to ~1/window/user.
 *   - Returns the query promise so callers can attach a `.catch`; a DB hiccup here must
 *     degrade to "activity not stamped this tick", never a 500 on the underlying request.
 *
 * Idempotent and safe to call concurrently: two racing stamps both resolve to the same
 * `last_active_at ≈ NOW()`.
 */
export function touchUserActive(userId: string): Promise<unknown> {
  return pool.query(
    `UPDATE users
        SET last_active_at = NOW()
      WHERE id = $1::uuid
        AND (last_active_at IS NULL
             OR last_active_at < NOW() - INTERVAL '${LAST_ACTIVE_STAMP_THROTTLE}')`,
    [userId],
  );
}
