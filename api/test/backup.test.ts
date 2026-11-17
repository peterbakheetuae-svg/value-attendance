import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

import { unseal } from '../src/lib/secretbox.ts';

// backups are always encrypted (BACKUP_ENCRYPTION_KEY is mandatory for an export)
const BK = Buffer.alloc(32, 9).toString('base64');
let h: Harness;
before(async () => { process.env.BACKUP_ENCRYPTION_KEY = BK; h = await harness(); await cast(h); });
after(async () => { await h.close(); delete process.env.BACKUP_TOKEN; delete process.env.BACKUP_ENCRYPTION_KEY; });

/** a table page as the restore tool reads it: «rows» opened with the backup key */
const get = async (path: string, token?: string) => {
  const res = await fetch(h.base + path, { headers: token ? { 'x-backup-token': token } : {} });
  const body = res.headers.get('content-type')?.includes('json') ? await res.json() : null;
  if (body && typeof body.rows === 'string') body.rows = JSON.parse(unseal(body.rows, 'BACKUP_ENCRYPTION_KEY')!);
  return { status: res.status, body };
};

test('backup export: off without a configured token, wrong token refused, never exports sessions', async () => {
  assert.equal((await get('/backup/tables', 'anything-anything-anything')).status, 401, 'not configured');
  process.env.BACKUP_TOKEN = 'b'.repeat(32);
  assert.equal((await get('/backup/tables')).status, 401);
  assert.equal((await get('/backup/tables', 'c'.repeat(32))).status, 401);
  const t = await get('/backup/tables', 'b'.repeat(32));
  assert.equal(t.status, 200);
  const names = t.body.tables.map((x: any) => x.table);
  assert.ok(names.includes('employees') && names.includes('attendance'));
  assert.ok(!names.includes('sessions') && !names.includes('push_tokens'));
  const e = await get('/backup/table/employees', 'b'.repeat(32));
  assert.equal(e.status, 200);
  assert.ok(e.body.rows.length >= 9);
  assert.equal(e.body.next, null);
  assert.equal((await get('/backup/table/sessions', 'b'.repeat(32))).status, 404);
  assert.equal((await get('/backup/table/pg_user', 'b'.repeat(32))).status, 404);
});

test('minute heartbeat runs the sweep only with the backup token', async () => {
  process.env.BACKUP_TOKEN = 'x'.repeat(30);
  const post = (token?: string) => fetch(h.base + '/backup/sweep', { method: 'POST', headers: token ? { 'x-backup-token': token } : {} });
  assert.equal((await post()).status, 401);
  assert.equal((await post('y'.repeat(30))).status, 401);
  assert.equal((await post('x'.repeat(30))).status, 200);
  delete process.env.BACKUP_TOKEN;
});

test('VA-05: the whole export carries no password hash, session / OTP / push secret, integration token or signing secret', async () => {
  process.env.BACKUP_TOKEN = 'b'.repeat(32);
  const T = 'b'.repeat(32);
  // secrets planted everywhere they can live
  await h.db.query(`INSERT INTO integrations (source, access_token, verify_token, key_hash) VALUES ('meta', 'EAAplaintoken-secret-1', 'verify-secret-2', 'hash-secret-3')
                    ON CONFLICT (source) DO UPDATE SET access_token = EXCLUDED.access_token, verify_token = EXCLUDED.verify_token, key_hash = EXCLUDED.key_hash`);
  await h.db.query(`INSERT INTO meta_pages (page_id, name, access_token) VALUES ('123456', 'P', 'EAApagetoken-secret-4')`);
  const ms = (await h.db.query(`SELECT media_secret FROM company_settings LIMIT 1`)).rows[0]?.media_secret;
  const pw = (await h.db.query(`SELECT password_hash FROM employees WHERE password_hash IS NOT NULL LIMIT 1`)).rows[0].password_hash;
  const secrets = ['EAAplaintoken-secret-1', 'verify-secret-2', 'hash-secret-3', 'EAApagetoken-secret-4', pw, ...(ms ? [String(ms)] : [])];
  const tables = (await get('/backup/tables', T)).body.tables.map((x: any) => x.table);
  for (const t of ['partner_sessions', 'password_otps', 'action_otps', 'partner_email_otps', 'web_push_subscriptions']) {
    assert.ok(!tables.includes(t), `${t} is never exported`);
    assert.equal((await get(`/backup/table/${t}`, T)).status, 404);
  }
  let all = '';
  for (const t of tables) {
    let offset: number | null = 0;
    while (offset !== null) {
      const r = await get(`/backup/table/${t}?offset=${offset}`, T);
      assert.equal(r.status, 200, t);
      all += JSON.stringify(r.body.rows);
      if (t === 'employees') assert.ok(r.body.redacted.includes('password_hash'));
      if (t === 'integrations') assert.deepEqual([...r.body.redacted].sort(), ['access_token', 'key_hash', 'verify_token']);
      offset = r.body.next;
    }
  }
  for (const s of secrets) assert.ok(!all.includes(s), 'a secret leaked into the backup');
  assert.ok(!all.includes('scrypt$'), 'no password hash in any table');
  // the business data is still there (restorable)
  assert.ok(all.includes('"full_name"') && all.includes('"page_id":"123456"'));
});

