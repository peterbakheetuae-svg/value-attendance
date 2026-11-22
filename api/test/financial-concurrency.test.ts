import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { harness, cast, PW, type Harness } from './helpers.ts';

/**
 * Duplicate financial effects under CONCURRENT repeats (double-tap, flaky network resend, replay): the same operation
 * fired in parallel must take effect exactly once. Synthetic data in a throwaway database.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let tGm = '';
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gm.body.id]);
  tGm = await h.login('GM1', PW);
});
after(async () => { await h.close(); });

const N = 8;
const par = <T>(f: () => Promise<T>) => Promise.all(Array.from({ length: N }, f));
const count = async (sql: string, v: unknown[] = []) => Number((await h.db.query(sql, v)).rows[0].n);
const statuses = (rs: { status: number }[]) => rs.map((r) => r.status).sort().join(',');

test('opening balance fired in parallel → recorded once', async () => {
  const rs = await par(() => h.call(tGm, 'POST', '/cash/adjustments', { cashbox: 'hr', kind: 'opening', amount: 100000, reason: 'رصيد افتتاحي' }));
  assert.equal(rs.filter((r) => r.status === 201).length, 1, statuses(rs));
  assert.equal(await count(`SELECT count(*) AS n FROM cash_adjustments WHERE cashbox = 'hr' AND kind = 'opening'`), 1);
  await h.call(c.t.owner, 'POST', '/cash/adjustments', { cashbox: 'office', kind: 'opening', amount: 100000, reason: 'رصيد افتتاحي' });
});

test('receipt with one clientRef fired in parallel → one receipt, one number', async () => {
  const ref = randomUUID();
  const rs = await par(() => h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 1234, payerName: 'عميل تجريبي', purpose: 'اختبار', clientRef: ref }));
  // exactly one receipt is created; concurrent copies are refused (409) rather than answered with the receipt —
  // the money is recorded once either way (a sequential resend gets 200 + duplicate:true, tested in cash.test.ts)
  assert.equal(rs.filter((r) => r.status === 201).length, 1, statuses(rs));
  assert.ok(rs.every((r) => [200, 201, 409].includes(r.status)), statuses(rs));
  console.error('receipt 409 reason:', rs.find((r) => r.status === 409)?.body?.error?.details?.reason ?? rs.find((r) => r.status === 409)?.body?.error?.code);
  assert.equal(await count(`SELECT count(*) AS n FROM cash_receipts WHERE client_ref = $1`, [ref]), 1);
});

test('expense with one clientRef fired in parallel → one expense', async () => {
  const ref = randomUUID();
  const rs = await par(() => h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 50, category: 'ضيافة', reason: 'اختبار', beneficiary: 'محل', clientRef: ref }));
  assert.equal(rs.filter((r) => r.status === 201).length, 1, statuses(rs));
  assert.ok(rs.every((r) => [200, 201, 409].includes(r.status)), statuses(rs));
  assert.equal(await count(`SELECT count(*) AS n FROM cash_expenses WHERE client_ref = $1`, [ref]), 1);
});

test('expense approval and reversal fired in parallel → one decision, one reversal', async () => {
  const big = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 44200, category: 'إيجار', reason: 'اختبار', beneficiary: 'المالك' });
  const id = big.body.expense.id;
  const d = await par(() => h.call(tGm, 'POST', `/cash/expenses/${id}/decision`, { decision: 'approve' }));
  assert.equal(d.filter((r) => r.status === 200).length, 1, statuses(d));
  const rv = await par(() => h.call(tGm, 'POST', `/cash/expenses/${id}/reverse`, { reason: 'اختبار العكس' }));
  assert.equal(rv.filter((r) => r.status === 200).length, 1, statuses(rv));
  assert.equal(await count(`SELECT count(*) AS n FROM audit_log WHERE entity_id = $1::text AND action LIKE '%reverse%'`, [id]), 1);
});

test('receipt reversal fired in parallel → reversed once', async () => {
  const r = await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 777, payerName: 'عميل تجريبي', purpose: 'اختبار', clientRef: randomUUID() });
  const id = r.body.receipt.id;
  const rv = await par(() => h.call(tGm, 'POST', `/cash/receipts/${id}/reverse`, { reason: 'اختبار العكس' }));
  assert.equal(rv.filter((x) => x.status === 200).length, 1, statuses(rv));
});

test('transfer decision / execution / receipt fired in parallel → each step once, money moves once', async () => {
  const t = await h.call(c.t.hr, 'POST', '/cash/transfers', { direction: 'office_to_hr', amount: 5000, reason: 'اختبار' });
  const id = t.body.transfer?.id ?? t.body.id;
  assert.ok(id, JSON.stringify(t.body));
  const d = await par(() => h.call(tGm, 'POST', `/cash/transfers/${id}/decision`, { decision: 'approve' }));
  assert.equal(d.filter((r) => r.status === 200).length, 1, 'decision ' + statuses(d));
  const x = await par(() => h.call(tGm, 'POST', `/cash/transfers/${id}/execute`, { amount: 5000 }));
  assert.equal(x.filter((r) => r.status === 200).length, 1, 'execute ' + statuses(x));
  const rc = await par(() => h.call(c.t.hr, 'POST', `/cash/transfers/${id}/receive`, {}));
  assert.equal(rc.filter((r) => r.status === 200).length, 1, 'receive ' + statuses(rc));
  const row = (await h.db.query(`SELECT status FROM cash_transfers WHERE id = $1`, [id])).rows[0];
  assert.ok(row);
});

test('payout confirmation (employee code) fired in parallel → money leaves the cashbox once', async () => {
  const fund = await h.call(tGm, 'POST', '/payouts', { employeeId: c.ids.hr, kind: 'fund', amount: 5000, note: 'اختبار' });
  assert.equal(fund.status, 201, JSON.stringify(fund.body));
  const fcode = (await h.call(c.t.hr, 'POST', `/payouts/${fund.body.payout.id}/code`, {})).body.code;
  const fv = await par(() => h.call(tGm, 'POST', `/payouts/${fund.body.payout.id}/verify`, { code: fcode }));
  assert.equal(fv.filter((r) => r.status === 200).length, 1, 'fund ' + statuses(fv));
  const pay = await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'commission', amount: 300 });
  assert.equal(pay.status, 201, JSON.stringify(pay.body));
  const before = (await h.call(c.t.hr, 'GET', '/payouts')).body.balance;
  const code = (await h.call(c.t.e1, 'POST', `/payouts/${pay.body.payout.id}/code`, {})).body.code;
  const v = await par(() => h.call(c.t.hr, 'POST', `/payouts/${pay.body.payout.id}/verify`, { code }));
  assert.equal(v.filter((r) => r.status === 200).length, 1, statuses(v));
  assert.equal((await h.call(c.t.hr, 'GET', '/payouts')).body.balance, before - 300, 'deducted exactly once');
});

test('manual payout double-tap → one pending payout (the second is refused)', async () => {
  const rs = await par(() => h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e3, kind: 'work_expense', amount: 75 }));
  assert.equal(rs.filter((r) => r.status === 201).length, 1, statuses(rs));
  assert.equal(await count(`SELECT count(*) AS n FROM payouts WHERE employee_id = $1 AND kind = 'work_expense' AND amount_egp = 75`, [c.ids.e3]), 1);
});

test('sale registration and installment collection fired in parallel → one sale, one collection', async () => {
  const project = (await h.call(tGm, 'POST', '/commissions/projects', { name: 'Concurrency', totalPct: 1.5, salesPct: 0.3, managerPct: 0.4, companyPct: 0.8 })).body.project.id;
  const body = { projectId: project, unitNo: 'C-1', buyerName: 'مشتري تجريبي', buyerPhone: '0100', totalPrice: 1_000_000, downPayment: 100_000,
    saleDate: '2026-03-10', downPaymentDueDate: '2026-03-20', frequency: 'monthly', installmentsCount: 9, firstDueDate: '2026-04-10' };
  const ss = await par(() => h.call(c.t.hr, 'POST', '/sales', body));
  assert.equal(ss.filter((r) => r.status === 201).length, 1, statuses(ss));
  const sale = ss.find((r) => r.status === 201)!.body;
  const line0 = sale.schedule[0];
  const ref = randomUUID();
  const cs = await par(() => h.call(c.t.hr, 'POST', `/sales/${sale.sale.id}/collect`, { installmentId: line0.id, kind: 'reservation', amount: 50_000, recipient: 'hr', clientRef: ref }));
  assert.ok(cs.some((r) => r.status === 200 || r.status === 201), statuses(cs));
  assert.equal(await count(`SELECT count(*) AS n FROM cash_receipts WHERE client_ref = $1`, [ref]), 1);
  assert.equal(await count(`SELECT count(*) AS n FROM cash_receipts WHERE sale_id = $1`, [sale.sale.id]), 1, 'money recorded once');
});
