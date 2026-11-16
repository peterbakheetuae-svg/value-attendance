import { createHmac, timingSafeEqual } from 'node:crypto';
import type { Q } from '../db.ts';
import { one } from '../db.ts';

let cached: string | null = null;
async function secret(q: Q) {
  cached ??= (await one(q, `SELECT media_secret FROM company_settings`)).media_secret as string;
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
  const want = createHmac('sha256', await secret(q)).update(`${kind}:${id}:${exp}:${viewer}`).digest();
  const got = Buffer.from(sig, 'base64url');
  return got.length === want.length && timingSafeEqual(got, want) ? viewer : null;
}
