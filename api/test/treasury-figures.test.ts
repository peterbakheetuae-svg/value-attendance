// The office's own money vs money held for others: total cash + bank, the office's commission revenue, the owners' trust
// and the office's available funds are four different figures. The owners' 800,000 never becomes revenue or profit;
// an internal move between cash and bank creates neither.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-11-10T10:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

test('1,000,000 held = 200,000 office commission + 800,000 owners\' trust — each shown as itself', async () => {
  const pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج الأمانات', ownerName: 'مالك المشروع', ownerPhone: '0100' })).body.project.id;
  const u = await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'T-1', clientName: 'عميل', unitPrice: 5_000_000, depositAmount: 800_000, paymentMethod: 'cash' });
  assert.equal(u.status, 201, JSON.stringify(u.body));
  const r1 = await h.call(c.t.hr, 'POST', `/exclusive/units/${u.body.unit.id}/receipts`, { kind: 'reservation', amount: 800_000 });
  assert.equal(r1.status, 201, JSON.stringify(r1.body));
  const r2 = await h.call(c.t.owner, 'POST', '/cash/receipts', { recipient: 'manager', kind: 'commission', amount: 200_000, payerName: 'مطور', purpose: 'عمولة مشروع' });
  assert.equal(r2.status, 201, JSON.stringify(r2.body));
  const o = (await h.call(c.t.owner, 'GET', '/cash/overview')).body;
  assert.equal(o.available.total, 1_000_000, 'all the money in the boxes and the bank');
  assert.equal(o.available.trust, 800_000, 'held for the owner');
  assert.equal(o.available.afterTrust, 200_000, 'the office\'s available funds');
  assert.equal(o.result.commissions, 200_000, 'office revenue = commissions only');
  assert.equal(o.result.net, 200_000, 'no expense yet: profit = the commission, never the 1,000,000');
  // an internal move (cash → bank inside the office box) creates no revenue and no expense
  const mv = await h.call(c.t.owner, 'POST', '/cash/bank-moves', { direction: 'cash_to_bank', amount: 50_000 });
  assert.ok([200, 201].includes(mv.status), JSON.stringify(mv.body));
  const o2 = (await h.call(c.t.owner, 'GET', '/cash/overview')).body;
  assert.equal(o2.available.office.bank, 50_000); assert.equal(o2.available.office.cash, 150_000);
  assert.equal(o2.available.total, 1_000_000); assert.equal(o2.result.commissions, 200_000); assert.equal(o2.result.net, 200_000);
});
