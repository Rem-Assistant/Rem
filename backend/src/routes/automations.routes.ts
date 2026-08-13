import { Router, Request, Response } from 'express';
import { requireJwt } from '../middleware/auth.js';
import { listActiveToolkitSlugs } from '../services/composio.service.js';
import { listDescriptors } from '../services/connector-signals.registry.js';
import { gatherBrief } from '../services/brief.service.js';
import { deriveSuggestions } from '../services/suggestions.service.js';
import { resolveUserTimezone } from '../services/brief-authoring.service.js';
import {
  AUTOMATION_KINDS,
  getAutomationInputs,
  isAutomationKind,
  type ActiveConnectorAccountSource,
} from '../services/automation-inputs.service.js';
import {
  getAutomationOutputs,
  readNewestBriefArtifact,
  type AutomationOutputObservers,
} from '../services/automation-outputs.service.js';

/**
 * Automations — the server-authored description of what an automation actually reads and produces.
 *
 *   GET /api/v1/automations/:kind/inputs    — derived Inputs rows for the authed user
 *   GET /api/v1/automations/:kind/outputs   — derived Outputs rows for the authed user
 *
 * JWT-scoped: every fact is read for `req.userId` and nothing accepts a user id from the client.
 *
 * This route exists because the app used to hand-write these rows (`AutomationContract.swift`
 * typed `.planned` for connectors as a Swift literal). Hand-written capability claims cannot
 * self-correct and were wrong in both directions. Here, `state` is computed from the registry,
 * the live Composio connection authority, and our own recorded collect provenance.
 *
 * The connector list comes from `listDescriptors()` — the SAME registry the ingest cron and the
 * Daily Brief collector read (`connector-signals.registry.ts`). There is deliberately no local
 * array of connectors here: a connector this screen can name is exactly a connector some code
 * path can actually read, and the only way to add one is to add a descriptor.
 *
 * `ConnectorSignalDescriptor` is a structural supertype of `ConnectorInputDescriptorFacts`
 * (`source`, `toolkitSlug`, `displayName` — same names, same types), so it is passed straight
 * through with no adapter. Rename any of the three in the registry and this line fails to
 * compile, rather than the client failing to decode at runtime.
 */
const router = Router();

/** Production binding of the live connection authority. Injected so the derivation stays pure. */
const composioAccounts: ActiveConnectorAccountSource = {
  listActiveToolkitSlugs: (userId, toolkitSlugs, timeoutMs) =>
    listActiveToolkitSlugs(userId, toolkitSlugs, timeoutMs),
};

/**
 * Production binding of the OUTPUT producers.
 *
 * Each observer calls the REAL producer — `gatherBrief` for the attention buckets,
 * `deriveSuggestions` for the suggestion list, the artifacts table the authoring pipeline writes.
 * Nothing here re-implements "what counts as overdue" or "what makes a suggestion": a second copy
 * of that logic is exactly how the client's hand-typed contract drifted out of truth. Delete a
 * producer and this file stops compiling, rather than the screen quietly keeping its claim.
 */
const outputObservers: AutomationOutputObservers = {
  readNewestBriefArtifact: (userId, db) => readNewestBriefArtifact(userId, db),
  countAttentionItems: async (userId, now, timezone) => {
    const brief = await gatherBrief(userId, now, timezone);
    // The two buckets the triage output surfaces, read off the producer's own result. Using
    // `counts` rather than array lengths keeps this correct if a bucket is ever page-capped.
    return brief.counts.blocked + brief.counts.overdue;
  },
  countTaskSuggestions: async (userId, now, timezone) =>
    (await deriveSuggestions(userId, now, timezone)).length,
};

router.get('/automations/:kind/inputs', requireJwt, async (req: Request, res: Response) => {
  const kind = req.params.kind;
  // An unknown kind is a missing resource, not a malformed request — and never a guessed
  // contract. Returning a plausible-looking default here would recreate the original defect.
  if (!isAutomationKind(kind)) {
    return res.status(404).json({
      error: `Unknown automation kind "${String(kind)}". Known: ${AUTOMATION_KINDS.join(', ')}.`,
    });
  }
  try {
    const userId = (req as Request & { userId: string }).userId;
    const payload = await getAutomationInputs(
      userId,
      kind,
      listDescriptors(),
      composioAccounts,
    );
    return res.json(payload);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    // Message only — never the user id, an account id, or any connector payload.
    console.error('[AUTOMATIONS] inputs failed:', message);
    return res.status(500).json({ error: 'failed to load automation inputs' });
  }
});

router.get('/automations/:kind/outputs', requireJwt, async (req: Request, res: Response) => {
  const kind = req.params.kind;
  if (!isAutomationKind(kind)) {
    return res.status(404).json({
      error: `Unknown automation kind "${String(kind)}". Known: ${AUTOMATION_KINDS.join(', ')}.`,
    });
  }
  try {
    const userId = (req as Request & { userId: string }).userId;
    // Same timezone chain the brief itself resolves through, so "overdue" here means what it
    // means in the brief. A failure falls back to UTC exactly as `brief.routes.ts` does.
    const timezone = (await resolveUserTimezone(userId).catch(() => undefined)) ?? 'UTC';
    const payload = await getAutomationOutputs(userId, new Date(), timezone, outputObservers);
    return res.json(payload);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    // Message only — never the user id and never any produced content.
    console.error('[AUTOMATIONS] outputs failed:', message);
    return res.status(500).json({ error: 'failed to load automation outputs' });
  }
});

export default router;
