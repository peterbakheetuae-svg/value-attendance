import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { assignWaiting } from '../src/modules/lead_routing.ts';

/** Value Aqar's webhooks (inquiries → leads; projects / units → «المشاريع الواردة» → adopted ones come in) and Meta's check */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let key: string; let campaign: string;
before(async () => {
  h = await harness('2026-11-14T08:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  const pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج الربط', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  const ch = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
  const cp = await h.call(c.t.acc, 'POST', '/leads/campaigns', { name: 'استفسارات فاليو عقار', channelId: ch, projectId: pid });
  assert.equal(cp.status, 201, JSON.stringify(cp.body));
  campaign = cp.body.campaign?.id ?? (await h.db.query(`SELECT id FROM lead_campaigns ORDER BY created_at DESC LIMIT 1`)).rows[0].id;
  await h.db.query(`UPDATE lead_campaigns SET form_assignees = $2 WHERE id = $1`, [campaign, [c.ids.e1]]);
});
after(async () => { await h.close(); });

const hook = (body: unknown, k = key) => h.call(null, 'POST', '/public/hooks/valueaqar', body, { 'x-value-key': k });

test('Value Aqar: the key; an inquiry is a lead on the «فاليو عقار» channel (no campaign), by the default rule; the same number twice once', async () => {
  assert.equal((await h.call(c.t.e1, 'GET', '/integrations')).status, 403);
  const k = await h.call(c.t.acc, 'POST', '/integrations/valueaqar/key', {});
  assert.equal(k.status, 200, JSON.stringify(k.body));
  key = k.body.key;
  const list = (await h.call(c.t.acc, 'GET', '/integrations')).body;
  assert.ok(list.valueaqar.hasKey && !JSON.stringify(list).includes(key), 'the key is never shown again');
  assert.ok(list.people.length > 0, 'the salesmen to choose from');
  assert.equal((await hook({ type: 'INSERT', table: 'inquiries', record: { name: 'x', phone: '01011112222' } }, 'wrong')).status, 401);
  // no rule yet: the lead still comes in, with nobody — and the managers are told
  const r0 = await hook({ type: 'INSERT', table: 'inquiries', record: { id: 'q0', full_name: 'عميل بدري', phone: '01099990000' } });
  assert.equal(r0.status, 200, JSON.stringify(r0.body));
  const l0 = (await h.db.query(`SELECT l.*, ch.name AS ch FROM leads l LEFT JOIN lead_channels ch ON ch.id = l.channel_id WHERE l.id = $1`, [r0.body.lead])).rows[0];
  assert.equal(l0.ch, 'فاليو عقار');
  assert.equal(l0.campaign_id, null, 'a direct channel, not a campaign');
  assert.equal(l0.assigned_to, null);
  const told = await h.db.query(`SELECT recipient_id FROM notifications WHERE type = 'lead_waiting' AND entity_id = $1`, [r0.body.lead]);
  assert.ok(told.rows.some((x) => x.recipient_id === c.ids.acc), 'the administrative officer is alerted');
  // the default rule: one salesman
  assert.equal((await h.call(c.t.acc, 'PUT', '/integrations/routes', { target: 'default', mode: 'one', assignees: [c.ids.e1, c.ids.e2] })).status, 400, '«one» = one salesman');
  assert.equal((await h.call(c.t.acc, 'PUT', '/integrations/routes', { target: 'default', mode: 'one', assignees: [c.ids.e1] })).status, 200);
  const r = await hook({ type: 'INSERT', table: 'inquiries', schema: 'public', record: { id: 'q1', full_name: 'عميل الموقع', phone: '+20 101 111 2222', message: 'عايز شقة' }, old_record: null });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.body.lead);
  const lead = (await h.db.query(`SELECT * FROM leads WHERE id = $1`, [r.body.lead])).rows[0];
  assert.equal(lead.assigned_to, c.ids.e1);
  assert.equal(lead.campaign_id, null);
  assert.match(lead.notes, /عايز شقة/);
  const again = await hook({ type: 'INSERT', table: 'inquiries', record: { full_name: 'عميل الموقع', phone: '01011112222' } });
  assert.equal(again.body.duplicate, true);
});

