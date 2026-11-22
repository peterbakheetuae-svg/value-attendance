// clientRef retries are answered only to the person who sent the form: anybody else presenting the same reference gets
// a plain 409 (client_ref_reused) and none of the original row — no amount, payer, phone or receipt number.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
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
