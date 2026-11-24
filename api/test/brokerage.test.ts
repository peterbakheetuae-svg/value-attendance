// Resale / rental (proposed migration 087): proposal by the sales employee, approval + distribution by the general manager
// (never by the proposer or a beneficiary), a frozen agreement, commission collected per side as office revenue (the rest a
// receivable, never cash), employee shares → commission entitlements once fully collected, paid once; before 087 nothing.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { harness, cast, regrantAppRole, type Harness } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const SQL = readFileSync(new URL('../../db/proposed/087_brokerage_deals.sql', import.meta.url), 'utf8');
const proposed = (n: string) => readFileSync(new URL(`../../db/proposed/${n}`, import.meta.url), 'utf8');
const reason = (r: any) => r.body?.error?.details?.reason;
const commissionIncome = async () => Number((await h.db.query(`SELECT COALESCE(sum(amount_egp), 0) s FROM cash_receipts WHERE kind = 'commission' AND status = 'posted'`)).rows[0].s);
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

// the client of a deal is ALWAYS an existing lead (never typed): a fresh one per deal, assigned to the proposer
let leadNo = 0;
const leadOf = async (salesId: string) => {
  leadNo++;
  const phone = `0109${String(7000000 + leadNo)}`;
  const pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'مشروع ' + phone, ownerName: 'مالك', ownerPhone: '0100' })).body.project.id;
  const channel = (await h.call(c.t.owner, 'GET', '/leads/meta')).body.channels[0].id;
  const r = await h.call(c.t.owner, 'POST', '/leads', { fullName: `عميل ${leadNo}`, phone, projectId: pid, channelId: channel, assignees: [salesId] });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  return r.body.lead.id as string;
};
const resale = async (o: Record<string, unknown> = {}) => ({ kind: 'resale', property: 'شقة 120م — التجمع', ownerName: 'مالك الشقة',
  leadId: await leadOf(c.ids.e1), price: 2_000_000, ratePct: 2, paidBy: 'both', ownerAmount: 20_000, contributorId: c.ids.e1, closerId: c.ids.e2,
  salesManagerId: c.ids.sm1, ...o });

test('before 087: nothing new — installed:false, a proposal is refused, every other screen unchanged', async () => {
  assert.equal((await h.call(c.t.e1, 'GET', '/brokerage/status')).body.installed, false);
  assert.equal((await h.call(c.t.e1, 'GET', '/brokerage/deals')).body.installed, false);
  assert.equal(reason(await h.call(c.t.e1, 'POST', '/brokerage/deals', await resale())), 'brokerage_not_installed');
  assert.equal((await h.call(c.t.hr, 'GET', '/commissions/entitlements?scope=all')).status, 200);
  await h.db.tx(async (q) => { await q.query(SQL); });
  await h.db.tx(async (q) => { await q.query(SQL); }); // a second run changes nothing
  // the client is picked from the leads (089, on top of the listings 088)
  await h.db.tx(async (q) => { await q.query(proposed('088_brokerage_listings.sql')); });
  await h.db.tx(async (q) => { await q.query(proposed('089_brokerage_deal_lead.sql')); });
  await regrantAppRole(h);
  forgetPermissionKeys();
  // no deal with a typed client: the lead is required, whoever proposes (the owner included)
  const typed = { kind: 'resale', property: 'شقة', ownerName: 'مالك', clientName: 'عميل مكتوب', price: 1_000_000, ratePct: 2, paidBy: 'client' };
  assert.equal(reason(await h.call(c.t.e1, 'POST', '/brokerage/deals', typed)), 'lead_required');
  assert.equal(reason(await h.call(c.t.owner, 'POST', '/brokerage/deals', typed)), 'lead_required');
  assert.equal((await h.call(c.t.e1, 'GET', '/brokerage/status')).body.installed, true);
});

