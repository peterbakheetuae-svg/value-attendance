import { createHmac, timingSafeEqual } from 'node:crypto';
import type { Q } from '../db.ts';
import { one } from '../db.ts';

let cached: Buffer | null = null;
/**
 * The key media links are signed with: the database's media_secret mixed with SECRETS_KEY (set on the API host only, never
 * in the database, a backup or a reply) — a copy of media_secret alone (an old backup, the old settings reply) can not
 * sign a link. Changing SECRETS_KEY ends every link in circulation (the app simply asks for new ones).
 */
async function secret(q: Q): Promise<Buffer> {
  if (cached) return cached;
  const db = String((await one(q, `SELECT media_secret FROM company_settings`)).media_secret);
  const host = process.env.SECRETS_KEY ?? '';
  cached = host ? createHmac('sha256', Buffer.from(host, 'base64')).update('media-links:' + db).digest() : Buffer.from(db);
  return cached;
}

const TTL_S = 24 * 3600;

/**
 * Relative URL (prefix with the API base) valid for 24 h, bound to the employee it was issued to:
 * /media/<kind>/<id>?exp=..&v=<viewer>&sig=.. — when it is opened, the viewer's CURRENT permissions and scope are checked
 * again (a link stops working as soon as his access is taken away, not only when it expires).
 */
export async function signedMediaPath(q: Q, kind: 'photo' | 'selfie', id: string, viewer: string, now = new Date()) {
  const exp = Math.floor(now.getTime() / 1000) + TTL_S;
  const sig = createHmac('sha256', await secret(q)).update(`${kind}:${id}:${exp}:${viewer}`).digest('base64url');
  return `/media/${kind}/${id}?exp=${exp}&v=${viewer}&sig=${sig}`;
}

/** the viewer the link was issued to, or null (bad / expired / unbound link) */
export async function verifyMedia(q: Q, kind: string, id: string, exp: string | null, viewer: string | null, sig: string | null, now = new Date()) {
  if (!exp || !sig || !viewer || !/^\d+$/.test(exp) || Number(exp) < now.getTime() / 1000) return null;
  // a link lives 24 h at most: one made to expire later was not made here
  if (Number(exp) > now.getTime() / 1000 + TTL_S + 300) return null;
  const want = createHmac('sha256', await secret(q)).update(`${kind}:${id}:${exp}:${viewer}`).digest();
  const got = Buffer.from(sig, 'base64url');
  return got.length === want.length && timingSafeEqual(got, want) ? viewer : null;
}
