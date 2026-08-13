import http from 'node:http';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { WebSocketServer } from 'ws';
import {
  ApprovalCheckTimeoutError,
  ApprovalRetryFailedError,
  autoApproveDevices,
  autoApproveDevicesHttp,
  NoPendingPairingRequestError,
  patchGatewayConfig,
  logoutGatewayChannel,
  withGatewayRequester,
} from './gateway-pair.service.js';

let server: http.Server | null = null;

afterEach(async () => {
  vi.restoreAllMocks();

  if (!server) return;

  await new Promise<void>((resolve) => {
    server?.close(() => resolve());
  });
  server = null;
});

describe('gateway pair service approval scopes', () => {
  it('uses upstream channels.logout with the exact channel identifier', async () => {
    server = http.createServer();
    const wss = new WebSocketServer({ server });
    let logoutParams: Record<string, unknown> | null = null;

    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'event', event: 'connect.challenge' }));
      ws.on('message', (raw) => {
        const frame = JSON.parse(raw.toString());
        if (frame.method === 'connect') {
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
          return;
        }
        if (frame.method === 'channels.logout') {
          logoutParams = frame.params;
          ws.send(JSON.stringify({
            type: 'res',
            id: frame.id,
            ok: true,
            payload: { channel: 'whatsapp', accountId: 'default', cleared: true },
          }));
          return;
        }
        if (frame.method === 'channels.status') {
          ws.send(JSON.stringify({
            type: 'res',
            id: frame.id,
            ok: true,
            payload: {
              channelAccounts: { whatsapp: [{ accountId: 'default', linked: false }] },
            },
          }));
        }
      });
    });

    await new Promise<void>((resolve) => server?.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Expected server address info');

    await expect(logoutGatewayChannel(
      `http://127.0.0.1:${address.port}`,
      'gateway-token',
      'whatsapp',
      'setup-password',
    )).resolves.toBeUndefined();
    expect(logoutParams).toEqual({ channel: 'whatsapp' });
  }, 10_000);

  it('accepts an already-cleared account only after status proves it is unlinked', async () => {
    server = http.createServer();
    const wss = new WebSocketServer({ server });

    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'event', event: 'connect.challenge' }));
      ws.on('message', (raw) => {
        const frame = JSON.parse(raw.toString());
        if (frame.method === 'connect') {
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
          return;
        }
        if (frame.method === 'channels.logout') {
          ws.send(JSON.stringify({
            type: 'res', id: frame.id, ok: true,
            payload: { channel: 'whatsapp', accountId: 'default', cleared: false, loggedOut: false },
          }));
          return;
        }
        if (frame.method === 'channels.status') {
          ws.send(JSON.stringify({
            type: 'res', id: frame.id, ok: true,
            payload: {
              channelAccounts: { whatsapp: [{ accountId: 'default', linked: false }] },
            },
          }));
        }
      });
    });

    await new Promise<void>((resolve) => server?.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Expected server address info');

    await expect(logoutGatewayChannel(
      `http://127.0.0.1:${address.port}`,
      'gateway-token',
      'whatsapp',
      'setup-password',
    )).resolves.toBeUndefined();
  }, 10_000);

  it('rejects logout when guarded cleanup leaves the account linked', async () => {
    server = http.createServer();
    const wss = new WebSocketServer({ server });

    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'event', event: 'connect.challenge' }));
      ws.on('message', (raw) => {
        const frame = JSON.parse(raw.toString());
        if (frame.method === 'connect') {
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
          return;
        }
        if (frame.method === 'channels.logout') {
          ws.send(JSON.stringify({
            type: 'res', id: frame.id, ok: true,
            payload: { channel: 'whatsapp', accountId: 'default', cleared: false, loggedOut: false },
          }));
          return;
        }
        if (frame.method === 'channels.status') {
          ws.send(JSON.stringify({
            type: 'res', id: frame.id, ok: true,
            payload: {
              channelAccounts: { whatsapp: [{ accountId: 'default', linked: true }] },
            },
          }));
        }
      });
    });

    await new Promise<void>((resolve) => server?.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Expected server address info');

    await expect(logoutGatewayChannel(
      `http://127.0.0.1:${address.port}`,
      'gateway-token',
      'whatsapp',
      'setup-password',
    )).rejects.toThrow('Channel credentials remain linked after logout (whatsapp:default)');
  }, 10_000);

  it('surfaces an upstream channels.logout rejection', async () => {
    server = http.createServer();
    const wss = new WebSocketServer({ server });

    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'event', event: 'connect.challenge' }));
      ws.on('message', (raw) => {
        const frame = JSON.parse(raw.toString());
        if (frame.method === 'connect') {
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
          return;
        }
        if (frame.method === 'channels.logout') {
          ws.send(JSON.stringify({
            type: 'res', id: frame.id, ok: false, error: { message: 'credential cleanup failed' },
          }));
        }
      });
    });

    await new Promise<void>((resolve) => server?.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Expected server address info');

    await expect(logoutGatewayChannel(
      `http://127.0.0.1:${address.port}`,
      'gateway-token',
      'whatsapp',
      'setup-password',
    )).rejects.toThrow('channels.logout failed (whatsapp): credential cleanup failed');
  }, 10_000);

  it('connects with operator.admin and approves pending devices', async () => {
    server = http.createServer();
    const wss = new WebSocketServer({ server });

    let connectScopes: string[] = [];
    let approvedRequestId: string | null = null;

    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'event', event: 'connect.challenge' }));

      ws.on('message', (raw) => {
        const frame = JSON.parse(raw.toString());

        if (frame.method === 'connect') {
          connectScopes = frame.params.scopes;
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
          return;
        }

        if (frame.method === 'device.pair.list') {
          ws.send(JSON.stringify({
            type: 'res',
            id: frame.id,
            ok: true,
            payload: { pending: [{ requestId: 'pair-1', deviceId: 'node-1' }] },
          }));
          return;
        }

        if (frame.method === 'device.pair.approve') {
          approvedRequestId = frame.params.requestId;
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
        }
      });
    });

    await new Promise<void>((resolve) => {
      server?.listen(0, '127.0.0.1', resolve);
    });

    const address = server.address();
    if (!address || typeof address === 'string') {
      throw new Error('Expected server address info');
    }

    await expect(autoApproveDevices(`http://127.0.0.1:${address.port}`, 'gateway-token', 'setup-password'))
      .resolves.toBe(1);

    expect(connectScopes).toEqual(expect.arrayContaining([
      'operator.pairing',
      'operator.admin',
    ]));
    expect(approvedRequestId).toBe('pair-1');
  }, 10_000);

  it('does not count a rejected approval response as an approved device', async () => {
    server = http.createServer();
    const wss = new WebSocketServer({ server });

    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'event', event: 'connect.challenge' }));
      ws.on('message', (raw) => {
        const frame = JSON.parse(raw.toString());
        if (frame.method === 'connect') {
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
          return;
        }
        if (frame.method === 'device.pair.list') {
          ws.send(JSON.stringify({
            type: 'res', id: frame.id, ok: true,
            payload: { pending: [{ requestId: 'pair-rejected', deviceId: 'node-1' }] },
          }));
          return;
        }
        if (frame.method === 'device.pair.approve') {
          ws.send(JSON.stringify({
            type: 'res', id: frame.id, ok: false,
            error: { message: 'approval denied' },
          }));
        }
      });
    });

    await new Promise<void>((resolve) => { server?.listen(0, '127.0.0.1', resolve); });
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Expected server address info');

    await expect(autoApproveDevices(
      `http://127.0.0.1:${address.port}`,
      'gateway-token',
      'setup-password',
      25,
      5
    )).rejects.toBeInstanceOf(ApprovalCheckTimeoutError);
  }, 10_000);

  // Regression guard for #1087's live-test failure: "Connect rejected: protocol mismatch".
  // Root cause was a single fixed PROTOCOL_VERSION (3) sent as BOTH minProtocol and maxProtocol,
  // which a v4 gateway's `maxProtocol >= <gateway protocol>` handshake gate rejects outright. This
  // server mimics that real gateway gate (openclaw/src/gateway/server/ws-connection/
  // message-handler.ts `supportsCurrentProtocol`) so the test actually fails if this file ever
  // regresses to a fixed/stale version again — a config.get that merely "resolves" wouldn't catch
  // that if the mock server always accepted `connect` unconditionally.
  it('sends a minProtocol/maxProtocol RANGE that a v4 gateway accepts (regression: #1087 protocol mismatch)', async () => {
    server = http.createServer();
    const wss = new WebSocketServer({ server });
    const GATEWAY_PROTOCOL_VERSION = 4; // mirrors openclaw/src/gateway/protocol/version.ts at the pinned ref
    let seenConnectParams: { minProtocol: number; maxProtocol: number } | null = null;

    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'event', event: 'connect.challenge' }));
      ws.on('message', (raw) => {
        const frame = JSON.parse(raw.toString());
        if (frame.method === 'connect') {
          const { minProtocol, maxProtocol } = frame.params;
          seenConnectParams = { minProtocol, maxProtocol };
          const supportsCurrentProtocol =
            maxProtocol >= GATEWAY_PROTOCOL_VERSION && minProtocol <= GATEWAY_PROTOCOL_VERSION;
          if (!supportsCurrentProtocol) {
            ws.send(JSON.stringify({
              type: 'res',
              id: frame.id,
              ok: false,
              error: { message: 'protocol mismatch' },
            }));
            return;
          }
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
          return;
        }
        if (frame.method === 'config.get') {
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true, payload: { hash: 'hash-1' } }));
          return;
        }
        if (frame.method === 'config.patch') {
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
        }
      });
    });

    await new Promise<void>((resolve) => { server?.listen(0, '127.0.0.1', resolve); });
    const address = server.address();
    if (!address || typeof address === 'string') {
      throw new Error('Expected server address info');
    }

    await expect(
      patchGatewayConfig(`http://127.0.0.1:${address.port}`, 'gateway-token', { mcp: { servers: {} } }, 'setup-password')
    ).resolves.toBeUndefined();

    expect(seenConnectParams).not.toBeNull();
    expect(seenConnectParams!.maxProtocol).toBeGreaterThanOrEqual(GATEWAY_PROTOCOL_VERSION);
    expect(seenConnectParams!.minProtocol).toBeLessThanOrEqual(GATEWAY_PROTOCOL_VERSION);
  }, 10_000);

  it('throws when no pending pairing request is approved', async () => {
    server = http.createServer();
    const wss = new WebSocketServer({ server });

    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'event', event: 'connect.challenge' }));

      ws.on('message', (raw) => {
        const frame = JSON.parse(raw.toString());

        if (frame.method === 'connect') {
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
          return;
        }

        if (frame.method === 'device.pair.list') {
          ws.send(JSON.stringify({
            type: 'res',
            id: frame.id,
            ok: true,
            payload: { pending: [] },
          }));
        }
      });
    });

    await new Promise<void>((resolve) => {
      server?.listen(0, '127.0.0.1', resolve);
    });

    const address = server.address();
    if (!address || typeof address === 'string') {
      throw new Error('Expected server address info');
    }

    await expect(
      autoApproveDevices(
        `http://127.0.0.1:${address.port}`,
        'gateway-token',
        'setup-password',
        25,
        5
      )
    ).rejects.toBeInstanceOf(NoPendingPairingRequestError);
  }, 10_000);

  it('approves pending devices through the setup HTTP endpoint', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(
      JSON.stringify({ ok: true, approved: 2 }),
      { status: 200, headers: { 'Content-Type': 'application/json' } }
    ));

    await expect(
      autoApproveDevicesHttp('https://gateway.example', 'gateway-token', 'setup-password', 25, 5)
    ).resolves.toBe(2);

    expect(fetch).toHaveBeenCalledWith(
      'https://gateway.example/setup/api/approve-all',
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({
          Authorization: expect.stringMatching(/^Basic /),
        }),
      })
    );
  });

  it('reports no pending request only after a successful empty HTTP check', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(
      JSON.stringify({ ok: true, approved: 0 }),
      { status: 200, headers: { 'Content-Type': 'application/json' } }
    ));

    await expect(
      autoApproveDevicesHttp('https://gateway.example', 'gateway-token', 'setup-password', 25, 5)
    ).rejects.toBeInstanceOf(NoPendingPairingRequestError);
  });

  it('falls back to the ranged WebSocket client when an old wrapper reports protocol mismatch', async () => {
    server = http.createServer();
    const wss = new WebSocketServer({ server });
    let approvedRequestId: string | null = null;

    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'event', event: 'connect.challenge' }));
      ws.on('message', (raw) => {
        const frame = JSON.parse(raw.toString());
        if (frame.method === 'connect') {
          const supportsV4 = frame.params.minProtocol <= 4 && frame.params.maxProtocol >= 4;
          ws.send(JSON.stringify({
            type: 'res', id: frame.id, ok: supportsV4,
            error: supportsV4 ? undefined : { message: 'protocol mismatch' },
          }));
          return;
        }
        if (frame.method === 'device.pair.list') {
          ws.send(JSON.stringify({
            type: 'res', id: frame.id, ok: true,
            payload: { pending: [{ requestId: 'pair-stale-wrapper', deviceId: 'node-1' }] },
          }));
          return;
        }
        if (frame.method === 'device.pair.approve') {
          approvedRequestId = frame.params.requestId;
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
        }
      });
    });

    await new Promise<void>((resolve) => { server?.listen(0, '127.0.0.1', resolve); });
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Expected server address info');

    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      JSON.stringify({ ok: false, error: 'Error: Connect rejected: protocol mismatch' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    ));

    await expect(autoApproveDevicesHttp(
      `http://127.0.0.1:${address.port}`,
      'gateway-token',
      'setup-password',
      5_000,
      5
    )).resolves.toBe(1);
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(approvedRequestId).toBe('pair-stale-wrapper');
  }, 10_000);

  it('classifies repeated HTTP auth failures as approval retry failures', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(
      'bad setup password',
      { status: 401 }
    ));

    const approval = autoApproveDevicesHttp('https://gateway.example', 'gateway-token', 'setup-password', 25, 5);

    await expect(approval).rejects.toBeInstanceOf(ApprovalRetryFailedError);
    await expect(approval).rejects.toThrow('approve-all HTTP 401');
  });

  it('keeps transient HTTP failures as approval still pending', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(
      'gateway warming',
      { status: 503 }
    ));

    const approval = autoApproveDevicesHttp('https://gateway.example', 'gateway-token', 'setup-password', 25, 5);

    await expect(approval).rejects.toBeInstanceOf(ApprovalCheckTimeoutError);
    await expect(approval).rejects.toThrow('approve-all HTTP 503');
  });
});