test('Value Aqar: projects come into «المشاريع الواردة»; only an adopted one comes in, with its units kept in sync', async () => {
  assert.equal((await hook({ type: 'INSERT', table: 'projects', record: { id: 'p9', name: 'كمبوند الواحة', developer_name: 'مطور الواحة', city: 'العاشر' } })).status, 200);
  assert.equal((await hook({ type: 'INSERT', table: 'units', record: { id: 'u1', project_id: 'p9', unit_number: 'A-1', area: '120', price: '2,400,000', type: 'شقة' } })).status, 200);
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM ex_inventory WHERE external_ref IS NOT NULL`)).rows[0].n, 0, 'nothing until it is adopted');
  const pp = (await h.call(c.t.acc, 'GET', '/integrations')).body.projects.find((x: any) => x.externalId === 'p9');
  assert.equal(pp.status, 'new');
  assert.equal(pp.units, 1);
  const ad = await h.call(c.t.acc, 'POST', `/integrations/projects/${pp.id}/adopt`, { as: 'marketing' });
  assert.equal(ad.status, 200, JSON.stringify(ad.body));
  const proj = (await h.db.query(`SELECT * FROM commission_projects WHERE id = $1`, [ad.body.projectId])).rows[0];
  assert.equal(proj.kind, 'marketing');
  let inv = (await h.db.query(`SELECT * FROM ex_inventory WHERE project_id = $1`, [proj.id])).rows;
  assert.equal(inv.length, 1);
  assert.equal(Number(inv[0].unit_price), 2400000);
  // a new unit / a change / a deletion on Value Aqar follow
  await hook({ type: 'INSERT', table: 'units', record: { id: 'u2', project_id: 'p9', unit_number: 'A-2', price: '3000000' } });
  await hook({ type: 'UPDATE', table: 'units', record: { id: 'u1', project_id: 'p9', unit_number: 'A-1', price: '2500000' } });
  await hook({ type: 'DELETE', table: 'units', old_record: { id: 'u2', project_id: 'p9' } });
  inv = (await h.db.query(`SELECT unit_no, unit_price, active FROM ex_inventory WHERE project_id = $1 ORDER BY unit_no`, [proj.id])).rows;
  assert.deepEqual(inv.map((x) => [x.unit_no, Number(x.unit_price), x.active]), [['A-1', 2500000, true], ['A-2', 3000000, false]]);
  // another project is ignored → nothing comes in
  await hook({ type: 'INSERT', table: 'projects', record: { id: 'p10', name: 'مشروع مش بتاعنا' } });
  const p10 = (await h.call(c.t.acc, 'GET', '/integrations')).body.projects.find((x: any) => x.externalId === 'p10');
  assert.equal((await h.call(c.t.acc, 'POST', `/integrations/projects/${p10.id}/ignore`, {})).status, 200);
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM commission_projects WHERE name = 'مشروع مش بتاعنا'`)).rows[0].n, 0);
});

test('Meta: the webhook check needs the verify token; no token → leads are skipped', async () => {
  await h.call(c.t.acc, 'PATCH', '/integrations/meta', { newVerifyToken: true, campaignId: campaign });
  const vt = (await h.call(c.t.acc, 'GET', '/integrations')).body.meta.verifyToken;
  assert.ok(vt);
  assert.equal((await h.call(null, 'GET', '/public/hooks/meta?hub.mode=subscribe&hub.verify_token=nope&hub.challenge=123')).status, 403);
  const ok = await h.call(null, 'GET', `/public/hooks/meta?hub.mode=subscribe&hub.verify_token=${vt}&hub.challenge=12345`);
  assert.equal(ok.status, 200);
  assert.equal(ok.raw.toString('utf8'), '12345');
  const p = await h.call(null, 'POST', '/public/hooks/meta', { entry: [{ changes: [{ field: 'leadgen', value: { leadgen_id: '1' } }] }] });
  assert.equal(p.body.skipped, 'off', 'no access token yet');
  assert.equal((await h.call(c.t.acc, 'PATCH', '/integrations/meta/forms', { campaignId: campaign, formId: '123456789' })).status, 200);
  assert.equal((await h.db.query(`SELECT meta_form_id FROM lead_campaigns WHERE id = $1`, [campaign])).rows[0].meta_form_id, '123456789');
});

