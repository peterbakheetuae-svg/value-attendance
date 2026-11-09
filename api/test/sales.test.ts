import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { harness, cast, PW, type Harness } from './helpers.ts';

/** Financial system phase 2: unit sales — reservation → down payment → installments, collections, cancellation. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let tGm = ''; let project = ''; let saleId = '';

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE code = 'GM1'`);
  tGm = await h.login('GM1', PW);
  project = (await h.call(tGm, 'POST', '/commissions/projects', { name: 'Kayan', totalPct: 1.5, salesPct: 0.3, managerPct: 0.4, companyPct: 0.8 })).body.project.id;
});
after(async () => { await h.close(); });

test('schedule maths: 4 frequencies, rounding into the last installment, month ends', async () => {
  const { buildSchedule } = await import('../src/modules/sales.ts');
  const q = buildSchedule({ total: 1_000_000, down: 100_000, downDue: '2026-03-15', frequency: 'quarterly', count: 7, installmentAmount: null, firstDue: '2026-06-30' });
  assert.equal(q.length, 8);
  assert.equal(q.reduce((s, x) => s + Math.round(x.amount * 100), 0), 100_000_000, 'down + installments = price exactly');
  assert.equal(q[1].amount, 128571.42);
  assert.equal(q[7].amount, 128571.48, 'rounding difference on the last one');
  assert.deepEqual(q.slice(1, 4).map((x) => x.due), ['2026-06-30', '2026-09-30', '2026-12-30']);
  const m = buildSchedule({ total: 50_000, down: 0, downDue: '2026-01-31', frequency: 'monthly', count: null, installmentAmount: 15_000, firstDue: '2026-01-31' });
  assert.deepEqual(m.slice(1).map((x) => [x.due, x.amount]), [['2026-01-31', 15000], ['2026-02-28', 15000], ['2026-03-31', 15000], ['2026-04-30', 5000]]);
  for (const [f, months] of [['semiannual', 6], ['annual', 12]] as const) {
    const s = buildSchedule({ total: 30, down: 10, downDue: '2026-01-01', frequency: f, count: 2, installmentAmount: null, firstDue: '2026-01-10' });
    assert.equal(s[2].due, months === 6 ? '2026-07-10' : '2027-01-10');
  }
});

test('register a sale: one buyer per unit, schedule generated, totals exact', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', '/sales', {})).status, 400, 'a salesperson may submit, but not an empty sale');
  const body = { projectId: project, unitNo: 'A-101', buyerName: 'أحمد علي', buyerPhone: '0100', totalPrice: 4_500_000, downPayment: 450_000,
    saleDate: '2026-03-10', downPaymentDueDate: '2026-03-20', frequency: 'monthly', installmentsCount: 36, firstDueDate: '2026-04-10' };
  const s = await h.call(c.t.hr, 'POST', '/sales', body);
  assert.equal(s.status, 201, JSON.stringify(s.body));
  saleId = s.body.sale.id;
  assert.equal(s.body.schedule.length, 37);
  assert.equal(s.body.schedule[0].kind, 'down_payment');
  assert.equal(s.body.schedule.reduce((x: number, l: any) => x + Math.round(l.amount * 100), 0), 450_000_000);
  assert.equal(s.body.sale.stage, 'reserved');
  const dup = await h.call(tGm, 'POST', '/sales', { ...body, unitNo: ' a-101 ', buyerName: 'شخص تاني' });
  assert.equal(dup.status, 409);
  assert.equal(dup.body.error.details.reason, 'unit_has_buyer');
  assert.equal((await h.call(tGm, 'POST', '/sales', { ...body, unitNo: 'B-1', downPayment: 5_000_000 })).status, 400, 'down > price');
});

test('reservation then the rest of the down payment, partial installment, no over-collection, receipts in the cashbox', async () => {
  const line0 = (await h.call(c.t.hr, 'GET', `/sales/${saleId}`)).body.schedule[0];
  const ref = randomUUID();
  const r1 = await h.call(c.t.hr, 'POST', `/sales/${saleId}/collect`, { installmentId: line0.id, kind: 'reservation', amount: 50_000, recipient: 'hr', clientRef: ref });
  assert.equal(r1.status, 201, JSON.stringify(r1.body));
  assert.equal(r1.body.receipt.kind, 'reservation');
  assert.equal((await h.call(c.t.hr, 'POST', `/sales/${saleId}/collect`, { installmentId: line0.id, kind: 'reservation', amount: 50_000, recipient: 'hr', clientRef: ref })).status, 200, 'same form twice → one receipt');
  const over = await h.call(c.t.hr, 'POST', `/sales/${saleId}/collect`, { installmentId: line0.id, amount: 400_001, recipient: 'hr' });
  assert.equal(over.status, 422);
  assert.equal(over.body.error.details.reason, 'over_collect');
  const r2 = await h.call(tGm, 'POST', `/sales/${saleId}/collect`, { installmentId: line0.id, amount: 400_000, recipient: 'manager' });
  assert.equal(r2.status, 201);
  assert.equal(r2.body.receipt.cashbox, 'office', 'the manager got it himself');
  assert.equal(r2.body.sale.stage, 'installments');
  assert.equal(r2.body.schedule[0].status, 'paid');
  // installment 1 (100,000): partial 30,000 → partial; remaining 70,000
  const l1 = r2.body.schedule[1];
  const p = await h.call(c.t.hr, 'POST', `/sales/${saleId}/collect`, { installmentId: l1.id, amount: 30_000, recipient: 'hr' });
  assert.equal(p.body.schedule[1].paid, 30_000);
  assert.equal(p.body.schedule[1].remaining, l1.amount - 30_000);
  assert.equal(p.body.schedule[1].status, 'partial');
  assert.equal(p.body.sale.remaining, 4_500_000 - 480_000);
  assert.equal(p.body.receipts.length, 3);
  // cashboxes
  const sum = (await h.call(tGm, 'GET', '/cash/summary')).body;
  assert.equal(sum.hr.bookBalance, 80_000);
  assert.equal(sum.office.bookBalance, 400_000);
  // a sale receipt can't be posted through the plain receipts endpoint
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'installment', amount: 1, payerName: 'xx', purpose: 'xx', saleId })).status, 400);
});

test('installments due page: filters and statuses (overdue / due today / not due)', async () => {
  h.now.value = new Date('2026-04-11T08:00:00Z');
  const all = (await h.call(c.t.hr, 'GET', '/sales/installments/due')).body;
  const first = all.installments.find((x: any) => x.seq === 1);
  assert.equal(first.status, 'overdue', 'due 10 Apr, partly paid, now 11 Apr');
  assert.equal(first.remaining, first.amount - 30_000);
  assert.ok(!all.installments.some((x: any) => x.seq === 0), 'paid lines hidden by default');
  assert.equal((await h.call(c.t.hr, 'GET', '/sales/installments/due?overdue=1')).body.installments.length, 1);
  h.now.value = new Date('2026-05-10T08:00:00Z');
  const today = (await h.call(c.t.hr, 'GET', '/sales/installments/due?today=1')).body.installments;
  assert.equal(today.length, 1);
  assert.equal(today[0].status, 'due');
  assert.equal((await h.call(c.t.hr, 'GET', '/sales/installments/due?buyer=أحمد&from=2026-06-01&to=2026-08-31')).body.installments.length, 3);
  assert.equal((await h.call(c.t.e1, 'GET', '/sales/installments/due')).status, 403);
});

test('cancel (manager / owner) → lines cancelled, collections kept, full refund up to what was collected', async () => {
  assert.equal((await h.call(c.t.hr, 'POST', `/sales/${saleId}/cancel`, { reason: 'العميل انسحب' })).status, 403);
  const x = await h.call(tGm, 'POST', `/sales/${saleId}/cancel`, { reason: 'العميل انسحب' });
  assert.equal(x.status, 200);
  assert.equal(x.body.sale.status, 'cancelled');
  assert.equal(x.body.sale.refundDue, 480_000);
  assert.ok(x.body.schedule.filter((l: any) => l.seq > 1).every((l: any) => l.status === 'cancelled'));
  assert.equal(x.body.receipts.length, 3, 'collections never deleted');
  const over = await h.call(tGm, 'POST', `/sales/${saleId}/refund`, { cashbox: 'office', amount: 480_001 });
  assert.equal(over.body.error.details.reason, 'over_refund');
  const rf = await h.call(tGm, 'POST', `/sales/${saleId}/refund`, { cashbox: 'office', amount: 400_000, reason: 'رد المقدم' });
  assert.equal(rf.body.sale.refundDue, 80_000);
  assert.equal((await h.call(tGm, 'GET', '/cash/summary')).body.office.bookBalance, 0);
  // the unit can be sold again now
  assert.equal((await h.call(c.t.hr, 'POST', '/sales', { projectId: project, unitNo: 'A-101', buyerName: 'مشتري جديد', totalPrice: 1000, downPayment: 1000,
    saleDate: '2026-05-10', downPaymentDueDate: '2026-05-10' })).status, 201);
  // and nothing about the sale can be edited or deleted
  await assert.rejects(h.db.query(`UPDATE sale_installments SET amount_egp = 1 WHERE sale_id = $1`, [saleId]), /cannot be edited/);
  await assert.rejects(h.db.query(`DELETE FROM unit_sales WHERE id = $1`, [saleId]), /never deleted/);
});

test('a salesperson submits a sale with its commission: waits for the management, no collecting before approval', async () => {
  const body = { projectId: project, unitNo: 'S-7', buyerName: 'منى حسن', buyerPhone: '01000000000', totalPrice: 1_000_000, downPayment: 1_000_000,
    saleDate: '2026-03-10', downPaymentDueDate: '2026-03-10', withCommission: true, pricePerM2: 10_000, areaM2: 100 };
  const s = await h.call(c.t.e1, 'POST', '/sales', body);
  assert.equal(s.status, 201, JSON.stringify(s.body));
  assert.equal(s.body.sale.status, 'pending');
  assert.equal(s.body.sale.paymentMethod, 'cash');
  assert.equal(s.body.sale.commission.status, 'pending');
  const id = s.body.sale.id;
  assert.equal((await h.call(c.t.e1, 'POST', '/sales', { ...body, withCommission: false })).body.error.details.reason, 'unit_has_buyer', 'a waiting unit is taken');
  assert.equal((await h.call(c.t.hr, 'POST', `/sales/${id}/collect`, { installmentId: s.body.schedule[0].id, amount: 10, recipient: 'hr' })).status, 409);
  // the salesperson sees only his own; cannot decide
  const mine = (await h.call(c.t.e1, 'GET', '/sales')).body.sales;
  assert.ok(mine.every((x: any) => x.createdBy === c.ids.e1) && mine.length === 1);
  assert.equal((await h.call(c.t.e1, 'POST', `/sales/${id}/decision`, { decision: 'approve' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', `/sales/${id}/decision`, { decision: 'approve' })).status, 403, 'HR records, the management approves');
  const ok = await h.call(tGm, 'POST', `/sales/${id}/decision`, { decision: 'approve' });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(ok.body.sale.status, 'active');
  assert.equal((await h.call(c.t.hr, 'POST', `/sales/${id}/collect`, { installmentId: s.body.schedule[0].id, amount: 10, recipient: 'hr' })).status, 201);
});

test('rejected sale frees the unit and rejects its waiting commission; HR files the commission for the salesperson', async () => {
  const body = { projectId: project, unitNo: 'S-8', buyerName: 'كريم', totalPrice: 500_000, downPayment: 100_000, saleDate: '2026-03-10',
    downPaymentDueDate: '2026-03-15', frequency: 'monthly', installmentsCount: 4, firstDueDate: '2026-04-10', withCommission: true, pricePerM2: 5000, areaM2: 100 };
  const s = await h.call(c.t.e2, 'POST', '/sales', body);
  assert.equal(s.body.sale.paymentMethod, 'installments');
  assert.equal((await h.call(tGm, 'POST', `/sales/${s.body.sale.id}/decision`, { decision: 'reject' })).status, 400, 'a reason is required');
  const rej = await h.call(tGm, 'POST', `/sales/${s.body.sale.id}/decision`, { decision: 'reject', reason: 'السعر غلط' });
  assert.equal(rej.body.sale.status, 'rejected');
  assert.equal(rej.body.sale.commission.status, 'rejected');
  // HR / المدير may file the commission for the salesperson (a salesperson's employeeId is ignored)
  const hr = await h.call(c.t.hr, 'POST', '/sales', { ...body, employeeId: c.ids.e2 });
  assert.equal(hr.status, 201, JSON.stringify(hr.body));
  assert.equal(hr.body.sale.status, 'active', 'HR records directly');
  assert.equal(hr.body.sale.commission.employeeName, 'موظف ٢');
});
