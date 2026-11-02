// JSON responses, the error shape every route returns, and security headers.

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }
}

const securityHeaders: Record<string, string> = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
};

export function json(
  body: unknown,
  requestId: string,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...securityHeaders, 'X-Request-Id': requestId, ...headers },
  });
}

/** A client-safe error: a stable code, a short message, the request id. */
export function errorResponse(error: ApiError, requestId: string): Response {
  return json(
    { error: { code: error.code, message: error.message, requestId } },
    requestId,
    error.status,
    error.headers,
  );
}

/** The caller's id if it is a sane token, else a fresh one. */
export function requestIdFor(request: Request): string {
  const given = request.headers.get('X-Request-Id');
  return given && /^[A-Za-z0-9-]{8,64}$/.test(given)
    ? given
    : crypto.randomUUID();
}

const maxBodyBytes = 4 * 1024;

/** Parses a small JSON object body (at most [maxBytes]), rejecting anything else. */
export async function readJsonBody(
  request: Request,
  maxBytes = maxBodyBytes,
): Promise<Record<string, unknown>> {
  const type = request.headers.get('Content-Type') ?? '';
  if (!type.toLowerCase().startsWith('application/json')) {
    throw new ApiError(415, 'unsupported_media_type', 'Expected JSON.');
  }
  const declared = Number(request.headers.get('Content-Length') ?? '0');
  if (declared > maxBytes) {
    throw new ApiError(413, 'payload_too_large', 'Request body too large.');
  }
  const text = await readLimited(request, maxBytes);
  let value: unknown;
  try {
    value = JSON.parse(text || '{}');
  } catch {
    throw new ApiError(400, 'invalid_json', 'Malformed JSON.');
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new ApiError(400, 'invalid_json', 'Expected a JSON object.');
  }
  return value as Record<string, unknown>;
}

/**
 * The body as text, stopping at [maxBytes] bytes: a body sent without
 * a Content-Length (chunked) is never read into memory in full.
 */
async function readLimited(request: Request, maxBytes: number): Promise<string> {
  if (!request.body) return '';
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel().catch(() => {});
      throw new ApiError(413, 'payload_too_large', 'Request body too large.');
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

/** A short printable string from a body field, or the fallback. */
export function shortText(value: unknown, max: number, fallback = ''): string {
  if (typeof value !== 'string') return fallback;
  const clean = value.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  return clean.slice(0, max);
}
