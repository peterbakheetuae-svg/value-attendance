import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { harness, cast, type Harness, confirmPayout } from './helpers.ts';
import { SECRET_COLUMN } from '../src/modules/backup.ts';

/**
 * The whole backup → restore path, as it would run after a disaster: a database with real activity is exported page by
 * page exactly as the Drive script saves it (encrypted), then api/scripts/backup-restore.mjs loads the folder into a NEW empty
 * database. Every table must come back with the same rows and the same content (credentials aside — never backed up).
 */
const BK = Buffer.alloc(32, 7).toString('base64');
const TOKEN = 't'.repeat(32);
let src: Harness; let dst: Harness; let dir = '';
const JPG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(64, 3)]).toString('base64');
before(async () => {
  process.env.BACKUP_ENCRYPTION_KEY = BK; process.env.BACKUP_TOKEN = TOKEN;
  src = await harness('2026-03-10T08:00:00Z'); const c = await cast(src);
  dst = await harness('2026-03-10T08:00:00Z');
  // real activity: attendance, a leave request, an advance with a photo (binary), cash, a lead, settings
  await src.call(c.t.e1, 'POST', '/attendance/check-in', {});
  await src.call(c.t.e1, 'POST', '/requests', { type: 'full_day_absence', startDate: '2026-03-20', endDate: '2026-03-20', absenceType: 'annual', reason: 'ظرف' });
  await src.call(c.t.e2, 'POST', '/advances', { kind: 'advance', amount: 1500, period: '2026-03-01', note: 'سلفة', attachment: JPG });
  const fund = await src.call(c.t.owner, 'POST', '/payouts', { employeeId: c.ids.hr, kind: 'fund', amount: 9000 });
  await confirmPayout(src, c.t.hr, c.t.owner, fund.body.payout.id);
  await src.call(c.t.e1, 'POST', '/leads', { name: 'عميل تجربة', phone: '01000000001', projectLater: true });
  await src.call(c.t.owner, 'PATCH', '/settings', { breakMinutes: 40 });
  dir = mkdtempSync(join(tmpdir(), 'va-backup-'));
});
after(async () => {
  await src.close(); await dst.close(); if (dir) rmSync(dir, { recursive: true, force: true });
  delete process.env.BACKUP_ENCRYPTION_KEY; delete process.env.BACKUP_TOKEN;
});

const get = async (path: string) => (await fetch(src.base + path, { headers: { 'x-backup-token': TOKEN } })).json();

test('backup (encrypted, as on Drive) → restore into a new database: every table, same rows, same content', async () => {
  // 1) export like backup/google-drive-backup.gs: one file per table (parts when large), «rows» sealed
  const list = await get('/backup/tables');
  for (const t of list.tables) {
    // the keyset cursor (`after`) the Drive script sends since R6; `offset` is the fallback for an older API
    let offset: number | null = 0, after: string | null = null, part = 1;
    do {
      const q: string = after ? `after=${encodeURIComponent(after)}` : `offset=${offset}`;
      const page = await get(`/backup/table/${encodeURIComponent(t.table)}?${q}`);
      assert.equal(page.encrypted, true);
      const name = t.table + (page.next !== null || part > 1 ? '.part' + part : '') + '.json';
      writeFileSync(join(dir, name), JSON.stringify(page.rows));
      offset = page.next; after = page.after ?? null; part++;
    } while (offset !== null);
  }
  // 2) restore with the tool, into the empty database (as a non-superuser would: foreign keys checked pass by pass)
  const u = new URL(process.env.TEST_PG_URL!); u.pathname = '/' + dst.dbName;
  let out = '';
  try {
    out = execFileSync(process.execPath, [new URL('../scripts/backup-restore.mjs', import.meta.url).pathname, dir], {
      env: { ...process.env, DATABASE_URL: u.toString(), BACKUP_ENCRYPTION_KEY: BK, RESTORE_NO_REPLICA: '1' }, encoding: 'utf8', stdio: 'pipe',
    });
  } catch (e: any) {
    assert.fail(`restore failed:\n${String(e.stdout).split('\n').filter((l) => /FAILED|MISMATCH/.test(l)).join('\n')}\n${e.stderr}`);
  }
  assert.match(out, /restore complete/);
  // 3) the same content in every table (secret columns aside)
  let checked = 0;
  for (const t of list.tables.map((x: any) => x.table as string)) {
    const cols = (await src.db.query(`SELECT column_name AS c FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1
                                        ORDER BY ordinal_position`, [t])).rows.map((x) => x.c as string).filter((c) => !SECRET_COLUMN.test(c));
    const q = `SELECT count(*)::int AS n, md5(COALESCE(string_agg(x::text, '|' ORDER BY x::text), '')) AS h
                 FROM (SELECT ${cols.map((c) => `"${c}"`).join(', ')} FROM "${t}") x`;
    const [a, b] = [(await src.db.query(q)).rows[0], (await dst.db.query(q)).rows[0]];
    assert.equal(b.n, a.n, `${t}: row count`);
    if (b.h !== a.h) {
      const rowsOf = async (h: Harness) => (await h.db.query(`SELECT x::text AS r FROM (SELECT ${cols.map((c) => `"${c}"`).join(', ')} FROM "${t}") x ORDER BY 1`)).rows.map((x) => x.r);
      const [ra, rb] = [await rowsOf(src), await rowsOf(dst)];
      assert.fail(`${t}: content differs\nbackup:  ${ra.find((x) => !rb.includes(x))?.slice(0, 900)}\nrestore: ${rb.find((x) => !ra.includes(x))?.slice(0, 900)}`);
    }
    checked++;
  }
  assert.ok(checked > 60, `checked ${checked} tables`);
  // credentials are not restored: nobody signs in with a restored account until HR resets the password
  const hashes = (await dst.db.query(`SELECT DISTINCT password_hash FROM employees`)).rows.map((x) => x.password_hash);
  assert.deepEqual(hashes, ['!restored-reset-required']);
  // new rows after the restore get new ids (sequences moved past the restored ones)
  const r = await dst.db.query(`INSERT INTO audit_log (actor_id, action, entity) VALUES (NULL, 'restore.check', 'x') RETURNING id`);
  assert.ok(r.rows[0].id);
  // never into a database that already has data
  assert.throws(() => execFileSync(process.execPath, [new URL('../scripts/backup-restore.mjs', import.meta.url).pathname, dir], {
    env: { ...process.env, DATABASE_URL: u.toString(), BACKUP_ENCRYPTION_KEY: BK }, encoding: 'utf8', stdio: 'pipe' }), /refused|status 2/);
});
