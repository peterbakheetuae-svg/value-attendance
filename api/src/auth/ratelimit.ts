import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { AppError } from '../http/errors.ts';
import type { Req } from '../http/router.ts';
import { securityAlert } from './alerts.ts';

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

export function clientIp(req: Req): string | null {
  if (process.env.VERCEL !== '1' && process.env.TRUST_PLATFORM_IP !== '1') return null;
  const v = req.headers['x-vercel-forwarded-for'] ?? req.headers['x-real-ip'];
  const ip = String(Array.isArray(v) ? v[0] : v ?? '').split(',')[0].trim();
  return /^[0-9a-fA-F:.]{3,45}$/.test(ip) ? ip : null;
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
