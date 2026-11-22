/**
 * VALUNIVO Cloudflare gateway — a restricted edge layer in front of the Vercel API (the authoritative backend).
 *
 * What it does:
 *  - forwards every API request unchanged (method, path, query, body, Authorization) to UPSTREAM (Vercel);
 *  - removes client-supplied headers that could impersonate the platform or the gateway (forwarding / IP / cf-* /
 *    x-va-gw-*), then passes the visitor's real address (CF-Connecting-IP, written by Cloudflare's edge) to Vercel,
 *    HMAC-signed with VA_GATEWAY_SECRET so Vercel's per-IP sign-in throttle sees each visitor instead of Cloudflare;
 *  - never caches: the subrequest is made with cache "no-store" and every response leaves with Cache-Control: no-store;
 *  - rejects obviously invalid traffic early (unknown methods, bodies over the API's own 8 MiB limit) and, if an
 *    AUTH_RL rate-limit binding is configured, adds an approximate per-IP edge limit on sign-in / recovery routes.
 *
 * What it never does: hold database credentials or bindings, read or log request/response bodies, tokens or query
 * strings, make authorization decisions, or fall back to another backend on its own. If Vercel cannot be reached the
 * gateway answers 502/504 and the app's existing behaviour (try the next API address — Vercel directly) applies.
 * Vercel enforces authentication, authorization and throttling itself, whether or not traffic came through here.
 */

export interface Env {
  UPSTREAM?: string;
  VA_GATEWAY_SECRET?: string;
  AUTH_RL?: { limit(o: { key: string }): Promise<{ success: boolean }> };
}

const MAX_BODY = 8 * 1024 * 1024; // same as the API (src/http/router.ts)
const METHODS = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']);
const UPSTREAM_TIMEOUT_MS = 25_000;
/** POST routes where guessing is possible: an approximate extra edge limit (Vercel's database-backed limit stays authoritative) */
export const AUTH_PATHS = new Set(['/auth/login', '/auth/forgot', '/auth/forgot/verify', '/auth/forgot/reset']);
/** request headers that are dropped before forwarding */
const STRIP = [/^x-va-gw-/, /^x-forwarded-/, /^forwarded$/, /^x-real-ip$/, /^x-vercel-/, /^true-client-ip$/, /^x-client-ip$/,
  /^cf-/, /^cdn-loop$/, /^host$/, /^connection$/, /^keep-alive$/, /^te$/, /^upgrade$/, /^proxy-/];
const IP_RE = /^[0-9a-fA-F:.]{3,45}$/;

const json = (status: number, code: string, message: string) => new Response(JSON.stringify({ error: { code, message } }),
  { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });

const b64url = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/** same value as gatewaySignature() in src/auth/ratelimit.ts (HMAC-SHA256, base64url) */
export async function sign(secret: string, ts: string, ip: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64url(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`va-gw-v1\n${ts}\n${ip}`)));
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const upstream = (env.UPSTREAM ?? '').replace(/\/+$/, '');
    if (!/^https:\/\/[a-z0-9.-]+$/i.test(upstream)) return json(503, 'not_configured', 'Gateway upstream is not configured');
    if (!METHODS.has(req.method)) return json(405, 'method_not_allowed', 'Method not allowed');
    const url = new URL(req.url);
    if (url.pathname === '/__gateway/health') return new Response(JSON.stringify({ ok: true }), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

    const declared = Number(req.headers.get('content-length') ?? 0);
    if (declared > MAX_BODY) return json(413, 'payload_too_large', 'Request body too large');

    const ipRaw = (req.headers.get('cf-connecting-ip') ?? '').trim();
    const ip = IP_RE.test(ipRaw) ? ipRaw : null;

    if (env.AUTH_RL && req.method === 'POST' && AUTH_PATHS.has(url.pathname) && ip) {
      const { success } = await env.AUTH_RL.limit({ key: `${ip}|${url.pathname}` });
      if (!success) return json(429, 'rate_limited', 'Too many attempts from this network. Try again later');
    }

    const headers = new Headers();
    req.headers.forEach((v, k) => { if (!STRIP.some((re) => re.test(k))) headers.set(k, v); });
    const secret = env.VA_GATEWAY_SECRET ?? '';
    if (ip && secret.length >= 32) {
      const ts = String(Math.floor(Date.now() / 1000));
      headers.set('x-va-gw-ip', ip);
      headers.set('x-va-gw-ts', ts);
      headers.set('x-va-gw-sig', await sign(secret, ts, ip));
    }

    let body: ArrayBuffer | undefined;
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      body = await req.arrayBuffer();
      if (body.byteLength > MAX_BODY) return json(413, 'payload_too_large', 'Request body too large');
    }

    let res: Response;
    try {
      res = await fetch(upstream + url.pathname + url.search, {
        method: req.method, headers, body, redirect: 'manual', cache: 'no-store',
        signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
      });
    } catch (e: any) {
      return e?.name === 'TimeoutError'
        ? json(504, 'upstream_timeout', 'The API did not answer in time')
        : json(502, 'upstream_unavailable', 'The API cannot be reached');
    }
    const out = new Headers(res.headers);
    out.set('Cache-Control', 'no-store');
    return new Response(req.method === 'HEAD' ? null : res.body, { status: res.status, statusText: res.statusText, headers: out });
  },
};
