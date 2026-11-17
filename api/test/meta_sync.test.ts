import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/** Meta (081): several Facebook pages with their own tokens, and a linked Meta campaign's leads pulled by themselves */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let campaign: string;
const realFetch = globalThis.fetch;
const calls: string[] = [];
const lead = (id: string, campaignId: string, phone: string, name: string) => ({
  id, campaign_id: campaignId, campaign_name: `Meta ${campaignId}`, form_id: '9001', created_time: '2026-11-15T10:00:00+0000',
  field_data: [{ name: 'full_name', values: [name] }, { name: 'phone_number', values: [phone] }],
});
before(async () => {
  process.env.SECRETS_KEY = Buffer.alloc(32, 3).toString('base64');   // tokens sealed at rest (VA-05)
  h = await harness('2026-11-17T08:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  const pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج ميتا', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  const ch = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
  await h.call(c.t.acc, 'POST', '/leads/campaigns', { name: 'حملة ميتا', channelId: ch, projectId: pid });
  campaign = (await h.db.query(`SELECT id FROM lead_campaigns WHERE name = 'حملة ميتا'`)).rows[0].id;
  await h.db.query(`UPDATE lead_campaigns SET form_assignees = $2 WHERE id = $1`, [campaign, [c.ids.e1]]);
  await h.db.query(`INSERT INTO integrations (source, active) VALUES ('meta', true) ON CONFLICT (source) DO UPDATE SET active = true`);
  // Meta's Graph API, faked: a user token reaching two pages; page A's form has a linked and an unlinked lead
  globalThis.fetch = (async (url: any, init: any) => {
    const u = String(url);
    if (!u.startsWith('https://graph.facebook.com/')) return realFetch(url, init);
    calls.push(u);
    const tok = new URL(u).searchParams.get('access_token');
    const path = new URL(u).pathname.replace('/v21.0/', '');
    const j = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });
    if (path === 'me/accounts' && tok === 'BIZ-TOKEN-xxxxxxxxxxxxxxxxx') return j({ data: [] });
    if (path === 'me/businesses' && tok === 'BIZ-TOKEN-xxxxxxxxxxxxxxxxx') return j({ data: [{ id: '4242' }] });
    if (path === '4242/owned_pages' && tok === 'BIZ-TOKEN-xxxxxxxxxxxxxxxxx') return j({ data: [{ id: '1003', name: 'Biz Page', access_token: 'PAGE-C' }] });
    if (path === '4242/client_pages') return j({ data: [] });
    if (path === 'me' && tok === 'PERSON-TOKEN-xxxxxxxxxxxxxx') return j({ id: '77777', name: 'Peter' });
    if (path === 'me/accounts' && tok === 'USER-TOKEN-xxxxxxxxxxxxxxxx') {
      return j({ data: [{ id: '1001', name: 'Value Group', access_token: 'PAGE-A' }, { id: '1002', name: 'Value Square', access_token: 'PAGE-B' }] });
    }
    if (path.endsWith('/subscribed_apps')) return j({ success: true });
    if (path === '1001/leadgen_forms' && tok === 'PAGE-A') return j({ data: [{ id: '9001' }] });
    if (path === '1002/leadgen_forms' && tok === 'PAGE-B') return j({ data: [] });
    if (path === '9001/leads' && tok === 'PAGE-A') {
      return j({ data: [lead('5001', '777', '01055550001', 'عميل ميتا 1'), lead('5002', '888', '01055550002', 'مش مربوط')] });
    }
    if (path === '5003' && tok === 'PAGE-B') return j(lead('5003', '777', '01055550003', 'عميل ويبهوك'));
    return j({ error: { message: `unexpected ${path} ${tok}` } }, 400);
  }) as typeof fetch;
});
after(async () => { globalThis.fetch = realFetch; delete process.env.SECRETS_KEY; await h.close(); });

test('a user token adds all its pages (own page tokens, subscribed); tokens are never shown', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', '/integrations/meta/pages', { accessToken: 'USER-TOKEN-xxxxxxxxxxxxxxxx' })).status, 403);
  const r = await h.call(c.t.acc, 'POST', '/integrations/meta/pages', { accessToken: 'USER-TOKEN-xxxxxxxxxxxxxxxx' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.pages.map((p: any) => p.name), ['Value Group', 'Value Square']);
  assert.ok(r.body.pages.every((p: any) => p.subscribed));
  const it = (await h.call(c.t.acc, 'GET', '/integrations')).body;
  assert.equal(it.metaPages.length, 2);
  assert.ok(!JSON.stringify(it).includes('PAGE-A'));
  const stored = (await h.db.query(`SELECT access_token FROM meta_pages`)).rows.map((x) => x.access_token);
  assert.ok(stored.every((t: string) => t.startsWith('enc:v1:') && !t.includes('PAGE-')), 'page tokens encrypted at rest');
});

