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
  signal?: AbortSignal;
  /** OpenAI-compatible function definitions available to this completion. */
  tools?: readonly GmiToolDefinition[];
}

export interface GmiToolDefinition {
  type: 'function';
  function: {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  };
}

export interface GmiToolCall {
  name: string;
  toolCallId?: string;
  args?: unknown;
}

export interface GmiChatResult {
  content: string;
  model: string;
  toolCalls: GmiToolCall[];
  usage: {
    promptTokens: number;
    completionTokens: number;
    totalTokens: number;
  } | null;
}

const MAX_TOOL_CALLS = 16;
const MAX_TOOL_ARGUMENT_CHARS = 64 * 1024;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Parse only the OpenAI-compatible function-call shape. Malformed calls are ignored rather than
 * guessed at; the runtime's own allow-list/schema validator is the next and authoritative gate.
 */
function parseToolCalls(value: unknown): GmiToolCall[] {
  if (!Array.isArray(value)) return [];
  const calls: GmiToolCall[] = [];
  for (const candidate of value.slice(0, MAX_TOOL_CALLS)) {
    if (!isRecord(candidate) || candidate.type !== 'function' || !isRecord(candidate.function)) {
      continue;
    }
    const name = candidate.function.name;
    if (typeof name !== 'string' || !name.trim()) continue;
    const rawArguments = candidate.function.arguments;
    if (typeof rawArguments !== 'string' || rawArguments.length > MAX_TOOL_ARGUMENT_CHARS) continue;
    let args: unknown;
    try {
      args = JSON.parse(rawArguments);
    } catch {
      continue;
    }
    const id = typeof candidate.id === 'string' && candidate.id.trim()
      ? candidate.id.trim().slice(0, 256)
      : undefined;
    calls.push({
      name: name.trim().slice(0, 128),
      ...(id ? { toolCallId: id } : {}),
      args,
    });
  }
  return calls;
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
  constructor(
    message = 'GMI MaaS returned an empty completion',
    /** Billing evidence from the successful HTTP response, when the provider supplied it. */
    readonly completion?: GmiChatResult,
  ) {
    super(message);
    this.name = 'GmiEmptyCompletionError';
  }
}

export class GmiTimeoutError extends Error {
  constructor() {
    super('GMI MaaS request timed out');
    this.name = 'GmiTimeoutError';
  }
}

export class GmiCancelledError extends Error {
  constructor() {
    super('GMI MaaS request was cancelled');
    this.name = 'GmiCancelledError';
  }
}

export class GmiCredentialError extends Error {
  constructor(message = 'GMI MaaS rejected its credential') {
    super(message);
    this.name = 'GmiCredentialError';
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
  if (!apiKey) throw new GmiCredentialError('GMI_API_KEY is not set');

  const model = gmiModel(opts.model);
  const timeoutMs = opts.timeoutMs ?? 30_000;

  const controller = new AbortController();
  let timedOut = false;
  const cancel = () => controller.abort();
  opts.signal?.addEventListener('abort', cancel, { once: true });
  if (opts.signal?.aborted) cancel();
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
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
        ...(opts.tools?.length ? { tools: opts.tools } : {}),
      }),
      signal: controller.signal,
    });

    if (!res.ok) {
      const text = await res.text().catch(() => '');
      if (res.status === 401 || res.status === 403) throw new GmiCredentialError();
      throw new Error(`GMI MaaS responded ${res.status}: ${text.slice(0, 300)}`);
    }

    const data = (await res.json()) as {
      choices?: Array<{ message?: { content?: unknown; tool_calls?: unknown } }>;
      usage?: {
        prompt_tokens?: unknown;
        completion_tokens?: unknown;
        total_tokens?: unknown;
      };
    };
    const content = data.choices?.[0]?.message?.content;
    const text = typeof content === 'string' ? content.trim() : '';
    const toolCalls = parseToolCalls(data.choices?.[0]?.message?.tool_calls);

    const promptTokens = data.usage?.prompt_tokens;
    const completionTokens = data.usage?.completion_tokens;
    const totalTokens = data.usage?.total_tokens;
    const usage =
      typeof promptTokens === 'number' && Number.isFinite(promptTokens) &&
      typeof completionTokens === 'number' && Number.isFinite(completionTokens)
        ? {
            promptTokens,
            completionTokens,
            totalTokens: typeof totalTokens === 'number' && Number.isFinite(totalTokens)
              ? totalTokens
              : promptTokens + completionTokens,
          }
        : null;

    if (!text && toolCalls.length === 0) {
      throw new GmiEmptyCompletionError(undefined, {
        content: '',
        model,
        toolCalls: [],
        usage,
      });
    }

    return { content: text, model, toolCalls, usage };
  } catch (error: unknown) {
    if (controller.signal.aborted) {
      if (opts.signal?.aborted) throw new GmiCancelledError();
      if (timedOut) throw new GmiTimeoutError();
    }
    throw error;
  } finally {
    clearTimeout(timer);
    opts.signal?.removeEventListener('abort', cancel);
  }
}
