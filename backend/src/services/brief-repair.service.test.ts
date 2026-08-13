import { describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({ connect: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));
vi.mock('./gateway-agent.service.js', () => ({ readAssistantHistoryOnGateway: vi.fn() }));

const {
  BriefRepairError,
  repairCanonicalBrief,
  selectVerifiedBriefMessage,
  transcriptMessageDigest,
} = await import('./brief-repair.service.js');

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';
const LOCAL_DAY = '2026-08-08';
const TEXT = 'Saturday morning, and three things need your attention.';
const DIGEST = transcriptMessageDigest(TEXT);
const TIMESTAMP = '2026-08-08T17:30:00.000Z';
const STAGING_SYSTEM_IDENTIFIER = '7608502865891373092';
const BEGIN_SQL = 'BEGIN ISOLATION LEVEL SERIALIZABLE';

function databaseIdentity() {
  return {
    rows: [{ database_name: 'railway', system_identifier: STAGING_SYSTEM_IDENTIFIER }],
    rowCount: 1,
  };
}

function isDayLifecycleScan(sql: string): boolean {
  return sql.includes('SELECT id,') && sql.includes('FROM daily_brief_artifacts\n');
}

function message(overrides: Record<string, unknown> = {}) {
  return {
    messageId: 'message-1',
    text: TEXT,
    timestamp: TIMESTAMP,
    ...overrides,
  };
}

function dependencies(client?: any, historyMessages = [message()]) {
  return {
    database: { connect: vi.fn().mockResolvedValue(client) },
    resolveTimezone: vi.fn().mockResolvedValue('America/Los_Angeles'),
    readHistory: vi.fn().mockResolvedValue({ ok: true, messages: historyMessages }),
  };
}

function options(commit = false) {
  return {
    userId: USER_ID,
    localDay: LOCAL_DAY,
    transcriptDigest: DIGEST,
    messageId: 'message-1',
    commit,
  };
}

describe('selectVerifiedBriefMessage', () => {
  it('requires the exact digest, optional message id, and target local day', () => {
    const selected = selectVerifiedBriefMessage(
      [
        message({ messageId: 'wrong-id' }),
        message({ timestamp: '2026-08-07T17:30:00.000Z' }),
        message(),
      ],
      options(false),
      'America/Los_Angeles',
    );
    expect(selected.text).toBe(TEXT);
    expect(selected.messageId).toBe('message-1');
  });

  it('fails closed when no transcript message matches', () => {
    expect(() => selectVerifiedBriefMessage(
      [message({ text: 'Different prose' })],
      options(false),
      'America/Los_Angeles',
    )).toThrowError(expect.objectContaining({ code: 'message_not_found' }));
  });

  it('fails closed on duplicate digest matches when no message id disambiguates', () => {
    expect(() => selectVerifiedBriefMessage(
      [message({ messageId: null }), message({ messageId: null })],
      { localDay: LOCAL_DAY, transcriptDigest: DIGEST },
      'America/Los_Angeles',
    )).toThrowError(expect.objectContaining({ code: 'message_ambiguous' }));
  });

  it('requires message id whenever the gateway exposes one', () => {
    expect(() => selectVerifiedBriefMessage(
      [message()],
      { localDay: LOCAL_DAY, transcriptDigest: DIGEST },
      'America/Los_Angeles',
    )).toThrowError(expect.objectContaining({ code: 'message_id_required' }));
  });
});

describe('repairCanonicalBrief', () => {
  it('is dry-run by default and performs no database checkout or write', async () => {
    const deps = dependencies();
    const result = await repairCanonicalBrief(options(false), deps as any);

    expect(result).toMatchObject({
      mode: 'dry-run',
      transcriptDigest: DIGEST,
      messageIdVerified: true,
      invalidatedFallbackArtifacts: 0,
      invalidatedFallbackCacheRows: 0,
    });
    expect(deps.database.connect).not.toHaveBeenCalled();
  });

  it('is idempotent when the exact gateway artifact, delivery, and cache already exist', async () => {
    const queries: string[] = [];
    const client = {
      query: vi.fn(async (sql: string) => {
        queries.push(sql);
        if (sql.includes('pg_control_system()')) return databaseIdentity();
        if (sql === BEGIN_SQL || sql === 'COMMIT') return { rows: [], rowCount: null };
        if (sql.includes('SELECT id FROM users')) return { rows: [{ id: USER_ID }], rowCount: 1 };
        if (isDayLifecycleScan(sql)) return { rows: [], rowCount: 0 };
        if (sql.includes("DELETE FROM daily_briefs")) return { rows: [], rowCount: 0 };
        if (sql.includes("DELETE FROM daily_brief_artifacts")) return { rows: [], rowCount: 0 };
        if (sql.includes('SELECT a.id, a.revision, a.markdown, a.summary')) {
          return { rows: [{
            id: 'artifact-1', revision: 'revision-1', markdown: TEXT, summary: TEXT,
            source: 'gateway', authoring_active: false, delivery_fence_active: false,
            delivery_active: false,
          }] };
        }
        if (sql.includes('SELECT gateway_message_id')) {
          return { rows: [{ gateway_message_id: 'message-1' }] };
        }
        if (sql.includes('SELECT 1 FROM daily_briefs')) return { rows: [{ '?column?': 1 }] };
        throw new Error(`unexpected query: ${sql}`);
      }),
      release: vi.fn(),
    };
    const result = await repairCanonicalBrief(options(true), dependencies(client) as any);

    expect(result).toMatchObject({ mode: 'committed', alreadyAdopted: true });
    expect(queries).toContain('COMMIT');
    expect(queries.some((sql) => sql.includes('INSERT INTO daily_brief_artifacts'))).toBe(false);
    expect(client.release).toHaveBeenCalledOnce();
  });

  it('commits scoped fallback invalidation and verified adoption in one transaction', async () => {
    const queries: string[] = [];
    const client = {
      query: vi.fn(async (sql: string, params?: unknown[]) => {
        queries.push(sql);
        if (sql.includes('pg_control_system()')) return databaseIdentity();
        if (sql === BEGIN_SQL || sql === 'COMMIT') return { rows: [], rowCount: null };
        if (sql.includes('SELECT id FROM users')) return { rows: [{ id: USER_ID }], rowCount: 1 };
        if (isDayLifecycleScan(sql)) return { rows: [], rowCount: 0 };
        if (sql.includes("DELETE FROM daily_briefs")) return { rows: [], rowCount: 1 };
        if (sql.includes("DELETE FROM daily_brief_artifacts")) return { rows: [], rowCount: 2 };
        if (sql.includes('SELECT a.id, a.revision, a.markdown, a.summary')) return { rows: [] };
        if (sql.includes('INSERT INTO daily_brief_artifacts')) return { rows: [{ id: 'artifact-new' }], rowCount: 1 };
        if (sql.includes('INSERT INTO daily_brief_artifact_deliveries')) {
          expect(params?.[2]).toBe('message-1');
          return { rows: [], rowCount: 1 };
        }
        if (sql.includes('INSERT INTO daily_briefs')) return { rows: [], rowCount: 1 };
        throw new Error(`unexpected query: ${sql}`);
      }),
      release: vi.fn(),
    };

    const result = await repairCanonicalBrief(options(true), dependencies(client) as any);

    expect(result).toMatchObject({
      mode: 'committed',
      invalidatedFallbackArtifacts: 2,
      invalidatedFallbackCacheRows: 1,
      alreadyAdopted: false,
    });
    expect(queries.findIndex((sql) => sql.includes('pg_control_system()')))
      .toBeLessThan(queries.indexOf(BEGIN_SQL));
    expect(queries.indexOf(BEGIN_SQL)).toBeLessThan(queries.findIndex((sql) => sql.includes('DELETE FROM daily_briefs')));
    expect(queries.findIndex((sql) => sql.includes('INSERT INTO daily_briefs'))).toBeLessThan(queries.indexOf('COMMIT'));
    expect(client.release).toHaveBeenCalledOnce();
  });

  it('rolls back fallback invalidation when adoption fails', async () => {
    const queries: string[] = [];
    const client = {
      query: vi.fn(async (sql: string) => {
        queries.push(sql);
        if (sql.includes('pg_control_system()')) return databaseIdentity();
        if (sql === BEGIN_SQL || sql === 'ROLLBACK') return { rows: [], rowCount: null };
        if (sql.includes('SELECT id FROM users')) return { rows: [{ id: USER_ID }], rowCount: 1 };
        if (isDayLifecycleScan(sql)) return { rows: [], rowCount: 0 };
        if (sql.includes("DELETE FROM daily_briefs")) return { rows: [], rowCount: 1 };
        if (sql.includes("DELETE FROM daily_brief_artifacts")) return { rows: [], rowCount: 2 };
        if (sql.includes('SELECT a.id, a.revision, a.markdown, a.summary')) return { rows: [] };
        if (sql.includes('INSERT INTO daily_brief_artifacts')) throw new Error('simulated insert failure');
        throw new Error(`unexpected query: ${sql}`);
      }),
      release: vi.fn(),
    };

    await expect(repairCanonicalBrief(options(true), dependencies(client) as any))
      .rejects.toThrow('simulated insert failure');
    expect(queries).toContain('ROLLBACK');
    expect(queries).not.toContain('COMMIT');
    expect(client.release).toHaveBeenCalledOnce();
  });

  it('rejects a commit before BEGIN when the connected database is not pinned staging', async () => {
    const queries: string[] = [];
    const client = {
      query: vi.fn(async (sql: string) => {
        queries.push(sql);
        if (sql.includes('pg_control_system()')) {
          return { rows: [{ database_name: 'railway', system_identifier: 'production-cluster' }] };
        }
        throw new Error(`unexpected query: ${sql}`);
      }),
      release: vi.fn(),
    };

    await expect(repairCanonicalBrief(options(true), dependencies(client) as any))
      .rejects.toThrowError(expect.objectContaining({ code: 'database_identity_mismatch' }));
    expect(queries).not.toContain(BEGIN_SQL);
    expect(client.release).toHaveBeenCalledOnce();
  });

  it('revalidates a claim inserted after the initially empty day scan and performs no mutation', async () => {
    const queries: string[] = [];
    let releaseExactScan!: () => void;
    let markExactScanStarted!: () => void;
    let claimInserted = false;
    const exactScanStarted = new Promise<void>((resolve) => { markExactScanStarted = resolve; });
    const exactScanMayReturn = new Promise<void>((resolve) => { releaseExactScan = resolve; });
    const client = {
      query: vi.fn(async (sql: string) => {
        queries.push(sql);
        if (sql.includes('pg_control_system()')) return databaseIdentity();
        if (sql === BEGIN_SQL || sql === 'ROLLBACK') return { rows: [], rowCount: null };
        if (sql.includes('SELECT id FROM users')) return { rows: [{ id: USER_ID }], rowCount: 1 };
        // First predicate scan observes no artifact. A normal authoring claim commits immediately
        // after it, before the exact-slot FOR UPDATE revalidation returns.
        if (isDayLifecycleScan(sql)) return { rows: [], rowCount: 0 };
        if (sql.includes('SELECT a.id, a.revision, a.markdown, a.summary')) {
          markExactScanStarted();
          await exactScanMayReturn;
          return claimInserted
            ? { rows: [{
                id: 'phantom-claim', revision: 'revision-live', markdown: null, summary: null,
                source: 'gateway', authoring_active: true, delivery_fence_active: false,
                delivery_active: false,
              }], rowCount: 1 }
            : { rows: [], rowCount: 0 };
        }
        throw new Error(`unexpected query: ${sql}`);
      }),
      release: vi.fn(),
    };

    const repair = repairCanonicalBrief(options(true), dependencies(client) as any);
    await exactScanStarted;
    claimInserted = true;
    releaseExactScan();

    await expect(repair).rejects.toThrowError(expect.objectContaining({ code: 'repair_busy' }));
    expect(queries).toContain('ROLLBACK');
    expect(queries.some((sql) => sql.includes('DELETE FROM'))).toBe(false);
    expect(queries.some((sql) => sql.includes('INSERT INTO daily_brief'))).toBe(false);
  });

  it.each([
    ['authoring lease', { authoring_active: true, delivery_fence_active: false }],
    ['delivery fence', { authoring_active: false, delivery_fence_active: true }],
  ])('rolls back without invalidation while an active %s owns the artifact', async (_label, lifecycle) => {
    const queries: string[] = [];
    const client = {
      query: vi.fn(async (sql: string) => {
        queries.push(sql);
        if (sql.includes('pg_control_system()')) return databaseIdentity();
        if (sql === BEGIN_SQL || sql === 'ROLLBACK') return { rows: [], rowCount: null };
        if (sql.includes('SELECT id FROM users')) return { rows: [{ id: USER_ID }], rowCount: 1 };
        if (isDayLifecycleScan(sql)) {
          return { rows: [{ id: 'artifact-live', ...lifecycle }], rowCount: 1 };
        }
        throw new Error(`unexpected query: ${sql}`);
      }),
      release: vi.fn(),
    };

    await expect(repairCanonicalBrief(options(true), dependencies(client) as any))
      .rejects.toThrowError(expect.objectContaining({ code: 'repair_busy' }));
    expect(queries).toContain('ROLLBACK');
    expect(queries.some((sql) => sql.includes('DELETE FROM'))).toBe(false);
  });

  it('shares artifact and delivery row fencing and rejects an in-flight delivery', async () => {
    const queries: string[] = [];
    const client = {
      query: vi.fn(async (sql: string) => {
        queries.push(sql);
        if (sql.includes('pg_control_system()')) return databaseIdentity();
        if (sql === BEGIN_SQL || sql === 'ROLLBACK') return { rows: [], rowCount: null };
        if (sql.includes('SELECT id FROM users')) return { rows: [{ id: USER_ID }], rowCount: 1 };
        if (isDayLifecycleScan(sql)) {
          return { rows: [{ id: 'artifact-live', authoring_active: false, delivery_fence_active: false }], rowCount: 1 };
        }
        if (sql.includes("state = 'delivering'")) return { rows: [{ artifact_id: 'artifact-live' }], rowCount: 1 };
        throw new Error(`unexpected query: ${sql}`);
      }),
      release: vi.fn(),
    };

    await expect(repairCanonicalBrief(options(true), dependencies(client) as any))
      .rejects.toThrowError(expect.objectContaining({ code: 'repair_busy' }));
    expect(queries.find((sql) => sql.includes('daily_brief_artifacts'))).toContain('FOR UPDATE');
    expect(queries.find((sql) => sql.includes("state = 'delivering'"))).toContain('FOR UPDATE');
    expect(queries.some((sql) => sql.includes('DELETE FROM'))).toBe(false);
  });
});
