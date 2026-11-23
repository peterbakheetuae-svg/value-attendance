import { ok, type Module } from '../ctx.ts';
import { AppError, notFound } from '../http/errors.ts';
import type { Req } from '../http/router.ts';
import { sweep } from './tracking.ts';
import { backupKeyConfigured, seal } from '../lib/secretbox.ts';
import { hasBackupToken } from '../lib/backup-token.ts';

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

// the token check is shared with the scheduler's other knocks (lib/backup-token.ts — the same rule as before)
const authorized = (req: Req): boolean => hasBackupToken(req.headers);


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

  /** The table's primary-key columns (quoted) and types, in key order — straight from the catalog. */
  const primaryKey = async (table: string) => (await db.query<{ col: string; type: string }>(`
      SELECT quote_ident(a.attname) AS col, format_type(a.atttypid, a.atttypmod) AS type
        FROM pg_index i JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum, n) ON true
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
       WHERE i.indrelid = ('public.' || quote_ident($1))::regclass AND i.indisprimary ORDER BY k.n`, [table])).rows;
  const decodeCursor = (raw: string, n: number): string[] => {
    let v: unknown;
    try { v = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8')); } catch { v = null; }
    if (!n || !Array.isArray(v) || v.length !== n || !v.every((x) => typeof x === 'string')) {
      throw new AppError('validation_failed', 'after is invalid', { field: 'after' });
    }
    return v as string[];
  };

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
    // R6: pages follow the table's primary key. With `after` (the cursor the previous page returned) every row that
    // existed when the export started is sent exactly once even while the app edits or deletes rows in between
    // (keyset). `offset` alone still works for the current Drive script (ordered by the key now, not by physical place).
    const pk = await primaryKey(name);
    const afterRaw = req.query.get('after');
    const after = afterRaw ? decodeCursor(afterRaw, pk.length) : null;
    // to_jsonb: every value exactly as stored (times to the microsecond, numbers in full, files as \\x hex) — a restore
    // gives back the same rows, not rounded copies
    const cols = pk.map((c) => `x.${c.col}`);
    const res = !pk.length
      ? await db.query(`SELECT to_jsonb(x) AS j, NULL::text[] AS k FROM "${name}" x ORDER BY ctid OFFSET $1 LIMIT 2000`, [offset])
      : after
        ? await db.query(`SELECT to_jsonb(x) AS j, ARRAY[${cols.map((c) => `${c}::text`).join(', ')}] AS k FROM "${name}" x
             WHERE (${cols.join(', ')}) > (${pk.map((c, i) => `$${i + 1}::text::${c.type}`).join(', ')}) ORDER BY ${cols.join(', ')} LIMIT 2000`, after)
        : await db.query(`SELECT to_jsonb(x) AS j, ARRAY[${cols.map((c) => `${c}::text`).join(', ')}] AS k FROM "${name}" x
             ORDER BY ${cols.join(', ')} OFFSET $1 LIMIT 2000`, [offset]);
    const rows: unknown[] = []; let size = 0;
    for (const { j: row } of res.rows) {
      const o: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(row as Record<string, unknown>)) o[k] = SECRET_COLUMN.test(k) ? null : v;
      const len = JSON.stringify(o).length;
      if (rows.length && size + len > MAX_CHUNK) break;
      rows.push(o); size += len;
    }
    const more = rows.length < res.rows.length || res.rows.length === 2000;
    const next = more ? offset + rows.length : null;
    const last = res.rows[rows.length - 1]?.k as string[] | null | undefined;
    const cursor = more && pk.length && last ? Buffer.from(JSON.stringify(last)).toString('base64url') : null;
    const redacted = (await db.query<{ c: string }>(`SELECT column_name AS c FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 ORDER BY ordinal_position`, [name])).rows.map((x) => x.c).filter((k) => SECRET_COLUMN.test(k));
    // encrypted at rest in the Drive copy: «rows» is one sealed string (AES-256-GCM), opened with tools/backup-decrypt.mjs
    // and the same key for a restore
    return ok({ table: name, offset, rows: seal(JSON.stringify(rows), 'BACKUP_ENCRYPTION_KEY'), next, after: cursor, redacted, encrypted: true });
  });
};
