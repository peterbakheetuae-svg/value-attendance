import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE company_settings SET require_employee_documents = true`);
});
after(async () => { await h.close(); });

const PDF = Buffer.from('%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF').toString('base64');
const JPG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xff, 0xd9]).toString('base64');
const stage = (tok: string, kind: string, mime: string, data: string) =>
  h.call(tok, 'POST', '/documents/staged', { kind, mime, data, fileName: `${kind}.${mime.split('/')[1]}` });
let empId = '';

test('employee creation is blocked until the three required documents are attached', async () => {
  const base = { code: 'NEW1', fullName: 'موظف جديد', role: 'sales_employee', password: PW };
  const r0 = await h.call(c.t.hr, 'POST', '/employees', base);
  assert.equal(r0.status, 400);
  assert.deepEqual(r0.body.error.details.missing, ['acknowledgment', 'job_description', 'national_id']);
  // type validation: declared type and real content must both be right
  assert.equal((await stage(c.t.hr, 'acknowledgment', 'image/jpeg', JPG)).status, 400, 'acknowledgment must be a PDF');
  assert.equal((await stage(c.t.hr, 'acknowledgment', 'application/pdf', JPG)).status, 400, 'fake PDF');
  assert.equal((await stage(c.t.hr, 'national_id', 'application/pdf', PDF)).status, 400, 'ID must be an image');
  assert.equal((await stage(c.t.e1, 'acknowledgment', 'application/pdf', PDF)).status, 403, 'employees cannot stage');
  const ack = (await stage(c.t.hr, 'acknowledgment', 'application/pdf', PDF)).body.id;
  const jd = (await stage(c.t.hr, 'job_description', 'application/pdf', PDF)).body.id;
  const idc = (await stage(c.t.hr, 'national_id', 'image/jpeg', JPG)).body.id;
  assert.equal((await h.call(c.t.hr, 'POST', '/employees', { ...base, documents: { acknowledgment: jd, jobDescription: ack, nationalId: idc } })).status, 400, 'wrong kinds');
  assert.equal((await h.call(c.t.owner, 'POST', '/employees', { ...base, documents: { acknowledgment: ack, jobDescription: jd, nationalId: idc } })).status, 400, 'someone else staged them');
  const r = await h.call(c.t.hr, 'POST', '/employees', { ...base, documents: { acknowledgment: ack, jobDescription: jd, nationalId: idc } });
  assert.equal(r.status, 201);
  empId = r.body.id;
  const docs = await h.call(c.t.hr, 'GET', `/employees/${empId}/documents`);
  assert.deepEqual(docs.body.missing, []);
  assert.equal(docs.body.required.national_id.mime, 'image/jpeg');
});

test('documents are private and replacing keeps history', async () => {
  const docs = (await h.call(c.t.hr, 'GET', `/employees/${empId}/documents`)).body;
  const ackId = docs.required.acknowledgment.id;
  assert.equal((await h.call(c.t.e1, 'GET', `/documents/${ackId}`)).status, 404, 'other employee');
  assert.equal((await h.call(c.t.sm1, 'GET', `/employees/${empId}/documents`)).status, 404, 'manager without documents.read');
  assert.equal((await h.call(null, 'GET', `/documents/${ackId}`)).status, 401);
  const file = await h.call(c.t.hr, 'GET', `/documents/${ackId}`);
  assert.equal(file.status, 200);
  assert.equal(file.raw.subarray(0, 4).toString(), '%PDF');
  const rep = await h.call(c.t.hr, 'POST', `/employees/${empId}/documents`, { kind: 'acknowledgment', mime: 'application/pdf', data: PDF, fileName: 'v2.pdf' });
  assert.equal(rep.status, 201);
  const after = (await h.call(c.t.hr, 'GET', `/employees/${empId}/documents`)).body;
  assert.equal(after.required.acknowledgment.id, rep.body.id);
  const old = after.documents.find((d: any) => d.id === ackId);
  assert.ok(old.replaced_at && old.replaced_by === rep.body.id, 'old version kept as history');
  await assert.rejects(h.db.query(`DELETE FROM employee_documents WHERE id = $1`, [ackId]));
  await assert.rejects(h.db.query(`UPDATE employee_documents SET content = 'x' WHERE id = $1`, [ackId]));
  assert.equal((await h.call(c.t.e1, 'POST', `/employees/${c.ids.e1}/documents`, { kind: 'national_id', mime: 'image/jpeg', data: JPG, fileName: 'id.jpg' })).status, 403);
  assert.equal((await h.call(c.t.e1, 'POST', `/employees/${c.ids.e1}/documents`, { mime: 'image/jpeg', data: JPG, fileName: 'sick.jpg' })).status, 201, 'own request attachment');
});

test('custody: owner/HR assign, employee sees own, history is permanent', async () => {
  const add = { assetName: 'لابتوب Dell', assetType: 'laptop', serialNo: 'SN-1', condition: 'new', description: 'لابتوب الشغل' };
  assert.equal((await h.call(c.t.sm1, 'POST', `/employees/${c.ids.e1}/custody`, add)).status, 403);
  assert.equal((await h.call(c.t.e1, 'POST', `/employees/${c.ids.e1}/custody`, add)).status, 403);
  const r = await h.call(c.t.hr, 'POST', `/employees/${c.ids.e1}/custody`, add);
  assert.equal(r.status, 201);
  const o = await h.call(c.t.owner, 'POST', `/employees/${c.ids.e1}/custody`, { assetName: 'شريحة', assetType: 'sim' });
  assert.equal(o.status, 201);
  const mine = await h.call(c.t.e1, 'GET', `/employees/${c.ids.e1}/custody`);
  assert.equal(mine.body.items.length, 2);
  assert.equal(mine.body.canManage, false);
  assert.equal((await h.call(c.t.e2, 'GET', `/employees/${c.ids.e1}/custody`)).status, 404);
  assert.equal((await h.call(c.t.sm1, 'GET', `/employees/${c.ids.e1}/custody`)).status, 404, 'manager not authorized by default');
  const n = await h.call(c.t.e1, 'GET', '/notifications');
  assert.ok(n.body.notifications.some((x: any) => x.type === 'custody_assigned'));
  const [x, y] = await Promise.all([
    h.call(c.t.hr, 'POST', `/custody/${r.body.item.id}/close`, { outcome: 'returned', condition: 'good' }),
    h.call(c.t.owner, 'POST', `/custody/${r.body.item.id}/close`, { outcome: 'returned', condition: 'good' })]);
  assert.deepEqual([x.status, y.status].sort(), [200, 409]);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/custody/${r.body.item.id}`, { notes: 'x' })).status, 409);
  await assert.rejects(h.db.query(`DELETE FROM custody_items WHERE id = $1`, [r.body.item.id]));
  const all = await h.call(c.t.hr, 'GET', '/custody?status=assigned');
  assert.equal(all.body.items.length, 1);
  assert.equal((await h.call(c.t.e1, 'GET', '/custody')).status, 403);
});

