import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { harness, cast, PW, type Harness } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

// Settings / remaining finance items: printing and receipt photos, the payer's phone, the office's income vs the
// cashbox, advances for others and the general-manager fallback, data import / reset — each on its own permission,
// exactly as today before migration 066 (throwaway database; the 066 keys are added below only for the last test).
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let tGm = ''; let gmId = ''; let expenseId = '';
const IMG = Buffer.alloc(200, 7).toString('base64');

before(async () => {
  h = await harness('2026-11-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  gmId = gm.body.id;
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gmId]);
  tGm = await h.login('GM1', PW);
  assert.equal((await h.call(tGm, 'POST', '/cash/adjustments', { cashbox: 'hr', kind: 'opening', amount: 10000, reason: 'رصيد افتتاحي' })).status, 201);
  const r = await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'installment', amount: 5000, payerName: 'عميل', payerPhone: '01055500011',
    purpose: 'قسط', clientRef: randomUUID() });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const x = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 300, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل', attachment: IMG });
  assert.equal(x.status, 201, JSON.stringify(x.body));
  expenseId = x.body.expense.id;
});
after(async () => { await h.close(); });

test('before 066: receipts, photos, printing and the office\'s figures exactly as today', async () => {
  const s = (await h.call(c.t.hr, 'GET', '/cash/summary')).body;
  assert.deepEqual([s.can.print, s.can.attachmentView, s.can.attachmentUpload], [true, true, true]);
  assert.equal((await h.call(c.t.hr, 'GET', `/cash/expenses/${expenseId}/attachment`)).status, 200);
  assert.equal((await h.call(c.t.e1, 'GET', `/cash/expenses/${expenseId}/attachment`)).status, 403, 'not his cashbox');
  assert.equal((await h.call(c.t.e1, 'GET', `/cash/attachment/expense/${expenseId}`)).status, 403);
  assert.equal((await h.call(c.t.hr, 'GET', '/cash/receipts')).body.receipts[0].payerPhone, '01055500011');
  const ov = (await h.call(tGm, 'GET', '/cash/overview')).body;
  assert.ok(ov.result && ov.commissionSplit && ov.income.trust, 'the office sees its income and the trust');
  const od = (await h.call(tGm, 'GET', '/dashboard/owner?view=finance')).body;
  assert.ok(od.ring && od.kpis.some((k: any) => k.icon === 'profit'));
  assert.notEqual((await h.call(tGm, 'GET', '/finance/dashboard')).body.operating.officeCommission, null);
});

