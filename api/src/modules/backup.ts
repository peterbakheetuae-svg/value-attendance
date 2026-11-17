import { timingSafeEqual, createHash } from 'node:crypto';
import { ok, type Module } from '../ctx.ts';
import { AppError, notFound } from '../http/errors.ts';
import type { Req } from '../http/router.ts';
import { sweep } from './tracking.ts';
import { backupKeyConfigured, seal } from '../lib/secretbox.ts';

/**
 * Daily backup export, read by a Google Apps Script in the owner's Google Drive.
 * Off unless BACKUP_TOKEN (≥ 24 characters, a secret set on Netlify) is configured; the script sends it
 * in the X-Backup-Token header. Read-only. Session tokens and phone push tokens are never exported.
 */
// VA-05 — a backup never carries credentials. Two layers:
//  1. tables that hold nothing but credentials / one-time codes are never exported (nothing in them is needed to restore
//     the business data: sessions are signed in again, codes are requested again);
//  2. in every other table — including tables added later — any column whose NAME says it is a secret is emptied
//     (value null) and listed in the reply's «redacted». Restoring: see the restore notes (password hashes, Meta tokens and
//     the media signing secret are set again after a restore — users reset their passwords, the tokens are pasted again).
const SKIP = new Set(['sessions', 'push_tokens', 'partner_sessions', 'password_otps', 'action_otps', 'partner_email_otps',
  'web_push_subscriptions']);
/** a column holding a credential (password hashes, token hashes, OTP hashes, access / verify tokens, keys, secrets) */
export const SECRET_COLUMN = /(password_hash|token_hash|code_hash|key_hash|access_token|refresh_token|verify_token|secret|private_key|api_key|p256dh|^auth$|^token$)/i;

const MAX_CHUNK = 3_500_000; // keep each reply under the hosting limit

function authorized(req: Req): boolean {
  const want = process.env.BACKUP_TOKEN ?? '';
  const got = String(req.headers['x-backup-token'] ?? '');
  if (want.length < 24 || !got) return false;
  const a = createHash('sha256').update(want).digest(), b = createHash('sha256').update(got).digest();
  return timingSafeEqual(a, b);
}

function plain(v: unknown): unknown {
  if (Buffer.isBuffer(v)) return { $base64: v.toString('base64') };
  if (v instanceof Date) return v.toISOString();
  return v;
}

export const backupModule: Module = (r, { db, clock }) => {
  const guard = (req: Req) => { if (!authorized(req)) throw new AppError('unauthenticated', 'Backup token required'); };
  // the business data never leaves unencrypted: without BACKUP_ENCRYPTION_KEY (32 bytes, base64) nothing is exported
  // (the minute heartbeat below is not an export and keeps working)
  const exportGuard = (req: Req) => {
    guard(req);
    if (!backupKeyConfigured()) {
      throw new AppError('unprocessable', 'Backups are encrypted: set BACKUP_ENCRYPTION_KEY on the API host first', { reason: 'backup_key_missing' });
    }
  };
  /** Minute heartbeat (no scheduler on the free plan): overdue permissions ring, reminders go out on time. */
  r.post('/backup/sweep', async (req) => {
    guard(req);
    await sweep(db, clock());
    return ok({ ok: true });
  });

  const tables = async () => (await db.query<{ t: string }>(`SELECT table_name AS t FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY 1`)).rows.map((x) => x.t).filter((t) => !SKIP.has(t));

  r.get('/backup/tables', async (req) => {
    exportGuard(req);
    const out = [];
    for (const t of await tables()) {
      const n = await db.query(`SELECT count(*)::int AS n FROM "${t}"`);
      out.push({ table: t, rows: n.rows[0].n });
    }
    return ok({ generatedAt: new Date().toISOString(), tables: out });
  });

  r.get('/backup/table/:name', async (req) => {
    exportGuard(req);
    const name = req.params.name;
    if (!(await tables()).includes(name)) throw notFound();
    const offset = Math.max(0, Number(req.query.get('offset') ?? 0) || 0);
    const res = await db.query(`SELECT * FROM "${name}" ORDER BY ctid OFFSET $1 LIMIT 2000`, [offset]);
    const rows: unknown[] = []; let size = 0;
    for (const row of res.rows) {
      const o: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(row)) o[k] = SECRET_COLUMN.test(k) ? null : plain(v);
      const len = JSON.stringify(o).length;
      if (rows.length && size + len > MAX_CHUNK) break;
      rows.push(o); size += len;
    }
    const next = rows.length < res.rows.length || res.rows.length === 2000 ? offset + rows.length : null;
    const redacted = (await db.query<{ c: string }>(`SELECT column_name AS c FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 ORDER BY ordinal_position`, [name])).rows.map((x) => x.c).filter((k) => SECRET_COLUMN.test(k));
    // encrypted at rest in the Drive copy: «rows» is one sealed string (AES-256-GCM), opened with tools/backup-decrypt.mjs
    // and the same key for a restore
    return ok({ table: name, offset, rows: seal(JSON.stringify(rows), 'BACKUP_ENCRYPTION_KEY'), next, redacted, encrypted: true });
  });
};
