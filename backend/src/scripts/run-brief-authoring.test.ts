import { beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

const { listBriefDeliveryRecoveryUserIds, recoverBriefDeliveries } = await import('./run-brief-authoring.js');

beforeEach(() => {
  poolMock.query.mockReset();
});

describe('standalone brief delivery recovery', () => {
  it('does not select task or check-in rows for fresh authoring', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });

    await expect(listBriefDeliveryRecoveryUserIds()).resolves.toEqual([]);

    const sql = String(poolMock.query.mock.calls[0][0]);
    expect(sql).not.toContain('FROM tasks');
    expect(sql).not.toContain('FROM user_checkins');
    expect(sql).toContain("a.source = 'gateway'");
  });

  it('selects only canonical artifacts missing an exact-revision rollout delivery', async () => {
    poolMock.query.mockResolvedValueOnce({
      rows: [{ user_id: 'recovery-user' }],
    });

    await expect(listBriefDeliveryRecoveryUserIds()).resolves.toEqual(['recovery-user']);

    const sql = String(poolMock.query.mock.calls[0][0]);
    expect(sql).toContain('SELECT DISTINCT a.user_id');
    expect(sql).toContain('JOIN daily_briefs b');
    expect(sql).toContain('d.artifact_revision = a.revision');
    expect(sql).toContain("d.session_key = 'rem-orchestrator'");
    expect(sql).toContain("'rem-today-' || TO_CHAR(a.brief_date, 'YYYYMMDD')");
  });

  it('retries existing artifact delivery without invoking a fresh authoring seam', async () => {
    const recover = vi.fn(async (userId: string) => userId === 'first' ? 2 : 1);

    await expect(recoverBriefDeliveries(['first', 'second'], recover)).resolves.toEqual({
      recovered: 3,
      failed: 0,
    });
    expect(recover).toHaveBeenCalledTimes(2);
    expect(recover).toHaveBeenNthCalledWith(1, 'first');
    expect(recover).toHaveBeenNthCalledWith(2, 'second');
  });
});