const offline = () => h.db.query(`UPDATE sessions SET last_seen_at = '2000-01-01'`);
const online = (id: string) => h.db.query(`UPDATE sessions SET last_seen_at = $2 WHERE employee_id = $1`, [id, h.now.value]);
const leadOf = async (id: string) => (await h.db.query(`SELECT * FROM leads WHERE id = $1`, [id])).rows[0];

test('distribution per project / property: one salesman, in turn among those online (else it waits and goes to the first who comes online), in turn among all', async () => {
  assert.equal((await h.call(c.t.e1, 'PUT', '/integrations/routes', { target: 'project', externalId: 'p9', mode: 'online', assignees: [c.ids.e1] })).status, 403);
  const pr = await h.call(c.t.acc, 'PUT', '/integrations/routes', { target: 'project', externalId: 'p9', mode: 'online', assignees: [c.ids.e1, c.ids.e2] });
  assert.equal(pr.status, 200, JSON.stringify(pr.body));
  assert.equal((await h.call(c.t.acc, 'PUT', '/integrations/routes', { target: 'project', externalId: 'nope', mode: 'turn', assignees: [c.ids.e1] })).status, 404);

  // nobody online → it waits for e1 / e2, the managers are told
  await offline();
  const w = await hook({ type: 'INSERT', table: 'inquiries', record: { full_name: 'مستني', phone: '01022220001', project_id: 'p9' } });
  assert.equal(w.status, 200, JSON.stringify(w.body));
  let l = await leadOf(w.body.lead);
  assert.equal(l.assigned_to, null);
  assert.deepEqual([...l.wait_pool].sort(), [c.ids.e1, c.ids.e2].sort());
  assert.ok(l.project_id, 'the adopted project');
  assert.ok((await h.db.query(`SELECT 1 FROM notifications WHERE type = 'lead_waiting' AND entity_id = $1 AND recipient_id = $2`, [l.id, c.ids.owner])).rows.length);
  // still nobody → still waiting; e2 comes online → it is his
  await h.db.tx((q) => assignWaiting(q, h.now.value));
  assert.equal((await leadOf(l.id)).assigned_to, null);
  await online(c.ids.e2);
  await h.db.tx((q) => assignWaiting(q, h.now.value));
  l = await leadOf(l.id);
  assert.equal(l.assigned_to, c.ids.e2);
  assert.equal(l.wait_since, null);

  // e2 online, e1 not → the next one is e2's too (only those online)
  const n = await hook({ type: 'INSERT', table: 'inquiries', record: { full_name: 'تاني', phone: '01022220002', project_id: 'p9' } });
  assert.equal((await leadOf(n.body.lead)).assigned_to, c.ids.e2);

  // a property's own rule beats its project's
  assert.equal((await h.call(c.t.acc, 'PUT', '/integrations/routes', { target: 'property', externalId: 'u1', mode: 'one', assignees: [c.ids.e3] })).status, 200);
  const u = await hook({ type: 'INSERT', table: 'inquiries', record: { full_name: 'وحدة', phone: '01022220003', property_id: 'u1' } });
  assert.equal((await leadOf(u.body.lead)).assigned_to, c.ids.e3);

  // a waiting lead a manager distributed himself stays with whom he chose
  await offline();
  const m = await hook({ type: 'INSERT', table: 'inquiries', record: { full_name: 'المدير وزعه', phone: '01022220004', project_id: 'p9' } });
  assert.equal((await leadOf(m.body.lead)).assigned_to, null);
  const as = await h.call(c.t.acc, 'POST', '/leads/assign', { ids: [m.body.lead], to: [c.ids.e3] });
  assert.equal(as.status, 200, JSON.stringify(as.body));
  await online(c.ids.e1);
  await h.db.tx((q) => assignWaiting(q, h.now.value));
  assert.equal((await leadOf(m.body.lead)).assigned_to, c.ids.e3);

  // «in turn among all»: given even with nobody online
  await offline();
  await h.call(c.t.acc, 'PUT', '/integrations/routes', { target: 'project', externalId: 'p9', mode: 'turn', assignees: [c.ids.e1, c.ids.e2] });
  h.now.value = new Date('2026-11-14T08:10:00Z');
  const t1 = await hook({ type: 'INSERT', table: 'inquiries', record: { full_name: 'دور 1', phone: '01022220005', project_id: 'p9' } });
  h.now.value = new Date('2026-11-14T08:11:00Z');
  const t2 = await hook({ type: 'INSERT', table: 'inquiries', record: { full_name: 'دور 2', phone: '01022220006', project_id: 'p9' } });
  const got = [(await leadOf(t1.body.lead)).assigned_to, (await leadOf(t2.body.lead)).assigned_to];
  assert.ok(got.every(Boolean));
  assert.notEqual(got[0], got[1], 'one each, in turn');

  // the list shows the rules
  const routes = (await h.call(c.t.acc, 'GET', '/integrations')).body.routes;
  assert.deepEqual(routes.map((x: any) => x.target).sort(), ['default', 'project', 'property']);
  const rid = routes.find((x: any) => x.target === 'property').id;
  assert.equal((await h.call(c.t.acc, 'POST', `/integrations/routes/${rid}/remove`, {})).status, 200);
});

