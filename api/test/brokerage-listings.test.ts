// Resale / rental listings (proposed 088 on top of 087): any salesperson lists a property (photos, type, address, area,
// price, finishing, description); anyone sells it with the client, the final price and the commission he took; the
// administrative officer is told, receives the commission and sets its split (seller / lister when someone else / sales
// manager, by amount or %, the rest to the office) — employee shares become commission entitlements; rental the same.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { harness, cast, insertEmployee, regrantAppRole, PW, type Harness } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let ao = ''; let aoT = '';
const sql = (n: string) => readFileSync(new URL(`../../db/proposed/${n}`, import.meta.url), 'utf8');
const reason = (r: any) => r.body?.error?.details?.reason;
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64').toString('base64');

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  ao = await insertEmployee(h.db, { code: 'AO1', name: 'المسؤول الإداري', role: 'accountant', joining: '2025-01-01' });
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [ao]);
  aoT = await h.login('AO1', PW);
});
after(async () => { await h.close(); });

const listing = (o: Record<string, unknown> = {}) => ({ kind: 'resale', title: 'شقة', address: 'التجمع الخامس — الحي الأول', area: 120,
  price: 2_500_000, finishing: 'super_lux', description: 'دور تالت، واجهة', ownerName: 'صاحب الشقة', ownerPhone: '01000000000', ...o });

test('before 088: listings answer installed:false and adding one is refused', async () => {
  await h.db.tx(async (q) => { await q.query(sql('087_brokerage_deals.sql')); });
  forgetPermissionKeys();
  assert.equal((await h.call(c.t.e1, 'GET', '/brokerage/listings')).body.installed, false);
  assert.equal(reason(await h.call(c.t.e1, 'POST', '/brokerage/listings', listing())), 'listings_not_installed');
  await h.db.tx(async (q) => { await q.query(sql('088_brokerage_listings.sql')); });
  await h.db.tx(async (q) => { await q.query(sql('088_brokerage_listings.sql')); }); // a second run changes nothing
  await regrantAppRole(h);
  const st = (await h.call(c.t.e1, 'GET', '/brokerage/status')).body;
  assert.equal(st.listings, true); assert.equal(st.can.propose, true); assert.equal(st.can.receive, false);
  assert.equal((await h.call(aoT, 'GET', '/brokerage/status')).body.can.receive, true, 'the administrative officer');
});

test('the 087 rules stay for a resale without a listing (rate 1 % – 2.5 %)', async () => {
  const base = { kind: 'resale', property: 'شقة', ownerName: 'مالك', clientName: 'مشتري', price: 1_000_000, paidBy: 'client' };
  assert.equal((await h.call(c.t.e1, 'POST', '/brokerage/deals', { ...base, ratePct: 3 })).status, 400);
  assert.equal((await h.call(c.t.e1, 'POST', '/brokerage/deals', { ...base, ratePct: 2 })).status, 201);
  await assert.rejects(h.db.query(`INSERT INTO brokerage_deals (kind, property, owner_name, client_name, price_egp, arrangement, client_commission_egp, contributor_id, closer_id, proposed_by)
                                  VALUES ('resale','x1','مالك','عميل',100,'fixed',5,$1,$1,$1)`, [c.ids.e1]), /resale_terms/, 'a fixed resale needs a listing');
});

test('a listing: all its fields, finishing from the five, photos one by one (8 max), the lister edits it while available', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', '/brokerage/listings', listing({ finishing: 'lux' }))).status, 400);
  assert.equal((await h.call(c.t.e1, 'POST', '/brokerage/listings', listing({ area: 0 }))).status, 400);
  const ref = randomUUID();
  const r = await h.call(c.t.e1, 'POST', '/brokerage/listings', listing({ clientRef: ref }));
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const l = r.body.listing;
  assert.deepEqual([l.title, l.area, l.price, l.finishing, l.finishingAr, l.status, l.listedBy.id], ['شقة', 120, 2_500_000, 'super_lux', 'سوبر لوكس', 'available', c.ids.e1]);
  assert.equal((await h.call(c.t.e1, 'POST', '/brokerage/listings', listing({ clientRef: ref }))).body.listing.id, l.id, 'a retry gives the same');
  for (let i = 0; i < 8; i++) assert.equal((await h.call(c.t.e1, 'POST', `/brokerage/listings/${l.id}/photos`, { mime: 'image/png', image: PNG })).status, 201);
  assert.equal(reason(await h.call(c.t.e1, 'POST', `/brokerage/listings/${l.id}/photos`, { mime: 'image/png', image: PNG })), 'too_many_photos');
  assert.equal((await h.call(c.t.e2, 'POST', `/brokerage/listings/${l.id}/photos`, { mime: 'image/png', image: PNG })).status, 403, 'not the lister');
  const got = (await h.call(c.t.e2, 'GET', '/brokerage/listings?kind=resale')).body.listings.find((x: any) => x.id === l.id);
  assert.equal(got.photos.length, 8); assert.equal(got.owner, null, 'the owner\'s phone is not for another salesperson'); assert.equal(got.can.sell, true); assert.equal(got.can.edit, false);
  const img = await h.call(c.t.e2, 'GET', `/brokerage/listings/${l.id}/photos/${got.photos[0]}`);
  assert.match(img.body.image, /^data:image\/png;base64,/);
  assert.equal((await h.call(c.t.e1, 'POST', `/brokerage/listings/${l.id}/photos/${got.photos[0]}/remove`)).status, 200);
  assert.equal((await h.call(c.t.e2, 'GET', `/brokerage/listings/${l.id}/photos/${got.photos[0]}`)).status, 404);
  const e = await h.call(c.t.e1, 'PATCH', `/brokerage/listings/${l.id}`, { price: 2_400_000, finishing: 'ultra_super_lux' });
  assert.deepEqual([e.body.listing.price, e.body.listing.finishingAr, e.body.listing.photos.length], [2_400_000, 'الترا سوبر لوكس', 7]);
  assert.equal((await h.call(c.t.e2, 'PATCH', `/brokerage/listings/${l.id}`, { price: 1 })).status, 403);
});

