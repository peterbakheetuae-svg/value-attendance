import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { AppError } from '../http/errors.ts';
import type { Req } from '../http/router.ts';
import { securityAlert } from './alerts.ts';
import { GW_HEADERS, GW_ID_RE, GW_IP_RE, GW_MAX_AGE_S, GW_MAX_FUTURE_S, canonical, normQuery } from '../lib/gateway-sig.ts';

/**
 * VA-06 — per-IP throttling of the sign-in / recovery endpoints, shared by every serverless instance (the counts live in
 * the database: audit_log rows «auth.ip_failed», no new table). Only FAILURES count, so employees who sign in correctly
 * are never slowed; an IP with too many failures in the window gets 429 until it ages out. Per-account lockout is unchanged.
 *
 * The client IP is taken ONLY from headers the platform itself writes (Vercel: x-vercel-forwarded-for / x-real-ip, which
 * it overwrites on every request) — never from a header a caller could forge on a host that does not overwrite it. Off
 * the platform (local server) there is no trusted IP and no IP throttling (account lockout still applies).
 */
export const IP_LIMITS: Record<string, { max: number; minutes: number }> = {
  login: { max: 30, minutes: 15 },
  forgot: { max: 20, minutes: 15 },
  otp: { max: 20, minutes: 15 },
};

const IP_RE = /^[0-9a-fA-F:.]{3,45}$/;
const header = (req: Req, k: string) => { const v = req.headers[k]; return String(Array.isArray(v) ? v[0] : v ?? ''); };

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
export function gatewayIp(req: Req, now = Date.now()): string | null {
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

export function clientIp(req: Req): string | null {
  const viaGateway = gatewayIp(req);
  if (viaGateway) return viaGateway;
  if (process.env.VERCEL !== '1' && process.env.TRUST_PLATFORM_IP !== '1') return null;
  const v = req.headers['x-vercel-forwarded-for'] ?? req.headers['x-real-ip'];
  const ip = String(Array.isArray(v) ? v[0] : v ?? '').split(',')[0].trim();
  return IP_RE.test(ip) ? ip : null;
}

async function failures(q: Q, ip: string, kind: string, minutes: number): Promise<number> {
  // entity / entity_id = 'auth_ip' / the IP: served by the existing audit_entity index
  // an attempt is noted before it runs; one that was not a failure is noted back («auth.ip_returned» — the audit log is
  // append-only, nothing is ever deleted from it)
  const r = await one(q, `SELECT GREATEST(0, count(*) FILTER (WHERE action = 'auth.ip_failed') - count(*) FILTER (WHERE action = 'auth.ip_returned'))::int AS n
      FROM audit_log
      WHERE entity = 'auth_ip' AND entity_id = $1 AND action IN ('auth.ip_failed', 'auth.ip_returned') AND after->>'kind' = $2
        AND at > now() - make_interval(mins => $3)`, [ip, kind, minutes]);
  return r?.n ?? 0;
}


/**
 * runs [fn]; a 401 / 400 (wrong password / wrong code) it throws is counted against the caller's IP. [countAll]: every
 * call counts (the forgot-password e-mail, whose reply is always the same success).
 */
export async function withIpLimit<T>(q: Q, req: Req, kind: keyof typeof IP_LIMITS, fn: () => Promise<T>, countAll = false): Promise<T> {
  const ip = clientIp(req);
  const lim = IP_LIMITS[kind];
  if (!ip) return fn();
  // the attempt is counted BEFORE it runs (then given back if it was not a failure): parallel attempts from one network
  // can not all pass the check together
  const mine = await one(q, `INSERT INTO audit_log (actor_id, action, entity, entity_id, after) VALUES (NULL, 'auth.ip_failed', 'auth_ip', $1, $2)
                               RETURNING id`, [ip, JSON.stringify({ ip, kind })]).catch(() => null);
  const giveBack = () => (mine ? q.query(`INSERT INTO audit_log (actor_id, action, entity, entity_id, after) VALUES (NULL, 'auth.ip_returned', 'auth_ip', $1, $2)`,
    [ip, JSON.stringify({ ip, kind })]).catch(() => undefined) : undefined);
  if (await failures(q, ip, kind, lim.minutes) > lim.max) {
    // suspicious: a network guessing passwords / codes — the owners hear about it once an hour per network
    await securityAlert(q, `ip:${kind}:${ip}:${Math.floor(Date.now() / 3600000)}`, 'تنبيه أمان: محاولات دخول كتير',
      `شبكة ${ip} عملت محاولات ${kind === 'login' ? 'دخول' : 'استرجاع'} غلط كتير واتوقفت مؤقتًا`);
    throw new AppError('rate_limited', 'Too many attempts from this network. Try again later', { reason: 'ip_rate_limited' });
  }
  try {
    const out = await fn();
    if (!countAll) await giveBack();
    return out;
  } catch (e: any) {
    if (!countAll && !(e instanceof AppError && (e.code === 'unauthenticated' || e.code === 'validation_failed'))) await giveBack();
    throw e;
  }
}
