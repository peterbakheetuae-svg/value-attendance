// The commission of a resale / rental handed over against the recipient's code (proposed 090 on top of 087–089): the seller
// states it as a % of the price / the monthly rent or as an amount and names who receives it (the general manager, the
// accountant or an administrative officer holding the office cashbox). The recipient's app shows a 4-digit code — never the
// seller's, never in a notification; the seller enters it → a numbered receipt in the recipient's name. The split is set
// afterwards (never collecting twice, never changing the amount); a deal whose commission is in a cashbox is never rejected.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, insertEmployee, regrantAppRole, PW, type Harness } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let ao = ''; let aoT = '';
const sql = (n: string) => readFileSync(new URL(`../../db/proposed/${n}`, import.meta.url), 'utf8');
const reason = (r: any) => r.body?.error?.details?.reason;

let leadNo = 0;
const leadOf = async (salesId: string) => {
  leadNo++;
  const phone = `0107${String(7000000 + leadNo)}`;
  const pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'مشروع ' + phone, ownerName: 'مالك', ownerPhone: '0100' })).body.project.id;
  const channel = (await h.call(c.t.owner, 'GET', '/leads/meta')).body.channels[0].id;
  const r = await h.call(c.t.owner, 'POST', '/leads', { fullName: `عميل التسليم ${leadNo}`, phone, projectId: pid, channelId: channel, assignees: [salesId] });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  return r.body.lead.id as string;
};
const listing = (o: Record<string, unknown> = {}) => ({ kind: 'resale', title: 'شقة التسليم', address: 'التجمع الخامس', area: 140,
  price: 2_000_000, finishing: 'super_lux', description: '', ownerName: 'المالك', ownerPhone: '01000000001', ...o });

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  ao = await insertEmployee(h.db, { code: 'AO9', name: 'المسؤول الإداري', role: 'accountant', joining: '2025-01-01' });
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [ao]);
  aoT = await h.login('AO9', PW);
  for (const f of ['087_brokerage_deals.sql', '088_brokerage_listings.sql', '089_brokerage_deal_lead.sql']) await h.db.tx(async (q) => { await q.query(sql(f)); });
  await regrantAppRole(h);
  forgetPermissionKeys();
});
after(async () => { await h.close(); });

test('before 090: no recipient asked (today\'s flow); 090 installs and runs twice safely', async () => {
  assert.equal((await h.call(c.t.e2, 'GET', '/brokerage/status')).body.handover, false);
  assert.equal((await h.call(c.t.e2, 'GET', '/brokerage/recipients')).body.installed, false);
  await h.db.tx(async (q) => { await q.query(sql('090_brokerage_handover.sql')); });
  await h.db.tx(async (q) => { await q.query(sql('090_brokerage_handover.sql')); });
  await regrantAppRole(h);
  assert.equal((await h.call(c.t.e2, 'GET', '/brokerage/status')).body.handover, true);
});

test('the recipients: holders of the office cashbox among the general manager / accountant / administrative officers — never the seller', async () => {
  const r = (await h.call(c.t.e2, 'GET', '/brokerage/recipients')).body;
  assert.equal(r.installed, true);
  assert.ok(r.recipients.some((x: any) => x.id === c.ids.owner && x.role === 'general_manager'), JSON.stringify(r.recipients));
  assert.ok(!r.recipients.some((x: any) => x.id === c.ids.e2), 'not the seller');
  assert.ok(!r.recipients.some((x: any) => [c.ids.e1, c.ids.e3].includes(x.id)), 'not a salesperson');
});

