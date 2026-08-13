import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => {
  const query = vi.fn();
  const transactionQuery = vi.fn((sql: string, params?: unknown[]) => {
    if (sql === 'BEGIN' || sql === 'COMMIT' || sql === 'ROLLBACK'
      || sql.startsWith('SELECT pg_advisory_xact_lock')) {
      return Promise.resolve({ rows: [], rowCount: 0 });
    }
    return query(sql, params);
  });
  return {
    query,
    transactionQuery,
    connect: vi.fn(async () => ({ query: transactionQuery, release: vi.fn() })),
  };
});
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

import {
  DeviceTokenOwnershipConflictError,
  disableDeviceToken,
  registerDeviceToken,
  unregisterDeviceToken,
  sendPush,
  isApnsConfigured,
  buildApnsPayload,
  normalizeApnsEnvironment,
  normalizeDevicePlatform,
  isRetryablePushResult,
  isPermanentlyInvalidDeviceTokenResponse,
  listDeviceTokens,
  shouldRefreshApnsProviderToken,
} from './push.service.js';

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';

const APNS_ENV_KEYS = ['APNS_KEY_ID', 'APNS_TEAM_ID', 'APNS_BUNDLE_ID', 'APNS_AUTH_KEY'] as const;

function clearApnsEnv() {
  for (const k of APNS_ENV_KEYS) delete process.env[k];
}

describe('push.service token normalizers', () => {
  it('normalizeApnsEnvironment defaults to production for junk', () => {
    expect(normalizeApnsEnvironment('sandbox')).toBe('sandbox');
    expect(normalizeApnsEnvironment('PRODUCTION')).toBe('production');
    expect(normalizeApnsEnvironment('nonsense')).toBe('production');
    expect(normalizeApnsEnvironment(undefined)).toBe('production');
  });

  it('normalizeDevicePlatform defaults to ios for junk', () => {
    expect(normalizeDevicePlatform('macos')).toBe('macos');
    expect(normalizeDevicePlatform('android')).toBe('ios');
    expect(normalizeDevicePlatform(undefined)).toBe('ios');
  });

  it('buildApnsPayload nests title/body, thread identity, and custom data', () => {
    const payload = buildApnsPayload({
      title: 'Hi',
      body: 'There',
      threadId: 'rem-daily-brief',
      data: { taskId: '42' },
    });
    expect(payload).toMatchObject({
      aps: {
        alert: { title: 'Hi', body: 'There' },
        sound: 'default',
        'thread-id': 'rem-daily-brief',
      },
      taskId: '42',
    });
  });
});

describe('push.service APNs failure classification', () => {
  it('retries transport, throttle, server, and provider-configuration failures', () => {
    expect(isRetryablePushResult({ token: 'a', ok: false, status: 0 })).toBe(true);
    expect(isRetryablePushResult({ token: 'a', ok: false, status: 429 })).toBe(true);
    expect(isRetryablePushResult({ token: 'a', ok: false, status: 503 })).toBe(true);
    expect(isRetryablePushResult({ token: 'a', ok: false, status: 400, reason: 'IdleTimeout' })).toBe(true);
    expect(isRetryablePushResult({ token: 'a', ok: false, status: 403, reason: 'ExpiredProviderToken' })).toBe(true);
    expect(isRetryablePushResult({ token: 'a', ok: false, status: 400, reason: 'DeviceTokenNotForTopic' })).toBe(true);
    expect(isRetryablePushResult({ token: 'a', ok: false, status: 400, reason: 'BadTopic' })).toBe(true);
    expect(isRetryablePushResult({ token: 'a', ok: false, status: 400, reason: 'BadDeviceToken' })).toBe(false);
    expect(isRetryablePushResult({ token: 'a', ok: false, status: 400, reason: 'PayloadTooLarge' })).toBe(false);
    expect(isRetryablePushResult({ token: 'a', ok: true, status: 200 })).toBe(false);
  });

  it('refreshes only an APNs-expired cached provider token', () => {
    expect(shouldRefreshApnsProviderToken({ ok: false, reason: 'ExpiredProviderToken' })).toBe(true);
    expect(shouldRefreshApnsProviderToken({ ok: false, reason: 'InvalidProviderToken' })).toBe(false);
    expect(shouldRefreshApnsProviderToken({ ok: true, reason: 'ExpiredProviderToken' })).toBe(false);
  });

  it('prunes every token-specific terminal APNs response', () => {
    expect(isPermanentlyInvalidDeviceTokenResponse(410, 'Unregistered')).toBe(true);
    expect(isPermanentlyInvalidDeviceTokenResponse(400, 'BadDeviceToken')).toBe(true);
    expect(isPermanentlyInvalidDeviceTokenResponse(400, 'DeviceTokenNotForTopic')).toBe(false);
    expect(isPermanentlyInvalidDeviceTokenResponse(400, 'BadTopic')).toBe(false);
    expect(isPermanentlyInvalidDeviceTokenResponse(503, 'ServiceUnavailable')).toBe(false);
  });
});

