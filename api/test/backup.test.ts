import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness;
before(async () => { h = await harness(); await cast(h); });
after(async () => { await h.close(); delete process.env.BACKUP_TOKEN; });

const get = async (path: string, token?: string) => {
  const res = await fetch(h.base + path, { headers: token ? { 'x-backup-token': token } : {} });
  return { status: res.status, body: res.headers.get('content-type')?.includes('json') ? await res.json() : null };
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
