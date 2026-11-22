import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import { AppError } from '../http/errors.ts';
import type { Req } from '../http/router.ts';
import { GW_HEADERS, GW_ID_RE, GW_IP_RE, GW_MAX_AGE_S, GW_MAX_FUTURE_S, canonical, normQuery } from '../lib/gateway-sig.ts';

const header = (req: Pick<Req, 'headers'>, k: string) => { const v = req.headers[k]; return String(Array.isArray(v) ? v[0] : v ?? ''); };

/**
 * Requests that come through the Cloudflare gateway (api/cloudflare/gateway.ts) reach Vercel from Cloudflare's own
 * addresses, so every employee would share one "IP". The gateway therefore passes the visitor's address
 * (CF-Connecting-IP, set by Cloudflare's edge) in a signed envelope (src/lib/gateway-sig.ts: method, path, query,
 * timestamp, request id, IP, body hash — HMAC with VA_GATEWAY_SECRET, known only to the gateway and Vercel).
 *
 *  - Feature off (no secret ≥ 32 chars on Vercel): gateway headers are ignored; behaviour exactly as before.
 *  - Feature on, no gateway headers: a direct request — the platform's own header is used, as before.
 *  - Feature on, ANY gateway header present but the envelope is incomplete, forged, for another request, too old /
 *    too far in the future, or a request id already seen: FAIL CLOSED — 403, the attempt is not served.
 *  - Rotation: VA_GATEWAY_SECRET_PREVIOUS (optional) is accepted too, so the gateway and Vercel can switch secrets
 *    without an outage; remove it once the gateway signs with the new one.
 * Replay: request ids are remembered for the signature window in this instance (best effort — serverless instances do
 * not share memory). Because a signature is bound to the exact method, path, query and body, a replay can only repeat
 * the identical request within 60 s, and only by someone who can read the TLS traffic between Cloudflare and Vercel.
 */
const seenIds = new Map<string, number>();
function rememberId(id: string, nowS: number): boolean {
  if (seenIds.size > 20_000) for (const [k, exp] of seenIds) if (exp < nowS) seenIds.delete(k);
  if ((seenIds.get(id) ?? 0) >= nowS) return false;
  seenIds.set(id, nowS + GW_MAX_AGE_S + GW_MAX_FUTURE_S);
  return true;
}
export function gatewaySignature(secret: string, c: string): string {
  return createHmac('sha256', secret).update(c).digest('base64url');
}
const secrets = () => [process.env.VA_GATEWAY_SECRET ?? '', process.env.VA_GATEWAY_SECRET_PREVIOUS ?? ''].filter((s) => s.length >= 32);
const gatewayRefused = () => new AppError('forbidden', 'Gateway signature invalid', { reason: 'gateway_signature_invalid' });

/** the visitor IP from a valid gateway envelope; null when the request did not come through the gateway (or the feature is off) */
export function gatewayIp(req: Pick<Req, 'method' | 'path' | 'query' | 'headers' | 'raw'>, now = Date.now()): string | null {
  const keys = secrets();
  if (!keys.length) return null;
  const present = Object.values(GW_HEADERS).some((k) => req.headers[k] !== undefined);
  if (!present) return null;
  const ip = header(req, GW_HEADERS.ip).trim();
  const ts = header(req, GW_HEADERS.ts).trim();
  const id = header(req, GW_HEADERS.id).trim().toLowerCase();
  const sig = header(req, GW_HEADERS.sig).trim();
  if (!GW_IP_RE.test(ip) || !/^\d{10}$/.test(ts) || !GW_ID_RE.test(id) || !/^[A-Za-z0-9_-]{43}$/.test(sig)) throw gatewayRefused();
  const nowS = Math.floor(now / 1000);
  const age = nowS - Number(ts);
  if (age > GW_MAX_AGE_S || age < -GW_MAX_FUTURE_S) throw gatewayRefused();
  const c = canonical({ method: req.method, path: req.path, query: normQuery(req.query), ts, id, ip,
    bodySha256: createHash('sha256').update(req.raw ?? Buffer.alloc(0)).digest('base64url') });
  const got = Buffer.from(sig);
  const ok = keys.some((k) => { const want = Buffer.from(gatewaySignature(k, c)); return want.length === got.length && timingSafeEqual(want, got); });
  if (!ok) throw gatewayRefused();
  if (!rememberId(id, nowS)) throw gatewayRefused();
  return ip;
}

