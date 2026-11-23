import { createHash, timingSafeEqual } from 'node:crypto';
import type { IncomingMessage } from 'node:http';

/**
 * The scheduler's secret (BACKUP_TOKEN, ≥ 24 characters, set on the API host): sent in the X-Backup-Token header by the
 * owner's Google Apps Script (backup + minute heartbeat) and by the GitHub scheduler (daily leads report). Off (always
 * false) while the host has no token of that length. Compared in constant time.
 */
export function hasBackupToken(headers: IncomingMessage['headers'], env: Record<string, string | undefined> = process.env): boolean {
  const want = env.BACKUP_TOKEN ?? '';
  const got = String(headers['x-backup-token'] ?? '');
  if (want.length < 24 || !got) return false;
  const a = createHash('sha256').update(want).digest(), b = createHash('sha256').update(got).digest();
  return timingSafeEqual(a, b);
}