test('advances for others: HR / finance only; the owner approves when there is no general manager (as before)', async () => {
  assert.equal((await h.call(c.t.e2, 'POST', '/advances', { kind: 'advance', amount: 100, period: '2026-11-01', employeeId: c.ids.e1 })).status, 403);
  const x = await h.call(c.t.hr, 'POST', '/advances', { kind: 'advance', amount: 100, period: '2026-11-01', employeeId: c.ids.e1 });
  assert.equal(x.status, 201, JSON.stringify(x.body));
  assert.equal(x.body.advance.status, 'pending');
  for (const t of [c.t.acc, c.t.sm1, c.t.e2]) assert.equal((await h.call(t, 'POST', `/advances/${x.body.advance.id}/decision`, { decision: 'confirm' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', `/advances/${x.body.advance.id}/decision`, { decision: 'reject' })).body.status, 'rejected');
  assert.ok((await h.call(c.t.owner, 'GET', '/me')).body.permissions.includes('advance.approve_all'));
  assert.ok(!(await h.call(tGm, 'GET', '/me')).body.permissions.includes('advance.approve_all'));
});

test('data import / reset: «استيراد ومسح البيانات» — the owner before 066, nobody by job title', async () => {
  const body = { employees: [] };
  for (const t of [tGm, c.t.hr, c.t.acc]) assert.equal((await h.call(t, 'POST', '/admin/import-permissions', body)).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', '/admin/import-permissions', body)).status, 200);
});

// last: the 066 keys of this module (only these; the migration itself is not run) — each one on its own
test('after 066: each of them is a permission of its own', async () => {
  const keys = ['cash.receipt_print', 'cash.attachment_view', 'cash.attachment_upload', 'finance.company_income', 'exclusive.view_finance',
    'exclusive.view_client', 'advance.create_for_others', 'advance.approve_all', 'data.reset'];
  await h.db.query(`INSERT INTO permissions (key, description) SELECT k, 'x' FROM unnest($1::text[]) k`, [keys]);
  for (const k of ['cash.receipt_print', 'cash.attachment_view', 'cash.attachment_upload', 'exclusive.view_client']) {
    await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) SELECT key, $1 FROM roles ON CONFLICT DO NOTHING`, [k]);
  }
  for (const [k, b] of [['finance.company_income', 'cash.office'], ['exclusive.view_finance', 'cash.office'], ['advance.create_for_others', 'finance.manage'],
    ['advance.create_for_others', 'employee.manage']]) {
    await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) SELECT DISTINCT role_key, $1 FROM role_permissions WHERE perm_key = $2 ON CONFLICT DO NOTHING`, [k, b]);
  }
  for (const k of ['advance.approve_all', 'data.reset']) await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) VALUES ('owner', $1)`, [k]);
  forgetPermissionKeys();
  const deny = (id: string, k: string) => h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, $2, false)`, [id, k]);
  const allow = (id: string, k: string) => h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, $2, true)`, [id, k]);
  const clear = (id: string) => h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [id]);
  // the same as before
  assert.equal((await h.call(c.t.hr, 'GET', `/cash/expenses/${expenseId}/attachment`)).status, 200);
  // the photo: viewing / uploading on their own (the cashbox stays his)
  await deny(c.ids.hr, 'cash.attachment_view');
  assert.equal((await h.call(c.t.hr, 'GET', `/cash/expenses/${expenseId}/attachment`)).status, 403);
  assert.equal((await h.call(c.t.hr, 'GET', '/cash/receipts')).status, 200, 'the cashbox itself stays');
  await clear(c.ids.hr);
  await deny(c.ids.hr, 'cash.attachment_upload');
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/expenses/${expenseId}/attachment`, { attachment: IMG })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 50, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل', attachment: IMG })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 50, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل' })).status, 201);
  await clear(c.ids.hr);
  await deny(c.ids.hr, 'cash.receipt_print');
  assert.equal((await h.call(c.t.hr, 'GET', '/cash/summary')).body.can.print, false);
  await clear(c.ids.hr);
  // the payer's phone: «بيانات العملاء»
  await deny(c.ids.hr, 'exclusive.view_client');
  const rc = (await h.call(c.t.hr, 'GET', '/cash/receipts')).body.receipts;
  assert.ok(rc.length && rc.every((x: any) => x.payerPhone === null));
  await clear(c.ids.hr);
  // the office's income / net and the owners' trust: separate from running the office cashbox
  await deny(gmId, 'finance.company_income');
  const ov = (await h.call(tGm, 'GET', '/cash/overview')).body;
  assert.ok(!ov.result && !ov.commissionSplit && ov.income.commissions === undefined && ov.income.trust, 'no income; the trust stays');
  const od = (await h.call(tGm, 'GET', '/dashboard/owner?view=finance')).body;
  assert.ok(od.ring === null && !od.kpis.some((k: any) => k.icon === 'profit') && od.kpis.some((k: any) => k.icon === 'wallet'));
  const fd = (await h.call(tGm, 'GET', '/finance/dashboard')).body;
  assert.equal(fd.operating.officeCommission, null);
  assert.equal((await h.call(tGm, 'GET', '/finance/dashboard/details?key=op_cover')).status, 403);
  await clear(gmId);
  await deny(gmId, 'exclusive.view_finance');
  const ov2 = (await h.call(tGm, 'GET', '/cash/overview')).body;
  assert.ok(ov2.result && ov2.income.trust === undefined);
  assert.ok(!(await h.call(tGm, 'GET', '/dashboard/owner?view=finance')).body.kpis.some((k: any) => ['percent', 'owner'].includes(k.icon)));
  await clear(gmId);
  // advances for others / approving any: their own permissions
  await deny(c.ids.hr, 'advance.create_for_others');
  assert.equal((await h.call(c.t.hr, 'POST', '/advances', { kind: 'advance', amount: 100, period: '2026-11-01', employeeId: c.ids.e2 })).status, 403);
  await clear(c.ids.hr);
  const x = await h.call(c.t.e2, 'POST', '/advances', { kind: 'advance', amount: 70, period: '2026-11-01' });
  assert.equal((await h.call(c.t.acc, 'POST', `/advances/${x.body.advance.id}/decision`, { decision: 'confirm' })).status, 403);
  await allow(c.ids.acc, 'advance.approve_all');
  assert.equal((await h.call(c.t.acc, 'POST', `/advances/${x.body.advance.id}/decision`, { decision: 'reject' })).body.status, 'rejected');
  await clear(c.ids.acc);
  // data import / reset: by permission, never by job title
  await allow(gmId, 'data.reset');
  assert.equal((await h.call(tGm, 'POST', '/admin/import-permissions', { employees: [] })).status, 200);
  await clear(gmId);
  assert.equal((await h.call(tGm, 'POST', '/admin/import-permissions', { employees: [] })).status, 403);
});
