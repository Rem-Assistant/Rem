import { describe, expect, it, vi } from 'vitest';
import type { DatabaseQueryable } from '../db/pool.js';

// Every read here injects its own queryable; the module-level `pool` default is never exercised.
// Mocked so importing the service does not require DATABASE_URL (house pattern — see
// suggestions.service.db.test.ts).
vi.mock('../db/pool.js', () => ({ pool: { query: async () => ({ rows: [] }) } }));

import {
  AUTOMATION_INPUT_CAPABILITIES,
  AUTOMATION_INPUT_STATES,
  deriveAutomationInputs,
  deriveConnected,
  deriveConnectorState,
  getAutomationInputs,
  isAutomationKind,
  readLastCollectFacts,
  toIsoOrNull,
  type ActiveConnectorAccountSource,
  type ActiveToolkitLookup,
  type AutomationInputRow,
  type ConnectorInputDescriptorFacts,
  type LastCollectFact,
} from './automation-inputs.service.js';

const gmail: ConnectorInputDescriptorFacts = {
  source: 'gmail',
  toolkitSlug: 'gmail',
  displayName: 'Gmail',
};
const slack: ConnectorInputDescriptorFacts = {
  source: 'slack',
  toolkitSlug: 'slack',
  displayName: 'Slack',
};

const connectedTo = (...slugs: string[]): ActiveToolkitLookup => ({ ok: true, slugs: new Set(slugs) });
const lookupFailed: ActiveToolkitLookup = { ok: false, reason: 'timeout' };

function fact(overrides: Partial<LastCollectFact> = {}): LastCollectFact {
  return {
    source: 'gmail',
    availability: 'available',
    unavailableReason: null,
    collectedAt: '2026-08-10T06:00:00.000Z',
    itemCount: 7,
    ...overrides,
  };
}

function derive(
  descriptors: ConnectorInputDescriptorFacts[],
  lookup: ActiveToolkitLookup,
  facts: LastCollectFact[] = [],
): AutomationInputRow[] {
  return deriveAutomationInputs({
    kind: 'daily-brief',
    descriptors,
    lookup,
    lastCollectBySource: new Map(facts.map((entry) => [entry.source, entry])),
  });
}

const connectorRow = (rows: AutomationInputRow[], source: string): AutomationInputRow => {
  const row = rows.find((candidate) => candidate.connector?.source === source);
  if (!row) throw new Error(`no connector row for ${source}`);
  return row;
};

function fakeDb(rows: unknown[]): { db: DatabaseQueryable; query: ReturnType<typeof vi.fn> } {
  const query = vi.fn().mockResolvedValue({ rows });
  return { db: { query } as unknown as DatabaseQueryable, query };
}