test('resale: 1 % – 2.5 % only; each side\'s share of the commission; contributor and closer are different people', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', '/brokerage/deals', await resale({ ratePct: 3 }))).status, 400);
  assert.equal((await h.call(c.t.e1, 'POST', '/brokerage/deals', await resale({ ratePct: 0.5 }))).status, 400);
  const r = await h.call(c.t.e1, 'POST', '/brokerage/deals', await resale());
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const d = r.body.deal;
  assert.equal(d.commission.total, 40_000); assert.equal(d.commission.owner.due, 20_000); assert.equal(d.commission.client.due, 20_000);
  assert.equal(d.contributor.id, c.ids.e1); assert.equal(d.closer.id, c.ids.e2); assert.equal(d.status, 'proposed');
  const only = await h.call(c.t.e1, 'POST', '/brokerage/deals', await resale({ paidBy: 'client', ratePct: 1 }));
  assert.equal(only.body.deal.commission.client.due, 20_000); assert.equal(only.body.deal.commission.owner.due, 0);
});

test('rental: one month from the owner / the tenant / half each / a fixed amount per side', async () => {
  const base = { kind: 'rental', property: 'شقة مفروشة', ownerName: 'المؤجر', price: 15_000, closerId: c.ids.e2 };
  const terms = async (o: Record<string, unknown>) => (await h.call(c.t.e1, 'POST', '/brokerage/deals', { ...base, leadId: await leadOf(c.ids.e1), ...o })).body.deal.commission;
  assert.deepEqual([(await terms({ arrangement: 'owner_month' })).owner.due, (await terms({ arrangement: 'owner_month' })).client.due], [15_000, 0]);
  const t = await terms({ arrangement: 'client_month' }); assert.deepEqual([t.owner.due, t.client.due], [0, 15_000]);
  const half = await terms({ arrangement: 'half_each', price: 15_001 }); assert.deepEqual([half.owner.due, half.client.due, half.total], [7_500.5, 7_500.5, 15_001]);
  const fixed = await terms({ arrangement: 'fixed', ownerAmount: 4_000, clientAmount: 6_000 }); assert.deepEqual([fixed.owner.due, fixed.client.due, fixed.total], [4_000, 6_000, 10_000]);
  assert.equal((await h.call(c.t.e1, 'POST', '/brokerage/deals', { ...base, leadId: await leadOf(c.ids.e1), arrangement: 'fixed', ownerAmount: 0, clientAmount: 0 })).status, 400);
});