test('العهدة list: add mobiles / laptops once, hand one to an employee from the list, never to two at once', async () => {
  const m = await h.call(c.t.hr, 'POST', '/custody/assets', { assetType: 'mobile', name: 'Samsung A15', serialNo: '356789012345678', lineNumber: '0100', accessories: ['charger'] });
  assert.equal(m.status, 201, JSON.stringify(m.body));
  assert.equal((await h.call(c.t.hr, 'POST', '/custody/assets', { assetType: 'mobile', name: 'Other', serialNo: '356789012345678' })).status, 409);
  assert.equal((await h.call(c.t.e1, 'POST', '/custody/assets', { assetType: 'laptop', name: 'Dell' })).status, 403);
  const g = await h.call(c.t.hr, 'POST', `/employees/${c.ids.e1}/custody`, { assetId: m.body.asset.id });
  assert.equal(g.status, 201, JSON.stringify(g.body));
  assert.equal(g.body.item.asset_name, 'Samsung A15');
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.e2}/custody`, { assetId: m.body.asset.id })).status, 409);
  const avail = (await h.call(c.t.hr, 'GET', '/custody/assets?type=mobile&available=1')).body.assets;
  assert.ok(!avail.some((x: any) => x.id === m.body.asset.id));
  const all = (await h.call(c.t.hr, 'GET', '/custody/assets')).body.assets;
  assert.equal(all.find((x: any) => x.id === m.body.asset.id).holder.employeeId, c.ids.e1);
});
