/**
 * Volatile runtime facts — what must never reach durable memory.
 *
 * ## Why (#1282 / #1277)
 *
 * Rem told a native iOS user it was "WebChat — you're chatting with me through the Rem web
 * interface", and separately claimed it could "check notifications, location, camera, photos"
 * while photo access is not exposed at all. The structural fix is upstream of here: the agent's
 * capability and surface sentences are now GENERATED from the gateway's own state every session
 * (by the hosted gateway's runtime-facts hook, operated separately), so the prompt cannot carry a stale
 * claim.
 *
 * That fix has exactly one way to lose: durable memory. A memory row saying "the user is on
 * WebChat" or "Rem can access the user's photos" is re-injected into every future session and
 * outranks a correct prompt indefinitely — a regenerated fact loses to a remembered one because
 * the model has no way to tell which is older. So the fix is only durable if volatile facts are
 * INELIGIBLE for extraction, not merely discouraged.
 *
 * ## What counts as volatile
 *
 * An ASSERTION about the RUNTIME rather than about the PERSON:
 *   - the surface / client / channel this conversation arrived on,
 *   - what Rem can or cannot do (capabilities, tools, connectors, device commands),
 *   - connection, pairing, or device state.
 *
 * All three are regenerated per session and change without the user doing anything.
 *
 * ## The durable-preference carve-out (this is a contract, not a hope)
 *
 * A sentence that expresses what the USER wants, asked for, or expects is a durable fact about
 * the person even when it names a channel, a surface, or a capability. "The user prefers the
 * web version of Notion over the desktop app" and "the user does not want Rem to have access to
 * their photos" are both real, storable facts; dropping them is as much a defect as storing a
 * stale one.
 *
 * `DURABLE_PREFERENCE_PATTERNS` is therefore checked FIRST and short-circuits the whole
 * classifier. That is what makes the comment above and the code below agree — the previous
 * revision promised this carve-out in prose and then dropped exactly those sentences.
 * `volatile-runtime-facts.service.test.ts` pins both directions.
 *
 * ## On principle 5 (structured signals over string parsing)
 *
 * This is a text classifier, which normally means we are on the wrong layer. It is deliberate
 * here: the input is a free-text sentence a language model wrote, so there is no structured
 * field to read — the structure was never captured. The structured fix lives in the prompt
 * generator; this module is the backstop at the write boundary, sized to catch the specific
 * false claims we have observed rather than to be a general classifier.
 *
 * ## PRIVACY: the verdict never carries user content
 *
 * A verdict reports the CATEGORY and a stable RULE ID. It deliberately does not carry the
 * matched substring. The matched substring is a slice of a user-derived memory candidate, and
 * the verdict travels into cron logs and into an HTTP response body — neither of which may
 * contain user memory content (see CLAUDE.md). A rule id is enough to debug "which rule fired"
 * without moving a single character of the candidate anywhere.
 */

/** Memory `source` values written by a machine rather than typed by the user. */
export const MACHINE_MEMORY_SOURCES = ['auto', 'agent', 'gateway', 'session', 'chat'] as const;

export type VolatileFactCategory = 'surface' | 'capability' | 'connection';

export interface VolatileFactVerdict {
  volatile: boolean;
  category?: VolatileFactCategory;
  /**
   * Stable id of the rule that fired, e.g. `surface.webchat`. Safe to log and to return over
   * HTTP: it is a constant from the table below, never a slice of the candidate fact.
   */
  rule?: string;
}

type Rule = { id: string; pattern: RegExp };

/**
 * Sentences that state what the USER wants, asked for, or expects.
 *
 * Checked before everything else. A preference is durable even when it mentions a channel, a
 * surface, or a capability — see the carve-out note in the file header.
 *
 * "should"/"must" are here on purpose: "Rem should confirm before sending email" is an
 * instruction about how the user wants to be worked with, not a claim about what Rem can do.
 */