test('backups encrypted at rest when BACKUP_ENCRYPTION_KEY is set; the decrypt tool restores the rows', async () => {
  const { execFileSync } = await import('node:child_process');
  const { writeFileSync, mkdtempSync } = await import('node:fs');
  const { join } = await import('node:path');
  const { tmpdir } = await import('node:os');
  process.env.BACKUP_TOKEN = 'b'.repeat(32);
  const key = Buffer.alloc(32, 9).toString('base64');
  process.env.BACKUP_ENCRYPTION_KEY = key;
  try {
    const res = await fetch(h.base + '/backup/table/employees', { headers: { 'x-backup-token': 'b'.repeat(32) } });
    const r = { status: res.status, body: await res.json() };   // exactly as the Drive script receives it
    assert.equal(r.status, 200);
    assert.equal(r.body.encrypted, true);
    assert.ok(typeof r.body.rows === 'string' && r.body.rows.startsWith('enc:v1:'));
    assert.ok(!r.body.rows.includes('full_name'), 'nothing readable');
    const dir = mkdtempSync(join(tmpdir(), 'bk-'));
    const file = join(dir, 'employees.json');
    writeFileSync(file, JSON.stringify(r.body.rows));   // exactly what the Drive script stores
    const out = execFileSync('node', [join(process.cwd(), '..', 'tools', 'backup-decrypt.mjs'), file], { env: { ...process.env, BACKUP_ENCRYPTION_KEY: key } }).toString();
    const rows = JSON.parse(out);
    assert.ok(rows.length >= 9 && rows[0].full_name !== undefined && rows.every((x: any) => x.password_hash === null));
  } finally { process.env.BACKUP_ENCRYPTION_KEY = BK; }
});

test('no BACKUP_ENCRYPTION_KEY (or a malformed one) → nothing is exported; the heartbeat still runs; a wrong key cannot open a backup', async () => {
  const { execFileSync } = await import('node:child_process');
  const { writeFileSync, mkdtempSync } = await import('node:fs');
  const { join } = await import('node:path');
  const { tmpdir } = await import('node:os');
  process.env.BACKUP_TOKEN = 'b'.repeat(32);
  const T = 'b'.repeat(32);
  const raw = await fetch(h.base + '/backup/table/employees', { headers: { 'x-backup-token': T } }).then((r) => r.json());
  try {
    for (const bad of [undefined, 'too-short', Buffer.alloc(16).toString('base64')]) {
      if (bad === undefined) delete process.env.BACKUP_ENCRYPTION_KEY; else process.env.BACKUP_ENCRYPTION_KEY = bad;
      for (const p of ['/backup/tables', '/backup/table/employees']) {
        const r = await fetch(h.base + p, { headers: { 'x-backup-token': T } });
        assert.equal(r.status, 422, `${p} with key ${bad}`);
        const b = await r.json();
        assert.equal(b.error.details.reason, 'backup_key_missing');
        assert.ok(!JSON.stringify(b).includes('full_name'), 'no data in the refusal');
      }
      assert.equal((await fetch(h.base + '/backup/sweep', { method: 'POST', headers: { 'x-backup-token': T } })).status, 200, 'heartbeat unaffected');
    }
  } finally { process.env.BACKUP_ENCRYPTION_KEY = BK; }
  // a backup file opened with the wrong key: the tool fails (non-zero), prints nothing of the data
  const dir = mkdtempSync(join(tmpdir(), 'bk-'));
  const file = join(dir, 'employees.json');
  writeFileSync(file, JSON.stringify(raw.rows));
  let failed = false;
  try {
    execFileSync('node', [join(process.cwd(), '..', 'tools', 'backup-decrypt.mjs'), file],
      { env: { ...process.env, BACKUP_ENCRYPTION_KEY: Buffer.alloc(32, 1).toString('base64') }, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e: any) { failed = true; assert.ok(!String(e.stdout ?? '').includes('full_name')); }
  assert.ok(failed, 'wrong key must fail');
});