test('approval: only an approver, never the proposer or a beneficiary; distribution within the commission; then frozen', async () => {
  const d = (await h.call(c.t.e1, 'POST', '/brokerage/deals', await resale())).body.deal;
  const shares = [
    { role: 'contributor', employeeId: c.ids.e1, mode: 'pct', value: 25 },
    { role: 'closer', employeeId: c.ids.e2, mode: 'pct', value: 25 },
    { role: 'sales_manager', employeeId: c.ids.sm1, mode: 'fixed', value: 2_000 },
    { role: 'other', beneficiary: 'وسيط خارجي', mode: 'fixed', value: 1_000 },
  ];
  assert.equal((await h.call(c.t.e1, 'POST', `/brokerage/deals/${d.id}/decision`, { decision: 'approve', shares })).status, 403, 'a sales employee');
  assert.equal(reason(await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/decision`, { decision: 'approve', shares: [...shares, { role: 'other', beneficiary: 'زيادة', mode: 'pct', value: 50 }] })), 'over_distributed');
  assert.equal((await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/decision`, { decision: 'approve', shares: [{ role: 'closer', employeeId: c.ids.e3, mode: 'pct', value: 10 }] })).status, 400, 'the closer is E2, not E3');
  assert.equal((await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/decision`, { decision: 'approve', shares: [...shares, { role: 'other', employeeId: c.ids.owner, mode: 'fixed', value: 1 }] })).status, 403, 'no share for the approver');
  // a deal the approver proposed himself
  const own = (await h.call(c.t.owner, 'POST', '/brokerage/deals', await resale({ contributorId: c.ids.e3, closerId: c.ids.e3, salesManagerId: null }))).body.deal;
  assert.equal((await h.call(c.t.owner, 'POST', `/brokerage/deals/${own.id}/decision`, { decision: 'approve', shares: [{ role: 'closer', employeeId: c.ids.e3, mode: 'pct', value: 10 }] })).status, 403);
  const ok = await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/decision`, { decision: 'approve', shares, note: 'تمام' });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  const x = ok.body.deal;
  assert.equal(x.status, 'approved');
  assert.deepEqual(x.shares.map((s: any) => s.amount), [10_000, 10_000, 2_000, 1_000]);
  assert.equal(x.snapshot.office, 17_000); assert.equal(x.snapshot.distributed, 23_000);
  // frozen: the API refuses, and so does the database
  assert.equal((await h.call(c.t.e1, 'PATCH', `/brokerage/deals/${d.id}`, { ratePct: 2.5, paidBy: 'client' })).status, 409);
  await assert.rejects(h.db.query(`UPDATE brokerage_deals SET owner_commission_egp = 1 WHERE id = $1`, [d.id]), /cannot be changed/);
  await assert.rejects(h.db.query(`UPDATE brokerage_shares SET amount_egp = 1 WHERE deal_id = $1`, [d.id]), /cannot be changed/);
  await assert.rejects(h.db.query(`DELETE FROM brokerage_deals WHERE id = $1`, [d.id]), /never deleted/);
  // later edits to the employee do not move the approved snapshot
  await h.db.query(`UPDATE employees SET full_name = 'اسم جديد' WHERE id = $1`, [c.ids.e2]);
  const again = (await h.call(c.t.owner, 'GET', '/brokerage/deals?kind=resale')).body.deals.find((y: any) => y.id === d.id);
  assert.deepEqual(again.snapshot.shares, x.snapshot.shares);
  const a = (await h.db.query(`SELECT action FROM audit_log WHERE entity = 'brokerage_deal' AND entity_id = $1 ORDER BY id`, [d.id])).rows.map((r) => r.action);
  assert.deepEqual(a, ['brokerage.propose', 'brokerage.approve']);
});

