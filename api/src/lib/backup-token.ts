import { createHash, timingSafeEqual } from 'node:crypto';
import type { IncomingMessage } from 'node:http';

/**
 * The scheduler's secret (BACKUP_TOKEN, ≥ 24 characters, set on the API host): sent in the X-Backup-Token header by the
 * owner's Google Apps Script (backup + minute heartbeat) and by the GitHub scheduler (daily leads report). Off (always
 * false) while the host has no token of that length. Compared in constant time.
 */
export function hasBackupToken(headers: IncomingMessage['headers'], env: Record<string, string | undefined> = process.env): boolean {
  return backupTokenSlot(headers, env) !== null;
}

/**
 * Which configured token matched: 'current' (BACKUP_TOKEN) or 'next' (BACKUP_TOKEN_NEXT — set only while the token is
 * being rotated, so the Apps Script and the API can be switched one after the other without a failed minute). Each is
 * accepted only when ≥ 24 characters; both are always compared (constant time, no early exit on the first match).
 */
export function backupTokenSlot(headers: IncomingMessage['headers'], env: Record<string, string | undefined> = process.env): 'current' | 'next' | null {
  const raw = headers['x-backup-token'];
  const got = String(Array.isArray(raw) ? raw[0] : raw ?? '');
  if (!got) return null;
  const g = createHash('sha256').update(got).digest();
  const eq = (want: string | undefined) => !!want && want.length >= 24 && timingSafeEqual(createHash('sha256').update(want).digest(), g);
  const cur = eq(env.BACKUP_TOKEN), nxt = eq(env.BACKUP_TOKEN_NEXT);
  return cur ? 'current' : nxt ? 'next' : null;
}
