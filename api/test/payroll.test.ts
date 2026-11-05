import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
// 2026-03-10 Tuesday; Cairo UTC+2. Default schedule 10:00–18:00 (480 min), late grace 15, Friday weekend.
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 9000, $2)`, [c.ids.e1, c.ids.owner]);
  // E1 joined on the 9th so only the 9th and 10th are working days
  await h.db.query(`UPDATE employees SET joining_date = '2026-03-09' WHERE id = $1`, [c.ids.e1]);
});
after(async () => { await h.close(); });
const at = (iso: string) => { h.now.value = new Date(iso); };

test('payroll: rules are off by default — minutes reported, no automatic money', async () => {
  at('2026-03-10T08:40:00Z'); // 10:40 → 40 min late
  await h.call(c.t.e1, 'POST', '/attendance/check-in', {});
  at('2026-03-10T14:00:00Z'); // 16:00 → 120 min early
  await h.call(c.t.e1, 'POST', '/attendance/check-out', {});
  const r = await h.call(c.t.owner, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-03`);
  assert.equal(r.status, 200);
  assert.equal(r.body.payroll.dayWage, 300);
  assert.equal(r.body.payroll.late.minutes, 25, 'minutes after the 15-minute grace');
  assert.equal(r.body.payroll.late.amount, 0);
  assert.equal(r.body.payroll.paidDays, 1, 'the 9th (no attendance) is not paid');
  assert.equal(r.body.payroll.attendanceSalary, 300, 'salary for the days = 1 × 300');
  assert.equal(r.body.payroll.net, 300);
});

test('payroll: per-minute + absence penalty, net to date', async () => {
  const s = await h.call(c.t.owner, 'PATCH', '/settings', { payrollAutoDeductions: true, dayDivisor: 30, deductionMode: 'per_minute', absencePenaltyDays: 1 });
  assert.equal(s.status, 200);
  const r = (await h.call(c.t.owner, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-03`)).body.payroll;
  assert.equal(r.late.amount, 15.63, '25 min × 300/480');
  assert.equal(r.absence.days, 1, 'the 9th has no attendance');
  assert.equal(r.absence.amount, 0, 'penalty 1 day = the unpaid day itself, nothing extra');
  assert.equal(r.early.amount, 75, '120 min × 0.625');
  assert.equal(r.net, Math.round((300 - 15.625 - 75) * 100) / 100);
  await h.call(c.t.owner, 'PATCH', '/settings', { absencePenaltyDays: 2 });
  const r2 = (await h.call(c.t.owner, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-03`)).body.payroll;
  assert.equal(r2.absence.amount, 300, 'penalty 2 days = one extra day');
  await h.call(c.t.owner, 'PATCH', '/settings', { absencePenaltyDays: 1 });
});

test('payroll: tiers — highest tier reached, once per day; same for early leave', async () => {
  await h.call(c.t.owner, 'PATCH', '/settings', { deductionMode: 'tiers',
    lateTiers: [{ afterMinutes: 15, amount: 50 }, { afterMinutes: 30, amount: 100 }, { afterMinutes: 60, amount: 200 }],
    earlyTiers: [{ afterMinutes: 0 + 1, amount: 40 }] });
  const r = (await h.call(c.t.owner, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-03`)).body.payroll;
  assert.equal(r.late.amount, 100, '40 min passed the 30-minute tier');
  assert.equal(r.early.amount, 40, 'left at 16:00 = 120 min early → tier');
});

test('payroll: simple rule — late > 30 min fixed amount, an hour or more per hour', async () => {
  await h.call(c.t.owner, 'PATCH', '/settings', { deductionMode: 'hourly', lateFixedAfterMinutes: 30, lateFixedAmount: 75, lateHourAmount: 120 });
  const r = (await h.call(c.t.owner, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-03`)).body.payroll;
  assert.equal(r.late.amount, 75, '40 min late → fixed amount');
  assert.equal(r.early.amount, 0, 'the simple rule is for lateness only');
  assert.equal(r.rules.lateHourAmount, 120);
  assert.equal((await h.call(c.t.owner, 'PATCH', '/settings', { lateFixedAfterMinutes: 90 })).status, 400);
  await h.call(c.t.owner, 'PATCH', '/settings', { deductionMode: 'tiers' });
});

test('payroll: validation and access', async () => {
  assert.equal((await h.call(c.t.owner, 'PATCH', '/settings', { dayDivisor: 28 })).status, 400);
  assert.equal((await h.call(c.t.owner, 'PATCH', '/settings', { lateTiers: Array(7).fill({ afterMinutes: 5, amount: 1 }) })).status, 400);
  assert.equal((await h.call(c.t.owner, 'PATCH', '/settings', { lateTiers: [{ afterMinutes: 5, amount: -1 }] })).status, 400);
  assert.equal((await h.call(c.t.hr, 'PATCH', '/settings', { dayDivisor: 26 })).status, 403, 'HR has no settings.manage');
  assert.equal((await h.call(c.t.e1, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-03`)).status, 200, 'own payslip (original JPH monthly report)');
  assert.equal((await h.call(c.t.e2, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-03`)).status, 403, 'not someone else\'s');
  const list = await h.call(c.t.owner, 'GET', '/reports/payroll?month=2026-03');
  const row = list.body.rows.find((x: any) => x.employee.id === c.ids.e1);
  assert.equal(row.payroll.late.amount, 100);
  const x = await h.call(c.t.owner, 'GET', '/reports/payroll.xlsx?month=2026-03');
  assert.equal(x.status, 200);
});

test('late rule with empty amounts still deducts the late minutes from the salary', async () => {
  const { hourlyLateAmount } = await import('../src/modules/payroll-calc.ts');
  const r = { lateFixedAfterMinutes: 30, lateFixedAmount: 0, lateHourAmount: 0 };
  assert.equal(hourlyLateAmount(r, 20, 1), 0, 'under the limit: nothing');
  assert.equal(hourlyLateAmount(r, 45, 1), 45, 'over half an hour: 45 minutes of pay');
  assert.equal(hourlyLateAmount(r, 90, 1), 90);
  assert.equal(hourlyLateAmount({ ...r, lateFixedAmount: 50 }, 45, 1), 50, 'a set amount wins');
  assert.equal(hourlyLateAmount({ ...r, lateHourAmount: 120 }, 90, 1), 180);
  assert.equal(hourlyLateAmount(r, 45, null), 0, 'no salary, no amount: nothing to deduct');
});