test('collection: revenue only when collected, per side, never over; receivable shown; full collection → entitlements, paid once', async () => {
  const d = (await h.call(c.t.e1, 'POST', '/brokerage/deals', await resale())).body.deal;
  assert.equal((await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/collect`, { side: 'owner', amount: 1000, recipient: 'manager' })).status, 409, 'not approved yet');
  await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/decision`, { decision: 'approve', shares: [
    { role: 'contributor', employeeId: c.ids.e1, mode: 'pct', value: 20 }, { role: 'closer', employeeId: c.ids.e2, mode: 'fixed', value: 6_000 },
    { role: 'other', beneficiary: 'شريك خارجي', mode: 'fixed', value: 500 }] });
  const income0 = await commissionIncome();
  const ref = randomUUID();
  const p1 = await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/collect`, { side: 'owner', amount: 15_000, recipient: 'manager', clientRef: ref });
  assert.equal(p1.status, 201, JSON.stringify(p1.body));
  const dup = await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/collect`, { side: 'owner', amount: 15_000, recipient: 'manager', clientRef: ref });
  assert.equal(dup.status, 200); assert.equal(dup.body.receiptId, p1.body.receiptId, 'a retry → the same receipt');
  assert.equal(reason(await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/collect`, { side: 'client', amount: 15_000, recipient: 'manager', clientRef: ref })), 'client_ref_reused');
  assert.equal(reason(await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/collect`, { side: 'owner', amount: 5_001, recipient: 'manager' })), 'over_collect');
  let x = p1.body.deal;
  assert.equal(await commissionIncome() - income0, 15_000, 'office revenue = what was collected, not the 40,000 agreed');
  assert.equal(x.commission.receivable, 25_000); assert.equal(x.commission.owner.receivable, 5_000);
  assert.equal(Number((await h.db.query(`SELECT count(*) n FROM commission_entitlements WHERE brokerage_share_id IS NOT NULL`)).rows[0].n), 0, 'nothing for the staff before it is all in');
  await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/collect`, { side: 'owner', amount: 5_000, recipient: 'manager' });
  x = (await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/collect`, { side: 'client', amount: 20_000, recipient: 'manager' })).body.deal;
  assert.equal(x.status, 'collected'); assert.equal(x.commission.receivable, 0);
  assert.equal(await commissionIncome() - income0, 40_000);
  const ents = (await h.db.query(`SELECT ce.employee_id, ce.role, ce.amount_egp::float8 a, to_char(ce.period, 'YYYY-MM') p FROM commission_entitlements ce
     JOIN brokerage_shares s ON s.id = ce.brokerage_share_id WHERE s.deal_id = $1 ORDER BY a`, [d.id])).rows;
  assert.deepEqual(ents.map((e) => [e.employee_id, e.role, e.a, e.p]), [[c.ids.e2, 'sales', 6_000, '2026-03'], [c.ids.e1, 'sales', 8_000, '2026-03']], 'the external beneficiary is not payroll');
  // listed with the other commissions and paid once through «صرف العمولة»
  const list = (await h.call(c.t.hr, 'GET', '/commissions/entitlements?scope=all')).body.entitlements;
  const mine = list.find((e: any) => e.employeeId === c.ids.e1 && e.amount === 8_000) ?? list.find((e: any) => e.amount === 8_000);
  assert.ok(mine, JSON.stringify(list.slice(0, 3)));
  const pay = await h.call(c.t.hr, 'POST', '/payouts', { kind: 'commission', employeeId: c.ids.e1, amount: 8_000, month: '2026-03', entitlementId: mine.id });
  assert.equal(pay.status, 201, JSON.stringify(pay.body));
  assert.equal((await h.call(c.t.hr, 'POST', '/payouts', { kind: 'commission', employeeId: c.ids.e1, amount: 8_000, month: '2026-03', entitlementId: mine.id })).status, 409);
  assert.equal((await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/collect`, { side: 'client', amount: 1, recipient: 'manager' })).status, 409, 'closed');
  const ov = (await h.call(c.t.owner, 'GET', '/cash/overview')).body.brokerage;
  assert.ok(ov && ov.collected >= 40_000 && ov.receivable >= 0 && Math.round((ov.agreed - ov.collected - ov.receivable) * 100) === 0, JSON.stringify(ov));
});

test('visibility, cancellation and server-side permissions', async () => {
  const d = (await h.call(c.t.e3, 'POST', '/brokerage/deals', { kind: 'rental', property: 'محل', ownerName: 'مالك', leadId: await leadOf(c.ids.e3), price: 9_000, arrangement: 'owner_month' })).body.deal;
  assert.ok(!(await h.call(c.t.e1, 'GET', '/brokerage/deals')).body.deals.some((x: any) => x.id === d.id), 'not his deal');
  assert.ok((await h.call(c.t.e3, 'GET', '/brokerage/deals')).body.deals.some((x: any) => x.id === d.id));
  assert.ok((await h.call(c.t.owner, 'GET', '/brokerage/deals')).body.deals.some((x: any) => x.id === d.id));
  assert.equal((await h.call(c.t.e1, 'POST', `/brokerage/deals/${d.id}/collect`, { side: 'owner', amount: 1, recipient: 'manager' })).status, 403);
  assert.equal((await h.call(c.t.e1, 'POST', `/brokerage/deals/${d.id}/cancel`, {})).status, 403, 'not the proposer');
  assert.equal((await h.call(c.t.e3, 'POST', `/brokerage/deals/${d.id}/cancel`, {})).body.deal.status, 'cancelled');
  assert.equal((await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/decision`, { decision: 'reject' })).status, 409, 'final');
  // an approved deal with money in can no longer be cancelled
  const e = (await h.call(c.t.e3, 'POST', '/brokerage/deals', { kind: 'rental', property: 'مكتب', ownerName: 'مالك', leadId: await leadOf(c.ids.e3), price: 6_000, arrangement: 'half_each' })).body.deal;
  await h.call(c.t.owner, 'POST', `/brokerage/deals/${e.id}/decision`, { decision: 'approve', shares: [{ role: 'closer', employeeId: c.ids.e3, mode: 'pct', value: 30 }] });
  await h.call(c.t.owner, 'POST', `/brokerage/deals/${e.id}/collect`, { side: 'owner', amount: 1_000, recipient: 'manager' });
  assert.equal((await h.call(c.t.owner, 'POST', `/brokerage/deals/${e.id}/cancel`, {})).status, 409);
  const sh = (await h.call(c.t.e3, 'GET', '/brokerage/deals?kind=rental')).body.deals.find((x: any) => x.id === e.id);
  assert.equal(sh.snapshot, null, 'the full snapshot is the manager\'s'); assert.equal(sh.owner.phone, null);
});

