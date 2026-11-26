import { createCipheriv, createECDH, createHmac, createPrivateKey, createSign, randomBytes } from 'node:crypto';
import type { Q } from '../db.ts';

/**
 * Web Push (RFC 8030 / 8291 / 8292) — notifications for the web app, including iPhone (iOS 16.4+, app added to
 * the Home Screen). Free: the browser's own push service delivers it. No library: VAPID (ES256) and the
 * aes128gcm payload encryption are done with node:crypto.
 *
 * The VAPID key (ES256 / P-256) is its OWN secret: VAPID_PRIVATE_KEY = the 32-byte private scalar, base64url (43
 * characters, no padding) — generate it with `node api/scripts/vapid-key.mjs`. It is never derived from another
 * credential any more (SEC-01 / rotation coupling: it used to be an HMAC of FCM_SERVICE_ACCOUNT's private key, else
 * BACKUP_TOKEN, so rotating either one silently replaced every browser subscription's key). Without the variable, or
 * with a value that is not a valid P-256 private key, Web Push is OFF (the API serves publicKey: null, the app does not
 * subscribe, nothing is sent) — an invalid key never falls back to anything. Android (FCM) is independent of it.
 * The app reads the public key from the API and re-subscribes by itself once when it changes (va-push.js).
 */
const N = BigInt('0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551'); // P-256 order

export type VapidState = 'ok' | 'missing' | 'invalid';
let cache: { raw: string | undefined; state: VapidState; keys: { d: Buffer; pub: Buffer } | null } | null = null;
let warned = '';

/** Parse a configured key strictly; null = not a valid P-256 private scalar (the value itself is never logged). */
export function parseVapidPrivateKey(raw: string): { d: Buffer; pub: Buffer } | null {
  const v = raw.trim();
  if (!/^[A-Za-z0-9_-]{43}$/.test(v)) return null;
  const d = Buffer.from(v, 'base64url');
  if (d.length !== 32 || d.toString('base64url') !== v) return null;
  const n = BigInt('0x' + d.toString('hex'));
  if (n < 1n || n >= N) return null;
  try {
    const ecdh = createECDH('prime256v1'); ecdh.setPrivateKey(d);
    const pub = ecdh.getPublicKey();
    return pub.length === 65 && pub[0] === 4 ? { d, pub } : null;
  } catch { return null; }
}

function current() {
  const raw = process.env.VAPID_PRIVATE_KEY;
  if (cache && cache.raw === raw) return cache;
  const keys = raw ? parseVapidPrivateKey(raw) : null;
  const state: VapidState = !raw ? 'missing' : keys ? 'ok' : 'invalid';
  if (state === 'invalid' && warned !== 'invalid') console.error('[webpush] VAPID_PRIVATE_KEY is set but is not a valid P-256 private key (32 bytes, base64url) — Web Push is off');
  warned = state;
  cache = { raw, state, keys };
  return cache;
}

export const vapidState = (): VapidState => current().state;
export function vapidKeys(): { d: Buffer; pub: Buffer } | null { return current().keys; }

export const webPushPublicKey = () => vapidKeys()?.pub.toString('base64url') ?? null;

export function vapidAuth(endpoint: string): string {
  const k = vapidKeys()!;
  const head = Buffer.from(JSON.stringify({ typ: 'JWT', alg: 'ES256' })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600,
    sub: 'mailto:admin@jaurea.com' })).toString('base64url');
  const key = createPrivateKey({ format: 'jwk', key: { kty: 'EC', crv: 'P-256', d: k.d.toString('base64url'),
    x: k.pub.subarray(1, 33).toString('base64url'), y: k.pub.subarray(33, 65).toString('base64url') } });
  const sig = createSign('SHA256').update(`${head}.${claims}`).sign({ key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `vapid t=${head}.${claims}.${sig}, k=${k.pub.toString('base64url')}`;
}

const hmac = (key: Buffer, data: Buffer) => createHmac('sha256', key).update(data).digest();

/** RFC 8291 aes128gcm: one record, no padding. */
export function encryptPayload(payload: Buffer, uaPublic: Buffer, authSecret: Buffer, salt = randomBytes(16), as = createECDH('prime256v1')) {
  try { as.getPrivateKey(); } catch { as.generateKeys(); }
  const asPublic = as.getPublicKey();
  const shared = as.computeSecret(uaPublic);
  const prkKey = hmac(authSecret, shared);
  const ikm = hmac(prkKey, Buffer.concat([Buffer.from('WebPush: info\0'), uaPublic, asPublic, Buffer.from([1])]));
  const prk = hmac(salt, ikm);
  const cek = hmac(prk, Buffer.from('Content-Encoding: aes128gcm\0\x01', 'binary')).subarray(0, 16);
  const nonce = hmac(prk, Buffer.from('Content-Encoding: nonce\0\x01', 'binary')).subarray(0, 12);
  const c = createCipheriv('aes-128-gcm', cek, nonce);
  const body = Buffer.concat([c.update(Buffer.concat([payload, Buffer.from([2])])), c.final(), c.getAuthTag()]);
  const rs = Buffer.alloc(4); rs.writeUInt32BE(4096);
  return Buffer.concat([salt, rs, Buffer.from([asPublic.length]), asPublic, body]);
}

/** Send to every web subscription of an employee; dead ones are removed. Never throws. */
export async function webPushTo(q: Q, employeeId: string, m: { id: string; type: string; title: string; body: string; entityId?: string | null; ring?: boolean }) {
  const out = { devices: 0, sent: 0, failed: 0, removed: 0 } as { devices: number; sent: number; failed: number; removed: number; off?: boolean };
  if (!vapidKeys()) return { ...out, off: true };
  try {
    const subs = await q.query<{ id: string; endpoint: string; p256dh: string; auth: string }>(`
      SELECT w.id, w.endpoint, w.p256dh, w.auth FROM web_push_subscriptions w JOIN sessions s ON s.id = w.session_id
       WHERE w.employee_id = $1 AND s.revoked_at IS NULL AND s.expires_at > now()`, [employeeId]);
    out.devices = subs.rows.length;
    await Promise.all(subs.rows.map(async (s) => {
      try {
        const payload = Buffer.from(JSON.stringify({ id: m.id, type: m.type, title: m.title, body: m.body, entityId: m.entityId ?? '', ring: m.ring === true }));
        const r = await fetch(s.endpoint, {
          method: 'POST',
          headers: { authorization: vapidAuth(s.endpoint), 'content-encoding': 'aes128gcm', 'content-type': 'application/octet-stream',
            ttl: '600', urgency: 'high' },
          body: encryptPayload(payload, Buffer.from(s.p256dh, 'base64url'), Buffer.from(s.auth, 'base64url')),
          signal: AbortSignal.timeout(5000),
        });
        if (r.ok) out.sent++; else out.failed++;
        if (r.status === 404 || r.status === 410) { await q.query(`DELETE FROM web_push_subscriptions WHERE id = $1`, [s.id]); out.removed++; }
      } catch { out.failed++; /* one browser unreachable: the others still get it */ }
    }));
  } catch { /* best-effort */ }
  return out;
}
