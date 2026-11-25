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
  // leads.config comes with the administrative officer's position (as in meta_sync.test.ts); the accountant role lacks it
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
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


test('a large page of leads: processing stops at the budget, the pass is incomplete and the checkpoint does not move', async () => {
  const before = (await h.db.query(`SELECT meta_synced_at FROM lead_campaigns WHERE id = $1`, [campaign])).rows[0].meta_synced_at;
  metaLeads = Array.from({ length: 300 }, (_, i) => lead(String(7000 + i), `0107777${String(i).padStart(4, '0')}`));
  const t0 = Date.now();
  const r = await syncMeta(h.db, h.now.value, { deadlineMs: 50 });
  const elapsed = Date.now() - t0;
  assert.equal(r.complete, false);
  assert.ok(r.added < 300, `stopped early (added ${r.added})`);
  assert.ok(elapsed < 50 + 1_500, `ended near the budget (${elapsed} ms: budget + at most one lead in progress)`);
  const after = (await h.db.query(`SELECT meta_synced_at FROM lead_campaigns WHERE id = $1`, [campaign])).rows[0].meta_synced_at;
  assert.deepEqual(after, before, 'an incomplete pass never advances the checkpoint');
  // the next pass with enough time finishes the rest; nothing is added twice
  h.now.value = new Date(h.now.value.getTime() + 60_000);
  const rest = await syncMeta(h.db, h.now.value, { deadlineMs: 60_000 });
  assert.equal(rest.complete, true);
  assert.equal(r.added + rest.added, 300);
  const n = (await h.db.query(`SELECT count(*)::int n FROM leads WHERE meta_lead_id::bigint BETWEEN 7000 AND 7299`)).rows[0].n;
  assert.equal(n, 300);
  assert.notDeepEqual((await h.db.query(`SELECT meta_synced_at FROM lead_campaigns WHERE id = $1`, [campaign])).rows[0].meta_synced_at, before,
    'a complete pass moves it');
});

test('regression (deterministic clock): the final lead crosses the deadline while it is processed → incomplete, checkpoint unchanged', async () => {
  h.now.value = new Date(h.now.value.getTime() + 60_000);
  const before = (await h.db.query(`SELECT meta_synced_at FROM lead_campaigns WHERE id = $1`, [campaign])).rows[0].meta_synced_at;
  metaLeads = [lead('8001', '01088880001'), lead('8002', '01088880002')];
  // a fake clock that only moves when the FINAL lead's transaction completes (no real waiting)
  let t = 1_000_000; let txs = 0;
  const db: any = {
    query: (...a: any[]) => (h.db.query as any)(...a),
    tx: async (fn: any) => { const r = await h.db.tx(fn); txs++; if (txs === 2) t += 60_000; return r; },
  };
  const r = await syncMeta(db, h.now.value, { deadlineMs: 10_000, clock: () => t });
  assert.equal(txs, 2, 'both leads were processed (the final one started inside the budget)');
  assert.equal(r.added, 2, 'the final lead\'s own transaction completed and is kept');
  assert.equal(r.complete, false, 'the pass is marked incomplete');
  const after = (await h.db.query(`SELECT meta_synced_at FROM lead_campaigns WHERE id = $1`, [campaign])).rows[0].meta_synced_at;
  assert.deepEqual(after, before, 'the checkpoint did not move');
});

test('normal completion with the same deterministic clock: complete, and the checkpoint advances to this run', async () => {
  h.now.value = new Date(h.now.value.getTime() + 60_000);
  metaLeads = [lead('8101', '01088881001'), lead('8102', '01088881002')];
  const t = 2_000_000;
  const r = await syncMeta(h.db, h.now.value, { deadlineMs: 10_000, clock: () => t });
  assert.equal(r.complete, true);
  assert.equal(r.added, 2);
  const after = (await h.db.query(`SELECT meta_synced_at FROM lead_campaigns WHERE id = $1`, [campaign])).rows[0].meta_synced_at;
  assert.equal(new Date(after).toISOString(), h.now.value.toISOString(), 'the checkpoint moved to this run');
});
