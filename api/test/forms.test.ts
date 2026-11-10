import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/** استمارات pilot: custody receipt — prefill from the employee record, permanent numbered records, never overwritten. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

const data = (x: Record<string, unknown> = {}) => ({
  employeeName: 'موظف ١', employeeCode: 'E1', jobTitle: 'مستشار عقاري', department: '', directManager: 'مدير فريق أ',
  receiptDate: '2026-03-10', phoneBrand: 'Samsung A15', imei: '356789012345678', lineNumber: '01001234567',
  condition: 'new', conditionOther: '', accessories: ['charger', 'cable'], accessoriesOther: '',
  signEmployeeName: '', signDate: '2026-03-10', custodianName: 'قسم IT', hrName: 'مديرة الموارد البشرية', ...x,
});

test('prefill comes from the employee record; only HR / documents managers use the form', async () => {
  const p = await h.call(c.t.hr, 'GET', `/forms/custody-receipt/prefill/${c.ids.e1}`);
  assert.equal(p.status, 200, JSON.stringify(p.body));
  assert.equal(p.body.prefill.employeeName, 'موظف ١');
  assert.equal(p.body.prefill.employeeCode, 'E1');
  assert.equal(p.body.prefill.directManager, 'مدير فريق أ');
  assert.equal(p.body.templateVersion, 1);
  assert.equal((await h.call(c.t.e1, 'GET', `/forms/custody-receipt/prefill/${c.ids.e1}`)).status, 403);
  assert.equal((await h.call(c.t.e1, 'POST', '/forms/custody-receipts', { employeeId: c.ids.e1, data: data() })).status, 403);
});

test('validation: required fields, condition / accessories "other" need their text', async () => {
  assert.equal((await h.call(c.t.hr, 'POST', '/forms/custody-receipts', { employeeId: c.ids.e1, data: data({ imei: '' }) })).status, 400);
  assert.equal((await h.call(c.t.hr, 'POST', '/forms/custody-receipts', { employeeId: c.ids.e1, data: data({ condition: 'other' }) })).status, 400);
  assert.equal((await h.call(c.t.hr, 'POST', '/forms/custody-receipts', { employeeId: c.ids.e1, data: data({ accessories: ['other'] }) })).status, 400);
  assert.equal((await h.call(c.t.hr, 'POST', '/forms/custody-receipts', { employeeId: c.ids.e1, data: data({ receiptDate: '10/3/2026' }) })).status, 400);
});

test('each save is a new numbered record with its template version; earlier ones reopen unchanged', async () => {
  const r1 = await h.call(c.t.hr, 'POST', '/forms/custody-receipts', { employeeId: c.ids.e1, data: data() });
  assert.equal(r1.status, 201, JSON.stringify(r1.body));
  assert.equal(r1.body.receipt.number, 1);
  assert.equal(r1.body.receipt.templateVersion, 1);
  assert.equal(r1.body.receipt.data.signEmployeeName, 'موظف ١', 'signature name defaults to the employee');
  const r2 = await h.call(c.t.hr, 'POST', '/forms/custody-receipts', { employeeId: c.ids.e1, data: data({ phoneBrand: 'iPhone 13' }) });
  assert.equal(r2.body.receipt.number, 2);
  const again = await h.call(c.t.hr, 'GET', `/forms/custody-receipts/${r1.body.receipt.id}`);
  assert.equal(again.body.receipt.data.phoneBrand, 'Samsung A15', 'not overwritten by the second one');
  const list = (await h.call(c.t.hr, 'GET', '/forms/custody-receipts')).body.receipts;
  assert.equal(list.length, 2);
  // the employee sees his own; others get nothing / 404
  assert.equal((await h.call(c.t.e1, 'GET', '/forms/custody-receipts')).body.receipts.length, 2);
  assert.equal((await h.call(c.t.e2, 'GET', '/forms/custody-receipts')).body.receipts.length, 0);
  assert.equal((await h.call(c.t.e2, 'GET', `/forms/custody-receipts/${r1.body.receipt.id}`)).status, 404);
  // stored in the immutable documents table: the database refuses edits and deletes
  await assert.rejects(h.db.query(`DELETE FROM employee_documents WHERE id = $1`, [r1.body.receipt.id]));
  await assert.rejects(h.db.query(`UPDATE employee_documents SET content = 'x' WHERE id = $1`, [r1.body.receipt.id]));
});

test('laptop custody receipt: its own fields and numbering; prefill offers the employee\'s laptops', async () => {
  const asset = await h.call(c.t.hr, 'POST', '/custody/assets', { assetType: 'laptop', name: 'Dell Latitude 5440', serialNo: 'SN-1234', specs: 'i5 / 16GB' });
  assert.equal(asset.status, 201, JSON.stringify(asset.body));
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.e2}/custody`, { assetId: asset.body.asset.id })).status, 201);
  const pf = (await h.call(c.t.hr, 'GET', `/forms/custody-receipt/prefill/${c.ids.e2}?device=laptop`)).body;
  assert.equal(pf.template, 'laptop_receipt');
  assert.equal(pf.items[0].serialNo, 'SN-1234');
  const d = { employeeName: 'x y', receiptDate: '2026-03-10', signDate: '2026-03-10', brand: 'Dell', serialNo: 'SN-1234', condition: 'new', accessories: ['charger'] };
  assert.equal((await h.call(c.t.hr, 'POST', '/forms/custody-receipts', { employeeId: c.ids.e2, device: 'laptop', data: { ...d, accessories: ['case'] } })).status, 400);
  const r = await h.call(c.t.hr, 'POST', '/forms/custody-receipts', { employeeId: c.ids.e2, device: 'laptop', data: d });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.receipt.number, 1);
  assert.equal(r.body.receipt.device, 'laptop');
  const list = (await h.call(c.t.hr, 'GET', '/forms/custody-receipts?device=laptop')).body.receipts;
  assert.equal(list.length, 1);
});

test('client intro form: any employee files it, his own name is the sales person; employees see only theirs', async () => {
  const d = { date: '2026-11-10', clientName: 'محمد علي', phone: '01012345678', whatsapp: '01012345678', job: 'مهندس', residence: 'التجمع',
    propertyTypes: ['residential', 'medical'] };
  const r = await h.call(c.t.e1, 'POST', '/forms/client-intros', { data: d, salesEmployeeId: c.ids.e2 });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.form.employeeId, c.ids.e1, 'an employee cannot file it under someone else');
  assert.ok(r.body.form.data.salesName.length > 1);
  assert.equal((await h.call(c.t.e1, 'POST', '/forms/client-intros', { data: { ...d, phone: '12' } })).status, 400);
  const hr = await h.call(c.t.hr, 'POST', '/forms/client-intros', { data: d, salesEmployeeId: c.ids.e2 });
  assert.equal(hr.body.form.employeeId, c.ids.e2);
  assert.equal((await h.call(c.t.e1, 'GET', '/forms/client-intros')).body.forms.length, 1);
  assert.equal((await h.call(c.t.hr, 'GET', '/forms/client-intros')).body.forms.length, 2);
});

test('HR / المدير / the owner delete an earlier form; nobody else; numbers are never given again', async () => {
  const perms = (await h.db.query(`SELECT role_key FROM role_permissions WHERE perm_key = 'forms.delete' ORDER BY role_key`)).rows.map((x) => x.role_key);
  assert.deepEqual(perms, ['hr_manager', 'manager', 'owner']);
  const r = await h.call(c.t.hr, 'POST', '/forms/custody-receipts', { employeeId: c.ids.e1, data: data() });
  const id = r.body.receipt.id; const n = r.body.receipt.number;
  assert.equal((await h.call(c.t.hr, 'GET', '/forms/custody-receipts')).body.canDelete, true);
  assert.equal((await h.call(c.t.e1, 'GET', '/forms/custody-receipts')).body.canDelete, false);
  assert.equal((await h.call(c.t.e1, 'DELETE', `/forms/${id}`)).status, 403);
  assert.equal((await h.call(c.t.acc, 'DELETE', `/forms/${id}`)).status, 403);
  const del = await h.call(c.t.hr, 'DELETE', `/forms/${id}`);
  assert.equal(del.status, 200, JSON.stringify(del.body));
  assert.equal((await h.call(c.t.hr, 'GET', `/forms/custody-receipts/${id}`)).status, 404);
  assert.equal((await h.call(c.t.hr, 'DELETE', `/forms/${id}`)).status, 404);
  const log = await h.db.query(`SELECT before FROM audit_log WHERE action = 'forms.delete' AND entity_id = $1`, [id]);
  assert.equal(log.rows[0].before.form.number, n, 'the audit log keeps a copy');
  const next = await h.call(c.t.hr, 'POST', '/forms/custody-receipts', { employeeId: c.ids.e1, data: data() });
  assert.equal(next.body.receipt.number, n + 1, 'a deleted number is not reused');
  // client intros too (owner); other documents stay undeletable
  const ci = (await h.call(c.t.hr, 'GET', '/forms/client-intros')).body.forms[0];
  assert.equal((await h.call(c.t.owner, 'DELETE', `/forms/${ci.id}`)).status, 200);
  const other = await h.db.query(`SELECT id FROM employee_documents WHERE employee_id IS NOT NULL AND file_name NOT LIKE 'custody-receipt-%' AND file_name NOT LIKE 'laptop-receipt-%' AND file_name NOT LIKE 'client-intro-%' LIMIT 1`);
  if (other.rows[0]) assert.equal((await h.call(c.t.hr, 'DELETE', `/forms/${other.rows[0].id}`)).status, 404);
  await assert.rejects(h.db.query(`DELETE FROM employee_documents WHERE id = $1`, [next.body.receipt.id]));
});
