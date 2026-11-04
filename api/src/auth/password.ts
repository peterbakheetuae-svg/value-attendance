import { randomBytes, scrypt as _scrypt, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';

const scrypt = promisify(_scrypt) as (pw: string, salt: Buffer, len: number, opts: object) => Promise<Buffer>;
const PARAMS = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };

/** Format: scrypt$N$r$p$saltB64$hashB64 */
export async function hashPassword(pw: string): Promise<string> {
  const salt = randomBytes(16);
  const h = await scrypt(pw, salt, 32, PARAMS);
  return `scrypt$${PARAMS.N}$${PARAMS.r}$${PARAMS.p}$${salt.toString('base64')}$${h.toString('base64')}`;
}

export async function verifyPassword(pw: string, stored: string): Promise<boolean> {
  const [alg, N, r, p, s, h] = stored.split('$');
  if (alg !== 'scrypt' || !s || !h) return false;
  const expected = Buffer.from(h, 'base64');
  const got = await scrypt(pw, Buffer.from(s, 'base64'), expected.length,
    { N: Number(N), r: Number(r), p: Number(p), maxmem: 64 * 1024 * 1024 });
  return got.length === expected.length && timingSafeEqual(got, expected);
}

export const PIN_RE = /^\d{4,8}$/;
/** Roles that may sign in with a numeric PIN (when the company allows PINs). */
export const PIN_ROLES = new Set(['sales_employee', 'sales_manager']);

export function passwordPolicyError(pw: unknown, opts: { allowPin?: boolean } = {}): string | null {
  if (typeof pw !== 'string') return 'Password is required';
  if (opts.allowPin && PIN_RE.test(pw)) return null;
  if (opts.allowPin && /^\d+$/.test(pw)) return 'The PIN must be 4 to 8 digits';
  if (pw.length < 8) return 'Password must be at least 8 characters';
  if (pw.length > 128) return 'Password is too long';
  if (!/[A-Za-z؀-ۿ]/.test(pw) || !/\d/.test(pw)) return 'Password must contain letters and digits';
  return null;
}

/** Human-friendly temporary password (no ambiguous chars). */
export function tempPassword(): string {
  const a = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz';
  const d = '23456789';
  const b = randomBytes(10);
  let out = '';
  for (let i = 0; i < 8; i++) out += a[b[i] % a.length];
  return out + d[b[8] % d.length] + d[b[9] % d.length];
}

export function newToken(): { token: string; hash: Buffer } {
  const token = randomBytes(32).toString('base64url');
  return { token, hash: sha256(token) };
}
export const sha256 = (s: string) => createHash('sha256').update(s).digest();

/** Random numeric PIN (6 digits, no leading zero). */
export function tempPin(): string {
  const b = randomBytes(6);
  let out = String(1 + (b[0] % 9));
  for (let i = 1; i < 6; i++) out += String(b[i] % 10);
  return out;
}
