/**
 * STAGING ONLY — synthetic stand-in for the Vercel API behind the staging gateway. It has no database, no business
 * routes and no production credentials, so nothing it returns can contain business data.
 *
 * It runs the exact verification code Vercel uses (src/auth/gateway-verify.ts) on each forwarded request and answers
 * with a verdict: trusted (+ the visitor IP), direct (no gateway headers), or refused (+ reason). It also reports which
 * header NAMES arrived (never values), the method, path, normalized query and the SHA-256 of the body it received.
 * VA_GATEWAY_SECRET / VA_GATEWAY_SECRET_PREVIOUS are Worker secrets (process.env via nodejs_compat), set per CI run.
 */
import { createHash } from 'node:crypto';
import { gatewayIp } from '../src/auth/gateway-verify.ts';

export default {
  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const raw = Buffer.from(await req.arrayBuffer());
    const headers: Record<string, string> = {};
    req.headers.forEach((v, k) => { headers[k] = v; });
    const r = { method: req.method, path: url.pathname, query: url.searchParams, headers, raw };
    const verify = () => {
      try { const ip = gatewayIp(r); return ip ? { verdict: 'trusted', ip } : { verdict: 'direct' }; }
      catch (e: any) { return { verdict: 'refused', status: e?.status ?? 500, reason: e?.details?.reason ?? 'error' }; }
    };
    const first = verify();
    // /__verify/replay: the same signed request presented a second time must be refused
    const second = url.pathname === '/__verify/replay' ? verify() : undefined;
    if (url.pathname === '/__verify/status-500') return new Response('{"synthetic":true}', { status: 500, headers: { 'content-type': 'application/json' } });
    return Response.json({
      synthetic: true, ...first, ...(second ? { replay: second } : {}),
      method: req.method, path: url.pathname, query: url.searchParams.toString(),
      bodySha256: createHash('sha256').update(raw).digest('base64url'),
      headerNames: Object.keys(headers).sort(),
    }, { headers: { 'cache-control': 'no-store' } });
  },
};
