import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { harness, cast, regrantAppRole, type Harness } from './helpers.ts';
import { migrate } from '../src/migrate-core.ts';
import { R2Client } from '../src/lib/r2.ts';
import { setFileStorageForTests } from '../src/lib/files.ts';

/**
 * R2 storage end to end (091 installed by the migration chain). R2 itself is an in-memory stand-in behind the real
 * client (real SigV4 requests, real status codes): no bucket or credential is used in CI.
 */
const objects = new Map<string, { data: Uint8Array; type: string; sha: string }>();
let failPuts = false;
let tamper = false;
const fakeFetch = (async (url: string, init: RequestInit) => {
  const key = new URL(url).pathname;
  const h = init.headers as Record<string, string>;
  assert.match(h.authorization, /^AWS4-HMAC-SHA256 /, 'every request is signed');
  if (init.method === 'PUT') {
    if (failPuts) return new Response('<Error><Code>InternalError</Code></Error>', { status: 500 });
    if (h['if-none-match'] === '*' && objects.has(key)) return new Response('<Error><Code>PreconditionFailed</Code></Error>', { status: 412 });
    objects.set(key, { data: new Uint8Array(init.body as Uint8Array), type: h['content-type'], sha: h['x-amz-meta-sha256'] });
    return new Response(null, { status: 200, headers: { etag: '"e"' } });
  }
  const o = objects.get(key);
  if (!o) return new Response(null, { status: 404 });
  if (init.method === 'HEAD') return new Response(null, { status: 200, headers: { 'content-length': String(o.data.length), 'content-type': o.type, 'x-amz-meta-sha256': o.sha } });
  if (init.method === 'GET') return new Response((tamper ? new Uint8Array([1, 2, 3]) : o.data) as unknown as BodyInit, { status: 200, headers: { 'content-type': o.type } });
  return new Response(null, { status: 405 });
}) as unknown as typeof fetch;

let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let pid: string; let channel: string;
before(async () => {
  h = await harness('2026-11-25T08:00:00Z'); c = await cast(h);
  await migrate(h.db); await regrantAppRole(h);   // the releases the template leaves out: 066, 083-089, 091 (R2)
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'مشروع R2', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  channel = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
  setFileStorageForTests(new R2Client({ accountId: 'a'.repeat(32), accessKeyId: 'AKID', secretAccessKey: 'SECRET', bucket: 'valunivo-files', jurisdiction: 'eu' }, fakeFetch));
});
after(async () => { setFileStorageForTests(undefined); await h.close(); });

const lead = async (name: string, phone: string) =>
  (await h.call(c.t.acc, 'POST', '/leads', { fullName: name, phone, projectId: pid, channelId: channel, assignees: [c.ids.e2] })).body.lead;
const pdf = (n: number) => Buffer.concat([Buffer.from('%PDF-1.4 '), Buffer.alloc(n, 7)]);

test('lead attachment goes to R2: verified, linked, bytes not in Postgres, integrity-checked download, permission kept', async () => {
  const l = await lead('عميل R2', '01030000101');
  const buf = pdf(500);
  const up = await h.call(c.t.e2, 'POST', `/leads/${l.id}/attachments`, { fileName: 'عقد.pdf', data: buf.toString('base64') });
  assert.equal(up.status, 201, JSON.stringify(up.body));
  const row = (await h.db.query(`SELECT data, data_file_id FROM lead_attachments WHERE id = $1`, [up.body.attachment.id])).rows[0];
  assert.equal(row.data, null, 'no bytes in Postgres');
  const f = (await h.db.query(`SELECT * FROM file_objects WHERE id = $1`, [row.data_file_id])).rows[0];
  assert.equal(f.status, 'verified');
  assert.equal(f.ref_count, 1);
  assert.equal(f.retention_class, 'crm');
  assert.equal(f.sha256, createHash('sha256').update(buf).digest('hex'));
  assert.match(f.object_key, /^staging\/lead_attachment\/\d{4}\/\d{2}\/[0-9a-f-]{36}$/, 'server-made key, no user text');
  assert.ok(!f.object_key.includes('عقد'));

  const dl = await h.call(c.t.e2, 'GET', `/leads/attachments/${up.body.attachment.id}`);
  assert.equal(dl.status, 200);
  assert.deepEqual(Buffer.from(dl.body.data, 'base64'), buf);
  assert.ok(!JSON.stringify(dl.body).includes('r2.cloudflarestorage.com'), 'no storage URL leaves the API');
  assert.equal((await h.call(c.t.e1, 'GET', `/leads/attachments/${up.body.attachment.id}`)).status, 404, 'other salesman: not his lead');

  tamper = true;
  assert.equal((await h.call(c.t.e2, 'GET', `/leads/attachments/${up.body.attachment.id}`)).status, 503, 'tampered object refused');
  tamper = false;
});

