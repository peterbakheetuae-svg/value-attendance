import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/** 098: a marketing company adds its own campaign (linked to itself by the server) and manages the ones it added. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let coA = '', coB = '', tA = '', tB = '', officeCamp = '', mine = '', pid = '';
const PASS = 'Start#2026x';
async function company(name: string, phone: string) {
  const id = (await h.call(c.t.owner, 'POST', '/marketing-companies', { name, kind: 'commission', defaultPct: 1 })).body.company.id;
  assert.equal((await h.call(c.t.owner, 'PATCH', `/leads/partners/${id}/login`, { phone, password: PASS })).status, 200);
  await h.db.query(`UPDATE marketing_companies SET must_change_password = false, device_lock = false WHERE id = $1`, [id]);
  const lg = await h.call(null, 'POST', '/auth/login', { identifier: phone, password: PASS, deviceId: `campdev-${phone}-0000` });
  assert.equal(lg.status, 200, JSON.stringify(lg.body));
  return { id, token: lg.body.token as string };
}
before(async () => {
  h = await harness('2026-11-26T10:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  ({ id: coA, token: tA } = await company('شركة أ', '01200000101'));
  ({ id: coB, token: tB } = await company('شركة ب', '01200000202'));
  pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'مشروع الحملات', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  const ch = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
  const r = await h.call(c.t.acc, 'POST', '/leads/campaigns', { name: 'حملة الإدارة', channelId: ch, projectId: pid, companyId: coA });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  officeCamp = r.body.campaign.id;
});
after(async () => { await h.close(); });
const camp = async (id: string) => (await h.db.query(`SELECT * FROM lead_campaigns WHERE id = $1`, [id])).rows[0];

test('1/2. the company creates a campaign — linked to itself by the server, office told; default channel Facebook', async () => {
  const r = await h.call(tA, 'POST', '/partner/campaigns', { name: 'حملة الشتاء', projectId: pid, startsOn: '2026-12-01' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  mine = r.body.campaign.id;
  const x = await camp(mine);
  assert.deepEqual([x.marketing_company_id, x.created_by_company_id, x.project_id, x.active], [coA, coA, pid, true]);
  const fb = (await h.db.query(`SELECT id FROM lead_channels WHERE name = 'فيسبوك'`)).rows[0]?.id ?? null;
  assert.equal(x.channel_id, fb);
  const told = (await h.db.query(`SELECT recipient_id FROM notifications WHERE type = 'partner_campaign_new'`)).rows.map((r) => r.recipient_id);
  assert.ok(told.includes(c.ids.owner), 'the office (leads.config) is told');
  assert.equal((await h.call(tA, 'POST', '/partner/campaigns', { name: 'حملة الشتاء' })).status, 409, 'no duplicate active name');
});

test('3/4. it appears in the company\'s interface (its campaigns, «الربط»); the other company does not see it', async () => {
  const l = (await h.call(tA, 'GET', '/partner/campaigns')).body.campaigns;
  assert.deepEqual(l.map((x: any) => [x.id, x.createdByCompany]).sort(), [[mine, true], [officeCamp, false]].sort());
  const integ = (await h.call(tA, 'GET', '/integrations')).body.campaigns.map((x: any) => x.id);
  assert.ok(integ.includes(mine) && integ.includes(officeCamp));
  assert.deepEqual((await h.call(tB, 'GET', '/partner/campaigns')).body.campaigns, []);
  assert.ok(!(await h.call(tB, 'GET', '/integrations')).body.campaigns.some((x: any) => x.id === mine));
  assert.ok((await h.call(tA, 'GET', '/leads/meta')).body.campaigns.some((x: any) => x.id === mine), 'usable for its leads');
});

test('5. it manages what it added (rename, dates, off); the office\'s campaign: Meta link only, no edit', async () => {
  const r = await h.call(tA, 'PATCH', `/partner/campaigns/${mine}`, { name: 'حملة الشتاء 2', endsOn: '2027-01-31' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal((await camp(mine)).name, 'حملة الشتاء 2');
  assert.equal((await h.call(tA, 'PATCH', `/partner/campaigns/${mine}`, { endsOn: '2026-11-01' })).status, 400, 'end before start');
  assert.equal((await h.call(tA, 'PATCH', `/partner/campaigns/${officeCamp}`, { name: 'x-renamed' })).status, 403);
  assert.equal((await camp(officeCamp)).name, 'حملة الإدارة');
  assert.equal((await h.call(tA, 'PATCH', `/leads/campaigns/${officeCamp}/partner`, { metaCampaignIds: ['120200000001'] })).status, 200, 'Meta link as before');
  const lead = await h.call(tA, 'POST', '/partner/leads', { campaignId: mine, fullName: 'عميل الحملة', phone: '01011112299' });
  assert.equal(lead.status, 201, JSON.stringify(lead.body));
});

test('6/7. another company cannot reach, edit or link it; a tampered company id is refused', async () => {
  assert.equal((await h.call(tB, 'PATCH', `/partner/campaigns/${mine}`, { name: 'مسروقة' })).status, 404);
  assert.equal((await h.call(tB, 'PATCH', `/leads/campaigns/${mine}/partner`, { metaCampaignIds: ['120200000002'] })).status, 404);
  assert.equal((await h.call(tB, 'POST', '/partner/leads', { campaignId: mine, fullName: 'x', phone: '01011113388' })).status, 400);
  for (const k of ['companyId', 'marketingCompanyId']) {
    const r = await h.call(tB, 'POST', '/partner/campaigns', { name: 'حملة مزورة', [k]: coA });
    assert.equal(r.status, 403, k);
  }
  assert.equal((await h.call(tA, 'PATCH', `/partner/campaigns/${mine}`, { companyId: coB })).status, 403);
  assert.equal((await h.call(tA, 'PATCH', `/leads/campaigns/${mine}/partner`, { companyId: coB })).status, 403);
  assert.equal((await camp(mine)).marketing_company_id, coA, 'still company A');
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM lead_campaigns WHERE name = 'حملة مزورة'`)).rows[0].n, 0);
});

test('8. unauthorized users: no token, employees, a sales manager cannot create; employees cannot use /partner routes', async () => {
  assert.equal((await h.call(null, 'POST', '/partner/campaigns', { name: 'بدون دخول' })).status, 401);
  for (const t of [c.t.e1, c.t.sm1, c.t.hr]) {
    assert.ok([401, 403].includes((await h.call(t, 'POST', '/partner/campaigns', { name: 'موظف' })).status));
    assert.equal((await h.call(t, 'POST', '/leads/campaigns', { name: 'موظف' })).status, 403);
  }
  assert.equal((await h.call(tA, 'POST', '/leads/campaigns', { name: 'شركة من باب الإدارة' })).status, 403, 'the office route stays closed to companies');
});

test('9/10. the office keeps full control; existing campaigns and links are unchanged', async () => {
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${mine}`, { name: 'اسم من الإدارة' })).status, 200);
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${mine}/partner`, { companyId: null })).status, 200, 'the office may free it');
  assert.equal((await h.call(tA, 'PATCH', `/partner/campaigns/${mine}`, { name: 'ترجع' })).status, 404, 'no longer the company\'s');
  const oc = await camp(officeCamp);
  assert.deepEqual([oc.marketing_company_id, oc.created_by_company_id, oc.project_id], [coA, null, pid]);
});

test('11/12. no other permission comes with it; company sign-in and its pages still work', async () => {
  for (const p of ['/employees', '/cash/summary', '/attendance/today', '/payroll/batches', '/leads/config/routes']) {
    assert.ok([403, 404].includes((await h.call(tA, 'GET', p)).status), p);
  }
  assert.equal((await h.call(tA, 'GET', '/partner/profile')).status, 200);
  assert.equal((await h.call(tA, 'GET', '/leads')).status, 200);
});
