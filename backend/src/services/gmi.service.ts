/**
 * Shared GMI Cloud (MaaS) client.
 *
 * GMI serves an OpenAI-compatible chat-completions API at GMI_BASE_URL
 * (default https://api.gmi-serving.com/v1). This is the cheap, open-weights brain
 * Rem uses for high-volume, latency-tolerant work (cloud task runs, digests).
 *
 * The retired agentbox.service.ts predated this module and inlined its own GMI call plus
 * the GMI_AGENTBOX_URL hero path; new callers should use gmiChat() so there is one
 * place that knows the base URL, default model, auth header, and timeout.
 *
 * Dependency-free: uses global fetch (Node 18+).
 */

export interface GmiChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface GmiChatOptions {
  temperature?: number;
  maxTokens?: number;
  model?: string;
  timeoutMs?: number;
}

export interface GmiChatResult {
  content: string;
  model: string;
}

export const DEFAULT_GMI_BASE_URL = 'https://api.gmi-serving.com/v1';
export const DEFAULT_GMI_MODEL = 'nvidia/nemotron-3-ultra-550b-a55b';

/**
 * Thrown when GMI returns a 2xx response whose completion is empty / whitespace-only. This is a
 * *transient model no-op* — the HTTP request itself succeeded, the model just produced nothing —
 * which is categorically different from a transport/auth/HTTP failure. Callers that must not
 * hard-fail on a model shrug (e.g. the nightly memory-extraction batch) can catch this via
 * `instanceof` and treat it as a SKIP, while still surfacing genuine errors. Structured signal
 * over string-matching the message (see CLAUDE.md decision principle 5).
 */
export class GmiEmptyCompletionError extends Error {
  constructor(message = 'GMI MaaS returned an empty completion') {
    super(message);
    this.name = 'GmiEmptyCompletionError';
  }
}

/** True when a GMI API key is configured and gmiChat() can actually reach GMI. */
export function isGmiConfigured(): boolean {
  return Boolean(process.env.GMI_API_KEY?.trim());
}

function gmiBaseUrl(): string {
  return process.env.GMI_BASE_URL?.trim() || DEFAULT_GMI_BASE_URL;
}

function gmiModel(override?: string): string {
  return override?.trim() || process.env.GMI_MODEL?.trim() || DEFAULT_GMI_MODEL;
}

/**
 * Call GMI MaaS chat-completions and return the assistant text + the model used.
 * Throws on missing key, transport error, non-2xx, or empty completion — callers
 * that must never hard-fail (digests, agent runs) are expected to catch and fall back.
 */
export async function gmiChat(
  messages: GmiChatMessage[],
  opts: GmiChatOptions = {},
): Promise<GmiChatResult> {
  const apiKey = process.env.GMI_API_KEY?.trim();
  if (!apiKey) throw new Error('GMI_API_KEY is not set');

  const model = gmiModel(opts.model);
  const timeoutMs = opts.timeoutMs ?? 30_000;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${gmiBaseUrl()}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model,
        messages,
        temperature: opts.temperature ?? 0.4,
        max_tokens: opts.maxTokens ?? 600,
      }),
      signal: controller.signal,
    });

    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(`GMI MaaS responded ${res.status}: ${text.slice(0, 300)}`);
    }

    const data = (await res.json()) as {
      choices?: Array<{ message?: { content?: unknown } }>;
    };
    const content = data.choices?.[0]?.message?.content;
    const text = typeof content === 'string' ? content.trim() : '';
    if (!text) throw new GmiEmptyCompletionError();

    return { content: text, model };
  } finally {
    clearTimeout(timer);
  }
}
