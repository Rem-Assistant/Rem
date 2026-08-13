import { beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

const { updateUserTimezone } = await import('./user.service.js');

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';

beforeEach(() => {
  poolMock.query.mockReset();
});

describe('updateUserTimezone', () => {
  it('upserts a valid IANA timezone onto the user row', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const result = await updateUserTimezone(USER_ID, 'America/Los_Angeles');
    expect(result).toEqual({ ok: true, timezone: 'America/Los_Angeles' });
    expect(poolMock.query).toHaveBeenCalledTimes(1);
    const [sql, params] = poolMock.query.mock.calls[0];
    expect(String(sql)).toContain('UPDATE users SET timezone');
    expect(params).toEqual([USER_ID, 'America/Los_Angeles']);
  });

  it('trims surrounding whitespace before storing', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const result = await updateUserTimezone(USER_ID, '  Europe/Paris  ');
    expect(result).toEqual({ ok: true, timezone: 'Europe/Paris' });
    expect(poolMock.query.mock.calls[0][1]).toEqual([USER_ID, 'Europe/Paris']);
  });

  it('REJECTS junk without writing (no 500) and never touches the DB', async () => {
    for (const junk of ['Not/AZone', 'garbage', '', '   ', 'America/Nowhere']) {
      const result = await updateUserTimezone(USER_ID, junk);
      expect(result).toEqual({ ok: false, reason: 'invalid' });
    }
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('REJECTS a non-string body value without writing', async () => {
    for (const bad of [undefined, null, 42, {}, ['America/Los_Angeles']]) {
      const result = await updateUserTimezone(USER_ID, bad);
      expect(result).toEqual({ ok: false, reason: 'invalid' });
    }
    expect(poolMock.query).not.toHaveBeenCalled();
  });
});