describe('registerDeviceToken', () => {
  beforeEach(() => vi.clearAllMocks());

  it('atomically transfers one APNs destination to the account that most recently registered it', async () => {
    poolMock.query.mockResolvedValueOnce({
      rows: [{ id: 'row-1', apns_token: 'abc', environment: 'sandbox', platform: 'ios' }],
    });
    const row = await registerDeviceToken(USER_ID, 'abc', 'sandbox', 'ios', 'install-1', 3);
    expect(row).toMatchObject({ id: 'row-1', apns_token: 'abc', environment: 'sandbox' });
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('INSERT INTO device_tokens');
    expect(sql).toContain('INSERT INTO push_installation_fences');
    expect(sql).toContain('retired_siblings');
    expect(sql).toContain('IS DISTINCT FROM ($2, $3)');
    expect(sql).toContain('ON CONFLICT (apns_token, environment) DO UPDATE');
    expect(sql).toContain('user_id = EXCLUDED.user_id');
    expect(sql).toContain('EXCLUDED.ownership_generation > device_tokens.ownership_generation');
    expect(poolMock.query.mock.calls[0][1]).toEqual([USER_ID, 'abc', 'sandbox', 'ios', 'install-1', 3]);
    expect(poolMock.connect).toHaveBeenCalledTimes(1);
    expect(poolMock.transactionQuery.mock.calls.some(
      ([statement]) => String(statement).startsWith('SELECT pg_advisory_xact_lock'),
    )).toBe(true);
  });

  it('truthfully rejects a delayed generation when another account owns the destination', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({
        rows: [{
          id: 'row-new',
          user_id: 'f8679a96-0000-4000-8000-000000000099',
          apns_token: 'abc',
          environment: 'sandbox',
          platform: 'ios',
          enabled: true,
        }],
      });
    await expect(
      registerDeviceToken(USER_ID, 'abc', 'sandbox', 'ios', 'install-1', 2),
    ).rejects.toBeInstanceOf(DeviceTokenOwnershipConflictError);
    expect(poolMock.query).toHaveBeenCalledTimes(2);
  });

  it('gives generation-0 account switches a retryable conflict instead of a false 201', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({
        rows: [{
          id: 'current',
          user_id: 'f8679a96-0000-4000-8000-000000000099',
          apns_token: 'abc',
          environment: 'sandbox',
          platform: 'ios',
          enabled: true,
        }],
      });
    await expect(
      registerDeviceToken(USER_ID, 'abc', 'sandbox', 'ios', `legacy:${USER_ID}`, 0),
    ).rejects.toMatchObject({ code: 'device_token_ownership_conflict', retryable: true });
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('device_tokens.user_id = EXCLUDED.user_id');
    expect(sql).not.toContain('push_installation_fences');
  });

  it('treats a rejected stale refresh as success only when this account still owns an enabled row', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({
        rows: [{
          id: 'current',
          user_id: USER_ID,
          apns_token: 'abc',
          environment: 'sandbox',
          platform: 'ios',
          enabled: true,
        }],
      });

    await expect(
      registerDeviceToken(USER_ID, 'abc', 'sandbox', 'ios', 'install-1', 2),
    ).resolves.toMatchObject({ id: 'current' });
  });

  it('rejects a stale registration after this account has a newer sign-out tombstone', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({
        rows: [{
          id: 'current',
          user_id: USER_ID,
          apns_token: 'abc',
          environment: 'sandbox',
          platform: 'ios',
          enabled: false,
        }],
      });

    await expect(
      registerDeviceToken(USER_ID, 'abc', 'sandbox', 'ios', 'install-1', 2),
    ).rejects.toBeInstanceOf(DeviceTokenOwnershipConflictError);
  });

  it('lets a generation-0 account switch retry successfully after delayed unregister wins', async () => {
    const oldUserId = 'f8679a96-0000-4000-8000-000000000099';
    poolMock.query
      // New legacy account arrives before the old account's unregister.
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({
        rows: [{
          id: 'old-row',
          user_id: oldUserId,
          apns_token: 'abc',
          environment: 'sandbox',
          platform: 'ios',
          enabled: true,
        }],
      })
      // Delayed old-account unregister removes only its still-owned row.
      .mockResolvedValueOnce({ rowCount: 1, rows: [{ id: 'old-row' }] })
      // The new account retries after 409 and now owns the fresh insert.
      .mockResolvedValueOnce({
        rows: [{ id: 'new-row', apns_token: 'abc', environment: 'sandbox', platform: 'ios' }],
      });

    await expect(
      registerDeviceToken(USER_ID, 'abc', 'sandbox', 'ios', `legacy:${USER_ID}`, 0),
    ).rejects.toMatchObject({ retryable: true });
    await expect(unregisterDeviceToken(oldUserId, 'abc')).resolves.toBe(true);
    await expect(
      registerDeviceToken(USER_ID, 'abc', 'sandbox', 'ios', `legacy:${USER_ID}`, 0),
    ).resolves.toMatchObject({ id: 'new-row' });
  });
});

