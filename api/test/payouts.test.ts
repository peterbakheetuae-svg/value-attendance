import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let gmId = ''; let tGm = '';
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير', role: 'manager' });
  gmId = gm.body.id;
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gmId]);
  tGm = await h.login('GM1', PW);
  await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 9000, $2)`, [c.ids.e1, c.ids.owner]);
});
after(async () => { await h.close(); });

test('cash: the manager hands cash to HR; HR confirms; HR payments come out of the HR cashbox (it may go negative)', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', '/payouts', { employeeId: c.ids.e2, kind: 'fund', amount: 5000 })).status, 403);
  assert.equal((await h.call(tGm, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'fund', amount: 5000 })).status, 400, 'cash only to HR');
  const fund = await h.call(tGm, 'POST', '/payouts', { employeeId: c.ids.hr, kind: 'fund', amount: 5000, note: 'عهدة مارس' });
  assert.equal(fund.status, 201);
  assert.equal((await h.call(c.t.hr, 'GET', '/payouts')).body.balance, 0, 'not counted until HR confirms');
  assert.equal((await h.call(c.t.hr, 'POST', `/payouts/${fund.body.payout.id}/receive`, {})).status, 200);
  assert.equal((await h.call(c.t.hr, 'GET', '/payouts')).body.balance, 5000);

  const pay = await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'salary', amount: 3000, month: '2026-03' });
  assert.equal(pay.status, 201);
  assert.equal((await h.call(c.t.hr, 'GET', '/payouts')).body.balance, 2000, 'deducted from HR cash');
  // approved policy: the HR cashbox may go below zero — the deficit is what the office owes it
  const over = await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e2, kind: 'commission', amount: 2500 });
  assert.equal(over.status, 201);
  assert.equal((await h.call(c.t.hr, 'GET', '/payouts')).body.balance, -500);
  assert.equal((await h.call(c.t.hr, 'POST', `/payouts/${over.body.payout.id}/cancel`, {})).status, 200);
  // the employee sees it, confirms receipt; others cannot
  const mine = (await h.call(c.t.e1, 'GET', '/payouts?scope=mine')).body.payouts;
  assert.equal(mine.length, 1);
  assert.equal(mine[0].canReceive, true);
  assert.equal((await h.call(c.t.e2, 'POST', `/payouts/${pay.body.payout.id}/receive`, {})).status, 404);
  assert.equal((await h.call(c.t.e1, 'POST', `/payouts/${pay.body.payout.id}/receive`, {})).status, 200);
  assert.equal((await h.call(c.t.e1, 'POST', `/payouts/${pay.body.payout.id}/receive`, {})).status, 409);
  // shows on the monthly payroll as paid
  const p = (await h.call(c.t.e1, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-03`)).body.payroll;
  assert.equal(p.salaryPaid, 3000);
  assert.equal(p.remaining, Math.round((p.net - 3000) * 100) / 100);
  // a payout not yet received can be cancelled by HR: cash comes back
  const c2 = await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e2, kind: 'work_expense', amount: 500 });
  assert.equal((await h.call(c.t.hr, 'POST', `/payouts/${c2.body.payout.id}/cancel`, {})).status, 200);
  assert.equal((await h.call(c.t.hr, 'GET', '/payouts')).body.balance, 2000);
  assert.equal((await h.call(c.t.e2, 'GET', '/payouts')).body.payouts.length, 2, 'employees see only their own');
});
