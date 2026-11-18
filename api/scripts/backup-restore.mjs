// Restores a VALUNIVO backup folder (the Drive folder "Value Attendance Backups/YYYY-MM-DD", downloaded) into an EMPTY
// database that already has the schema (run the migrations on it first). Never point it at production.
//
// Usage (on the owner's computer):
//   set BACKUP_ENCRYPTION_KEY=<the same base64 key as on Vercel>
//   set DATABASE_URL=<a NEW, empty, migrated database — e.g. a Neon branch made for the restore>
//   cd api && npm ci        (once — the tool uses the API's database driver)
//   node scripts/backup-restore.mjs <backup folder>
//
// What it does: opens each table file (encrypted or not), loads its rows with the foreign keys checked at the end,
// moves every id sequence past the restored ids, and prints per table: rows in the files / rows in the database.
// Credentials are not in a backup (by design): every password hash is replaced by an unusable value (HR resets the
// passwords), Meta tokens are pasted again, and a new media-link key is made.
import { createDecipheriv, randomBytes } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import pg from 'pg';

const dir = process.argv[2];
if (!dir) { console.error('usage: node scripts/backup-restore.mjs <backup folder>'); process.exit(1); }
const url = process.env.DATABASE_URL ?? '';
if (!url) { console.error('DATABASE_URL (the EMPTY database to restore into) is required'); process.exit(1); }
const key = process.env.BACKUP_ENCRYPTION_KEY ? Buffer.from(process.env.BACKUP_ENCRYPTION_KEY, 'base64') : null;

function open(text) {
  const v = JSON.parse(text);
  if (Array.isArray(v)) return v;
  if (typeof v === 'string' && v.startsWith('enc:v1:')) {
    if (!key || key.length !== 32) throw new Error('this backup is encrypted: set BACKUP_ENCRYPTION_KEY (32 bytes, base64)');
    const b = Buffer.from(v.slice(7), 'base64');
    const d = createDecipheriv('aes-256-gcm', key, b.subarray(0, 12));
    d.setAuthTag(b.subarray(12, 28));
    return JSON.parse(Buffer.concat([d.update(b.subarray(28)), d.final()]).toString('utf8'));
  }
  throw new Error('not a backup table file');
}

// rows per table, parts joined in order (t.json, or t.part1.json, t.part2.json …)
const files = readdirSync(dir).filter((f) => f.endsWith('.json') && !f.startsWith('_'));
const byTable = new Map();
for (const f of files.sort((a, b) => a.localeCompare(b, 'en', { numeric: true }))) {
  const t = f.replace(/\.part\d+\.json$|\.json$/, '');
  byTable.set(t, [...(byTable.get(t) ?? []), ...open(readFileSync(join(dir, f), 'utf8'))]);
}

const db = new pg.Client({ connectionString: url });
await db.connect();
const exists = new Set((await db.query(`SELECT table_name AS t FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'`)).rows.map((r) => r.t));
// safety: only an empty database (the migrations' own seed rows aside) — a restore never mixes into live data
const busy = (await db.query(`SELECT count(*)::int AS n FROM employees`)).rows[0].n;
if (busy > 0) { console.error(`refused: the target database already has ${busy} employees — restore into a NEW empty database`); process.exit(2); }

const fix = (row, cols) => {
  const o = {};
  for (const [k, v] of Object.entries(row)) {
    if (!cols.has(k)) continue; // a column that no longer exists
    o[k] = v && typeof v === 'object' && '$base64' in v ? '\\x' + Buffer.from(v.$base64, 'base64').toString('hex') : v;
  }
  return o;
};

