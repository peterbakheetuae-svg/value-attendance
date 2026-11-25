import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { seal } from '../src/lib/secretbox.ts';
import { syncMeta, takeMetaLead } from '../src/modules/meta_sync.ts';

/** the scheduled Meta sync (POST /integrations/meta/sync/run, .github/workflows/meta-sync.yml): no app needs to be open */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let campaign: string;
const realFetch = globalThis.fetch;
const TOKEN = 'scheduler-token-0123456789abcdef';
let metaLeads: any[] = [];
const saved = { SECRETS_KEY: process.env.SECRETS_KEY, BACKUP_TOKEN: process.env.BACKUP_TOKEN };
const lead = (id: string, phone: string) => ({ id, campaign_id: '777', campaign_name: 'Meta 777', form_id: '9001', created_time: '2026-11-25T09:00:00+0000',
  field_data: [{ name: 'full_name', values: [`عميل ${id}`] }, { name: 'phone_number', values: [phone] }] });
before(async () => {
  process.env.SECRETS_KEY = Buffer.alloc(32, 4).toString('base64');
  process.env.BACKUP_TOKEN = TOKEN;
  h = await harness('2026-11-25T10:00:00Z'); c = await cast(h);
  const pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'مشروع الجدولة', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  const ch = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
  await h.call(c.t.acc, 'POST', '/leads/campaigns', { name: 'حملة مجدولة', channelId: ch, projectId: pid });
  campaign = (await h.db.query(`SELECT id FROM lead_campaigns WHERE name = 'حملة مجدولة'`)).rows[0].id;
  await h.db.query(`UPDATE lead_campaigns SET form_assignees = $2, meta_campaign_ids = '{777}' WHERE id = $1`, [campaign, [c.ids.e1]]);
  await h.db.query(`INSERT INTO integrations (source, active) VALUES ('meta', true) ON CONFLICT (source) DO UPDATE SET active = true`);
  await h.db.query(`INSERT INTO meta_pages (page_id, name, access_token, subscribed) VALUES ('1001', 'Value Group', $1, true)`, [seal('PAGE-A')]);
  metaLeads = [lead('6001', '01066660001'), lead('6002', '01066660002')];
  globalThis.fetch = (async (url: any, init: any) => {
    const u = new URL(String(url));
    if (u.hostname !== 'graph.facebook.com') return realFetch(url, init);
    const j = (b: unknown) => new Response(JSON.stringify(b), { status: 200, headers: { 'content-type': 'application/json' } });
    const path = u.pathname.replace(/^\/v[0-9]+\.0\//, '');
    if (path === '1001/leadgen_forms') return j({ data: [{ id: '9001' }] });
    if (path === '9001/leads') return j({ data: metaLeads });
    return j({ data: [] });
  }) as typeof fetch;
});
after(async () => {
  globalThis.fetch = realFetch;
  for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  await h.close();
});

test('the scheduler needs its token (or a person with leads.config); a wrong token or an employee is refused', async () => {
  assert.equal((await h.call(null, 'POST', '/integrations/meta/sync/run', {}, { 'x-backup-token': 'wrong-token-xxxxxxxxxxxxxxxx' })).status, 401);
  assert.equal((await h.call(c.t.e1, 'POST', '/integrations/meta/sync/run', {})).status, 403);
});

test('a scheduled run pulls the linked campaign\'s leads once; a second knock right after does not run; the same leads never come twice', async () => {
  const r = await h.call(null, 'POST', '/integrations/meta/sync/run', {}, { 'x-backup-token': TOKEN });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ran, true);
  assert.equal(r.body.added, 2);
  const again = await h.call(null, 'POST', '/integrations/meta/sync/run', {}, { 'x-backup-token': TOKEN });
  assert.deepEqual(again.body, { ran: false, reason: 'recent', errors: [] });
  h.now.value = new Date(h.now.value.getTime() + 6 * 60_000);
  const later = await h.call(null, 'POST', '/integrations/meta/sync/run', {}, { 'x-backup-token': TOKEN });
  assert.equal(later.body.ran, true);
  assert.equal(later.body.added, 0, 'idempotent: meta_lead_id is unique');
  const n = (await h.db.query(`SELECT count(*)::int n FROM leads WHERE meta_lead_id IN ('6001','6002')`)).rows[0].n;
  assert.equal(n, 2);
  assert.ok(!JSON.stringify(later.body).includes('PAGE-A'));
});

test('switched off: the scheduler is told why and nothing is pulled', async () => {
  await h.db.query(`UPDATE integrations SET active = false WHERE source = 'meta'`);
  h.now.value = new Date(h.now.value.getTime() + 6 * 60_000);
  const r = await h.call(null, 'POST', '/integrations/meta/sync/run', {}, { 'x-backup-token': TOKEN });
  assert.deepEqual(r.body, { ran: false, reason: 'off', errors: [] });
  await h.db.query(`UPDATE integrations SET active = true WHERE source = 'meta'`);
});

test('two overlapping passes over the same Meta lead add it once — no duplicate, no unique-index error (per-lead lock)', async () => {
  metaLeads = [lead('6101', '01066661001')];
  const [a, b] = await Promise.all([syncMeta(h.db, h.now.value), syncMeta(h.db, h.now.value)]);
  assert.equal(a.added + b.added, 1);
  assert.deepEqual([...a.errors, ...b.errors], []);
  // a webhook delivery of the same lead at the same time: «exists», not an error
  const both = await Promise.all([takeMetaLead(h.db, lead('6102', '01066661002'), h.now.value), takeMetaLead(h.db, lead('6102', '01066661002'), h.now.value)]);
  assert.deepEqual(both.sort(), ['added', 'exists']);
  const n = (await h.db.query(`SELECT meta_lead_id, count(*)::int n FROM leads WHERE meta_lead_id IN ('6101','6102') GROUP BY 1 ORDER BY 1`)).rows;
  assert.deepEqual(n, [{ meta_lead_id: '6101', n: 1 }, { meta_lead_id: '6102', n: 1 }]);
});

