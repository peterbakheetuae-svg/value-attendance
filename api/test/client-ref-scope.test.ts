// clientRef retries are answered only to the person who sent the form, and only for the same operation on the same target
// (sale, installment, cashbox, kind, amount …). Anything else gets a plain 409 (client_ref_reused) and none of the
// original row — no amount, payer, phone or receipt number. Concurrent identical sends make one record, never a 500.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { harness, cast, PW, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let project = '';
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE code = 'GM1'`);
  const tGm = await h.login('GM1', PW);
  project = (await h.call(tGm, 'POST', '/commissions/projects', { name: 'CR', totalPct: 1.5, salesPct: 0.3, managerPct: 0.4, companyPct: 0.8 })).body.project.id;
  await h.call(tGm, 'POST', '/cash/adjustments', { cashbox: 'office', kind: 'opening', amount: 500_000, reason: 'رصيد افتتاحي' });
});
let n = 0;
async function sale() {
  const s = await h.call(c.t.hr, 'POST', '/sales', { projectId: project, unitNo: `CR-${++n}`, buyerName: 'مشتري', buyerPhone: '0105550' + String(1000 + n),
    totalPrice: 100_000, downPayment: 10_000, saleDate: '2026-03-10', downPaymentDueDate: '2026-03-20', frequency: 'monthly', installmentsCount: 3, firstDueDate: '2026-04-10' });
  assert.equal(s.status, 201, JSON.stringify(s.body));
  return { id: s.body.sale.id as string, lines: s.body.schedule as any[] };
}
const receiptsOf = async (saleId: string) => (await h.db.query(`SELECT id, amount_egp FROM cash_receipts WHERE sale_id = $1 ORDER BY ref_no`, [saleId])).rows;
const reason = (r: any) => r.body?.error?.details?.reason;
after(async () => { await h.close(); });

const leaks = (body: unknown, ...secrets: string[]) => secrets.some((s) => JSON.stringify(body).includes(s));

test('receipts: the sender retries and gets his receipt; another user with the same clientRef gets 409 and nothing of it', async () => {
  const ref = randomUUID();
  const office = { recipient: 'manager', kind: 'reservation', amount: 31337, payerName: 'عميل سري', payerPhone: '01099990000', purpose: 'حجز وحدة Z-9', clientRef: ref };
  const first = await h.call(c.t.owner, 'POST', '/cash/receipts', office);
  assert.equal(first.status, 201, JSON.stringify(first.body));
  const retry = await h.call(c.t.owner, 'POST', '/cash/receipts', office);
  assert.equal(retry.status, 200); assert.equal(retry.body.duplicate, true); assert.equal(retry.body.receipt.id, first.body.receipt.id);

  // the accountant (HR cashbox only) presents the owner's reference with a form of his own
  const other = await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 1, payerName: 'أي حد', purpose: 'تجربة', clientRef: ref });
  assert.equal(other.status, 409, JSON.stringify(other.body));
  assert.equal(other.body.error?.details?.reason ?? other.body.reason ?? other.body.error?.reason, 'client_ref_reused');
  assert.ok(!leaks(other.body, 'عميل سري', '01099990000', '31337', first.body.receipt.receiptNo, first.body.receipt.id), 'nothing of the original receipt');
  const n = Number((await h.db.query(`SELECT count(*) FROM cash_receipts WHERE client_ref = $1`, [ref])).rows[0].count);
  assert.equal(n, 1, 'no second receipt either');
});

test('expenses: the same rule — a foreign clientRef never returns another user\'s expense', async () => {
  const ref = randomUUID();
  const first = await h.call(c.t.owner, 'POST', '/cash/expenses', { cashbox: 'office', amount: 4242, category: 'ضيافة', reason: 'بند خاص', beneficiary: 'مورد سري', clientRef: ref });
  assert.ok([200, 201].includes(first.status), JSON.stringify(first.body));
  const retry = await h.call(c.t.owner, 'POST', '/cash/expenses', { cashbox: 'office', amount: 4242, category: 'ضيافة', reason: 'بند خاص', beneficiary: 'مورد سري', clientRef: ref });
  assert.ok([200, 201].includes(retry.status)); assert.equal(retry.body.duplicate, true);
  const other = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 1, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل', clientRef: ref });
  assert.equal(other.status, 409, JSON.stringify(other.body));
  assert.ok(!leaks(other.body, 'مورد سري', '4242', 'بند خاص'), 'nothing of the original expense');
});

test('sale collection (one line): retry of the same line → its receipt; the same reference on another sale / line / amount → 409, nothing recorded', async () => {
  const a = await sale(), b = await sale(); const ref = randomUUID();
  const body = { installmentId: a.lines[0].id, amount: 1_000, recipient: 'hr', clientRef: ref };
  const first = await h.call(c.t.hr, 'POST', `/sales/${a.id}/collect`, body);
  assert.equal(first.status, 201, JSON.stringify(first.body));
  const retry = await h.call(c.t.hr, 'POST', `/sales/${a.id}/collect`, body);
  assert.equal(retry.status, 200); assert.equal(retry.body.duplicate, true); assert.equal(retry.body.receipt.id, first.body.receipt.id);
  // the reported defect: the same reference on ANOTHER sale used to answer 200 duplicate with sale A's receipt
  const other = await h.call(c.t.hr, 'POST', `/sales/${b.id}/collect`, { ...body, installmentId: b.lines[0].id });
  assert.equal(other.status, 409, JSON.stringify(other.body)); assert.equal(reason(other), 'client_ref_reused');
  assert.ok(!JSON.stringify(other.body).includes(first.body.receipt.id), 'never the other sale\'s receipt');
  assert.equal((await receiptsOf(b.id)).length, 0, 'and nothing recorded on sale B');
  assert.equal(reason(await h.call(c.t.hr, 'POST', `/sales/${a.id}/collect`, { ...body, installmentId: a.lines[1].id })), 'client_ref_reused', 'another line');
  assert.equal(reason(await h.call(c.t.hr, 'POST', `/sales/${a.id}/collect`, { ...body, amount: 2_000 })), 'client_ref_reused', 'another amount');
  assert.equal((await receiptsOf(a.id)).length, 1);
});

test('sale collection split across installments: still split correctly; its retry → duplicate, nothing new; reused on another sale / kind → 409', async () => {
  const a = await sale(), b = await sale(); const ref = randomUUID();
  const body = { kind: 'installment', amount: 45_000, recipient: 'hr', clientRef: ref };
  const first = await h.call(c.t.hr, 'POST', `/sales/${a.id}/collect-auto`, body);
  assert.equal(first.status, 201, JSON.stringify(first.body));
  assert.equal(first.body.receiptIds.length, 2, '30,000 on installment 1 + 15,000 on installment 2');
  assert.deepEqual((await receiptsOf(a.id)).map((r: any) => Number(r.amount_egp)), [30_000, 15_000]);
  const retry = await h.call(c.t.hr, 'POST', `/sales/${a.id}/collect-auto`, body);
  assert.equal(retry.status, 200); assert.equal(retry.body.duplicate, true);
  assert.deepEqual(retry.body.receiptIds, first.body.receiptIds, 'the retry answers with every receipt of the first send, in order');
  // a different total under the same reference is another collection — even though its first line (30,000) would fit
  for (const amount of [40_000, 50_000, 30_000]) {
    const r = await h.call(c.t.hr, 'POST', `/sales/${a.id}/collect-auto`, { ...body, amount });
    assert.equal(r.status, 409, `amount ${amount}: ${JSON.stringify(r.body)}`); assert.equal(reason(r), 'client_ref_reused');
    assert.ok(!leaks(r.body, ...first.body.receiptIds), 'nothing of the original receipts');
  }
  assert.equal((await receiptsOf(a.id)).length, 2, 'the retry recorded nothing');
  const other = await h.call(c.t.hr, 'POST', `/sales/${b.id}/collect-auto`, body);
  assert.equal(other.status, 409); assert.equal(reason(other), 'client_ref_reused'); assert.equal((await receiptsOf(b.id)).length, 0);
  assert.equal(reason(await h.call(c.t.hr, 'POST', `/sales/${a.id}/collect-auto`, { ...body, kind: 'down_payment', amount: 5_000 })), 'client_ref_reused', 'another kind');
  // the reference of a sale collection is no plain cashbox receipt either
  assert.equal(reason(await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'installment', amount: 30_000, payerName: 'مشتري', purpose: 'قسط', clientRef: ref })), 'client_ref_reused');
});

test('cashbox receipt / expense / owner draw / injection: the same reference with another amount, kind, category or operation → 409', async () => {
  const ref = randomUUID();
  const rc = { recipient: 'hr', kind: 'reservation', amount: 700, payerName: 'عميل', purpose: 'حجز', clientRef: ref };
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/receipts', rc)).status, 201);
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/receipts', rc)).status, 200, 'the same form → the same receipt');
  assert.equal(reason(await h.call(c.t.hr, 'POST', '/cash/receipts', { ...rc, amount: 701 })), 'client_ref_reused');
  assert.equal(reason(await h.call(c.t.hr, 'POST', '/cash/receipts', { ...rc, kind: 'other' })), 'client_ref_reused');
  const er = randomUUID();
  const ex = { cashbox: 'hr', amount: 300, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل', clientRef: er };
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/expenses', ex)).status, 201);
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/expenses', ex)).status, 200);
  assert.equal(reason(await h.call(c.t.hr, 'POST', '/cash/expenses', { ...ex, category: 'إيجار' })), 'client_ref_reused');
  assert.equal(reason(await h.call(c.t.hr, 'POST', '/cash/expenses', { ...ex, amount: 301 })), 'client_ref_reused');
  // the owner's office expense reference is not an owner draw, and an injection reference is not a receipt
  const oe = randomUUID();
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/expenses', { cashbox: 'office', amount: 50, category: 'ضيافة', reason: 'قهوة', beneficiary: 'محل', clientRef: oe })).status, 201);
  assert.equal(reason(await h.call(c.t.owner, 'POST', '/cash/owner-draws', { amount: 50, clientRef: oe })), 'client_ref_reused');
  const ij = randomUUID();
  const inj = await h.call(c.t.owner, 'POST', '/cash/injections', { target: 'office', amount: 1_000, clientRef: ij });
  assert.equal(inj.status, 201, JSON.stringify(inj.body));
  const injAgain = await h.call(c.t.owner, 'POST', '/cash/injections', { target: 'office', amount: 1_000, clientRef: ij });
  assert.equal(injAgain.body.receipt.id, inj.body.receipt.id); assert.equal(injAgain.body.receipt.receiptNo, inj.body.receipt.receiptNo);
  assert.equal(reason(await h.call(c.t.owner, 'POST', '/cash/injections', { target: 'bank', amount: 1_000, clientRef: ij })), 'client_ref_reused');
  assert.equal(reason(await h.call(c.t.owner, 'POST', '/cash/receipts', { recipient: 'manager', kind: 'other', amount: 1_000, payerName: 'x y', purpose: 'xx', clientRef: ij })), 'client_ref_reused');
});

test('concurrent identical sends: one record, every answer the same record, no 500', async () => {
  const ref = randomUUID();
  const rc = { recipient: 'hr', kind: 'reservation', amount: 900, payerName: 'عميل متزامن', purpose: 'حجز', clientRef: ref };
  const rs = await Promise.all(Array.from({ length: 6 }, () => h.call(c.t.hr, 'POST', '/cash/receipts', rc)));
  assert.deepEqual(rs.map((r) => r.status).sort(), [200, 200, 200, 200, 200, 201], JSON.stringify(rs.map((r) => r.body?.error ?? r.status)));
  assert.equal(new Set(rs.map((r) => r.body.receipt.id)).size, 1);
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM cash_receipts WHERE client_ref = $1`, [ref])).rows[0].count), 1);

  const er = randomUUID();
  const ex = { cashbox: 'hr', amount: 120, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل', clientRef: er };
  const es = await Promise.all(Array.from({ length: 5 }, () => h.call(c.t.hr, 'POST', '/cash/expenses', ex)));
  assert.deepEqual(es.map((r) => r.status).sort(), [200, 200, 200, 200, 201]);
  assert.equal(new Set(es.map((r) => r.body.expense.id)).size, 1);

  const a = await sale(); const sr = randomUUID();
  const line = { installmentId: a.lines[1].id, amount: 30_000, recipient: 'hr', clientRef: sr };
  const ls = await Promise.all(Array.from({ length: 4 }, () => h.call(c.t.hr, 'POST', `/sales/${a.id}/collect`, line)));
  assert.deepEqual(ls.map((r) => r.status).sort(), [200, 200, 200, 201], JSON.stringify(ls.map((r) => r.body?.error ?? r.status)));
  const ar = randomUUID();
  const auto = { kind: 'installment', amount: 40_000, recipient: 'hr', clientRef: ar };
  const as = await Promise.all(Array.from({ length: 4 }, () => h.call(c.t.hr, 'POST', `/sales/${a.id}/collect-auto`, auto)));
  assert.deepEqual(as.map((r) => r.status).sort(), [200, 200, 200, 201], JSON.stringify(as.map((r) => r.body?.error ?? r.status)));
  assert.deepEqual((await receiptsOf(a.id)).map((r: any) => Number(r.amount_egp)), [30_000, 30_000, 10_000], 'line 1 once, then 30,000 + 10,000 once');
});
