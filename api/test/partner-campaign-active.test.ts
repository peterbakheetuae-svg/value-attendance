import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/** 098 follow-up: a campaign's on / off state is changed only on purpose (an edit never restarts a stopped campaign). */
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
const listed = async (t: string) => (await h.call(t, 'GET', '/integrations')).body.campaigns as any[];

test('1. editing a stopped campaign (name only) keeps it stopped; it stays listed in «الربط» as stopped', async () => {
  mine = (await h.call(tA, 'POST', '/partner/campaigns', { name: 'حملة الربيع' })).body.campaign.id;
  assert.equal((await h.call(tA, 'PATCH', `/partner/campaigns/${mine}`, { active: false })).status, 200);
  assert.equal((await camp(mine)).active, false);
  const r = await h.call(tA, 'PATCH', `/partner/campaigns/${mine}`, { name: 'حملة الربيع 2' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const x = await camp(mine);
  assert.deepEqual([x.name, x.active], ['حملة الربيع 2', false], 'still stopped');
  const row = (await listed(tA)).find((c) => c.id === mine);
  assert.ok(row, 'its own stopped campaign is listed');
  assert.deepEqual([row.active, row.createdByCompany], [false, true]);
});

test('2/3. explicitly starting and stopping it', async () => {
  assert.equal((await h.call(tA, 'PATCH', `/partner/campaigns/${mine}`, { active: true })).status, 200);
  assert.equal((await camp(mine)).active, true);
  assert.equal((await h.call(tA, 'PATCH', `/partner/campaigns/${mine}`, { name: 'حملة الربيع 3' })).status, 200);
  assert.equal((await camp(mine)).active, true, 'a name edit keeps it running');
  assert.equal((await h.call(tA, 'PATCH', `/partner/campaigns/${mine}`, { active: false })).status, 200);
  assert.equal((await camp(mine)).active, false);
  assert.equal((await h.call(tA, 'PATCH', `/partner/campaigns/${mine}`, { active: 'yes' })).status, 400, 'only a real boolean');
  assert.equal((await camp(mine)).active, false);
});

test('4/5. another company: not listed, not editable (stopped or running); a tampered company id is refused', async () => {
  assert.ok(!(await listed(tB)).some((c) => c.id === mine));
  assert.equal((await h.call(tB, 'PATCH', `/partner/campaigns/${mine}`, { active: true })).status, 404);
  assert.equal((await camp(mine)).active, false);
  assert.equal((await h.call(tB, 'POST', '/partner/campaigns', { name: 'مزورة', companyId: coA })).status, 403);
  assert.equal((await h.call(tA, 'PATCH', `/partner/campaigns/${mine}`, { active: true, marketingCompanyId: coB })).status, 403);
  assert.equal((await camp(mine)).active, false, 'a refused request changes nothing');
});

test('6/7. the office campaign: the company cannot start / stop it; Meta linking works as before; a stopped office campaign is not listed', async () => {
  assert.equal((await h.call(tA, 'PATCH', `/partner/campaigns/${officeCamp}`, { active: false })).status, 403);
  assert.equal((await camp(officeCamp)).active, true);
  assert.equal((await h.call(tA, 'PATCH', `/leads/campaigns/${officeCamp}/partner`, { metaCampaignIds: ['120200000077'] })).status, 200);
  assert.deepEqual((await camp(officeCamp)).meta_campaign_ids, ['120200000077']);
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${officeCamp}`, { active: false })).status, 200, 'the office stops it');
  assert.ok(!(await listed(tA)).some((c) => c.id === officeCamp), 'as before: the office\'s stopped campaigns are not shown to the company');
});

test('8. unauthorized roles cannot change a company campaign\'s state', async () => {
  for (const t of [null, c.t.e1, c.t.sm1, c.t.hr]) {
    assert.ok([401, 403].includes((await h.call(t, 'PATCH', `/partner/campaigns/${mine}`, { active: true })).status));
  }
  assert.equal((await camp(mine)).active, false);
});