const DURABLE_PREFERENCE_PATTERNS: ReadonlyArray<RegExp> = [
  /\b(prefers?|preference for|rather than|instead of)\b/i,
  /\b(wants?|wanted|would like|likes?|dislikes?|hates?|enjoys?)\b/i,
  /\b(asked|requested|expects?|insists?|requires?|needs? (?:me|rem|us|you) to)\b/i,
  /\b(should(?:n't| not)?|must(?:n't| not)?)\b/i,
];

/** True when the sentence reads as a user preference/instruction rather than a runtime claim. */
export function isDurableUserPreference(fact: string): boolean {
  return DURABLE_PREFERENCE_PATTERNS.some((pattern) => pattern.test(fact));
}

/**
 * Tokens and frames that describe the chat SURFACE.
 *
 * `webchat` is the head of this list for a reason: it is OpenClaw's internal id for the
 * gateway's own chat transport (`INTERNAL_MESSAGE_CHANNEL`), stamped onto every `chat.send`
 * turn and rendered into the system prompt as `channel=webchat`. A model that summarises its
 * own context will write it down as if it were the user's app. Rem has no web client at all.
 *
 * Everything after the internal ids requires a "is on / using / through" FRAME rather than a
 * bare noun, so an ordinary sentence that merely names a web app is not caught.
 */
const SURFACE_RULES: ReadonlyArray<Rule> = [
  { id: 'surface.webchat', pattern: /\bweb ?chat\b/i },
  { id: 'surface.openclaw', pattern: /\bopenclaw\b/i },
  { id: 'surface.control-ui', pattern: /\bcontrol ui\b/i },
  { id: 'surface.gateway', pattern: /\bthe gateway\b/i },
  { id: 'surface.node-session', pattern: /\bnode session\b/i },
  {
    id: 'surface.web-client-frame',
    pattern:
      /\b(?:on|in|via|through|using)\s+(?:the\s+)?(?:rem\s+)?web\s+(?:interface|version|client|app|browser|portal)\b/i,
  },
  {
    id: 'surface.conversation-medium',
    pattern: /\b(chatting|talking|messaging) (with|to) (me|rem|the assistant) (through|via|on)\b/i,
  },
];

/** Subjects that refer to the assistant/runtime rather than to the user. */
const RUNTIME_SUBJECT = String.raw`(?:rem|the assistant|the ai|the agent|the app)`;

/**
 * Claims about what the runtime CAN or CANNOT do. Capabilities move when the user pairs a
 * device, links a connector, or an operator changes `gateway.nodes.allowCommands` — so a
 * remembered capability is a promise with an expiry date.
 */