const report = [];
await db.query('BEGIN');
// the migrations seed some lookup rows (roles, permissions, settings …): the backup's copy replaces them
await db.query(`SET CONSTRAINTS ALL DEFERRED`);
const order = [...byTable.keys()].filter((t) => exists.has(t));
for (const t of order) await db.query(`ALTER TABLE "${t}" DISABLE TRIGGER USER`).catch(() => {});
for (const t of order) await db.query(`DELETE FROM "${t}"`).catch(() => {});
// load with foreign keys off for the session when allowed (superuser); otherwise in passes until every table fits
let replica = true;
// (RESTORE_NO_REPLICA=1 forces the pass-by-pass way — what a non-superuser such as Neon's owner role gets)
if (process.env.RESTORE_NO_REPLICA === '1') replica = false;
else {
  try { await db.query('SAVEPOINT r'); await db.query(`SET session_replication_role = replica`); await db.query('RELEASE SAVEPOINT r'); }
  catch { replica = false; await db.query('ROLLBACK TO SAVEPOINT r'); }
}
const pending = [...order];
// foreign keys that point at another table (or the same one): loaded empty first when they go round in a circle
// (employees ↔ teams …), then filled in once every table is in
const fks = new Map();
for (const x of (await db.query(`
    SELECT c.conrelid::regclass::text AS t, a.attname AS col, c.confrelid::regclass::text AS ref, NOT a.attnotnull AS nullable
      FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
     WHERE c.contype = 'f' AND array_length(c.conkey, 1) = 1 AND c.connamespace = 'public'::regnamespace`)).rows) {
  const t = x.t.replace(/^"|"$/g, '');
  fks.set(t, [...(fks.get(t) ?? []), { col: x.col, ref: x.ref.replace(/^"|"$/g, ''), nullable: x.nullable }]);
}
const later = []; // [table, rows with only the id + the columns loaded empty]
for (let pass = 0; pending.length && pass < 12; pass++) {
  const loose = pass >= 2; // after two full passes, what is still waiting is a circle
  for (const t of [...pending]) {
    const meta = (await db.query(`SELECT column_name AS c, is_nullable = 'NO' AS req, data_type AS dt
                                    FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1`, [t])).rows;
    const cols = new Set(meta.map((m) => m.c));
    const rows = byTable.get(t).map((r) => fix(r, cols));
    // redacted credentials: required columns get an unusable value (nobody can sign in with it)
    for (const m of meta) {
      if (!m.req) continue;
      for (const r of rows) if (r[m.c] === null || r[m.c] === undefined) {
        if (/password_hash|pin_hash|code_hash|token_hash/.test(m.c)) r[m.c] = '!restored-reset-required';
        else if (/secret/.test(m.c)) r[m.c] = randomBytes(32).toString('hex');
      }
    }
    let held = [];
    if (loose) {
      held = (fks.get(t) ?? []).filter((f) => f.nullable && (pending.includes(f.ref) || f.ref === t)).map((f) => f.col);
      if (held.length && cols.has('id')) {
        later.push([t, rows.filter((r) => held.some((c) => r[c] != null)).map((r) => Object.fromEntries([['id', r.id], ...held.map((c) => [c, r[c]])]))]);
        for (const r of rows) for (const c of held) r[c] = null;
      }
    }
    try {
      await db.query('SAVEPOINT s');
      for (let i = 0; i < rows.length; i += 500) {
        await db.query(`INSERT INTO "${t}" SELECT * FROM jsonb_populate_recordset(NULL::"${t}", $1::jsonb)`, [JSON.stringify(rows.slice(i, i + 500))]);
      }
      await db.query('RELEASE SAVEPOINT s');
      pending.splice(pending.indexOf(t), 1);
    } catch (e) {
      await db.query('ROLLBACK TO SAVEPOINT s');
      if (!/foreign key/i.test(String(e.message)) || replica) { console.error(`${t}: ${e.message}`); pending.splice(pending.indexOf(t), 1); report.push([t, rows.length, 'FAILED']); }
    }
  }
}
for (const t of pending) report.push([t, byTable.get(t).length, 'FAILED (foreign keys)']);
// the circle's columns filled in now that every table is in
for (const [t, rows] of later) {
  for (const r of rows) {
    const cols = Object.keys(r).filter((c) => c !== 'id');
    await db.query(`UPDATE "${t}" SET (${cols.map((c) => `"${c}"`).join(', ')}) =
                      (SELECT ${cols.map((c) => `x."${c}"`).join(', ')} FROM jsonb_populate_record(NULL::"${t}", $2::jsonb) x) WHERE id = $1`,
      [r.id, JSON.stringify(r)]);
  }
}
if (replica) await db.query(`SET session_replication_role = origin`);
for (const t of order) await db.query(`ALTER TABLE "${t}" ENABLE TRIGGER USER`).catch(() => {});
// every id sequence past the restored ids
const seqs = (await db.query(`SELECT c.table_name AS t, c.column_name AS c, pg_get_serial_sequence(quote_ident(c.table_name), c.column_name) AS s
                                FROM information_schema.columns c WHERE c.table_schema = 'public' AND c.column_default LIKE 'nextval%'`)).rows;
for (const x of seqs) if (x.s) await db.query(`SELECT setval($1, GREATEST((SELECT COALESCE(max("${x.c}"), 0) FROM "${x.t}"), 1))`, [x.s]);
await db.query('COMMIT');

let failed = 0;
for (const t of order) {
  const n = (await db.query(`SELECT count(*)::int AS n FROM "${t}"`)).rows[0].n;
  const want = byTable.get(t).length;
  const bad = report.find((r) => r[0] === t);
  if (bad || n !== want) failed++;
  console.log(`${t}\tbackup ${want}\tdatabase ${n}${bad ? '\t' + bad[2] : n !== want ? '\tMISMATCH' : ''}`);
}
for (const t of byTable.keys()) if (!exists.has(t)) console.log(`${t}\tskipped (no such table in this schema)`);
await db.end();
if (failed) { console.error(`${failed} table(s) did not restore fully`); process.exit(3); }
console.log('restore complete — next: HR resets passwords, the Meta pages are linked again');
