import { createHmac, timingSafeEqual } from 'node:crypto';
import type { Q } from '../db.ts';
import { one } from '../db.ts';

let cached: string | null = null;
async function secret(q: Q) {
  cached ??= (await one(q, `SELECT media_secret FROM company_settings`)).media_secret as string;
  return cached;
}

const TTL_S = 24 * 3600;

/** Relative URL (prefix with the API base) valid for 24 h: /media/<kind>/<id>?exp=..&sig=.. */
export async function signedMediaPath(q: Q, kind: 'photo' | 'selfie' | 'advance', id: string, now = new Date()) {
  const exp = Math.floor(now.getTime() / 1000) + TTL_S;
  const sig = createHmac('sha256', await secret(q)).update(`${kind}:${id}:${exp}`).digest('base64url');
  return `/media/${kind}/${id}?exp=${exp}&sig=${sig}`;
}

export async function verifyMedia(q: Q, kind: string, id: string, exp: string | null, sig: string | null, now = new Date()) {
  if (!exp || !sig || !/^\d+$/.test(exp) || Number(exp) < now.getTime() / 1000) return false;
  const want = createHmac('sha256', await secret(q)).update(`${kind}:${id}:${exp}`).digest();
  const got = Buffer.from(sig, 'base64url');
  return got.length === want.length && timingSafeEqual(got, want);
}
