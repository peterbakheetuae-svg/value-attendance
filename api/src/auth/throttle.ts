import { createHash } from 'node:crypto';
import type { Q } from '../db.ts';
import { one } from '../db.ts';

/**
 * SEC-05 — progressive, multi-signal sign-in throttling (replaces the hard 15-minute account lock, which let anyone who
 * knew an employee code keep that employee out). State is in the database (login_throttle, migration 095), so it holds
 * across parallel requests, API instances and restarts.
 *
 * Buckets (each a row):
 *  - pair:  <account> + <the caller's network>             — guessing from one network
 *  - dev:   <account> + <a device already approved for it> — the real user's own phone has its own bucket, which an
 *                                                            attacker (who does not know that device's id) can not fill
 *  - acct:  <account>, failures from unknown devices only   — guessing spread over many networks
 *  - unk:   SHA-256(<unknown sign-in name>) + <network>      — unknown names throttle the same way (no enumeration)
 *
 * Each attempt is RESERVED (counted as a failure) before the password is checked, in one atomic statement, and given
 * back on success: parallel attempts can not slip past a block. A bucket allows PAIR_FREE attempts, then each further
 * one waits 30 s, 60 s, 120 s … (cap 15 min) after the previous; nothing ever locks for good, and a right password
 * resets the bucket. The account-wide bucket only slows unknown devices, so a distributed attack can not keep the
 * real user's approved phone out either.
 */
export const PAIR_FREE = 5;
export const ACCT_FREE = 20;
export const BASE_DELAY_S = 30;
export const MAX_DELAY_S = 900;
const PAIR_WINDOW_H = 24;
const ACCT_WINDOW_H = 1;

export type Bucket = { key: string; free: number; windowH: number };

export const pairBucket = (account: string, ip: string | null): Bucket => ({ key: `pair:${account}|${ip ?? '-'}`, free: PAIR_FREE, windowH: PAIR_WINDOW_H });
export const deviceBucket = (account: string, deviceId: string): Bucket => ({ key: `dev:${account}|${createHash('sha256').update(deviceId).digest('hex').slice(0, 32)}`, free: PAIR_FREE, windowH: PAIR_WINDOW_H });
export const accountBucket = (account: string): Bucket => ({ key: `acct:${account}`, free: ACCT_FREE, windowH: ACCT_WINDOW_H });
export const unknownBucket = (identifier: string, ip: string | null): Bucket => ({
  key: `unk:${createHash('sha256').update(identifier.trim().toLowerCase()).digest('hex').slice(0, 32)}|${ip ?? '-'}`, free: PAIR_FREE, windowH: PAIR_WINDOW_H });

/** the wait after the n-th counted attempt (0 while n < free) */
export const delayAfter = (n: number, free: number) => (n < free ? 0 : Math.min(MAX_DELAY_S, BASE_DELAY_S * 2 ** (n - free)));

export type Reserved = { ok: true; fails: number } | { ok: false; retryAfterS: number };

/**
 * Count one attempt against [b] unless it is blocked right now. Atomic (one INSERT … ON CONFLICT DO UPDATE … WHERE):
 * of N parallel attempts on a fresh bucket at most [b.free] pass before the block is set.
 */
export async function reserve(q: Q, b: Bucket): Promise<Reserved> {
  const r = await one(q, `
    INSERT INTO login_throttle AS t (key, fails, last_fail_at, blocked_until)
    VALUES ($1, 1, now(), CASE WHEN 1 >= $2::int THEN now() + make_interval(secs => LEAST($4::float, $3::float)) END)
    ON CONFLICT (key) DO UPDATE SET
      fails = CASE WHEN t.last_fail_at < now() - make_interval(hours => $5::int) THEN 1 ELSE t.fails + 1 END,
      last_fail_at = now(),
      blocked_until = CASE
        WHEN (CASE WHEN t.last_fail_at < now() - make_interval(hours => $5::int) THEN 1 ELSE t.fails + 1 END) >= $2::int
        THEN now() + make_interval(secs => LEAST($4::float, $3::float * power(2, (CASE WHEN t.last_fail_at < now() - make_interval(hours => $5::int) THEN 1 ELSE t.fails + 1 END) - $2::int)))
        ELSE NULL END
     WHERE t.blocked_until IS NULL OR t.blocked_until <= now()
    RETURNING fails`, [b.key, b.free, BASE_DELAY_S, MAX_DELAY_S, b.windowH]);
  if (r) return { ok: true, fails: r.fails };
  const w = await one(q, `SELECT GREATEST(1, ceil(extract(epoch FROM blocked_until - now())))::int AS s FROM login_throttle WHERE key = $1`, [b.key]);
  return { ok: false, retryAfterS: w?.s ?? BASE_DELAY_S };
}

/** a right password: the bucket starts over */
export async function clear(q: Q, b: Bucket) {
  await q.query(`UPDATE login_throttle SET fails = 0, blocked_until = NULL WHERE key = $1`, [b.key]);
}

/** HR / owner reset a password: every bucket of that account starts over */
export async function clearAccount(q: Q, account: string) {
  await q.query(`UPDATE login_throttle SET fails = 0, blocked_until = NULL
                  WHERE key = $1 OR key LIKE $2 OR key LIKE $3`, [`acct:${account}`, `pair:${account}|%`, `dev:${account}|%`]);
}
