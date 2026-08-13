import { webcrypto } from 'node:crypto';

// Composio's SDK (@composio/core / @composio/client) uses the Web Crypto global
// `crypto.randomUUID()`. That global is undefined on Node runtimes where
// `globalThis.crypto` isn't exposed (no Node version is pinned here, so Railway's
// default can be one of those), which surfaced as
// "Cannot read properties of undefined (reading 'randomUUID')" on GET /composio/toolkits.
//
// Polyfill it before anything that might touch it. This module is imported FIRST in
// server.ts so it runs ahead of the Composio route/SDK module initialization.
if (!globalThis.crypto) {
  (globalThis as unknown as { crypto: Crypto }).crypto = webcrypto as unknown as Crypto;
}
