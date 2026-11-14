import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

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

test('Value Aqar: the key, an inquiry becomes a lead on the campaign, the same number twice once', async () => {
  assert.equal((await h.call(c.t.e1, 'GET', '/integrations')).status, 403);
  const k = await h.call(c.t.acc, 'POST', '/integrations/valueaqar/key', {});
  assert.equal(k.status, 200, JSON.stringify(k.body));
  key = k.body.key;
  const list = (await h.call(c.t.acc, 'GET', '/integrations')).body;
  assert.ok(list.valueaqar.hasKey && !JSON.stringify(list).includes(key), 'the key is never shown again');
  assert.equal((await h.call(c.t.acc, 'PATCH', '/integrations/valueaqar', { campaignId: campaign })).status, 200);
  assert.equal((await hook({ type: 'INSERT', table: 'inquiries', record: { name: 'x', phone: '01011112222' } }, 'wrong')).status, 401);
  const r = await hook({ type: 'INSERT', table: 'inquiries', schema: 'public', record: { id: 'q1', full_name: 'عميل الموقع', phone: '+20 101 111 2222', message: 'عايز شقة' }, old_record: null });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.body.lead);
  const lead = (await h.db.query(`SELECT * FROM leads WHERE id = $1`, [r.body.lead])).rows[0];
  assert.equal(lead.assigned_to, c.ids.e1);
  assert.equal(lead.campaign_id, campaign);
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