test('storage down: clear 503, no row, file record left as orphan (never linkable)', async () => {
  const l = await lead('عميل عطل', '01030000102');
  failPuts = true;
  const r = await h.call(c.t.e2, 'POST', `/leads/${l.id}/attachments`, { fileName: 'x.pdf', data: pdf(100).toString('base64') });
  failPuts = false;
  assert.equal(r.status, 503, JSON.stringify(r.body));
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM lead_attachments WHERE lead_id = $1`, [l.id])).rows[0].count), 0);
  const orphan = (await h.db.query(`SELECT status, ref_count FROM file_objects WHERE status = 'orphan'`)).rows;
  assert.equal(orphan.length, 1);
  assert.equal(orphan[0].ref_count, 0);
});

test('a stored file record cannot be deleted, re-pointed or detached while linked', async () => {
  const f = (await h.db.query(`SELECT id FROM file_objects WHERE ref_count = 1 LIMIT 1`)).rows[0];
  await assert.rejects(h.db.query(`DELETE FROM file_objects WHERE id = $1`, [f.id]), /never deleted/);
  await assert.rejects(h.db.query(`UPDATE file_objects SET object_key = 'staging/lead_attachment/2026/11/00000000-0000-4000-8000-000000000000' WHERE id = $1`, [f.id]), /preserved exactly/);
  await assert.rejects(h.db.query(`UPDATE file_objects SET status = 'detached' WHERE id = $1`, [f.id]), /still referenced/);
});

test('D4: a duplicate lead\'s attachments move to the lead that stays (never deleted)', async () => {
  const a1 = await lead('عميل مكرر', '01030000103');
  const up = await h.call(c.t.e2, 'POST', `/leads/${a1.id}/attachments`, { fileName: 'بطاقة.pdf', data: pdf(50).toString('base64') });
  assert.equal(up.status, 201);
  const before = Number((await h.db.query(`SELECT count(*) FROM lead_attachments`)).rows[0].count);
  const fileId = (await h.db.query(`SELECT data_file_id FROM lead_attachments WHERE id = $1`, [up.body.attachment.id])).rows[0].data_file_id;
  // the API's merge paths move rows with UPDATE ... SET lead_id; the file stays linked through it
  const a2 = await lead('عميل مكرر ٢', '01030000104');
  await h.db.query(`UPDATE lead_attachments SET lead_id = $2 WHERE lead_id = $1`, [a1.id, a2.id]);
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM lead_attachments`)).rows[0].count), before);
  assert.equal((await h.db.query(`SELECT ref_count FROM file_objects WHERE id = $1`, [fileId])).rows[0].ref_count, 1);
});

test('D3: data-reset refused entirely while posted money records exist; nothing is wiped', async () => {
  const adv = await h.call(c.t.owner, 'POST', '/admin/opening-advance', { employeeId: c.ids.e1, amount: 500, month: '2026-11', note: 'سلفة' });
  assert.equal(adv.status, 201, JSON.stringify(adv.body));
  const leadsBefore = Number((await h.db.query(`SELECT count(*) FROM leads`)).rows[0].count);
  const dry = await h.call(c.t.owner, 'POST', '/admin/data-reset', { employees: [], attendance: [] });
  assert.equal(dry.status, 200);
  assert.ok(dry.body.blockers.some((b: any) => b.table === 'advance_requests' && b.rows >= 1), JSON.stringify(dry.body.blockers));
  const res = await h.call(c.t.owner, 'POST', '/admin/data-reset', { employees: [], attendance: [], dryRun: false, confirm: 'امسح البيانات' });
  assert.equal(res.status, 409, JSON.stringify(res.body));
  assert.ok(JSON.stringify(res.body).includes('protected_data'));
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM leads`)).rows[0].count), leadsBefore, 'nothing wiped');
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM advance_requests`)).rows[0].count) >= 1, true);
});