describe('disableDeviceToken', () => {
  beforeEach(() => vi.clearAllMocks());

  it('retains a generation tombstone so delayed registration cannot resubscribe after logout', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ fenced: true, disabled: true }] });
    expect(await disableDeviceToken(USER_ID, 'abc', 'install-1', 4)).toBe(true);
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('INSERT INTO push_installation_fences');
    expect(sql).toContain('DELETE FROM device_tokens');
    expect(sql).toContain('push_installation_fences.ownership_generation <= EXCLUDED.ownership_generation');
    expect(poolMock.query.mock.calls[0][1]).toEqual([USER_ID, 'abc', 'install-1', 4, false]);
    expect(poolMock.transactionQuery.mock.calls.some(
      ([statement]) => String(statement).startsWith('SELECT pg_advisory_xact_lock'),
    )).toBe(true);
  });

  it('persists the generation fence even when the rotated token row has not inserted yet', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ fenced: true, disabled: false }] });

    expect(await disableDeviceToken(USER_ID, 'fresh-token', 'install-1', 5)).toBe(true);
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('fenced_installation');
    expect(sql).toContain('EXISTS (SELECT 1 FROM fenced_installation)');
    expect(sql).toContain('WHERE $5::boolean');
  });

  it('retires a migrated legacy token in the same transaction as the new installation tombstone', async () => {
    poolMock.query.mockResolvedValueOnce({
      rows: [{ fenced: true, disabled: false, legacy_retired: true }],
    });

    expect(await disableDeviceToken(USER_ID, 'abc', 'install-1', 6, true)).toBe(true);
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('retired_legacy_destination');
    expect(sql).toContain("device_tokens.installation_id = 'legacy:' || $1::text");
    expect(poolMock.query.mock.calls[0][1]).toEqual([USER_ID, 'abc', 'install-1', 6, true]);
  });

  it('reports legacy retirement even if a newer account already owns the current installation', async () => {
    poolMock.query.mockResolvedValueOnce({
      rows: [{ fenced: false, disabled: false, legacy_retired: true }],
    });
    expect(await disableDeviceToken(USER_ID, 'abc', 'install-1', 6, true)).toBe(true);
  });

  it('does not let an older account fence a transferred installation', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ fenced: false, disabled: false }] });
    expect(await disableDeviceToken(USER_ID, 'abc', 'install-1', 4)).toBe(false);
  });

  it('preserves legacy exact-token unregister behavior without an installation fence', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 1, rows: [{ id: 'legacy-row' }] });
    expect(await disableDeviceToken(USER_ID, 'abc', `legacy:${USER_ID}`, 0)).toBe(true);
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('DELETE FROM device_tokens');
    expect(sql).not.toContain('push_installation_fences');
    expect(poolMock.query.mock.calls[0][1]).toEqual([USER_ID, 'abc']);
  });
});

