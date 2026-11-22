/**
 * Signed-request format shared by the Cloudflare gateway (api/cloudflare/gateway.ts, Web Crypto) and the Vercel API
 * (src/auth/ratelimit.ts, node:crypto). Pure string code — no platform APIs — so both sides build byte-identical input.
 *
 * Signature = base64url(HMAC-SHA256(VA_GATEWAY_SECRET, canonical)) where canonical binds:
 *   version, HTTP method, normalized path, normalized query, unix timestamp, per-request id (nonce), client IP,
 *   SHA-256 of the exact request body.
 * So a signature cannot be moved to another method, route, query, body or visitor, and expires after the window.
 */
export const GW_VERSION = 'va-gw-v2';
export const GW_HEADERS = { ip: 'x-va-gw-ip', ts: 'x-va-gw-ts', id: 'x-va-gw-id', sig: 'x-va-gw-sig' } as const;
/** accepted age of a signature; a little future skew is allowed for clock drift */
export const GW_MAX_AGE_S = 60;
export const GW_MAX_FUTURE_S = 10;
export const GW_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const GW_IP_RE = /^[0-9a-fA-F:.]{3,45}$/;

/** WHATWG-normalized query (identical on Workers and Node for the same URL) */
export const normQuery = (q: URLSearchParams) => q.toString();

export function canonical(p: { method: string; path: string; query: string; ts: string; id: string; ip: string; bodySha256: string }): string {
  return [GW_VERSION, p.method.toUpperCase(), p.path, p.query, p.ts, p.id, p.ip, p.bodySha256].join('\n');
}
