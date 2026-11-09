import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { harness, cast, PW, type Harness } from './helpers.ts';

/** Financial system phase 1: office cashbox + HR cashbox, transfers, expenses, receipts, permissions, audit. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let gmId = ''; let tGm = '';

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  gmId = gm.body.id;
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gmId]);
  tGm = await h.login('GM1', PW);
});
after(async () => { await h.close(); });

const sum = async (tok: string) => (await h.call(tok, 'GET', '/cash/summary')).body;

test('who sees which cashbox — enforced by the API', async () => {
  const hr = await sum(c.t.hr);
  assert.ok(hr.hr, 'HR sees the HR cashbox');
  assert.equal(hr.office, undefined, 'HR never sees the office cashbox');
  assert.equal(hr.total, undefined);
  assert.equal((await h.call(c.t.hr, 'GET', '/cash/ledger?cashbox=office')).status, 403);
  const gm = await sum(tGm);
  assert.ok(gm.office && gm.hr && gm.total !== undefined, 'manager sees both');
  assert.equal((await h.call(c.t.e1, 'GET', '/cash/summary')).status, 403, 'employees see no cashbox');
  assert.equal((await h.call(c.t.sm1, 'GET', '/cash/summary')).status, 403);
  assert.equal(hr.can.office, false);
});

test('opening balances (once), office collection by the manager, HR collection by HR — numbered receipts, no duplicates', async () => {
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/adjustments', { cashbox: 'hr', kind: 'opening', amount: 10000, reason: 'رصيد افتتاحي' })).status, 403);
  assert.equal((await h.call(tGm, 'POST', '/cash/adjustments', { cashbox: 'hr', kind: 'opening', amount: 10000, reason: 'رصيد افتتاحي' })).status, 201);
  assert.equal((await h.call(tGm, 'POST', '/cash/adjustments', { cashbox: 'hr', kind: 'opening', amount: 1, reason: 'مرة تانية' })).status, 409);
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/adjustments', { cashbox: 'office', kind: 'opening', amount: 50000, reason: 'رصيد افتتاحي' })).status, 201);

  const ref = randomUUID();
  const body = { recipient: 'hr', kind: 'reservation', amount: 20000, payerName: 'أحمد علي', purpose: 'حجز وحدة A-101', clientRef: ref, externalNo: 'B-77' };
  const r1 = await h.call(c.t.hr, 'POST', '/cash/receipts', body);
  assert.equal(r1.status, 201, JSON.stringify(r1.body));
  assert.match(r1.body.receipt.receiptNo, /^R-\d{6}$/);
  assert.equal(r1.body.receipt.cashbox, 'hr');
  assert.equal(r1.body.receipt.actualRecipientId, c.ids.hr);
  const again = await h.call(c.t.hr, 'POST', '/cash/receipts', body);
  assert.equal(again.status, 200, 'same form twice → the same receipt');
  assert.equal(again.body.duplicate, true);
  assert.equal(again.body.receipt.id, r1.body.receipt.id);
  const dupNo = await h.call(c.t.hr, 'POST', '/cash/receipts', { ...body, clientRef: randomUUID(), externalNo: ' b-77 ' });
  assert.equal(dupNo.status, 409, 'paper receipt number used once');
  assert.equal(dupNo.body.error.details.reason, 'duplicate_receipt');

  // HR never collects into the office cashbox, the manager never into the HR one
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'manager', recipientId: gmId, kind: 'down_payment', amount: 30000, payerName: 'سارة', purpose: 'مقدم' })).status, 403);
  assert.equal((await h.call(tGm, 'POST', '/cash/receipts', { ...body, clientRef: randomUUID(), externalNo: null })).status, 403);
  // the manager received cash himself: office cashbox, recorded by him
  const m = await h.call(tGm, 'POST', '/cash/receipts', { recipient: 'manager', kind: 'down_payment', amount: 30000, payerName: 'سارة', purpose: 'مقدم' });
  assert.equal(m.status, 201);
  assert.equal(m.body.receipt.cashbox, 'office');
  assert.equal(m.body.receipt.actualRecipientId, gmId);
  assert.equal((await h.call(c.t.e1, 'POST', '/cash/receipts', body)).status, 403);

  assert.equal((await sum(c.t.hr)).hr.bookBalance, 30000);
  assert.equal((await sum(tGm)).office.bookBalance, 80000);
  // HR sees only its own (HR cashbox) receipts and no office balance
  const hrList = (await h.call(c.t.hr, 'GET', '/cash/receipts')).body.receipts;
  assert.equal(hrList.length, 1);
});

test('HR expenses: direct below 1,000, manager approval above; the HR cashbox may go negative and shows the deficit', async () => {
  const small = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 800, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل' });
  assert.equal(small.body.expense.status, 'posted');
  const big = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 44200, category: 'إيجار', reason: 'إيجار المكتب', beneficiary: 'المالك' });
  assert.equal(big.status, 201);
  assert.equal(big.body.expense.status, 'pending_approval');
  assert.equal((await sum(c.t.hr)).hr.bookBalance, 29200, 'not counted until approved');
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/expenses/${big.body.expense.id}/decision`, { decision: 'approve' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'office', amount: 10, category: 'xx', reason: 'xx', beneficiary: 'xx' })).status, 403);
  assert.equal((await h.call(tGm, 'POST', `/cash/expenses/${big.body.expense.id}/decision`, { decision: 'approve' })).status, 200);
  const s = (await sum(tGm)).hr;
  assert.equal(s.bookBalance, -15000);
  assert.equal(s.deficit, 15000, 'amount the office must transfer');
  // reviewed after payment; reversed by the manager → original kept, balance restored by a reversal line
  assert.equal((await h.call(tGm, 'POST', `/cash/expenses/${small.body.expense.id}/review`, {})).status, 200);
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/expenses/${small.body.expense.id}/reverse`, { reason: 'خطأ' })).status, 403);
  assert.equal((await h.call(tGm, 'POST', `/cash/expenses/${small.body.expense.id}/reverse`, { reason: 'اتسجل بالغلط' })).status, 200);
  assert.equal((await sum(tGm)).hr.bookBalance, -14200);
  const led = (await h.call(tGm, 'GET', '/cash/ledger?cashbox=hr')).body.entries;
  assert.ok(led.some((x: any) => x.type === 'expense' && x.amount === -800) && led.some((x: any) => x.type === 'expense_reversal' && x.amount === 800));
  // the database refuses edits / deletes
  await assert.rejects(h.db.query(`UPDATE cash_expenses SET amount_egp = 1 WHERE id = $1`, [small.body.expense.id]), /cannot be changed/);
  await assert.rejects(h.db.query(`DELETE FROM cash_receipts`), /never deleted/);
});

test('transfer office → HR: HR asks, manager approves and hands over, HR confirms — balances move together only then', async () => {
  const t = await h.call(c.t.hr, 'POST', '/cash/transfers', { direction: 'office_to_hr', amount: 14200, reason: 'تغطية العجز' });
  assert.equal(t.status, 201);
  const id = t.body.transfer.id;
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/transfers/${id}/decision`, { decision: 'approve' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/transfers/${id}/receive`, {})).status, 409, 'nothing handed over yet');
  assert.equal((await h.call(tGm, 'POST', `/cash/transfers/${id}/execute`, {})).status, 409, 'approve first');
  assert.equal((await h.call(tGm, 'POST', `/cash/transfers/${id}/decision`, { decision: 'approve' })).status, 200);
  assert.equal((await h.call(tGm, 'POST', `/cash/transfers/${id}/execute`, { amount: 14200 })).status, 200);
  assert.equal((await sum(tGm)).hr.bookBalance, -14200, 'not moved before receipt');
  assert.equal((await sum(tGm)).hr.incomingTransfers.amount, 14200);
  assert.equal((await h.call(tGm, 'POST', `/cash/transfers/${id}/receive`, {})).status, 403, 'the giver cannot confirm');
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/transfers/${id}/receive`, {})).status, 200);
  const s = await sum(tGm);
  assert.equal(s.hr.bookBalance, 0);
  assert.equal(s.office.bookBalance, 80000 - 14200);
  assert.equal(s.total, 80000 - 14200);
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/transfers/${id}/receive`, {})).status, 409, 'once');
});

test('transfer HR → office: manager asks, HR hands over the actual amount, manager confirms', async () => {
  await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'installment', amount: 50000, payerName: 'محمود', purpose: 'قسط' });
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/transfers', { direction: 'hr_to_office', amount: 1, reason: 'xx' })).status, 403);
  const t = await h.call(tGm, 'POST', '/cash/transfers', { direction: 'hr_to_office', amount: 50000, reason: 'توريد التحصيل' });
  const id = t.body.transfer.id;
  assert.equal((await h.call(tGm, 'POST', `/cash/transfers/${id}/execute`, {})).status, 403, 'HR hands over');
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/transfers/${id}/execute`, { amount: 45000 })).status, 200);
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/transfers/${id}/receive`, {})).status, 403);
  assert.equal((await h.call(tGm, 'POST', `/cash/transfers/${id}/receive`, {})).status, 200);
  const s = await sum(tGm);
  assert.equal(s.hr.bookBalance, 5000);
  assert.equal(s.office.bookBalance, 80000 - 14200 + 45000);
  // every step is in the audit log
  const log = await h.db.query(`SELECT action FROM audit_log WHERE entity = 'cash_transfer' AND entity_id = $1 ORDER BY at, id`, [id]);
  assert.deepEqual(log.rows.map((x) => x.action), ['cash.transfer.request', 'cash.transfer.execute', 'cash.transfer.receive']);
});

test('the existing صرف مالية payments count against the HR cashbox', async () => {
  await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 9000, $2) ON CONFLICT DO NOTHING`, [c.ids.e1, c.ids.owner]);
  const before = (await sum(c.t.hr)).hr.bookBalance;
  const p = await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'salary', amount: 3000, month: '2026-03' });
  assert.equal(p.status, 201);
  assert.equal((await sum(c.t.hr)).hr.bookBalance, before, 'not out of the cashbox until the employee confirms');
  assert.equal((await h.call(c.t.e1, 'POST', `/payouts/${p.body.payout.id}/receive`, {})).status, 200);
  assert.equal((await sum(c.t.hr)).hr.bookBalance, before - 3000);
  assert.equal((await h.call(c.t.hr, 'GET', '/payouts')).body.balance, before - 3000);
});

test('expense approval threshold is a setting (owner / manager only)', async () => {
  assert.equal((await h.call(c.t.hr, 'PATCH', '/cash/settings', { expenseApprovalThreshold: 5000 })).status, 403);
  assert.equal((await h.call(tGm, 'PATCH', '/cash/settings', { expenseApprovalThreshold: 5000 })).status, 200);
  const x = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 4000, category: 'صيانة', reason: 'تكييف', beneficiary: 'فني' });
  assert.equal(x.body.expense.status, 'posted');
});