test('a sale stated as a %: the recipient is required, the code is his alone, the commission is in his cashbox only after the code', async () => {
  const l = (await h.call(c.t.e1, 'POST', '/brokerage/listings', listing())).body.listing;
  const leadId = await leadOf(c.ids.e2);
  const body = { leadId, finalPrice: 2_000_000, commissionBasis: 'percent', commissionPct: 1.5 };
  assert.equal((await h.call(c.t.e2, 'POST', `/brokerage/listings/${l.id}/sell`, body)).status, 400, 'no recipient');
  assert.equal((await h.call(c.t.e2, 'POST', `/brokerage/listings/${l.id}/sell`, { ...body, recipientId: c.ids.e3 })).status, 400, 'a salesperson');
  assert.equal((await h.call(c.t.e2, 'POST', `/brokerage/listings/${l.id}/sell`, { ...body, recipientId: c.ids.e2 })).status, 400, 'himself');
  const s = await h.call(c.t.e2, 'POST', `/brokerage/listings/${l.id}/sell`, { ...body, recipientId: c.ids.owner });
  assert.equal(s.status, 201, JSON.stringify(s.body));
  const d = s.body.deal;
  assert.deepEqual([d.commission.total, d.commissionBasis, d.commissionPct, d.status], [30_000, 'percent', 1.5, 'proposed']);
  assert.deepEqual([d.handover.to.id, d.handover.waiting, d.handover.canEnterCode, d.handover.canShowCode], [c.ids.owner, true, true, false]);
  assert.equal(d.client.name.startsWith('عميل التسليم'), true, 'the client is the lead');
  // the recipient is told — without any code
  const told = (await h.call(c.t.owner, 'GET', '/notifications')).body.notifications.filter((n: any) => n.type === 'brokerage_handover');
  assert.equal(told.length, 1);
  assert.doesNotMatch(JSON.stringify(told), /كود[^"]{0,6}\d{4}/, 'never the code');
  // nothing in a cashbox yet; the split waits for the code
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM cash_receipts WHERE brokerage_deal_id = $1`, [d.id])).rows[0].n, 0);
  const aoView = (await h.call(aoT, 'GET', '/brokerage/deals')).body.deals.find((x: any) => x.id === d.id);
  assert.equal(aoView.canReceive, false, 'nothing to split before the code');
  assert.equal(reason(await h.call(aoT, 'POST', `/brokerage/deals/${d.id}/receive`, { shares: [{ role: 'closer', employeeId: c.ids.e2, mode: 'pct', value: 30 }] })), 'handover_pending');
  // the code: the recipient only
  assert.equal((await h.call(c.t.e2, 'POST', `/brokerage/deals/${d.id}/handover/code`)).status, 404, 'the seller never sees it');
  const code = await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/handover/code`);
  assert.equal(code.status, 200, JSON.stringify(code.body));
  assert.match(code.body.code, /^\d{4}$/);
  assert.equal(code.body.amount, 30_000);
  const kept = (await h.db.query(`SELECT code_hash FROM action_otps WHERE action = $1`, [`brokerage:${d.id}`])).rows;
  assert.ok(kept.length === 1 && !kept[0].code_hash.includes(code.body.code), 'only a hash is kept');
  // a wrong code, someone else entering it → refused; the right code by the seller → handed over
  const wrong = code.body.code === '0000' ? '1111' : '0000';
  assert.equal(reason(await h.call(c.t.e2, 'POST', `/brokerage/deals/${d.id}/handover/verify`, { code: wrong })), 'otp_invalid');
  assert.equal((await h.call(c.t.e3, 'POST', `/brokerage/deals/${d.id}/handover/verify`, { code: code.body.code })).status, 404, 'not the seller');
  const v = await h.call(c.t.e2, 'POST', `/brokerage/deals/${d.id}/handover/verify`, { code: code.body.code });
  assert.equal(v.status, 200, JSON.stringify(v.body));
  assert.ok(v.body.deal.handover.at);
  const rec = (await h.db.query(`SELECT kind, amount_egp::float a, cashbox, actual_recipient_id, recorded_by, brokerage_side, status FROM cash_receipts WHERE brokerage_deal_id = $1`, [d.id])).rows;
  assert.deepEqual(rec, [{ kind: 'commission', a: 30_000, cashbox: 'office', actual_recipient_id: c.ids.owner, recorded_by: c.ids.e2, brokerage_side: 'client', status: 'posted' }]);
  assert.equal(reason(await h.call(c.t.e2, 'POST', `/brokerage/deals/${d.id}/handover/verify`, { code: code.body.code })), 'not_open', 'once');
  // the money is in a cashbox: the deal is never rejected / cancelled; the handover itself never changes
  assert.equal(reason(await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/decision`, { decision: 'reject' })), 'commission_received');
  assert.equal((await h.call(c.t.e2, 'POST', `/brokerage/deals/${d.id}/cancel`, {})).status, 409);
  await assert.rejects(h.db.query(`UPDATE brokerage_deals SET handover_to = $2 WHERE id = $1`, [d.id, ao]), /cannot be changed/);
  // the split afterwards: the amount that entered the cashbox stays; the deal closes; no second receipt
  const split = { shares: [{ role: 'closer', employeeId: c.ids.e2, mode: 'pct', value: 30 }, { role: 'contributor', employeeId: c.ids.e1, mode: 'fixed', value: 3_000 }] };
  assert.equal(reason(await h.call(aoT, 'POST', `/brokerage/deals/${d.id}/receive`, { ...split, amount: 25_000 })), 'handover_amount_fixed');
  assert.equal((await h.call(aoT, 'GET', '/brokerage/deals')).body.deals.find((x: any) => x.id === d.id).canReceive, true);
  const r = await h.call(aoT, 'POST', `/brokerage/deals/${d.id}/receive`, split);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.deal.status, 'collected');
  assert.equal(r.body.receiptId, v.body.receiptId, 'the receipt of the handover');
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM cash_receipts WHERE brokerage_deal_id = $1`, [d.id])).rows[0].n, 1, 'never collected twice');
  const ents = (await h.db.query(`SELECT employee_id, amount_egp::float a FROM commission_entitlements WHERE brokerage_share_id IN (SELECT id FROM brokerage_shares WHERE deal_id = $1) ORDER BY a DESC`, [d.id])).rows;
  assert.deepEqual(ents.map((x) => [x.employee_id, x.a]), [[c.ids.e2, 9_000], [c.ids.e1, 3_000]]);
  assert.equal((await h.db.query(`SELECT stage FROM leads WHERE id = $1`, [leadId])).rows[0].stage, 'done_deal');
});

test('a rental stated as an amount; codes are limited (5 in 15 minutes)', async () => {
  const l = (await h.call(c.t.e1, 'POST', '/brokerage/listings', listing({ kind: 'rental', title: 'شقة إيجار', price: 15_000 }))).body.listing;
  const s = await h.call(c.t.e3, 'POST', `/brokerage/listings/${l.id}/sell`,
    { leadId: await leadOf(c.ids.e3), finalPrice: 15_000, commissionBasis: 'amount', commission: 7_500, recipientId: c.ids.owner });
  assert.equal(s.status, 201, JSON.stringify(s.body));
  assert.deepEqual([s.body.deal.kind, s.body.deal.commission.total, s.body.deal.commissionBasis, s.body.deal.commissionPct], ['rental', 7_500, 'amount', null]);
  for (let i = 0; i < 5; i++) assert.equal((await h.call(c.t.owner, 'POST', `/brokerage/deals/${s.body.deal.id}/handover/code`)).status, 200);
  assert.equal(reason(await h.call(c.t.owner, 'POST', `/brokerage/deals/${s.body.deal.id}/handover/code`)), 'otp_rate_limited');
  // only the newest code works
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM action_otps WHERE action = $1 AND used_at IS NULL AND expires_at > now()`, [`brokerage:${s.body.deal.id}`])).rows[0].n, 1);
});
