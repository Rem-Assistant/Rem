/**
 * routine-governance — the server-side safety layer the runner consults BEFORE any
 * write (#797). Two independent gates, both pure and unit-testable:
 *
 *   1. Hard deny list — categories that must NEVER be auto-executed regardless of a
 *      routine's autonomy level: send email/messages, legal/financial/immigration
 *      decisions, delete data, change sharing (docs/rebuild/10-ROUTINES-DESIGN.md,
 *      "Governance"). A routine whose instruction asks for one of these is blocked
 *      from executing — it may only surface a comment for the human to review.
 *   2. Autonomy gate — the L0–L4 ladder. L0–L2 are read-only/plan; L3+ may execute
 *      pre-authorized categories. This matches `buildRunReport`'s `canExecute`
 *      (autonomyLevel >= 3) in routine-schedule.service.ts.
 *
 * NOTE (principle 5 — structured signals over string parsing): the deny list screens
 * a user's free-text *instruction*, for which there is no upstream structured field,
 * so regex content-screening is the right layer here. When connector writes land,
 * those proposed actions arrive as structured categories and MUST be screened by
 * category (a denied-category set), not by re-parsing strings. This v1 list is a
 * heuristic floor, not a substitute for that — TODO(#797): harden + add category
 * screening once the runner can perform external writes.
 */

/** The autonomy level at and above which a routine may execute writes (L3 "safe writes"). */
export const WRITE_AUTONOMY_THRESHOLD = 3;

/** True when a routine's autonomy permits executing writes (L3+). Pure. */
export function canExecuteWrites(autonomy: number): boolean {
  return autonomy >= WRITE_AUTONOMY_THRESHOLD;
}

/** Whether a run at this autonomy level executes its writes or only plans them. Pure. */
export function planOrExecute(autonomy: number): 'plan' | 'execute' {
  return canExecuteWrites(autonomy) ? 'execute' : 'plan';
}

/** Hard-deny categories — never auto-executed, regardless of autonomy level. */
export type DenyCategory =
  | 'send_communications'
  | 'legal_financial_immigration'
  | 'delete_data'
  | 'change_sharing';

/**
 * High-signal patterns per denied category. Intentionally conservative: over-flagging
 * routes a routine to human review (the safe default) rather than letting it act.
 */
const DENY_PATTERNS: Array<[DenyCategory, RegExp]> = [
  [
    'send_communications',
    /\b(send\s+(an?\s+|the\s+)?(email|e-mail|message|text|sms|dm|slack|note|reply)|email\s+(my|the|him|her|them|to)\b|reply\s+to\b.{0,30}\b(email|message|text|dm)|forward\s+(this|the|an?\s+)?(email|message))/i,
  ],
  [
    'legal_financial_immigration',
    /\b(legal\s+advice|lawsuit|sue\b|attorney|contract|invoice|wire\s+(money|funds|transfer)|transfer\s+(money|funds)|payment|pay\s+(my|the|him|her|them|a\s+)?(bill|invoice)|\btax(es)?\b|immigration|visa\b|green\s?card|passport)/i,
  ],
  ['delete_data', /\b(delete|erase|wipe|destroy|purge)\b|\bdrop\s+(table|database)\b/i],
  [
    'change_sharing',
    /\b(unshare|make\s+(it|this)\s+public|change\s+sharing|grant\s+access|revoke\s+access|change\s+permission|share\s+(it|this|my|the)\b)/i,
  ],
];

export interface DenyScreenResult {
  denied: boolean;
  categories: DenyCategory[];
}

/**
 * Screen a free-text instruction against the hard deny list. Returns every category
 * matched so the surfaced comment can name what was blocked. Pure — no I/O.
 */
export function screenForDeniedAction(text: string | null | undefined): DenyScreenResult {
  const categories: DenyCategory[] = [];
  if (text) {
    for (const [category, pattern] of DENY_PATTERNS) {
      if (pattern.test(text)) categories.push(category);
    }
  }
  return { denied: categories.length > 0, categories };
}

/** Human-readable label for a denied category (for the surfaced comment). */
export function describeDenyCategory(category: DenyCategory): string {
  switch (category) {
    case 'send_communications':
      return 'sending email/messages';
    case 'legal_financial_immigration':
      return 'legal/financial/immigration decisions';
    case 'delete_data':
      return 'deleting data';
    case 'change_sharing':
      return 'changing sharing/permissions';
  }
}
