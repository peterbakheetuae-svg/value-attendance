import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { harness, cast, type Harness } from './helpers.ts';
import { receiptListSelect } from '../src/modules/cash.ts';

/**
 * Remediation R3–R6 (docs/SPEED_ENGINEER_AUDIT.md §7): the faster queries must return exactly what the old ones did.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(4000, 7)]).toString('base64');

test('R3: receipt and expense lists no longer read the photo, and return exactly what the single-record read returns', async () => {
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/adjustments', { cashbox: 'hr', kind: 'opening', amount: 90000, reason: 'رصيد افتتاحي' })).status, 201);
  const rc = await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 1500, payerName: 'عميل', purpose: 'حجز',
    clientRef: randomUUID(), attachment: jpeg });
  assert.equal(rc.status, 201, JSON.stringify(rc.body));
  const rcPlain = await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'reservation', amount: 700, payerName: 'عميل ٢', purpose: 'حجز', clientRef: randomUUID() });
  const ex = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 300, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل', attachment: jpeg });
  assert.equal(ex.status, 201, JSON.stringify(ex.body));

  const receipts = await h.call(c.t.hr, 'GET', '/cash/receipts');
  const expenses = await h.call(c.t.hr, 'GET', '/cash/expenses');
  assert.equal(receipts.status, 200); assert.equal(expenses.status, 200);
  const raw = JSON.stringify(receipts.body) + JSON.stringify(expenses.body);
  assert.ok(!raw.includes(jpeg.slice(0, 40)), 'no image bytes in a list');
  // identical to the record the full (unchanged) select returned at creation — every field, including hasAttachment
  assert.deepEqual(receipts.body.receipts.find((x: any) => x.id === rc.body.receipt.id), rc.body.receipt);
  assert.deepEqual(receipts.body.receipts.find((x: any) => x.id === rcPlain.body.receipt.id), rcPlain.body.receipt);
  assert.deepEqual(expenses.body.expenses.find((x: any) => x.id === ex.body.expense.id), ex.body.expense);
  assert.equal(rc.body.receipt.hasAttachment, true);
  assert.equal(rcPlain.body.receipt.hasAttachment, false);
  // the photo is still served by its own permission-checked route
  const photo = await h.call(c.t.owner, 'GET', `/cash/attachment/receipt/${rc.body.receipt.id}`);
  assert.equal(photo.status, 200);
  assert.equal(photo.body.attachment, jpeg);
});

test('R3: the list column set is every column of the table except the photo (follows future migrations)', async () => {
  const sql = await receiptListSelect(h.db);
  assert.ok(!/\br\.\*/.test(sql), 'no r.*');
  assert.ok(!/\br\.(?:"attachment"|attachment)\s*,/.test(sql), 'the photo column itself is not selected');
  assert.match(sql, /\(r\.attachment IS NOT NULL\) AS has_attachment/);
  const cols = (await h.db.query(`SELECT count(*)::int AS n FROM information_schema.columns WHERE table_name = 'cash_receipts' AND table_schema = current_schema()`)).rows[0].n;
  const listed = sql.slice(sql.indexOf('SELECT ') + 7, sql.indexOf(', (r.attachment')).split(', ').length;
  assert.equal(listed, cols - 1);
});
