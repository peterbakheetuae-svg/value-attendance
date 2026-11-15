import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

// Finance / treasury: each financial action on its own permission, checked at the operation; box scope; no self
// approval; double decisions refused; a revoked permission stops at once (throwaway database; before migration 066
// the fine keys resolve to the keys they were split from).
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let gmId = ''; let tGm = '';
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  gmId = gm.body.id;
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gmId]);
  tGm = await h.login('GM1', PW);
  await h.call(tGm, 'POST', '/cash/adjustments', { cashbox: 'hr', kind: 'opening', amount: 10000, reason: 'رصيد افتتاحي' });
  await h.call(c.t.owner, 'POST', '/cash/adjustments', { cashbox: 'office', kind: 'opening', amount: 50000, reason: 'رصيد افتتاحي' });
});
after(async () => { await h.close(); });
const me = async (t: string) => (await h.call(t, 'GET', '/me')).body.permissions as string[];
const FINE = ['cash.approve', 'cash.reverse', 'cash.bank_view', 'cash.bank_transfer', 'cash.owner_funds'];

test('/me and the cashbox flags: each financial action resolved on its own', async () => {
  const gm = await me(tGm), hr = await me(c.t.hr), e = await me(c.t.e1);
  for (const k of FINE) { assert.ok(gm.includes(k), `GM ${k}`); assert.ok(!hr.includes(k), `HR ${k}`); assert.ok(!e.includes(k)); }
  assert.ok(gm.includes('finance.dashboard_view') && hr.includes('finance.dashboard_view') && !e.includes('finance.dashboard_view'));
  const can = (await h.call(c.t.hr, 'GET', '/cash/summary')).body.can;
  assert.deepEqual([can.approve, can.reverse, can.bankView, can.bankTransfer, can.ownerFunds], [false, false, false, false, false]);
  const g = (await h.call(tGm, 'GET', '/cash/summary')).body.can;
  assert.deepEqual([g.approve, g.reverse, g.bankView, g.bankTransfer, g.ownerFunds], [true, true, true, true, true]);
});

test('every financial operation refuses an account without its permission (direct API access)', async () => {
  const id = '00000000-0000-4000-8000-000000000000';
  for (const t of [c.t.hr, c.t.e1, c.t.sm1, c.t.acc]) {
    for (const [m, p, b] of [
      ['POST', `/cash/receipts/${id}/reverse`, { reason: 'xxx' }], ['POST', `/cash/expenses/${id}/reverse`, { reason: 'xxx' }],
      ['POST', `/cash/expenses/${id}/decision`, { decision: 'approve' }], ['POST', `/cash/expenses/${id}/review`, {}],
      ['POST', `/cash/transfers/${id}/decision`, { decision: 'approve' }],
      ['GET', '/cash/bank-moves'], ['POST', '/cash/bank-moves', { direction: 'cash_to_bank', amount: 10 }],
      ['GET', '/cash/injections'], ['POST', '/cash/injections', { amount: 10 }], ['PUT', '/cash/owners', { owners: [] }],
      ['POST', '/cash/owner-draws', { amount: 10 }], ['PATCH', '/cash/settings', { expenseApprovalThreshold: 5 }],
    ] as const) {
      assert.equal((await h.call(t, m, p, b)).status, 403, `${m} ${p}`);
    }
  }
  for (const t of [c.t.e1, c.t.sm1]) {
    assert.equal((await h.call(t, 'GET', '/finance/dashboard')).status, 403);
    assert.equal((await h.call(t, 'GET', '/cash/summary')).status, 403);
    assert.equal((await h.call(t, 'GET', '/cash/ledger?cashbox=hr')).status, 403);
    assert.equal((await h.call(t, 'GET', `/finance/employee-account/${c.ids.e2}`)).status, 403, 'another employee\'s account');
  }
  assert.equal((await h.call(c.t.e1, 'GET', `/finance/employee-account/${c.ids.e1}`)).status, 200, 'his own');
  assert.equal((await h.call(c.t.hr, 'GET', '/cash/ledger?cashbox=office')).status, 403, 'HR never sees the office box');
});

test('approval: never your own, never twice; a restriction applies at once', async () => {
  const big = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 5000, category: 'إيجار', reason: 'إيجار', beneficiary: 'المالك' });
  assert.equal(big.body.expense.status, 'pending_approval');
  const eid = big.body.expense.id;
  // the manager restricted from cash.office (the key cash.approve falls back to) → refused
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'cash.office', false)`, [gmId]);
  assert.equal((await h.call(tGm, 'POST', `/cash/expenses/${eid}/decision`, { decision: 'approve' })).status, 403);
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [gmId]);
  const [x, y] = await Promise.all([
    h.call(tGm, 'POST', `/cash/expenses/${eid}/decision`, { decision: 'approve' }),
    h.call(c.t.owner, 'POST', `/cash/expenses/${eid}/decision`, { decision: 'approve' })]);
  assert.deepEqual([x.status, y.status].sort(), [200, 409], 'only one decision wins');
  // an expense the manager recorded himself above the threshold cannot be approved by him
  const mine = await h.call(tGm, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 4000, category: 'صيانة', reason: 'تكييف', beneficiary: 'فني' });
  if (mine.status === 201 && mine.body.expense.status === 'pending_approval') {
    assert.equal((await h.call(tGm, 'POST', `/cash/expenses/${mine.body.expense.id}/decision`, { decision: 'approve' })).status, 403);
  }
  // a transfer request cannot be decided by whoever asked for it
  const t = await h.call(c.t.hr, 'POST', '/cash/transfers', { direction: 'office_to_hr', amount: 1000, reason: 'عجز' });
  assert.equal(t.status, 201);
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/transfers/${t.body.transfer.id}/decision`, { decision: 'approve' })).status, 403);
  // the requester loses the HR cashbox: he can no longer cancel it either
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'cash.hr_operate', false)`, [c.ids.hr]);
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/transfers/${t.body.transfer.id}/cancel`, {})).status, 403);
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.hr]);
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/transfers/${t.body.transfer.id}/cancel`, {})).status, 200);
});

test('reversing needs its permission and a box the account may see; the dashboard follows the boxes', async () => {
  const r = await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 300, payerName: 'عميل', purpose: 'حجز' });
  assert.equal(r.status, 201);
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/receipts/${r.body.receipt.id}/reverse`, { reason: 'غلط' })).status, 403);
  assert.equal((await h.call(tGm, 'POST', `/cash/receipts/${r.body.receipt.id}/reverse`, { reason: 'غلط' })).status, 200);
  assert.equal((await h.call(tGm, 'POST', `/cash/receipts/${r.body.receipt.id}/reverse`, { reason: 'غلط' })).status, 409, 'once');
  assert.equal((await h.call(c.t.hr, 'GET', '/finance/dashboard')).status, 200, 'HR: its own box');
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'cash.hr_view', false)`, [c.ids.hr]);
  assert.equal((await h.call(c.t.hr, 'GET', '/finance/dashboard')).status, 403);
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.hr]);
});