const CAPABILITY_RULES: ReadonlyArray<Rule> = [
  {
    id: 'capability.runtime-subject-can',
    pattern: new RegExp(
      String.raw`\b${RUNTIME_SUBJECT}\b[^.]{0,40}\b(can|cannot|can't|could|is able to|isn't able to|is unable to|has access to|does not have access to|doesn't have access to|supports|does not support|doesn't support|is capable of)\b`,
      'i',
    ),
  },
  // Second person — the extractor sometimes writes the fact addressed to Rem itself.
  {
    id: 'capability.second-person-can',
    pattern:
      /\byou (can|cannot|can't|are able to|are unable to|have access to|do not have access to|don't have access to)\b/i,
  },
  {
    id: 'capability.sensor-access',
    pattern:
      /\b(?:has|have|had|lacks?|without)\s+(?:no\s+)?(?:access to|the ability to (?:read|see|use))\s+(?:the user's |their )?(photos|camera|screen|microphone|notifications)\b/i,
  },
  {
    id: 'capability.tool-exposure',
    pattern:
      /\b(is|are) (not )?(exposed|available|enabled|implemented|supported) (as a |on |for )?(tool|command|capability|device)/i,
  },
];

/**
 * Connection / pairing / device state. All of it is a snapshot of one moment.
 *
 * Scoped to runtime subjects so an ordinary user fact ("commutes with their phone") is not
 * caught, and so "connected" only trips when it is about the plumbing.
 */
const CONNECTION_RULES: ReadonlyArray<Rule> = [
  {
    id: 'connection.device-state',
    pattern:
      /\b(device|phone|iphone|ipad|mac|macbook|node|gateway|session|connection)\b[^.]{0,30}\b(is|are|was|were|isn't|is not)\b[^.]{0,20}\b(paired|unpaired|paired up|connected|disconnected|online|offline|reachable|unreachable|active|suspended|asleep)\b/i,
  },
  {
    id: 'connection.right-now',
    pattern:
      /\b(currently|right now|at the moment)\b[^.]{0,30}\b(connected|disconnected|paired|online|offline)\b/i,
  },
  {
    id: 'connection.runtime-subject',
    pattern: new RegExp(
      String.raw`\b${RUNTIME_SUBJECT}\b[^.]{0,40}\bis (currently )?(connected|disconnected|online|offline|running)\b`,
      'i',
    ),
  },
];

const CATEGORIES: ReadonlyArray<{ category: VolatileFactCategory; rules: ReadonlyArray<Rule> }> = [
  { category: 'surface', rules: SURFACE_RULES },
  { category: 'capability', rules: CAPABILITY_RULES },
  { category: 'connection', rules: CONNECTION_RULES },
];

/** Every rule id this module can report. Used by tests to pin the ids as a stable surface. */
export const VOLATILE_RULE_IDS: ReadonlyArray<string> = CATEGORIES.flatMap(({ rules }) =>
  rules.map((rule) => rule.id),
);

/**
 * Classify one candidate fact. Pure — no I/O, no model call.
 *
 * Returns the category and the RULE ID that fired. It never returns any part of the candidate:
 * the verdict is logged and returned over HTTP, and user memory content may go to neither.
 */
export function classifyVolatileFact(fact: unknown): VolatileFactVerdict {
  if (typeof fact !== 'string') return { volatile: false };
  const trimmed = fact.trim();
  if (trimmed.length === 0) return { volatile: false };

  // A statement of what the user wants is durable, even when it names a surface or capability.
  if (isDurableUserPreference(trimmed)) return { volatile: false };

  for (const { category, rules } of CATEGORIES) {
    for (const rule of rules) {
      if (rule.pattern.test(trimmed)) {
        return { volatile: true, category, rule: rule.id };
      }
    }
  }
  return { volatile: false };
}

/** Convenience predicate. True when the fact asserts something about the runtime. */
export function isVolatileRuntimeFact(fact: unknown): boolean {
  return classifyVolatileFact(fact).volatile;
}

/** Drop every volatile candidate from a batch, preserving order. Pure. */
export function rejectVolatileFacts(facts: string[]): string[] {
  return facts.filter((fact) => !isVolatileRuntimeFact(fact));
}

/** True when `source` marks a fact as machine-written (and therefore subject to the filter). */
export function isMachineMemorySource(source: string | null | undefined): boolean {
  if (typeof source !== 'string') return false;
  return (MACHINE_MEMORY_SOURCES as readonly string[]).includes(source.trim().toLowerCase());
}

/**
 * A machine tried to store a volatile runtime fact. Distinct from MemoryValidationError so a
 * caller can count it as "correctly filtered" rather than as a malformed write.
 *
 * It lives HERE, next to the classifier, rather than in user-memory.service: that module opens
 * the Postgres pool at import time, and this error has to be constructible (and testable)
 * without a database.
 *
 * PRIVACY: the message names the category and the classifier's stable rule id only. It must
 * never carry the candidate fact or any slice of it — this message is written to cron logs AND
 * returned in an HTTP response body, and user memory content may go to neither.
 */
export class VolatileMemoryRejectedError extends Error {
  constructor(
    readonly category: string,
    readonly rule: string,
  ) {
    super(
      `refusing to store a volatile ${category} fact in durable memory (rule ${rule}) — ` +
        'runtime facts are regenerated per session and must not be remembered',
    );
    this.name = 'VolatileMemoryRejectedError';
  }
}
