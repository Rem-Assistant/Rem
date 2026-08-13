import { Request } from 'express';

export interface ClientInfo {
  version: string;
  platform: string;
}

export function extractClientInfo(req: Request): ClientInfo {
  return {
    version: headerValue(req, 'x-client-version') ?? '-',
    platform: headerValue(req, 'x-client-platform') ?? '-',
  };
}

function headerValue(req: Request, name: string): string | null {
  const value = req.headers[name];
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}
