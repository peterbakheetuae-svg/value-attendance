import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { harness, cast, type Harness } from './helpers.ts';
import { seal } from '../src/lib/secretbox.ts';
import { metaUserHash } from '../src/lib/meta-oauth.ts';
import { takeMetaLead } from '../src/modules/meta_sync.ts';
import { syncInsights, runAutoKpis } from '../src/modules/marketing.ts';

/**
 * Marketing Intelligence (092) on a real database: attribution (C), ownership history (C), Ads Insights (D), lead quality
 * (E), KPI sources (F), the dashboard (G), Meta deauthorization / data deletion (A). Meta's HTTP endpoints are faked.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let campaign: string; let company: string; let otherCompany: string;
const realFetch = globalThis.fetch;
const KEYS = ['SECRETS_KEY', 'META_APP_ID', 'META_APP_SECRET', 'META_OAUTH_REDIRECT_URI'] as const;
const saved: Record<string, string | undefined> = {};
const SECRET = 'app-secret-0123456789abcdef';
let insightsRows: any[] = []; let insightsError: { code: number; message: string } | null = null; let insightsCalls = 0;
const lead = (id: string, phone: string, extra: Record<string, unknown> = {}) => ({ id, campaign_id: '777', campaign_name: 'Meta 777',
  form_id: '9001', ad_id: '4401', adset_id: '3301', created_time: '2026-11-25T09:00:00+0000',
  field_data: [{ name: 'full_name', values: [`عميل ${id}`] }, { name: 'phone_number', values: [phone] }], ...extra });
const signed = (p: unknown, key = SECRET) => {
  const payload = Buffer.from(JSON.stringify(p)).toString('base64url');
  return `${createHmac('sha256', key).update(payload).digest('base64url')}.${payload}`;
};
/** Meta posts these callbacks as a form (application/x-www-form-urlencoded) — sent the same way here */
const form = async (path: string, body: Record<string, string>) => {
  const res = await fetch(h.base + path, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(body).toString() });
  const raw = await res.text();
  return { status: res.status, body: (res.headers.get('content-type') ?? '').includes('json') ? JSON.parse(raw) : null };
};
let pid = ''; let ch = '';

before(async () => {
  for (const k of KEYS) saved[k] = process.env[k];
  Object.assign(process.env, { SECRETS_KEY: Buffer.alloc(32, 6).toString('base64'), META_APP_ID: '1234567890', META_APP_SECRET: SECRET,
    META_OAUTH_REDIRECT_URI: 'https://api.example.com/public/meta/oauth/callback' });
  h = await harness('2026-11-25T10:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);   // leads.config
  pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'مشروع التسويق', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  ch = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
  await h.call(c.t.acc, 'POST', '/leads/campaigns', { name: 'حملة الذكاء', channelId: ch, projectId: pid });
  campaign = (await h.db.query(`SELECT id FROM lead_campaigns WHERE name = 'حملة الذكاء'`)).rows[0].id;
  company = (await h.db.query(`INSERT INTO marketing_companies (name, kind, created_by) VALUES ('شركة أ', 'commission', $1) RETURNING id`, [c.ids.owner])).rows[0].id;
  otherCompany = (await h.db.query(`INSERT INTO marketing_companies (name, kind, created_by) VALUES ('شركة ب', 'commission', $1) RETURNING id`, [c.ids.owner])).rows[0].id;
  await h.db.query(`UPDATE lead_campaigns SET form_assignees = $2, meta_campaign_ids = '{777}', marketing_company_id = $3 WHERE id = $1`, [campaign, [c.ids.e1], company]);
  await h.db.query(`INSERT INTO integrations (source, active, access_token) VALUES ('meta', true, $1)
                    ON CONFLICT (source) DO UPDATE SET active = true, access_token = EXCLUDED.access_token`, [seal('OFFICE-TOKEN-xxxxxxxxxxxx')]);
  globalThis.fetch = (async (url: any, init: any) => {
    const u = new URL(String(url));
    if (u.hostname !== 'graph.facebook.com') return realFetch(url, init);
    const j = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });
    const path = u.pathname.replace(/^\/v[0-9]+\.0\//, '');
    if (path === '777/insights') {
      insightsCalls++;
      if (insightsError) return j({ error: insightsError }, 400);
      return j({ data: insightsRows });
    }
    return j({ data: [] });
  }) as typeof fetch;
});
after(async () => {
  globalThis.fetch = realFetch;
  for (const k of KEYS) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  await h.close();
});

