// Structured JSON responses + privacy-preserving logging for the edge functions.
// Success and error bodies share a predictable shape so the iOS client can
// decode them generically. We never put JWTs, action links, tokens, or full
// recipient addresses into responses or logs.

import { corsHeaders } from "./cors.ts";

export interface ErrorBody {
  ok: false;
  error: string;          // safe, user-presentable message
  code?: string;          // machine-readable code
  retryAfterSeconds?: number;
  correlationId: string;
}

/** A thrown error carrying an HTTP status + safe public message. */
export class HttpError extends Error {
  status: number;
  code?: string;
  retryAfterSeconds?: number;
  constructor(status: number, message: string, opts?: { code?: string; retryAfterSeconds?: number }) {
    super(message);
    this.status = status;
    this.code = opts?.code;
    this.retryAfterSeconds = opts?.retryAfterSeconds;
  }
}

export function jsonResponse(body: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders, ...extraHeaders },
  });
}

export function errorResponse(err: unknown, correlationId: string): Response {
  if (err instanceof HttpError) {
    const body: ErrorBody = {
      ok: false,
      error: err.message,
      code: err.code,
      retryAfterSeconds: err.retryAfterSeconds,
      correlationId,
    };
    const headers = err.retryAfterSeconds
      ? { "Retry-After": String(err.retryAfterSeconds) }
      : {};
    return jsonResponse(body, err.status, headers);
  }
  // Unknown/unexpected error — never leak internals.
  const body: ErrorBody = {
    ok: false,
    error: "Something went wrong. Please try again.",
    code: "internal_error",
    correlationId,
  };
  return jsonResponse(body, 500);
}

/** A short correlation id for log<->response stitching (no PII). */
export function newCorrelationId(): string {
  return crypto.randomUUID().slice(0, 8);
}

/** Redact an email for logs: keep first char + domain, mask the rest. */
export function redactEmail(email: string): string {
  const [local, domain] = email.split("@");
  if (!domain) return "***";
  const head = local.slice(0, 1);
  return `${head}***@${domain}`;
}

/** Structured, redaction-friendly log line. Never pass secrets/tokens/links. */
export function logInfo(fn: string, correlationId: string, msg: string, extra: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ fn, cid: correlationId, msg, ...extra }));
}

export function logWarn(fn: string, correlationId: string, msg: string, extra: Record<string, unknown> = {}): void {
  console.warn(JSON.stringify({ fn, cid: correlationId, msg, ...extra }));
}