// ------------------------------------------------------------------------------------------ reversals and settlements
async function collectedDeal(extra: unknown[] = []) {
  const d = (await h.call(c.t.e1, 'POST', '/brokerage/deals', await resale({ price: 1_000_000, ratePct: 1, paidBy: 'owner' }))).body.deal; // 10,000 from the owner
  const ok = await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/decision`, { decision: 'approve', shares: [
    { role: 'closer', employeeId: c.ids.e2, mode: 'fixed', value: 3_000 }, ...extra] });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  const r = await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/collect`, { side: 'owner', amount: 10_000, recipient: 'manager' });
  assert.equal(r.body.deal.status, 'collected');
  const ent = (await h.db.query(`SELECT ce.* FROM commission_entitlements ce JOIN brokerage_shares s ON s.id = ce.brokerage_share_id WHERE s.deal_id = $1`, [d.id])).rows[0];
  return { id: d.id as string, receiptId: r.body.receiptId as string, ent };
}
const payE2 = (entId: string) => h.call(c.t.hr, 'POST', '/payouts', { kind: 'commission', employeeId: c.ids.e2, amount: 3_000, month: '2026-03', entitlementId: entId });

test('a reversed commission receipt re-opens the deal and cancels its entitlements atomically — they can no longer be paid', async () => {
  const x = await collectedDeal();
  const rev = await h.call(c.t.owner, 'POST', `/cash/receipts/${x.receiptId}/reverse`, { reason: 'شيك مرتجع' });
  assert.equal(rev.status, 200, JSON.stringify(rev.body));
  const deal = (await h.call(c.t.owner, 'GET', '/brokerage/deals?kind=resale')).body.deals.find((d: any) => d.id === x.id);
  assert.equal(deal.status, 'approved'); assert.equal(deal.commission.receivable, 10_000);
  assert.equal((await h.db.query(`SELECT status FROM commission_entitlements WHERE id = $1`, [x.ent.id])).rows[0].status, 'cancelled');
  assert.equal((await payE2(x.ent.id)).status, 400, 'an invalidated entitlement cannot be paid');
  // collected again → the SAME entitlement is active again (never a second one) and is paid once
  const again = await h.call(c.t.owner, 'POST', `/brokerage/deals/${x.id}/collect`, { side: 'owner', amount: 10_000, recipient: 'manager' });
  assert.equal(again.body.deal.status, 'collected');
  const ents = (await h.db.query(`SELECT id, status FROM commission_entitlements WHERE brokerage_share_id = (SELECT id FROM brokerage_shares WHERE deal_id = $1)`, [x.id])).rows;
  assert.deepEqual(ents, [{ id: x.ent.id, status: 'active' }]);
  assert.equal((await payE2(x.ent.id)).status, 201);
  assert.ok((await h.db.query(`SELECT 1 FROM audit_log WHERE action = 'brokerage.reopen' AND entity_id = $1`, [x.id])).rows.length === 1);
});