test('092 installed: new columns, tables, triggers and the leads.quality permission (owner only)', async () => {
  const cols = (await h.db.query(`SELECT table_name, column_name FROM information_schema.columns WHERE (table_name, column_name) IN
      (('leads','attribution_source'),('leads','meta_adset_id'),('leads','quality'),('kpi_results','source'),('kpi_definitions','calc_source'),('integrations','meta_user_hash'))`)).rows;
  assert.equal(cols.length, 6);
  for (const t of ['lead_campaign_owners', 'meta_insights_daily', 'lead_quality_events']) {
    assert.ok((await h.db.query(`SELECT to_regclass($1) AS r`, [`public.${t}`])).rows[0].r, t);
  }
  const holders = (await h.db.query(`SELECT role_key FROM role_permissions WHERE perm_key = 'leads.quality'`)).rows.map((x) => x.role_key);
  assert.deepEqual(holders, ['owner']);
  const defaults = (await h.db.query(`SELECT count(*) FILTER (WHERE quality <> 'unreviewed')::int n FROM leads`)).rows[0].n;
  assert.equal(defaults, 0, 'existing leads start unreviewed');
});

test('C. attribution: set once at intake from what Meta sent; never rewritten by a later change', async () => {
  assert.equal(await takeMetaLead(h.db, lead('9101', '01099990001'), h.now.value, { source: 'meta_webhook', pageId: '1001' }), 'added');
  const l = (await h.db.query(`SELECT * FROM leads WHERE meta_lead_id = '9101'`)).rows[0];
  assert.deepEqual([l.attribution_source, l.meta_page_id, l.meta_form_id, l.meta_campaign_id, l.meta_adset_id, l.meta_ad_id, l.attributed_company_id],
    ['meta_webhook', '1001', '9001', '777', '3301', '4401', company]);
  // Meta sent no ad / ad set: those stay unknown (no invented values)
  assert.equal(await takeMetaLead(h.db, lead('9102', '01099990002', { ad_id: undefined, adset_id: 'x' }), h.now.value, { source: 'meta_sync', pageId: null }), 'added');
  const l2 = (await h.db.query(`SELECT * FROM leads WHERE meta_lead_id = '9102'`)).rows[0];
  assert.deepEqual([l2.attribution_source, l2.meta_page_id, l2.meta_ad_id, l2.meta_adset_id], ['meta_sync', null, null, null]);
  await assert.rejects(h.db.query(`UPDATE leads SET attributed_company_id = $2 WHERE id = $1`, [l.id, otherCompany]), /set once/);
  await assert.rejects(h.db.query(`UPDATE leads SET meta_campaign_id = '888' WHERE id = $1`, [l.id]), /set once/);
  // other fields of the lead still change freely
  await h.db.query(`UPDATE leads SET notes = 'x' WHERE id = $1`, [l.id]);
});

test('C. ownership history: every change of a campaign\'s company is kept; old leads keep their attribution', async () => {
  await h.db.query(`UPDATE lead_campaigns SET marketing_company_id = $2 WHERE id = $1`, [campaign, otherCompany]);
  await h.db.query(`UPDATE lead_campaigns SET marketing_company_id = NULL WHERE id = $1`, [campaign]);   // office-direct
  const r = await h.call(c.t.owner, 'GET', `/leads/campaigns/${campaign}/owners`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.owners.map((o: any) => [o.companyId, o.officeDirect, o.to === null]),
    [[null, true, true], [otherCompany, false, false], [company, false, false], [null, true, false]],
    'the campaign was made office-direct, then given to company A, then B, then office-direct again');
  assert.equal((await h.db.query(`SELECT attributed_company_id FROM leads WHERE meta_lead_id = '9101'`)).rows[0].attributed_company_id, company);
  assert.equal((await h.call(c.t.e1, 'GET', `/leads/campaigns/${campaign}/owners`)).status, 403);
  await h.db.query(`UPDATE lead_campaigns SET marketing_company_id = $2 WHERE id = $1`, [campaign, company]);
});

