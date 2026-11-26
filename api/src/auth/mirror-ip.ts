import { createHmac, timingSafeEqual } from 'node:crypto';

/**
 * SEC-05 / Cloudflare mirror — the original client IP of a request that came through the mirror Worker
 * (api/cloudflare-proxy/worker.js). Behind the mirror the platform header carries Cloudflare's egress address (shared by
 * every user of the mirror), so the Worker sends the caller's address it saw (CF-Connecting-IP) with an HMAC over it:
 *
 *   x-va-client-ip:  <ip>
 *   x-va-mirror-sig: v1.<unix seconds>.<hex HMAC-SHA256(MIRROR_SIGNING_KEY, "v1|<ts>|<ip>|<METHOD>|<pathname>")>
 *
 * The API uses that address ONLY when MIRROR_SIGNING_KEY is set (≥ 32 characters), the signature matches (constant
 * time), it is bound to this request's method and path, and it is at most MAX_SKEW_S old (replay window). Anything
 * else — no key, a missing / forged / expired / other-request signature, a malformed address — is ignored and the
 * platform's own header is used, exactly as before. The Worker strips any x-va-* header a caller sends.
 */
export const MAX_SKEW_S = 60;
const IP_RE = /^[0-9a-fA-F:.]{3,45}$/;

export function mirrorKey(): string | null {
  const k = process.env.MIRROR_SIGNING_KEY ?? '';
  return k.length >= 32 ? k : null;
}

export function mirrorSignature(key: string, ip: string, method: string, pathname: string, ts: number): string {
  const mac = createHmac('sha256', key).update(`v1|${ts}|${ip}|${method.toUpperCase()}|${pathname}`).digest('hex');
  return `v1.${ts}.${mac}`;
}

const first = (v: string | string[] | undefined) => String(Array.isArray(v) ? v[0] : v ?? '').trim();

/** the verified client IP from the mirror, or null (not from the mirror, or not verifiable) */
export function verifiedMirrorIp(headers: Record<string, string | string[] | undefined>, method: string, pathname: string,
  nowMs = Date.now()): string | null {
  const key = mirrorKey();
  if (!key) return null;
  const ip = first(headers['x-va-client-ip']);
  const sig = first(headers['x-va-mirror-sig']);
  if (!ip || !sig || !IP_RE.test(ip)) return null;
  const m = /^v1\.(\d{9,11})\.([0-9a-f]{64})$/.exec(sig);
  if (!m) return null;
  const ts = Number(m[1]);
  if (Math.abs(nowMs / 1000 - ts) > MAX_SKEW_S) return null;
  const want = Buffer.from(mirrorSignature(key, ip, method, pathname, ts).split('.')[2], 'hex');
  const got = Buffer.from(m[2], 'hex');
  return want.length === got.length && timingSafeEqual(want, got) ? ip : null;
}
