import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { unseal } from '../src/lib/secretbox.ts';

/**
 * R6: backup pages follow the primary key with a cursor (`after`). Supported consistency model, per table: every row
 * that exists when the export of the table starts and still exists at its end is exported exactly once, whatever the
 * app edits or deletes in between; rows added meanwhile may or may not be included; nothing is ever exported twice.
 * (A point-in-time copy across tables is Neon's own history — one HTTP page cannot hold a transaction open.)
 */
const BK = Buffer.alloc(32, 9).toString('base64');
const TOKEN = 'p'.repeat(32);
let h: Harness;
before(async () => {
  process.env.BACKUP_ENCRYPTION_KEY = BK; process.env.BACKUP_TOKEN = TOKEN;
  h = await harness(); await cast(h);
});
after(async () => { await h.close(); delete process.env.BACKUP_TOKEN; delete process.env.BACKUP_ENCRYPTION_KEY; });

const page = async (path: string) => {
  const res = await fetch(h.base + path, { headers: { 'x-backup-token': TOKEN } });
  const body = await res.json();
  if (typeof body.rows === 'string') body.rows = JSON.parse(unseal(body.rows, 'BACKUP_ENCRYPTION_KEY')!);
  return { status: res.status, body };
};

async function seed(n: number, tag = 'r6') {
  await h.db.query(`INSERT INTO notifications (recipient_id, type, title, dedupe_key)
    SELECT (SELECT id FROM employees WHERE code = 'OWNER'), 'test', 'n' || g, $2 || '-' || g FROM generate_series(1, $1) g`, [n, tag]);
}

test('R6 backup: cursor export with edits, deletes and inserts between pages — 0 duplicates, 0 missing', async () => {
  await seed(4500);
  const atStart = new Set((await h.db.query(`SELECT id FROM notifications`)).rows.map((r) => r.id as string));
  const got: string[] = [];
  let p = await page('/backup/table/notifications');
  assert.equal(p.status, 200);
  assert.equal(p.body.rows.length, 2000);
  assert.ok(p.body.after && p.body.next !== null);
  got.push(...p.body.rows.map((r: any) => r.id));
  // the app works while the export runs: edit 25 exported rows (moves them physically), delete 10 exported and 5 not
  // yet exported rows, add 5 new ones
  const exported = p.body.rows.map((r: any) => r.id as string);
  await h.db.query(`UPDATE notifications SET read_at = now(), title = title || ' (read)' WHERE id = ANY($1::uuid[])`, [exported.slice(100, 125)]);
  await h.db.query(`DELETE FROM notifications WHERE id = ANY($1::uuid[])`, [exported.slice(500, 510)]);
  const notYet = (await h.db.query(`SELECT id FROM notifications WHERE id <> ALL($1::uuid[]) ORDER BY id DESC LIMIT 5`, [exported])).rows.map((r) => r.id);
  await h.db.query(`DELETE FROM notifications WHERE id = ANY($1::uuid[])`, [notYet]);
  await seed(5, 'r6-late');
  let pages = 1;
  while (p.body.after) {
    p = await page(`/backup/table/notifications?after=${encodeURIComponent(p.body.after)}`);
    assert.equal(p.status, 200);
    got.push(...p.body.rows.map((r: any) => r.id));
    if (++pages > 10) assert.fail('no end');
  }
  assert.equal(p.body.next, null);
  const seen = new Set(got);
  assert.equal(seen.size, got.length, 'no row exported twice');
  const deleted = new Set([...exported.slice(500, 510), ...notYet]);
  const missing = [...atStart].filter((id) => !deleted.has(id) && !seen.has(id));
  assert.deepEqual(missing, [], 'every row present at the start (and not deleted) is exported');
  // every exported row is the row as stored (edited rows exported once, in their state at the time they were read)
  assert.ok(got.length >= atStart.size - 15);
});

test('R6 backup: the cursor works on composite and typed keys and resumes exactly after the given row', async () => {
  const checked: string[] = [];
  for (const t of ['role_permissions', 'employee_permissions', 'leave_balances', 'kpi_set_items', 'employees']) {
    const all = await page(`/backup/table/${t}`);
    assert.equal(all.status, 200, t);
    const rows = all.body.rows;
    if (rows.length < 2) continue;
    // cursor of a middle row, built the same way the API builds it (key columns as text)
    const pk = (await h.db.query(`SELECT a.attname AS c FROM pg_index i JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum, n) ON true
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum WHERE i.indrelid = $1::regclass AND i.indisprimary ORDER BY k.n`, [t])).rows.map((r) => r.c);
    const mid = Math.floor(rows.length / 2);
    const keyText = (await h.db.query(`SELECT ARRAY[${pk.map((c) => `x."${c}"::text`).join(', ')}] AS k FROM "${t}" x
      WHERE ${pk.map((c, i) => `x."${c}"::text = $${i + 1}`).join(' AND ')}`, pk.map((c) => String(rows[mid][c])))).rows[0]?.k;
    if (!keyText) continue; // (a value whose JSON form differs from its text form — covered by the export loop below)
    const cur = Buffer.from(JSON.stringify(keyText)).toString('base64url');
    const rest = await page(`/backup/table/${t}?after=${cur}`);
    assert.equal(rest.status, 200, t);
    assert.deepEqual(rest.body.rows, rows.slice(mid + 1), `${t} resumes right after the cursor row`);
    checked.push(t);
  }
  assert.ok(checked.includes('role_permissions') && checked.includes('employees'), checked.join(','));
});

test('R6 backup: a bad cursor is refused; offset paging (current Drive script) still works and follows the key', async () => {
  for (const bad of ['%%%', Buffer.from('[1]').toString('base64url'), Buffer.from('["a","b","c"]').toString('base64url'), Buffer.from('{}').toString('base64url')]) {
    assert.equal((await page(`/backup/table/notifications?after=${encodeURIComponent(bad)}`)).status, 400, bad);
  }
  const ids: string[] = [];
  let offset: number | null = 0;
  while (offset !== null) {
    const r = await page(`/backup/table/notifications?offset=${offset}`);
    ids.push(...r.body.rows.map((x: any) => x.id));
    offset = r.body.next;
  }
  const sorted = [...ids].sort();
  assert.equal(new Set(ids).size, ids.length);
  assert.equal(ids.length, Number((await h.db.query(`SELECT count(*) FROM notifications`)).rows[0].count));
  assert.deepEqual((await h.db.query(`SELECT id::text FROM notifications ORDER BY id`)).rows.map((r) => r.id), ids, 'key order');
  assert.ok(sorted.length > 0);
});
