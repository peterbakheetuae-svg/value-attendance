import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Db } from './db.ts';

export const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'db', 'migrations');

/** Applies pending migrations in order, each inside its own transaction. Returns names applied. */
export async function migrate(db: Db, dir = MIGRATIONS_DIR, opts: { skip?: (name: string) => boolean } = {}): Promise<string[]> {
  // created only when missing: an up-to-date database needs no CREATE privilege, so the runtime role can run this check
  // (pending migrations still need the owner / migration role — see MIGRATION_DATABASE_URL)
  if (!(await db.query(`SELECT to_regclass('public.schema_migrations') IS NOT NULL AS ok`)).rows[0].ok)
    await db.query(`CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  const done = new Set((await db.query(`SELECT name FROM schema_migrations`)).rows.map((r) => r.name));
  const files = readdirSync(dir).filter((f) => /^\d{3}_.+\.sql$/.test(f)).sort();
  const applied: string[] = [];
  for (const f of files) {
    if (done.has(f) || opts.skip?.(f)) continue;
    const sql = readFileSync(join(dir, f), 'utf8');
    // two deployments migrating the same database at once (2026-11-24: two Vercel projects build every main push) are
    // serialised: a transaction-scoped lock (safe through a pooled connection), then the migration is checked again —
    // the second runner skips what the first one applied instead of failing its build
    const ran = await db.tx(async (q) => {
      await q.query(`SELECT pg_advisory_xact_lock(hashtextextended('valunivo:schema_migrations', 0))`);
      if ((await q.query(`SELECT 1 FROM schema_migrations WHERE name = $1`, [f])).rows.length) return false;
      await q.query(sql);
      await q.query(`INSERT INTO schema_migrations (name) VALUES ($1)`, [f]);
      return true;
    });
    if (ran) applied.push(f);
  }
  return applied;
}