describe('automation input state is derived, never hand-written', () => {
  it('marks a connector included when a descriptor exists and an ACTIVE account is present', () => {
    const rows = derive([gmail], connectedTo('gmail'));
    const row = connectorRow(rows, 'gmail');
    expect(row.state).toBe('included');
    expect(row.capability).toBe('connector');
    expect(row.connector).toEqual({ source: 'gmail', displayName: 'Gmail' });
  });

  it('marks a connector not_connected when the descriptor exists but no ACTIVE account does', () => {
    expect(connectorRow(derive([gmail], connectedTo()), 'gmail').state).toBe('not_connected');
  });

  it('marks a connected connector unavailable when the last collect recorded a reason', () => {
    const rows = derive([gmail], connectedTo('gmail'), [
      fact({ availability: 'unavailable', unavailableReason: 'connector_unavailable', itemCount: 0 }),
    ]);
    const row = connectorRow(rows, 'gmail');
    expect(row.state).toBe('unavailable');
    expect(row.lastUnavailableReason).toBe('connector_unavailable');
    expect(row.lastItemCount).toBe(0);
    expect(row.lastCollectedAt).toBe('2026-08-10T06:00:00.000Z');
  });

  it('reports coming_soon for a capability with no descriptor, even with connectors present', () => {
    const rows = derive([gmail], connectedTo('gmail'));
    const cloud = rows.find((row) => row.capability === 'cloud_browser');
    expect(cloud?.state).toBe('coming_soon');
    expect(cloud?.connector).toBeNull();
  });

  it("keeps Rem's own stores included regardless of connector state", () => {
    const rows = derive([gmail], lookupFailed);
    expect(rows.find((row) => row.capability === 'rem_tasks')?.state).toBe('included');
    expect(rows.find((row) => row.capability === 'rem_calendar_items')?.state).toBe('included');
  });

  it('emits a stable row order: Rem stores, connectors by source, then not-yet-built', () => {
    const rows = derive([slack, gmail], connectedTo('gmail'));
    expect(rows.map((row) => row.capability)).toEqual([
      'rem_tasks', 'rem_calendar_items', 'connector', 'connector', 'cloud_browser',
    ]);
    expect(rows.filter((row) => row.connector).map((row) => row.connector?.source))
      .toEqual(['gmail', 'slack']);
  });

  it('deduplicates descriptors that share a source', () => {
    const rows = derive([gmail, { ...gmail, displayName: 'Gmail (dupe)' }], connectedTo('gmail'));
    expect(rows.filter((row) => row.capability === 'connector')).toHaveLength(1);
  });

  it('still lists the not-yet-built capability when the registry is empty', () => {
    const rows = derive([], connectedTo());
    expect(rows.map((row) => row.capability)).toEqual([
      'rem_tasks', 'rem_calendar_items', 'cloud_browser',
    ]);
  });

  it('carries no last-collect facts on a connector Rem has never collected', () => {
    const row = connectorRow(derive([gmail], connectedTo('gmail')), 'gmail');
    expect(row.lastCollectedAt).toBeNull();
    expect(row.lastItemCount).toBeNull();
    expect(row.lastUnavailableReason).toBeNull();
  });

  it('never leaks an unrecognized reason string into user-facing copy', () => {
    // `availability` is what puts the row in the unavailable branch (the enum, not the string).
    // The reason is then only ever used to CHOOSE a canned sentence, never interpolated into one.
    const rows = derive([gmail], connectedTo('gmail'), [
      fact({ availability: 'unavailable', unavailableReason: 'quota_exceeded_for_alice@example.com' }),
    ]);
    const row = connectorRow(rows, 'gmail');
    expect(row.state).toBe('unavailable');
    expect(row.lastUnavailableReason).toBe('quota_exceeded_for_alice@example.com');
    expect(row.detail).not.toContain('alice@example.com');
    expect(row.detail).toBe("Connected, but Rem couldn't read Gmail on the last brief.");
  });

  it('writes a detail sentence for every row', () => {
    for (const row of derive([gmail], connectedTo())) {
      expect(row.detail.trim().length).toBeGreaterThan(0);
      expect(row.detail.endsWith('.')).toBe(true);
    }
  });
});

describe('stale collect evidence never outranks the live connection authority', () => {
  it('treats a recorded no_active_connection as superseded once an ACTIVE account exists', () => {
    const rows = derive([gmail], connectedTo('gmail'), [
      fact({ availability: 'unavailable', unavailableReason: 'no_active_connection', itemCount: 0 }),
    ]);
    // Without this the user who just connected Gmail reads "unavailable" until the next brief.
    expect(connectorRow(rows, 'gmail').state).toBe('included');
  });

  it('prefers the live authority over provenance when the user has disconnected', () => {
    const rows = derive([gmail], connectedTo(), [fact()]);
    expect(connectorRow(rows, 'gmail').state).toBe('not_connected');
  });

  it('never reports unavailable for a connector that is not connected', () => {
    expect(deriveConnectorState('disconnected', fact({ unavailableReason: 'timeout' })))
      .toBe('not_connected');
  });
});

