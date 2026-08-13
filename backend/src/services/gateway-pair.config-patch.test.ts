import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const websocketConstructions = vi.hoisted(() => ({ count: 0 }));
vi.mock('ws', () => ({
  default: class UnexpectedWebSocket {
    constructor() {
      websocketConstructions.count += 1;
      throw new Error('unexpected WebSocket mutation');
    }
  },
}));

import { patchGatewayConfigHttp } from './gateway-pair.service.js';

describe('patchGatewayConfigHttp activation acknowledgement', () => {
  beforeEach(() => { websocketConstructions.count = 0; });
  afterEach(() => vi.unstubAllGlobals());

  it('rejects before any transport mutation when activation cannot be proven', async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);

    await expect(patchGatewayConfigHttp(
      'https://gateway.example.com',
      'token',
      { browser: { ssrfPolicy: { hostnameAllowlist: ['discord.com'] } } },
      undefined,
      { requireActivated: true },
    )).rejects.toThrow('activation cannot be confirmed without gateway setup access');

    expect(fetchSpy).not.toHaveBeenCalled();
    expect(websocketConstructions.count).toBe(0);
  });

  it('returns activated only when the wrapper confirms restart and readback', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(
      JSON.stringify({ ok: true, activated: true }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )));

    await expect(patchGatewayConfigHttp(
      'https://gateway.example.com',
      'token',
      { browser: { enabled: true } },
      'setup-password',
      { requireActivated: true },
    )).resolves.toEqual({ activated: true });
  });

  it('rejects the legacy immediate restarting response when activation is required', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(
      JSON.stringify({ ok: true, restarting: true }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )));

    await expect(patchGatewayConfigHttp(
      'https://gateway.example.com',
      'token',
      { browser: { enabled: true } },
      'setup-password',
      { requireActivated: true },
    )).rejects.toThrow('activation was not confirmed');
  });

  it('keeps non-interactive callers compatible while exposing an unconfirmed result', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(
      JSON.stringify({ ok: true, restarting: true }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )));

    await expect(patchGatewayConfigHttp(
      'https://gateway.example.com',
      'token',
      { browser: { enabled: true } },
      'setup-password',
    )).resolves.toEqual({ activated: false });
  });
});
