import { describe, expect, it, vi } from 'vitest';

vi.mock('../db/pool.js', () => ({ pool: { connect: vi.fn() } }));
vi.mock('../services/gateway-agent.service.js', () => ({
  readAssistantHistoryOnGateway: vi.fn(),
}));
import {
  assertStagingEnvironment,
  parseRepairArguments,
  STAGING_RAILWAY_ENVIRONMENT_ID,
} from './repair-canonical-brief.js';

describe('repair-canonical-brief CLI safety', () => {
  it('defaults to dry-run and accepts explicit identity fields', () => {
    expect(parseRepairArguments([
      '--user-id', 'user-id',
      '--local-day', '2026-08-08',
      '--digest', 'abc',
      '--message-id', 'message-1',
    ])).toEqual({
      userId: 'user-id',
      localDay: '2026-08-08',
      digest: 'abc',
      messageId: 'message-1',
      commit: false,
    });
  });

  it('requires the exact staging Railway environment', () => {
    expect(() => assertStagingEnvironment({
      RAILWAY_ENVIRONMENT_NAME: 'production',
      RAILWAY_ENVIRONMENT_ID: STAGING_RAILWAY_ENVIRONMENT_ID,
    }))
      .toThrow('refusing to run outside');
    expect(() => assertStagingEnvironment({}))
      .toThrow('refusing to run outside');
    expect(() => assertStagingEnvironment({
      RAILWAY_ENVIRONMENT_NAME: 'staging',
      RAILWAY_ENVIRONMENT_ID: 'f2d6a18a-2bef-47c6-80bd-782785da1e1f',
    })).toThrow('refusing to run outside');
    expect(() => assertStagingEnvironment({
      RAILWAY_ENVIRONMENT_NAME: 'staging',
      RAILWAY_ENVIRONMENT_ID: STAGING_RAILWAY_ENVIRONMENT_ID,
    }))
      .not.toThrow();
  });
});
