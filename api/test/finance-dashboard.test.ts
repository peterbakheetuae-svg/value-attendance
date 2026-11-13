import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

/** Financial system phase 5: role-based dashboards, the employee account report, monthly indicators (advice only). */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let tGm = '';

before(async () => {
  h = await harness('2026-03-20T08:00:00Z'); c = await cast(h);
  await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE code = 'GM1'`);
  tGm = await h.login('GM1', PW);
  await h.db.query(`INSERT INTO advance_requests (employee_id, kind, period, amount_egp, status, created_by, decided_by, decided_at)
                    VALUES ($1,'advance','2026-03-01',3000,'confirmed',$1,$2,now())`, [c.ids.e1, c.ids.owner]);
});
after(async () => { await h.close(); });

test('dashboard: HR sees the HR side only; the manager also sees office figures', async () => {
  assert.equal((await h.call(c.t.e1, 'GET', '/finance/dashboard')).status, 403);
  const hr = await h.call(c.t.hr, 'GET', '/finance/dashboard?month=2026-03');
  assert.equal(hr.status, 200, JSON.stringify(hr.body));
  assert.equal(hr.body.management, undefined, 'office figures never reach HR');
  assert.equal(hr.body.cash.office, undefined);
  assert.equal(hr.body.hr.outstandingAdvances, 3000);
  const gm = await h.call(tGm, 'GET', '/finance/dashboard?month=2026-03');
  assert.equal(gm.status, 200, JSON.stringify(gm.body));
  assert.ok(gm.body.management && typeof gm.body.management.unitsRemaining === 'number');
  assert.ok(gm.body.cash.office);
});

test('employee account: own always, others only with salary access', async () => {
  const mine = await h.call(c.t.e1, 'GET', `/finance/employee-account/${c.ids.e1}`);
  assert.equal(mine.status, 200, JSON.stringify(mine.body));
  assert.equal(mine.body.advances.length, 1);
  assert.equal((await h.call(c.t.e1, 'GET', `/finance/employee-account/${c.ids.e2}`)).status, 403);
  assert.equal((await h.call(c.t.hr, 'GET', `/finance/employee-account/${c.ids.e1}`)).status, 200);
});

test('indicators: compare with last month, alerts are advice only', async () => {
  assert.equal((await h.call(c.t.e1, 'GET', '/insights/employees?month=2026-03')).status, 403);
  const r = await h.call(tGm, 'GET', '/insights/employees?month=2026-03');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.previousMonth, '2026-02');
  const e1 = r.body.employees.find((x: any) => x.id === c.ids.e1);
  assert.ok(e1 && 'lateCount' in e1.current && 'lateCount' in e1.previous);
  assert.ok(Array.isArray(e1.alerts) && Array.isArray(e1.suggestions));
});

test('each cashbox box opens its list; office lists stay with the management; HR records the HR cashbox only', async () => {
  for (const key of ['collections', 'hr_expenses', 'salaries', 'salaries_paid', 'advances', 'commissions_unpaid', 'commissions',
    'installments_week', 'installments_overdue', 'batches_open', 'down_payments', 'installments_collected']) {
    const r = await h.call(c.t.hr, 'GET', `/finance/dashboard/details?key=${key}&month=2026-03`);
    assert.equal(r.status, 200, `${key}: ${JSON.stringify(r.body)}`);
    assert.ok(Array.isArray(r.body.rows) && typeof r.body.total === 'number');
  }
  assert.equal((await h.call(c.t.hr, 'GET', '/finance/dashboard/details?key=office_expenses')).status, 403);
  assert.equal((await h.call(tGm, 'GET', '/finance/dashboard/details?key=units_remaining')).status, 200);
  assert.equal((await h.call(tGm, 'GET', '/finance/dashboard/details?key=transfers_open')).status, 200);
  const adv = (await h.call(c.t.hr, 'GET', '/finance/dashboard/details?key=advances&month=2026-03')).body;
  assert.equal(adv.total, 3000);
  const d = (await h.call(c.t.hr, 'GET', '/finance/dashboard?month=2026-03')).body;
  assert.ok(typeof d.hr.salariesDue === 'number');
  // تكلفة تشغيل الشهر = المصروفات الثابتة + المرتبات; paid + left = total
  assert.equal(d.operating.total, Math.round((d.operating.fixed + d.operating.salaries) * 100) / 100);
  assert.ok(d.operating.salaries >= 0, 'every salary before any deduction');
  assert.equal(d.operating.remaining, Math.max(Math.round((d.operating.total - d.operating.paid) * 100) / 100, 0));
  // the owner / manager never record money in the HR cashbox
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 50, category: 'بوفيه', reason: 'شاي', beneficiary: 'البوفيه' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'other', amount: 50, payerName: 'عميل', purpose: 'دفعة' })).status, 403);
});