test('a campaign (Meta form / public form): its salesmen and its mode — online, else it waits', async () => {
  const f = await h.call(c.t.acc, 'POST', `/leads/campaigns/${campaign}/form`, { enabled: true, assignees: [c.ids.e1] });
  assert.equal(f.status, 200, JSON.stringify(f.body));
  const set = await h.call(c.t.acc, 'PATCH', `/integrations/campaigns/${campaign}`, { mode: 'online', assignees: [c.ids.e1, c.ids.e2] });
  assert.equal(set.status, 200, JSON.stringify(set.body));
  const camp = (await h.call(c.t.acc, 'GET', '/integrations')).body.campaigns.find((x: any) => x.id === campaign);
  assert.equal(camp.mode, 'online');
  await offline();
  assert.equal((await h.call(null, 'POST', `/public/leads/${f.body.token}`, { fullName: 'من الفورم', phone: '01033330001' })).status, 201);
  let l = (await h.db.query(`SELECT * FROM leads WHERE phone_norm LIKE '%1033330001' ORDER BY created_at DESC LIMIT 1`)).rows[0];
  assert.equal(l.assigned_to, null);
  assert.equal(l.campaign_id, campaign);
  await online(c.ids.e1);
  await h.db.tx((q) => assignWaiting(q, h.now.value));
  l = await leadOf(l.id);
  assert.equal(l.assigned_to, c.ids.e1);
});

test('a new Meta Verify token (one already in use) only with the code e-mailed to the person', async () => {
  const sent: any[] = [];
  const prev = globalThis.fetch;
  process.env.BREVO_API_KEY = 'k'; process.env.MAIL_FROM = 'hr@value.test';
  globalThis.fetch = (async (url: any, init: any) => {
    if (String(url).startsWith('https://api.brevo.com/')) { sent.push(JSON.parse(init.body)); return new Response('{}', { status: 201 }); }
    return prev(url, init);
  }) as typeof fetch;
  try {
    await h.db.query(`UPDATE employees SET email = 'acc@value.test' WHERE id = $1`, [c.ids.acc]);
    const before = (await h.db.query(`SELECT verify_token FROM integrations WHERE source = 'meta'`)).rows[0].verify_token;
    assert.ok(before);
    assert.equal((await h.call(c.t.acc, 'PATCH', '/integrations/meta', { newVerifyToken: true })).status, 400, 'no code');
    const s = await h.call(c.t.acc, 'POST', '/integrations/meta/verify-token/code', {});
    assert.equal(s.status, 200, JSON.stringify(s.body));
    assert.equal(sent.at(-1).to[0].email, 'acc@value.test');
    const code = /(\d{4})/.exec(sent.at(-1).textContent)![1];
    assert.equal((await h.call(c.t.acc, 'PATCH', '/integrations/meta', { newVerifyToken: true, code: code === '0000' ? '1111' : '0000' })).status, 400);
    assert.equal((await h.call(c.t.acc, 'PATCH', '/integrations/meta', { newVerifyToken: true, code })).status, 200);
    assert.notEqual((await h.db.query(`SELECT verify_token FROM integrations WHERE source = 'meta'`)).rows[0].verify_token, before);
    assert.equal((await h.call(c.t.acc, 'PATCH', '/integrations/meta', { newVerifyToken: true, code })).status, 400, 'single use');
  } finally {
    globalThis.fetch = prev; delete process.env.BREVO_API_KEY; delete process.env.MAIL_FROM;
  }
});