test('anyone sells it: the deal waits, the listing is pending, the administrative officer is told; nobody sells it twice', async () => {
  const l = (await h.call(c.t.e1, 'POST', '/brokerage/listings', listing({ title: 'محل' }))).body.listing;
  const ref = randomUUID();
  const s = await h.call(c.t.e2, 'POST', `/brokerage/listings/${l.id}/sell`, { clientName: 'المشتري', clientPhone: '0111', finalPrice: 2_300_000, commission: 46_000, clientRef: ref });
  assert.equal(s.status, 201, JSON.stringify(s.body));
  const d = s.body.deal;
  assert.deepEqual([d.status, d.contributor.id, d.closer.id, d.commission.total, d.price, d.listingId, d.arrangement, d.ratePct],
    ['proposed', c.ids.e1, c.ids.e2, 46_000, 2_300_000, l.id, 'fixed', null]);
  assert.equal((await h.call(c.t.e2, 'POST', `/brokerage/listings/${l.id}/sell`, { clientName: 'المشتري', finalPrice: 2_300_000, commission: 46_000, clientRef: ref })).body.deal.id, d.id);
  assert.equal(reason(await h.call(c.t.e3, 'POST', `/brokerage/listings/${l.id}/sell`, { clientName: 'آخر', finalPrice: 1, commission: 1 })), 'listing_not_available');
  const now = (await h.call(c.t.e1, 'GET', '/brokerage/listings')).body.listings.find((x: any) => x.id === l.id);
  assert.equal(now.status, 'pending'); assert.equal(now.deal.id, d.id); assert.equal(now.can.edit, false);
  const told = (await h.call(aoT, 'GET', '/notifications')).body.notifications.filter((n: any) => n.type === 'brokerage_sale');
  assert.ok(told.some((n: any) => n.entityId === d.id || n.entity_id === d.id), JSON.stringify(told));
  const forE1 = (await h.call(c.t.e3, 'GET', '/notifications')).body.notifications.filter((n: any) => n.type === 'brokerage_sale');
  assert.equal(forE1.length, 0, 'a salesperson is not told');
  const aoView = (await h.call(aoT, 'GET', '/brokerage/deals')).body.deals.find((x: any) => x.id === d.id);
  assert.equal(aoView.canReceive, true);
  assert.equal((await h.call(c.t.e2, 'GET', '/brokerage/deals')).body.deals.find((x: any) => x.id === d.id).canReceive, false);
});