describe('a failed connection lookup is not the same as having no connection', () => {
  // The regression these pin: `deriveConnected` used to accept the last collect and, when the live
  // lookup failed, return `last.availability === 'available'` — a PAST successful read standing in
  // for a CURRENT active account. A user who disconnected Gmail kept reading "Connected — Rem
  // reads the last 24 hours of Gmail" for as long as Composio was unreachable.
  it('reports unknown — never connected — when the live lookup failed, however good the history', () => {
    expect(deriveConnected(gmail, lookupFailed)).toBe('unknown');
  });

  it('reports unknown when the lookup failed and there is no history either', () => {
    expect(deriveConnected(gmail, lookupFailed)).toBe('unknown');
  });

  it('does not take the connection question from the manifest at all', () => {
    // The signature no longer admits a LastCollectFact. This is the structural guarantee: there is
    // no argument through which stale provenance could re-enter the connection decision.
    expect(deriveConnected.length).toBe(2);
  });

  it('renders unavailable, not a false claim of coverage and not a false Connect prompt', () => {
    const rows = derive([gmail], lookupFailed, [fact({ availability: 'available' })]);
    const row = connectorRow(rows, 'gmail');
    expect(row.state).toBe('unavailable');
    // The copy must not assert the connection the lookup failed to establish.
    expect(row.detail).not.toMatch(/^Connected/);
    expect(row.detail).toMatch(/couldn't check/i);
  });
});

describe('the state ladder reads the structured availability enum, not the reason string', () => {
  // CLAUDE.md principle 5. The ladder used to branch on `unavailableReason` being non-null, while
  // `availability` — a closed enum the collector already writes into the manifest and this service
  // already selects out of it — sat unread. The collector deliberately emits a non-null reason on
  // rows whose availability is fine, so any such row rendered as "unavailable".
  it('stays included when availability is available even though a reason is present', () => {
    expect(deriveConnectorState('connected', fact({
      availability: 'available',
      unavailableReason: 'partial_pages',
    }))).toBe('included');
  });

  it('goes unavailable when the enum says so', () => {
    expect(deriveConnectorState('connected', fact({
      availability: 'unavailable',
      unavailableReason: 'timeout',
    }))).toBe('unavailable');
  });

  it('does not regress to unavailable when a producer adds a new reason token', () => {
    expect(deriveConnectorState('connected', fact({
      availability: 'available',
      unavailableReason: 'some_future_token_nobody_has_written_yet',
    }))).toBe('included');
  });

  it('is included when there is no history at all', () => {
    expect(deriveConnectorState('connected', undefined)).toBe('included');
  });
});

describe('reading recorded collect provenance', () => {
  it('accepts ISO 8601 with AND without fractional seconds', async () => {
    const { db } = fakeDb([
      {
        source: 'gmail', availability: 'available', unavailable_reason: null,
        manifest_captured_at: '2026-02-15T01:00:00Z', column_captured_at: null, item_count: 3,
      },
      {
        source: 'slack', availability: 'available', unavailable_reason: null,
        manifest_captured_at: '2026-02-15T01:00:00.250Z', column_captured_at: null, item_count: 1,
      },
    ]);
    const facts = await readLastCollectFacts('user-1', db);
    expect(facts.get('gmail')?.collectedAt).toBe('2026-02-15T01:00:00.000Z');
    expect(facts.get('slack')?.collectedAt).toBe('2026-02-15T01:00:00.250Z');
  });

  it('falls back to the artifact column when the manifest timestamp is missing or garbage', async () => {
    const { db } = fakeDb([
      {
        source: 'gmail', availability: 'unavailable', unavailable_reason: 'timeout',
        manifest_captured_at: 'not-a-date',
        column_captured_at: new Date('2026-08-01T12:00:00Z'), item_count: null,
      },
    ]);
    const facts = await readLastCollectFacts('user-1', db);
    expect(facts.get('gmail')?.collectedAt).toBe('2026-08-01T12:00:00.000Z');
    expect(facts.get('gmail')?.itemCount).toBeNull();
  });

  it('sanitizes and bounds a recorded reason instead of trusting the producer', async () => {
    const { db } = fakeDb([
      {
        source: 'gmail', availability: 'unavailable',
        unavailable_reason: `line\u0000one\nline\u007ftwo${' pad'.repeat(60)}`,
        manifest_captured_at: null, column_captured_at: null, item_count: 0,
      },
    ]);
    const reason = (await readLastCollectFacts('user-1', db)).get('gmail')?.unavailableReason ?? '';
    expect(reason).not.toMatch(/[\u0000-\u001f\u007f]/);
    expect(reason.length).toBeLessThanOrEqual(120);
  });

  it('drops manifest entries with no usable source and rejects a negative item count', async () => {
    const { db } = fakeDb([
      { source: '   ', availability: 'available', unavailable_reason: null, manifest_captured_at: null, column_captured_at: null, item_count: 2 },
      { source: null, availability: 'available', unavailable_reason: null, manifest_captured_at: null, column_captured_at: null, item_count: 2 },
      { source: 'gmail', availability: 'available', unavailable_reason: null, manifest_captured_at: null, column_captured_at: null, item_count: -4 },
    ]);
    const facts = await readLastCollectFacts('user-1', db);
    expect([...facts.keys()]).toEqual(['gmail']);
    expect(facts.get('gmail')?.itemCount).toBeNull();
  });

  it('scopes the read to the caller and bounds the artifact scan', async () => {
    const { db, query } = fakeDb([]);
    await readLastCollectFacts('user-9', db, 25);
    expect(query).toHaveBeenCalledTimes(1);
    const [sql, params] = query.mock.calls[0];
    expect(params).toEqual(['user-9', 25]);
    expect(sql).toContain('user_id = $1::uuid');
    // JSON null and SQL NULL both live in this column; `IS NOT NULL` would let JSON null through
    // and `jsonb_array_elements` would then raise on a non-array.
    expect(sql).toContain("jsonb_typeof(input_manifest) = 'object'");
    expect(sql).toContain("jsonb_typeof(r.input_manifest->'manifest') = 'array'");
    expect(sql).toContain("DISTINCT ON (entry->>'source')");
  });
});

describe('getAutomationInputs observes before it derives', () => {
  const okAccounts = (slugs: string[]): ActiveConnectorAccountSource & { spy: ReturnType<typeof vi.fn> } => {
    const spy = vi.fn().mockResolvedValue(slugs);
    return { listActiveToolkitSlugs: spy, spy };
  };

  it('asks the connection authority only for the toolkits that have a descriptor', async () => {
    const { db } = fakeDb([]);
    const accounts = okAccounts(['gmail']);
    await getAutomationInputs('user-1', 'daily-brief', [slack, gmail, gmail], accounts, db);
    expect(accounts.spy).toHaveBeenCalledTimes(1);
    expect(accounts.spy.mock.calls[0][0]).toBe('user-1');
    expect(accounts.spy.mock.calls[0][1]).toEqual(['gmail', 'slack']);
  });

  it('does not call the connection authority when no descriptor exists', async () => {
    const { db } = fakeDb([]);
    const accounts = okAccounts([]);
    const { inputs } = await getAutomationInputs('user-1', 'daily-brief', [], accounts, db);
    expect(accounts.spy).not.toHaveBeenCalled();
    expect(inputs.some((row) => row.capability === 'connector')).toBe(false);
  });

  it('degrades instead of failing when the connection authority is unreachable', async () => {
    const { db } = fakeDb([]);
    const accounts: ActiveConnectorAccountSource = {
      listActiveToolkitSlugs: vi.fn().mockRejectedValue(new Error('composio down')),
    };
    const { inputs } = await getAutomationInputs('user-1', 'daily-brief', [gmail], accounts, db);
    const row = inputs.find((r) => r.capability === 'connector');
    // `unavailable`, not `not_connected`: we could not ask, so we neither promise coverage nor
    // tell an already-connected user to connect. It answers 200 either way — that is the degrade.
    expect(row?.state).toBe('unavailable');
    expect(row?.detail).not.toMatch(/^Connect /);
  });

  it('fails loudly when our own provenance cannot be read', async () => {
    const db = { query: vi.fn().mockRejectedValue(new Error('db down')) } as unknown as DatabaseQueryable;
    await expect(
      getAutomationInputs('user-1', 'daily-brief', [gmail], okAccounts(['gmail']), db),
    ).rejects.toThrow('db down');
  });
});

describe('pinned wire vocabulary', () => {
  it('exposes exactly the four capabilities and four states', () => {
    expect([...AUTOMATION_INPUT_CAPABILITIES])
      .toEqual(['rem_tasks', 'rem_calendar_items', 'connector', 'cloud_browser']);
    expect([...AUTOMATION_INPUT_STATES])
      .toEqual(['included', 'not_connected', 'unavailable', 'coming_soon']);
  });

  it('accepts only known automation kinds', () => {
    expect(isAutomationKind('daily-brief')).toBe(true);
    expect(isAutomationKind('daily_brief')).toBe(false);
    expect(isAutomationKind('')).toBe(false);
    expect(isAutomationKind(undefined)).toBe(false);
  });

  it('normalizes timestamps and rejects unparseable ones', () => {
    expect(toIsoOrNull('2026-02-15T01:00:00Z')).toBe('2026-02-15T01:00:00.000Z');
    expect(toIsoOrNull('2026-02-15T01:00:00.123Z')).toBe('2026-02-15T01:00:00.123Z');
    expect(toIsoOrNull(new Date('2026-02-15T01:00:00Z'))).toBe('2026-02-15T01:00:00.000Z');
    expect(toIsoOrNull('yesterday')).toBeNull();
    expect(toIsoOrNull('')).toBeNull();
    expect(toIsoOrNull(null)).toBeNull();
    expect(toIsoOrNull(new Date('nope'))).toBeNull();
  });
});
