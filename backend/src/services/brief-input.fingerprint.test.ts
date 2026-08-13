/**
 * The refactor guard.
 *
 * `collectGmailBriefInput` used to own the fetch loop; it now projects the shared runner's
 * collection. The snapshot `fingerprint` is a sha256 over `JSON.stringify`, so it changes if ANY
 * field value, field name or KEY ORDER moves — which is exactly what a "harmless" refactor would
 * do silently. These digests were captured by running the pre-refactor implementation; they are
 * not regenerated. If one of them fails, behaviour changed and the change is not a refactor.
 */

import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it, vi } from 'vitest';
import {
  collectGmailBriefInput,
  GMAIL_BRIEF_ITEM_LIMIT,
  GMAIL_BRIEF_MAX_ACCOUNTS,
  GMAIL_BRIEF_MAX_PAGES,
  GMAIL_BRIEF_TIMEOUT_MS,
  GMAIL_BRIEF_WINDOW_HOURS,
  type GmailBriefAdapter,
  type GmailBriefPage,
} from './brief-input.service.js';
import { CONNECTOR_SIGNAL_BOUNDS } from './connector-signals.runner.js';

const NOW = new Date('2026-08-09T17:00:00.000Z');
const fixture = JSON.parse(fs.readFileSync(
  fileURLToPath(new URL('./fixtures/gmail-brief-page.normalized.json', import.meta.url)),
  'utf8',
)) as GmailBriefPage;

function accounts(ids: string[]) {
  return { listActiveAccountIds: vi.fn(async () => ids) };
}

function adapter(pages: GmailBriefPage[]): GmailBriefAdapter {
  return { fetchPage: vi.fn(async () => pages.shift() ?? { items: [], nextPageToken: null }) };
}

describe('brief input snapshot is byte-identical after the descriptor refactor', () => {
  it('pins the available snapshot digest', async () => {
    const result = await collectGmailBriefInput('user-1', NOW, accounts(['active-1']), adapter([{ ...fixture }]));
    expect(result.fingerprint).toBe('ace73ac5202a6e3522c2b5d9f4aa8ac2e00320db1c7ec7c71b2a57547d073fdd');
    expect(result.manifest[0].fingerprint).toBe('6e3355250a16de9bcc629593d5408d6b81b0d5d2eddb85cdb3ec71f788fe7730');
    expect(Object.keys(result)).toEqual([
      'producer', 'producerVersion', 'capturedAt', 'manifest', 'gmail', 'fingerprint',
    ]);
    expect(Object.keys(result.manifest[0])).toEqual([
      'source', 'availability', 'action', 'actionVersion', 'windowStart', 'windowEnd',
      'stableIds', 'fingerprint', 'unavailableReason', 'connectedAccountIds',
    ]);
    expect(Object.keys(result.gmail[0])).toEqual([
      'stableId', 'providerMessageId', 'providerThreadId', 'sender', 'subject', 'snippet', 'timestamp',
    ]);
  });

  it('pins the unavailable snapshot digest', async () => {
    const result = await collectGmailBriefInput('user-1', NOW, accounts([]), adapter([]));
    expect(result.fingerprint).toBe('7e7b73c45d1144aaf4ad4c58062c2e8593c1c15a9249bfe60c0f8cdd613ebfc7');
    expect(result.manifest[0].fingerprint).toBe('4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945');
  });

  it('pins the successful-but-empty snapshot digest, which is NOT the unavailable one', async () => {
    const result = await collectGmailBriefInput(
      'user-1', NOW, accounts(['active-1']), adapter([{ items: [], nextPageToken: null }]),
    );
    expect(result.fingerprint).toBe('7535927853b3004dae552be740cf30dec392102a9bae2dff9ccfa0f75c6e3f95');
    expect(result.manifest[0].availability).toBe('available');
  });

  it('keeps the Daily Brief bound names as aliases of the shared bounds, not a second copy', () => {
    expect(GMAIL_BRIEF_ITEM_LIMIT).toBe(CONNECTOR_SIGNAL_BOUNDS.maxItems);
    expect(GMAIL_BRIEF_MAX_PAGES).toBe(CONNECTOR_SIGNAL_BOUNDS.maxPages);
    expect(GMAIL_BRIEF_MAX_ACCOUNTS).toBe(CONNECTOR_SIGNAL_BOUNDS.maxAccounts);
    expect(GMAIL_BRIEF_WINDOW_HOURS).toBe(CONNECTOR_SIGNAL_BOUNDS.windowHours);
    expect(GMAIL_BRIEF_TIMEOUT_MS).toBe(CONNECTOR_SIGNAL_BOUNDS.timeoutMs);
    expect(CONNECTOR_SIGNAL_BOUNDS).toEqual({
      maxAccounts: 3, maxItems: 20, maxPages: 3, windowHours: 24, timeoutMs: 2_500,
    });
  });
});
