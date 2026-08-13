import { describe, expect, it } from 'vitest';
import { extractClientInfo } from './client-info.js';

describe('extractClientInfo', () => {
  it('extracts client version and platform headers', () => {
    const req = {
      headers: {
        'x-client-version': '1.0+42',
        'x-client-platform': 'ios',
      },
    };

    expect(extractClientInfo(req as any)).toEqual({
      version: '1.0+42',
      platform: 'ios',
    });
  });

  it('falls back when headers are absent', () => {
    expect(extractClientInfo({ headers: {} } as any)).toEqual({
      version: '-',
      platform: '-',
    });
  });

  it('uses the first value when a proxy provides duplicate headers', () => {
    const req = {
      headers: {
        'x-client-version': ['1.0+42', '1.0+43'],
        'x-client-platform': ['ios', 'mac'],
      },
    };

    expect(extractClientInfo(req as any)).toEqual({
      version: '1.0+42',
      platform: 'ios',
    });
  });
});