describe('listDeviceTokens', () => {
  beforeEach(() => vi.clearAllMocks());

  it('fails current installations closed unless the strongest row matches the durable fence', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    await expect(listDeviceTokens(USER_ID)).resolves.toEqual([]);
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain('ROW_NUMBER() OVER');
    expect(sql).toContain('fence.user_id = destination.user_id');
    expect(sql).toContain('fence.ownership_generation = destination.ownership_generation');
    expect(sql).toContain("destination.installation_id LIKE 'legacy:%'");
    expect(sql).not.toContain('destination.installation_id IS NULL');
  });
});

describe('unregisterDeviceToken', () => {
  beforeEach(() => vi.clearAllMocks());

  it('returns true when a row was deleted', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 1, rows: [{ id: 'row-1' }] });
    expect(await unregisterDeviceToken(USER_ID, 'abc')).toBe(true);
  });

  it('returns false when nothing matched', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    expect(await unregisterDeviceToken(USER_ID, 'abc')).toBe(false);
  });
});

describe('sendPush no-op when unconfigured', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    clearApnsEnv();
  });
  afterEach(clearApnsEnv);

  it('isApnsConfigured is false with no creds', () => {
    expect(isApnsConfigured()).toBe(false);
  });

  it('does not query the DB or send when APNs is unconfigured', async () => {
    const results = await sendPush(USER_ID, { title: 'Hi', body: 'There' });
    expect(results).toEqual([]);
    // No-op short-circuits before ever loading device tokens.
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('isApnsConfigured stays false when only some creds are set', () => {
    process.env.APNS_KEY_ID = 'K';
    process.env.APNS_TEAM_ID = 'T';
    // bundle + key missing
    expect(isApnsConfigured()).toBe(false);
  });

  it('configured but no device tokens -> empty result, no APNs call', async () => {
    process.env.APNS_KEY_ID = 'KEYID';
    process.env.APNS_TEAM_ID = 'TEAMID';
    process.env.APNS_BUNDLE_ID = 'com.remapp.rem';
    process.env.APNS_AUTH_KEY = '-----BEGIN PRIVATE KEY-----\\nfake\\n-----END PRIVATE KEY-----';
    expect(isApnsConfigured()).toBe(true);
    poolMock.query.mockResolvedValueOnce({ rows: [] }); // listDeviceTokens
    const results = await sendPush(USER_ID, { title: 'Hi', body: 'There' });
    expect(results).toEqual([]);
    // Queried for tokens, found none, returned without opening an HTTP/2 session.
    expect(poolMock.query).toHaveBeenCalledTimes(1);
  });
});