test('once a share was paid, reversing the commission receipt is refused and nothing changes', async () => {
  const x = await collectedDeal();
  assert.equal((await payE2(x.ent.id)).status, 201);
  const rev = await h.call(c.t.owner, 'POST', `/cash/receipts/${x.receiptId}/reverse`, { reason: 'خطأ' });
  assert.equal(rev.status, 409); assert.equal(reason(rev), 'brokerage_shares_paid');
  assert.equal((await h.db.query(`SELECT status FROM cash_receipts WHERE id = $1`, [x.receiptId])).rows[0].status, 'posted');
  assert.equal((await h.db.query(`SELECT status FROM brokerage_deals WHERE id = $1`, [x.id])).rows[0].status, 'collected');
  assert.equal((await h.db.query(`SELECT status FROM commission_entitlements WHERE id = $1`, [x.ent.id])).rows[0].status, 'active');
});

test('an outside beneficiary is settled once from the office cashbox, audited; never before the commission is in', async () => {
  const d = (await h.call(c.t.e1, 'POST', '/brokerage/deals', await resale({ price: 1_000_000, ratePct: 1, paidBy: 'owner' }))).body.deal;
  await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/decision`, { decision: 'approve', shares: [{ role: 'other', beneficiary: 'وسيط خارجي', mode: 'fixed', value: 1_500 }] });
  let share = (await h.call(c.t.owner, 'GET', '/brokerage/deals?kind=resale')).body.deals.find((y: any) => y.id === d.id).shares[0];
  assert.equal((await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/shares/${share.id}/settle`, {})).status, 409, 'commission not collected yet');
  const r = await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/collect`, { side: 'owner', amount: 10_000, recipient: 'manager' });
  assert.equal(r.body.deal.shares[0].canSettle, true);
  assert.equal((await h.call(c.t.e1, 'POST', `/brokerage/deals/${d.id}/shares/${share.id}/settle`, {})).status, 403, 'not a cashbox holder');
  const ref = randomUUID();
  const s1 = await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/shares/${share.id}/settle`, { clientRef: ref });
  assert.equal(s1.status, 201, JSON.stringify(s1.body));
  const s2 = await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/shares/${share.id}/settle`, { clientRef: ref });
  assert.equal(s2.status, 200); assert.equal(s2.body.expenseId, s1.body.expenseId, 'a retry → the same expense');
  assert.equal(reason(await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/shares/${share.id}/settle`, {})), 'already_settled');
  const x = (await h.db.query(`SELECT cashbox, amount_egp::float8 a, status, beneficiary, brokerage_share_id FROM cash_expenses WHERE id = $1`, [s1.body.expenseId])).rows[0];
  assert.deepEqual(x, { cashbox: 'office', a: 1_500, status: 'posted', beneficiary: 'وسيط خارجي', brokerage_share_id: share.id });
  share = s1.body.deal.shares[0]; assert.ok(share.settlement); assert.equal(share.canSettle, false);
  // the commission receipt cannot be reversed while the outside share stands paid
  assert.equal(reason(await h.call(c.t.owner, 'POST', `/cash/receipts/${r.body.receiptId}/reverse`, { reason: 'خطأ' })), 'brokerage_shares_paid');
  // reversing the settlement expense re-opens the share for settlement
  assert.equal((await h.call(c.t.owner, 'POST', `/cash/expenses/${s1.body.expenseId}/reverse`, { reason: 'اتصرف غلط' })).status, 200);
  assert.equal((await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/shares/${share.id}/settle`, {})).status, 201);
  assert.ok((await h.db.query(`SELECT 1 FROM audit_log WHERE action = 'brokerage.settle_external' AND entity_id = $1`, [d.id])).rows.length === 2);
});

test('«إضافة» for everyone on these pages (owner\'s choice 2026-11-23): a cashbox holder can add a deal, still never approve his own', async () => {
  const st = await h.call(c.t.hr, 'GET', '/brokerage/status');
  assert.equal(st.body.can.propose, true, 'HR (a cashbox holder) sees «إضافة»');
  assert.equal((await h.call(c.t.owner, 'GET', '/brokerage/status')).body.can.propose, true);
});