test('linking a Meta campaign pulls its leads from Meta (once); the webhook reads with the page\'s own token', async () => {
  const l = await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${campaign}/partner`, { metaCampaignIds: ['777'] });
  assert.equal(l.status, 200, JSON.stringify(l.body));
  const rows = (await h.db.query(`SELECT full_name, meta_lead_id, assigned_to FROM leads WHERE campaign_id = $1`, [campaign])).rows;
  assert.deepEqual(rows.map((x) => x.full_name), ['عميل ميتا 1'], 'the linked campaign only');
  assert.equal(rows[0].meta_lead_id, '5001');
  assert.equal(rows[0].assigned_to, c.ids.e1);
  const again = await h.call(c.t.acc, 'POST', '/integrations/meta/sync', {});
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.added, 0, 'never twice');
  const w = await h.call(null, 'POST', '/public/hooks/meta', { entry: [{ id: '1002', changes: [{ field: 'leadgen', value: { leadgen_id: '5003' } }] }] });
  assert.equal(w.status, 200, JSON.stringify(w.body));
  assert.equal(w.body.added, 1);
  assert.ok(calls.some((u) => u.includes('/5003?') && u.includes('access_token=PAGE-B')));
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM leads WHERE campaign_id = $1`, [campaign])).rows[0].n, 2);
  // a page removed: its token is gone
  assert.equal((await h.call(c.t.acc, 'POST', '/integrations/meta/pages/1002/remove', {})).status, 200);
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM meta_pages`)).rows[0].n, 1);
});

test('a token that reaches its pages through a business portfolio; a person\'s token is never kept as a page', async () => {
  const b = await h.call(c.t.acc, 'POST', '/integrations/meta/pages', { accessToken: 'BIZ-TOKEN-xxxxxxxxxxxxxxxxx' });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.deepEqual(b.body.pages.map((p: any) => p.id), ['1003']);
  const u = await h.call(c.t.acc, 'POST', '/integrations/meta/pages', { accessToken: 'PERSON-TOKEN-xxxxxxxxxxxxxx' });
  assert.equal(u.status, 400, JSON.stringify(u.body));
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM meta_pages WHERE page_id = '77777'`)).rows[0].n, 0);
});

test('VA-09: with the apps\' secrets configured, only deliveries signed by one of them are taken', async () => {
  const { createHmac } = await import('node:crypto');
  const body = { entry: [{ id: '1001', changes: [{ field: 'leadgen', value: { leadgen_id: '5001' } }] }] };
  const raw = JSON.stringify(body);
  const sig = (secret: string, b = raw) => 'sha256=' + createHmac('sha256', secret).update(b).digest('hex');
  const post = (headers: Record<string, string>, b = raw) => fetch(h.base + '/public/hooks/meta', { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: b });
  process.env.META_APP_SECRETS = 'secret-app-one, secret-app-two';
  try {
    assert.equal((await post({})).status, 401, 'missing signature');
    assert.equal((await post({ 'x-hub-signature-256': 'sha256=' + 'a'.repeat(64) })).status, 401, 'invalid signature');
    assert.equal((await post({ 'x-hub-signature-256': sig('wrong-secret') })).status, 401, 'wrong app secret');
    assert.equal((await post({ 'x-hub-signature-256': sig('secret-app-one') }, raw.replace('5001', '5009'))).status, 401, 'modified body');
    assert.equal((await post({ 'x-hub-signature-256': sig('secret-app-one', '') }, '')).status, 401, 'empty body');
    assert.equal((await post({ 'x-hub-signature-256': sig('secret-app-one') })).status, 200, 'app one');
    assert.equal((await post({ 'x-hub-signature-256': sig('secret-app-two') })).status, 200, 'app two (retries welcome: the lead comes in once)');
  } finally { delete process.env.META_APP_SECRETS; }
  assert.equal((await post({})).status, 200, 'not configured yet: unchanged behaviour');
});
