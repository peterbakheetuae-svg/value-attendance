import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness, asLead } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

/**
 * Owner decision (16 Nov 2026): the payer's phone on receipts keeps its previous behaviour — it is NOT tied to
 * «بيانات العملاء» (exclusive.view_client). Proven on the sale-collection receipt, with the fine key present and denied.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

test('sale collection receipt: payer phone returned even when exclusive.view_client exists and is denied', async () => {
  await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE code = 'GM1'`);
  const tGm = await h.login('GM1', PW);
  const project = (await h.call(tGm, 'POST', '/commissions/projects', { name: 'Kayan', totalPct: 1.5, salesPct: 0.3, managerPct: 0.4, companyPct: 0.8 })).body.project.id;
  const s = await h.call(c.t.hr, 'POST', '/sales', await asLead(h, c.ids.hr, { projectId: project, unitNo: 'P-1', buyerName: 'مشتري', buyerPhone: '01055500077', totalPrice: 100_000,
    downPayment: 10_000, saleDate: '2026-03-10', downPaymentDueDate: '2026-03-20', frequency: 'monthly', installmentsCount: 3, firstDueDate: '2026-04-10' }));
  assert.equal(s.status, 201, JSON.stringify(s.body));
  // the fine key exists (as after 066), granted to every job title, then denied to this HR employee
  await h.db.query(`INSERT INTO permissions (key, description) VALUES ('exclusive.view_client', 'x') ON CONFLICT DO NOTHING`);
  await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) SELECT key, 'exclusive.view_client' FROM roles ON CONFLICT DO NOTHING`);
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'exclusive.view_client', false)`, [c.ids.hr]);
  forgetPermissionKeys();
  const line0 = s.body.schedule[0];
  const r = await h.call(c.t.hr, 'POST', `/sales/${s.body.sale.id}/collect`, { installmentId: line0.id, amount: 1_000, recipient: 'hr' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.receipt.payerPhone, '01055500077', 'the rejected view_client restriction is absent');
  const list = (await h.call(c.t.hr, 'GET', '/cash/receipts')).body.receipts;
  assert.ok(list.some((x: any) => x.payerPhone === '01055500077'));
});