test('C. manual attribution: only a lead with none, only once, only with leads.config', async () => {
  const id = (await h.db.query(`SELECT id FROM leads WHERE meta_lead_id = '9101'`)).rows[0].id;
  assert.equal((await h.call(c.t.acc, 'POST', `/leads/${id}/attribution`, { companyId: otherCompany })).status, 409, 'already attributed');
  // a lead entered by hand (the existing POST /leads): no attribution until someone with leads.config sets it, once
  const made = await h.call(c.t.owner, 'POST', '/leads', { fullName: 'عميل يدوي', phone: '01099990009', projectId: pid, channelId: ch, assignees: [c.ids.e2] });
  assert.equal(made.status, 201, JSON.stringify(made.body));
  const manual = made.body.lead.id;
  assert.equal((await h.db.query(`SELECT attribution_source FROM leads WHERE id = $1`, [manual])).rows[0].attribution_source, null, 'unknown until set');
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${manual}/attribution`, { companyId: company })).status, 403);
  assert.equal((await h.call(c.t.acc, 'POST', `/leads/${manual}/attribution`, { companyId: 'not-a-uuid' })).status, 400);
  assert.equal((await h.call(c.t.acc, 'POST', `/leads/${manual}/attribution`, { companyId: company })).status, 200);
  assert.equal((await h.call(c.t.acc, 'POST', `/leads/${manual}/attribution`, { companyId: null })).status, 409, 'set once');
});

test('E. quality: the owner classifies (reason required for a rejection); others are refused; the history is append-only', async () => {
  const id = (await h.db.query(`SELECT id FROM leads WHERE meta_lead_id = '9101'`)).rows[0].id;
  assert.equal((await h.call(c.t.acc, 'POST', `/leads/${id}/quality`, { quality: 'qualified' })).status, 403, 'not granted yet (owner decision)');
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${id}/quality`, { quality: 'qualified' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', `/leads/${id}/quality`, { quality: 'not_qualified' })).status, 400, 'a rejection needs a reason');
  assert.equal((await h.call(c.t.owner, 'POST', `/leads/${id}/quality`, { quality: 'bogus' })).status, 400);
  assert.equal((await h.call(c.t.owner, 'POST', `/leads/${id}/quality`, { quality: 'not_qualified', reason: 'ميزانية أقل بكتير' })).status, 200);
  assert.equal((await h.call(c.t.owner, 'POST', `/leads/${id}/quality`, { quality: 'qualified', reason: 'اتأكدنا تاني' })).status, 200, 'a correction');
  const hist = await h.call(c.t.owner, 'GET', `/leads/${id}/quality`);
  assert.deepEqual(hist.body.history.map((x: any) => [x.from, x.to]), [['not_qualified', 'qualified'], ['unreviewed', 'not_qualified']]);
  assert.equal(hist.body.quality, 'qualified');
  assert.equal(hist.body.attribution.source, 'meta_webhook');
  await assert.rejects(h.db.query(`UPDATE lead_quality_events SET reason = 'x' WHERE lead_id = $1`, [id]), /append-only/);
  // the stage (sales follow-up) is untouched by a quality decision
  assert.equal((await h.db.query(`SELECT stage FROM leads WHERE id = $1`, [id])).rows[0].stage, 'new');
  // once the owner grants the permission, that person may classify
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'leads.quality', true)`, [c.ids.acc]);
  assert.equal((await h.call(c.t.acc, 'POST', `/leads/${id}/quality`, { quality: 'unreachable', reason: 'مبيردش خالص' })).status, 200);
});

test('D. insights: days stored as Meta reported them; unavailable stays NULL; an incomplete answer never overwrites; checkpoint only after a complete pass', async () => {
  const day = (d: string, over: Record<string, unknown> = {}) => ({ campaign_id: '777', date_start: d, date_stop: d, account_currency: 'EGP',
    impressions: '1000', spend: '200.50', clicks: '20', actions: [{ action_type: 'lead', value: '4' }], ...over });
  insightsRows = [day('2026-11-23'), day('2026-11-24', { actions: [] })];
  const r = await syncInsights(h.db, h.now.value, { deadlineMs: 10_000 });
  assert.equal(r.ran, true); assert.equal((r as any).complete, true);
  const rows = (await h.db.query(`SELECT day::text, spend::float, leads FROM meta_insights_daily ORDER BY day`)).rows;
  assert.deepEqual(rows, [{ day: '2026-11-23', spend: 200.5, leads: 4 }, { day: '2026-11-24', spend: 200.5, leads: null }]);
  assert.equal((await h.db.query(`SELECT insights_synced_through::text t FROM integrations WHERE source = 'meta'`)).rows[0].t, '2026-11-24');
  // an incomplete answer (no spend) for a stored day is kept out
  insightsRows = [day('2026-11-23', { spend: undefined, impressions: undefined })];
  await syncInsights(h.db, h.now.value, { deadlineMs: 10_000 });
  assert.equal((await h.db.query(`SELECT spend::float s FROM meta_insights_daily WHERE day = '2026-11-23'`)).rows[0].s, 200.5);
  // a rate limit: the pass is incomplete, reported, the checkpoint stays
  h.now.value = new Date('2026-11-27T10:00:00Z');
  insightsError = { code: 17, message: 'User request limit reached' };
  const rl = await syncInsights(h.db, h.now.value, { deadlineMs: 10_000 }) as any;
  assert.deepEqual([rl.complete, rl.rateLimited], [false, true]);
  assert.equal((await h.db.query(`SELECT insights_synced_through::text t FROM integrations WHERE source = 'meta'`)).rows[0].t, '2026-11-24');
  insightsError = null;
  // the deadline crossing on the last stored day: incomplete, checkpoint unchanged
  let t = 0; insightsRows = [day('2026-11-25'), day('2026-11-26')];
  const clock = () => t;
  const realQuery = h.db.query.bind(h.db);
  const db: any = { ...h.db, query: async (...a: any[]) => { const x = await (realQuery as any)(...a); if (String(a[0]).includes('INSERT INTO meta_insights_daily')) t += 6_000; return x; }, tx: h.db.tx.bind(h.db) };
  const late = await syncInsights(db, h.now.value, { deadlineMs: 10_000, clock }) as any;
  assert.equal(late.complete, false);
  assert.equal((await h.db.query(`SELECT insights_synced_through::text t FROM integrations WHERE source = 'meta'`)).rows[0].t, '2026-11-24');
});

test('D. the insights route: scheduler token or leads.config; at most hourly', async () => {
  process.env.BACKUP_TOKEN = 'scheduler-token-0123456789abcdef';
  try {
    assert.equal((await h.call(c.t.e1, 'POST', '/integrations/meta/insights/run', {})).status, 403);
    const first = await h.call(null, 'POST', '/integrations/meta/insights/run', {}, { 'x-backup-token': process.env.BACKUP_TOKEN });
    assert.equal(first.status, 200, JSON.stringify(first.body));
    assert.equal(first.body.ran, true);
    const again = await h.call(null, 'POST', '/integrations/meta/insights/run', {}, { 'x-backup-token': process.env.BACKUP_TOKEN });
    assert.deepEqual([again.body.ran, again.body.reason], [false, 'recent']);
  } finally { delete process.env.BACKUP_TOKEN; }
});

test('F. KPI sources: mapped → pending; only the owner approves; a run fills empty / automatic rows, never a manual entry', async () => {
  const def = (await h.db.query(`SELECT id FROM kpi_definitions WHERE key = 'meetings'`)).rows[0].id;
  const manualDef = (await h.db.query(`SELECT id FROM kpi_definitions WHERE key = 'viewings'`)).rows[0].id;
  // a set must hold KPIs weighing 100 (deferred database check): made with its items in one transaction
  const set = await h.db.tx(async (q) => {
    const s = (await q.query(`INSERT INTO kpi_sets (name, scope_type, employee_id, created_by) VALUES ('t', 'employee', $1, $2) RETURNING id`, [c.ids.e1, c.ids.owner])).rows[0].id;
    await q.query(`INSERT INTO kpi_set_items (set_id, kpi_id, weight, target) VALUES ($1, $2, 50, 10), ($1, $3, 50, 10)`, [s, def, manualDef]);
    return s;
  });
  const period = '2026-11-01';
  const auto = (await h.db.query(`INSERT INTO kpi_results (employee_id, period, set_id, kpi_id, weight_snapshot, target_snapshot) VALUES ($1,$2,$3,$4,50,10) RETURNING id`, [c.ids.e1, period, set, def])).rows[0].id;
  await h.db.query(`UPDATE kpi_definitions SET calc_source = 'meetings_set', calc_approved_at = now(), calc_approved_by = $2 WHERE id = $1`, [manualDef, c.ids.owner]);
  const manual = (await h.db.query(`INSERT INTO kpi_results (employee_id, period, set_id, kpi_id, weight_snapshot, target_snapshot, actual, state, entered_by)
      VALUES ($1,$2,$3,$4,50,10,7,'in_progress',$5) RETURNING id`, [c.ids.e1, period, set, manualDef, c.ids.sm1])).rows[0].id;
  const lid = (await h.db.query(`SELECT id FROM leads WHERE meta_lead_id = '9101'`)).rows[0].id;
  await h.db.query(`INSERT INTO lead_actions (lead_id, stage, by_id, created_at) VALUES ($1, 'meeting', $2, '2026-11-20T10:00:00Z'), ($1, 'meeting', $2, '2026-11-21T10:00:00Z')`, [lid, c.ids.e1]);
  assert.equal((await h.call(c.t.e1, 'PATCH', `/kpi/definitions/${def}/calc`, { calcSource: 'meetings_set' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/kpi/definitions/${def}/calc`, { calcSource: 'invented' })).status, 400);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/kpi/definitions/${def}/calc`, { calcSource: 'meetings_set' })).body.status, 'pending_approval');
  await runAutoKpis(h.db, period, h.now.value);
  assert.equal((await h.db.query(`SELECT actual FROM kpi_results WHERE id = $1`, [auto])).rows[0].actual, null, 'not approved → not calculated');
  assert.equal((await h.call(c.t.hr, 'POST', `/kpi/definitions/${def}/calc/approve`, {})).status, 403, 'approval is the owner\'s');
  assert.equal((await h.call(c.t.owner, 'POST', `/kpi/definitions/${def}/calc/approve`, {})).status, 200);
  const run = await runAutoKpis(h.db, period, h.now.value);
  assert.ok(run.updated >= 1);
  const a = (await h.db.query(`SELECT actual::float, source, evidence FROM kpi_results WHERE id = $1`, [auto])).rows[0];
  assert.deepEqual([a.actual, a.source, a.evidence.calculator], [2, 'auto', 'meetings_set']);
  const m = (await h.db.query(`SELECT actual::float, source, entered_by FROM kpi_results WHERE id = $1`, [manual])).rows[0];
  assert.deepEqual([m.actual, m.source, m.entered_by], [7, 'manual', c.ids.sm1], 'a manual entry is never overwritten');
  // a person correcting an automatic value takes it over: the next run leaves it alone
  const fix = await h.call(c.t.owner, 'PUT', `/kpi/results/${auto}`, { state: 'in_progress', actual: 5 });
  assert.equal(fix.status, 200, JSON.stringify(fix.body));
  await runAutoKpis(h.db, period, h.now.value);
  const f = (await h.db.query(`SELECT actual::float, source, calculated_at FROM kpi_results WHERE id = $1`, [auto])).rows[0];
  assert.deepEqual([f.actual, f.source, f.calculated_at], [5, 'manual', null], 'a manual correction of an automatic row is never overwritten');
  const mine = await h.call(c.t.owner, 'GET', `/kpi/employees/${c.ids.e1}?month=2026-11`);
  assert.equal(mine.status, 200, JSON.stringify(mine.body));
  assert.ok(mine.body.current.items.every((i: any) => ['auto', 'manual'].includes(i.source)), 'each item says where its value came from');
  const list = await h.call(c.t.owner, 'GET', '/kpi/calculators');
  assert.equal(list.status, 200, JSON.stringify(list.body));
  assert.equal(list.body.definitions.filter((d: any) => d.status === 'auto').length, 2, 'only the two approved here');
  assert.ok(list.body.definitions.filter((d: any) => d.status === 'manual').length >= 10, 'every other KPI stays manual');
});

test('G. dashboard: management only; filters; spend unknown without insights, summed with them; no tokens', async () => {
  assert.equal((await h.call(c.t.e1, 'GET', '/marketing/overview')).status, 403);
  const r = await h.call(c.t.owner, 'GET', '/marketing/overview?from=2026-11-01&to=2026-11-30');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const camp = r.body.campaigns.find((x: any) => x.id === campaign);
  assert.ok(camp && camp.leads >= 2);
  const stored = (await h.db.query(`SELECT sum(spend)::float s FROM meta_insights_daily WHERE meta_campaign_id = '777' AND day BETWEEN '2026-11-01' AND '2026-11-30'`)).rows[0].s;
  assert.ok(stored > 0);
  assert.equal(camp.spend, stored, 'the stored days, summed');
  assert.equal(camp.costPerLead, Math.round((stored / camp.leads) * 100) / 100);
  assert.equal(camp.currency, 'EGP');
  assert.ok(r.body.totals.bySource.meta_webhook >= 1);
  const q = await h.call(c.t.owner, 'GET', '/marketing/overview?from=2026-11-01&to=2026-11-30&quality=unreachable');
  assert.equal(q.body.totals.leads, 1);
  assert.equal((await h.call(c.t.owner, 'GET', '/marketing/overview?quality=bogus')).status, 400);
  assert.equal((await h.call(c.t.owner, 'GET', '/marketing/overview?campaignId=not-a-uuid')).status, 400);
  const none = await h.call(c.t.owner, 'GET', '/marketing/overview?from=2025-01-01&to=2025-01-31');
  assert.deepEqual(none.body.campaigns, []);
  assert.ok(!JSON.stringify(r.body).match(/OFFICE-TOKEN|enc:v1:/));
});

test('A. deauthorize / data deletion: signed by our app only; the connecting person\'s token and pages are dropped; others change nothing', async () => {
  await h.db.query(`UPDATE integrations SET meta_user_hash = $1 WHERE source = 'meta'`, [metaUserHash('55555')]);
  await h.db.query(`INSERT INTO meta_pages (page_id, name, access_token, subscribed) VALUES ('1001', 'Value', $1, true) ON CONFLICT DO NOTHING`, [seal('PAGE-T')]);
  assert.equal((await form('/public/meta/deauthorize', { signed_request: signed({ algorithm: 'HMAC-SHA256', user_id: '55555' }, 'wrong-secret-xxxxxxxxxxxx') })).status, 401);
  const other = await form('/public/meta/deauthorize', { signed_request: signed({ algorithm: 'HMAC-SHA256', user_id: '66666' }) });
  assert.deepEqual([other.status, other.body.matched], [200, false]);
  assert.ok((await h.db.query(`SELECT access_token FROM integrations WHERE source = 'meta'`)).rows[0].access_token, 'another person: unchanged');
  const leadsBefore = (await h.db.query(`SELECT count(*)::int n FROM leads`)).rows[0].n;
  const del = await form('/public/meta/data-deletion', { signed_request: signed({ algorithm: 'HMAC-SHA256', user_id: '55555' }) });
  assert.equal(del.status, 200, JSON.stringify(del.body));
  assert.match(del.body.confirmation_code, /^[0-9a-f]{24}$/);
  assert.equal(del.body.url, `https://api.example.com/public/meta/data-deletion/${del.body.confirmation_code}`);
  const it = (await h.db.query(`SELECT access_token, meta_user_hash, last_error FROM integrations WHERE source = 'meta'`)).rows[0];
  assert.deepEqual([it.access_token, it.meta_user_hash], [null, null]);
  assert.ok(it.last_error.includes('إعادة الربط'));
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM meta_pages`)).rows[0].n, 0);
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM leads`)).rows[0].n, leadsBefore, 'leads and attribution untouched');
  assert.equal((await h.call(null, 'GET', `/public/meta/data-deletion/${del.body.confirmation_code}`)).status, 200);
  assert.equal((await h.call(null, 'GET', `/public/meta/data-deletion/${'0'.repeat(24)}`)).status, 404);
});
