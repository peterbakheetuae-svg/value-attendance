import { timingSafeEqual, createHash } from 'node:crypto';
import { ok, type Module } from '../ctx.ts';
import { AppError, notFound } from '../http/errors.ts';
import type { Req } from '../http/router.ts';

/**
 * Daily backup export, read by a Google Apps Script in the owner's Google Drive.
 * Off unless BACKUP_TOKEN (≥ 24 characters, a secret set on Netlify) is configured; the script sends it
 * in the X-Backup-Token header. Read-only. Session tokens and phone push tokens are never exported.
 */
const SKIP = new Set(['sessions', 'push_tokens']);
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

export const backupModule: Module = (r, { db }) => {
  const guard = (req: Req) => { if (!authorized(req)) throw new AppError('unauthenticated', 'Backup token required'); };

  const tables = async () => (await db.query<{ t: string }>(`SELECT table_name AS t FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY 1`)).rows.map((x) => x.t).filter((t) => !SKIP.has(t));

  r.get('/backup/tables', async (req) => {
    guard(req);
    const out = [];
    for (const t of await tables()) {
      const n = await db.query(`SELECT count(*)::int AS n FROM "${t}"`);
      out.push({ table: t, rows: n.rows[0].n });
    }
    return ok({ generatedAt: new Date().toISOString(), tables: out });
  });

  r.get('/backup/table/:name', async (req) => {
    guard(req);
    const name = req.params.name;
    if (!(await tables()).includes(name)) throw notFound();
    const offset = Math.max(0, Number(req.query.get('offset') ?? 0) || 0);
    const res = await db.query(`SELECT * FROM "${name}" ORDER BY ctid OFFSET $1 LIMIT 2000`, [offset]);
    const rows: unknown[] = []; let size = 0;
    for (const row of res.rows) {
      const o: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(row)) o[k] = plain(v);
      const len = JSON.stringify(o).length;
      if (rows.length && size + len > MAX_CHUNK) break;
      rows.push(o); size += len;
    }
    const next = rows.length < res.rows.length || res.rows.length === 2000 ? offset + rows.length : null;
    return ok({ table: name, offset, rows, next });
  });
};