describe('withGatewayRequester long-lived operator socket', () => {
  afterEach(() => { delete process.env.GATEWAY_WS_HEARTBEAT_MS; });

  it('sends WS ping heartbeats while a turn is in flight, then delivers the async final', async () => {
    // Drive the heartbeat down so the test does not have to wait 25s. We assert
    // the server observes pings while `fn` is held open (the keep-alive that
    // stops Fly/http-proxy from dropping the socket mid-turn — the root of the
    // "gateway connection closed before final" failure) AND that the delayed
    // canonical-key `chat` final still reaches the event tap.
    process.env.GATEWAY_WS_HEARTBEAT_MS = '30';

    server = http.createServer();
    const wss = new WebSocketServer({ server });
    let pings = 0;

    wss.on('connection', (ws) => {
      ws.on('ping', () => { pings += 1; });
      ws.send(JSON.stringify({ type: 'event', event: 'connect.challenge' }));
      ws.on('message', (raw) => {
        const frame = JSON.parse(raw.toString());
        if (frame.method === 'connect') {
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
        }
      });
    });

    await new Promise<void>((resolve) => server?.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Expected server address info');

    let received: { event: string; payload: any } | null = null;
    const result = await withGatewayRequester<string>(
      `http://127.0.0.1:${address.port}`,
      'gateway-token',
      async (_request, { onEvent }) => {
        onEvent((event, payload) => { received = { event, payload }; });
        // Hold the connection open ~250ms (several heartbeat intervals) while the
        // "turn" runs, then the server pushes a canonical-key chat final.
        return await new Promise<string>((resolve) => {
          const conn = [...wss.clients][0];
          setTimeout(() => {
            conn?.send(JSON.stringify({
              type: 'event',
              event: 'chat',
              payload: { runId: 'r1', sessionKey: 'agent:main:rem-canary-u1', state: 'final' },
            }));
          }, 150);
          setTimeout(() => resolve('done'), 250);
        });
      },
      'setup-password',
      5_000,
    );

    expect(result).toBe('done');
    expect(pings).toBeGreaterThan(0); // heartbeat kept the socket warm
    expect(received).toEqual({
      event: 'chat',
      payload: { runId: 'r1', sessionKey: 'agent:main:rem-canary-u1', state: 'final' },
    });
  }, 10_000);

  it('rejects when the gateway closes before an RPC response arrives', async () => {
    server = http.createServer();
    const wss = new WebSocketServer({ server });

    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'event', event: 'connect.challenge' }));
      ws.on('message', (raw) => {
        const frame = JSON.parse(raw.toString());
        if (frame.method === 'connect') {
          ws.send(JSON.stringify({ type: 'res', id: frame.id, ok: true }));
          return;
        }
        ws.close();
      });
    });

    await new Promise<void>((resolve) => server?.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('Expected server address info');
    const gatewayUrl = `http://127.0.0.1:${address.port}`;

    await expect(withGatewayRequester(
      gatewayUrl,
      'gateway-token',
      async (request) => await request('config.get', {}),
      'setup-password',
      5_000,
    )).rejects.toThrow(
      `Gateway WebSocket closed before the pending operation completed (${gatewayUrl})`,
    );
  }, 10_000);
});