test('the administrative officer receives it and splits it: seller / lister / sales manager by amount or %, the office the rest', async () => {
  const l = (await h.call(c.t.e1, 'POST', '/brokerage/listings', listing({ title: 'فيلا' }))).body.listing;
  const d = (await h.call(c.t.e2, 'POST', `/brokerage/listings/${l.id}/sell`, { clientName: 'عميل', finalPrice: 5_000_000, commission: 100_000 })).body.deal;
  const shares = [
    { role: 'closer', employeeId: c.ids.e2, mode: 'pct', value: 30 },
    { role: 'contributor', employeeId: c.ids.e1, mode: 'fixed', value: 10_000 },
    { role: 'sales_manager', employeeId: c.ids.sm1, mode: 'pct', value: 5 },
  ];
  const body = { amount: 100_000, salesManagerId: c.ids.sm1, shares, recipient: 'hr', paymentMethod: 'cash', clientRef: randomUUID() };
  assert.equal((await h.call(c.t.e3, 'POST', `/brokerage/deals/${d.id}/receive`, body)).status, 403, 'a salesperson');
  assert.equal(reason(await h.call(aoT, 'POST', `/brokerage/deals/${d.id}/receive`, { ...body, shares: [...shares, { role: 'other', beneficiary: 'زيادة', mode: 'pct', value: 70 }] })), 'over_distributed');
  assert.equal((await h.call(aoT, 'POST', `/brokerage/deals/${d.id}/receive`, { ...body, shares: [{ role: 'sales_manager', employeeId: c.ids.sm2, mode: 'pct', value: 5 }] })).status, 400, 'the sales manager chosen is SM1');
  const r = await h.call(aoT, 'POST', `/brokerage/deals/${d.id}/receive`, body);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.deal.status, 'collected');
  assert.deepEqual(r.body.deal.snapshot.shares.map((s: any) => [s.role, s.amount]), [['closer', 30_000], ['contributor', 10_000], ['sales_manager', 5_000]]);
  assert.equal(r.body.deal.snapshot.office, 55_000, 'the rest to the office');
  assert.equal((await h.call(aoT, 'POST', `/brokerage/deals/${d.id}/receive`, body)).body.receiptId, r.body.receiptId, 'a retry records nothing new');
  const rec = (await h.db.query(`SELECT kind, amount_egp::float a, cashbox FROM cash_receipts WHERE brokerage_deal_id = $1`, [d.id])).rows;
  assert.deepEqual(rec, [{ kind: 'commission', a: 100_000, cashbox: 'hr' }]);
  const ents = (await h.db.query(`SELECT employee_id, amount_egp::float a FROM commission_entitlements WHERE brokerage_share_id IN (SELECT id FROM brokerage_shares WHERE deal_id = $1) ORDER BY a DESC`, [d.id])).rows;
  assert.deepEqual(ents.map((x) => [x.employee_id, x.a]), [[c.ids.e2, 30_000], [c.ids.e1, 10_000], [c.ids.sm1, 5_000]]);
  assert.equal((await h.call(c.t.e1, 'GET', '/brokerage/listings')).body.listings.find((x: any) => x.id === l.id).status, 'sold');
});

test('a corrected commission amount; the seller is also the lister (one share); a cancelled sale makes it available again', async () => {
  const l = (await h.call(c.t.e1, 'POST', '/brokerage/listings', listing({ kind: 'rental', title: 'شقة مفروشة', price: 20_000 }))).body.listing;
  const d = (await h.call(c.t.e1, 'POST', `/brokerage/listings/${l.id}/sell`, { clientName: 'مستأجر', finalPrice: 18_000, commission: 18_000 })).body.deal;
  assert.equal(d.kind, 'rental');
  const r = await h.call(aoT, 'POST', `/brokerage/deals/${d.id}/receive`, { amount: 15_000, shares: [{ role: 'closer', employeeId: c.ids.e1, mode: 'pct', value: 40 }], recipient: 'hr' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.deepEqual([r.body.deal.commission.total, r.body.deal.snapshot.office], [15_000, 9_000]);
  // a sale withdrawn before anything is paid: the listing is offered again
  const l2 = (await h.call(c.t.e1, 'POST', '/brokerage/listings', listing({ title: 'مكتب' }))).body.listing;
  const d2 = (await h.call(c.t.e3, 'POST', `/brokerage/listings/${l2.id}/sell`, { clientName: 'عميل', finalPrice: 1_000_000, commission: 10_000 })).body.deal;
  assert.equal((await h.call(c.t.e3, 'POST', `/brokerage/deals/${d2.id}/cancel`, {})).status, 200);
  assert.equal((await h.call(c.t.e1, 'GET', '/brokerage/listings')).body.listings.find((x: any) => x.id === l2.id).status, 'available');
  // the lister withdraws it from the offer; another salesperson no longer sees it
  assert.equal((await h.call(c.t.e1, 'POST', `/brokerage/listings/${l2.id}/withdraw`)).body.listing.status, 'withdrawn');
  assert.equal((await h.call(c.t.e2, 'GET', '/brokerage/listings')).body.listings.some((x: any) => x.id === l2.id), false);
});

test('nobody receives a sale he is part of', async () => {
  const l = (await h.call(aoT, 'POST', '/brokerage/listings', listing({ title: 'أرض' }))).body.listing;
  const d = (await h.call(c.t.e2, 'POST', `/brokerage/listings/${l.id}/sell`, { clientName: 'عميل', finalPrice: 900_000, commission: 9_000 })).body.deal;
  assert.equal((await h.call(aoT, 'POST', `/brokerage/deals/${d.id}/receive`, { amount: 9_000, shares: [{ role: 'closer', employeeId: c.ids.e2, mode: 'pct', value: 10 }], recipient: 'hr' })).status, 403);
  const r = await h.call(c.t.owner, 'POST', `/brokerage/deals/${d.id}/receive`, { amount: 9_000, shares: [{ role: 'closer', employeeId: c.ids.e2, mode: 'pct', value: 10 }], recipient: 'manager' });
  assert.equal(r.status, 201, 'the general manager instead');
});
