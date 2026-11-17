import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/** شركات التسويق (075): their own sign-in, only their campaigns' leads (read-only + adding), and Meta only from chosen campaigns */
let pid: string;
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let camp1: string; let camp2: string; let other: string;
const realFetch = globalThis.fetch;
let metaLead: any = null;
before(async () => {
  h = await harness('2026-11-16T08:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج التسويق', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  const ch = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
  const mk = async (name: string) => {
    const r = await h.call(c.t.acc, 'POST', '/leads/campaigns', { name, channelId: ch, projectId: pid });
    assert.equal(r.status, 201, JSON.stringify(r.body));
    return r.body.campaign?.id ?? (await h.db.query(`SELECT id FROM lead_campaigns WHERE name = $1`, [name])).rows[0].id;
  };
  camp1 = await mk('حملة الشركة 1'); camp2 = await mk('حملة الشركة 2'); other = await mk('حملة تانية');
  await h.db.query(`UPDATE lead_campaigns SET form_assignees = $1`, [[c.ids.e1]]);
  // Meta's Graph API, faked: the lead read back with the office's token
  globalThis.fetch = (async (url: any, init: any) => {
    if (String(url).startsWith('https://graph.facebook.com/')) {
      return new Response(JSON.stringify(metaLead), { status: 200, headers: { 'content-type': 'application/json' } });
    }
    return realFetch(url, init);
  }) as typeof fetch;
});
after(async () => { globalThis.fetch = realFetch; await h.close(); });

let companyId: string; let pt: string;

test('the office: an existing marketing company gets its own sign-in (not an employee) and its campaigns', async () => {
  const mk = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'آدز ميديا', kind: 'commission', defaultPct: 1 });
  assert.equal(mk.status, 201, JSON.stringify(mk.body));
  companyId = mk.body.company.id;
  assert.equal((await h.call(c.t.e1, 'GET', '/leads/partners')).status, 403, 'leads settings only');
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/partners/${companyId}/login`, { email: 'ads@media.com' })).status, 400, 'a first password');
  const empMail = (await h.db.query(`SELECT email FROM employees WHERE id = $1`, [c.ids.e1])).rows[0].email;
  if (empMail) assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/partners/${companyId}/login`, { email: empMail, password: 'Start#2026x' })).status, 409, 'not an employee\'s e-mail');
  const r = await h.call(c.t.acc, 'PATCH', `/leads/partners/${companyId}/login`, { email: 'ads@media.com', phone: '01234567890', password: 'Start#2026x' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.body.company.hasLogin && !JSON.stringify(r.body).includes('Start#2026x'));
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM employees WHERE lower(email) = 'ads@media.com'`)).rows[0].n, 0, 'not in the employees');
  for (const id of [camp1, camp2]) {
    const l = await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${id}/partner`, { companyId });
    assert.equal(l.status, 200, JSON.stringify(l.body));
  }
  const list = (await h.call(c.t.acc, 'GET', '/leads/partners')).body.companies;
  assert.equal(list.find((x: any) => x.id === companyId).campaigns.length, 2);
});

test('the company signs in (e-mail or mobile), must change the password, and is refused everywhere else', async () => {
  const bad = await h.call(null, 'POST', '/auth/login', { identifier: 'ads@media.com', password: 'nope-nope', deviceId: 'device-main-0000000000000' });
  assert.equal(bad.status, 401);
  const lg = await h.call(null, 'POST', '/auth/login', { identifier: '+20 123 456 7890', password: 'Start#2026x', deviceId: 'device-main-0000000000000' });
  assert.equal(lg.status, 200, JSON.stringify(lg.body));
  assert.equal(lg.body.partner, true);
  assert.equal(lg.body.mustChangePassword, true);
  pt = lg.body.token;
  const me = await h.call(pt, 'GET', '/me');
  assert.equal(me.status, 200);
  assert.equal(me.body.employee.role_key, 'marketing_partner');
  assert.deepEqual(me.body.permissions, []);
  assert.equal((await h.call(pt, 'GET', '/partner/dashboard')).status, 403, 'change the password first');
  const cp = await h.call(pt, 'POST', '/auth/change-password', { currentPassword: 'Start#2026x', newPassword: 'Mine#2026yy' });
  assert.equal(cp.status, 200, JSON.stringify(cp.body));
  // every employee endpoint: refused with 403 (the app keeps it signed in), never data
  for (const [m, p] of [['GET', '/leads'], ['GET', '/employees'], ['GET', '/leads/dashboard'], ['GET', '/leads/partners'], ['POST', '/leads']] as const) {
    const x = await h.call(pt, m, p, m === 'POST' ? { fullName: 'x', phone: '01000000000' } : undefined);
    assert.equal(x.status, 403, `${m} ${p}`);
  }
  const relog = await h.call(null, 'POST', '/auth/login', { identifier: 'ads@media.com', password: 'Mine#2026yy', deviceId: 'device-main-0000000000000' });
  assert.equal(relog.status, 200);
  pt = relog.body.token;
});

test('it sees only its campaigns\' leads — stage, salesman, comments, closed — and adds leads, nothing else', async () => {
  const add = async (camp: string, name: string, phone: string, tok = c.t.acc) =>
    h.call(tok, 'POST', '/leads', { fullName: name, phone, campaignId: camp, projectId: pid });
  const l1 = await add(camp1, 'عميل حملة 1', '01011110001');
  assert.equal(l1.status, 201, JSON.stringify(l1.body));
  await add(other, 'عميل حملة تانية', '01011110002');
  const id1 = l1.body.lead.id;
  // a salesman's comment on it
  await h.db.query(`UPDATE leads SET assigned_to = $2 WHERE id = $1`, [id1, c.ids.e1]);
  const act = await h.call(c.t.e1, 'POST', `/leads/${id1}/actions`, { stage: 'following', comment: 'كلمته وهيرد', nextAt: '2026-11-17T09:00:00Z' });
  assert.ok([200, 201].includes(act.status), JSON.stringify(act.body));

  const leads = await h.call(pt, 'GET', '/partner/leads');
  assert.equal(leads.status, 200, JSON.stringify(leads.body));
  assert.deepEqual(leads.body.leads.map((x: any) => x.fullName), ['عميل حملة 1']);
  const other1 = (await h.db.query(`SELECT id FROM leads WHERE full_name = 'عميل حملة تانية'`)).rows[0].id;
  assert.equal((await h.call(pt, 'GET', `/partner/leads/${other1}`)).status, 404, 'another campaign\'s lead cannot be opened');
  const d = await h.call(pt, 'GET', `/partner/leads/${id1}`);
  assert.equal(d.status, 200);
  assert.equal(d.body.lead.salesman, (await h.db.query(`SELECT full_name FROM employees WHERE id = $1`, [c.ids.e1])).rows[0].full_name);
  assert.ok(d.body.actions.some((a: any) => a.comment === 'كلمته وهيرد' && a.stage?.key === 'following'));
  assert.equal(d.body.lead.closed, false);

  // adding: only to its own campaigns
  assert.equal((await h.call(pt, 'POST', '/partner/leads', { campaignId: other, fullName: 'مش بتاعتها', phone: '01011110003' })).status, 400);
  const mine = await h.call(pt, 'POST', '/partner/leads', { campaignId: camp2, fullName: 'ليد من الشركة', phone: '01011110004', notes: 'من معرض' });
  assert.equal(mine.status, 201, JSON.stringify(mine.body));
  const row = (await h.db.query(`SELECT * FROM leads WHERE id = $1`, [mine.body.lead.id])).rows[0];
  assert.equal(row.partner_company_id, companyId);
  assert.equal(row.assigned_to, c.ids.e1, 'distributed as the campaign says');
  assert.equal((await h.call(pt, 'POST', '/partner/leads', { campaignId: camp2, fullName: 'ليد من الشركة', phone: '01011110004' })).status, 409);
  // no actions, no distribution
  assert.equal((await h.call(pt, 'POST', `/leads/${id1}/actions`, { stage: 'cancelled', comment: 'x' })).status, 403);
  assert.equal((await h.call(pt, 'PATCH', `/leads/${id1}`, { fullName: 'y' })).status, 403);

  const dash = await h.call(pt, 'GET', '/partner/dashboard');
  assert.equal(dash.status, 200, JSON.stringify(dash.body));
  assert.equal(dash.body.counts.total, 2);
  assert.equal(dash.body.counts.today, 2);
  assert.equal(dash.body.campaigns.length, 2);
  assert.equal(dash.body.latest.length, 2);
  assert.equal(dash.body.created7.length, 7);
  assert.ok(dash.body.pipeline.some((s: any) => s.key === 'following' && s.count === 1));
});

test('Meta: only the chosen Meta campaigns come in; others are counted to be linked', async () => {
  await h.db.query(`INSERT INTO integrations (source, active, access_token) VALUES ('meta', true, 'tok') ON CONFLICT (source) DO UPDATE SET active = true, access_token = 'tok'`);
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${camp1}/partner`, { metaCampaignIds: ['abc'] })).status, 400);
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${camp1}/partner`, { metaCampaignIds: ['120001'] })).status, 200);
  const send = (leadgen: string) => h.call(null, 'POST', '/public/hooks/meta', { entry: [{ changes: [{ field: 'leadgen', value: { leadgen_id: leadgen } }] }] });
  metaLead = { campaign_id: '120001', campaign_name: 'Ads Nov', form_id: '9', field_data: [{ name: 'full_name', values: ['عميل فيسبوك'] }, { name: 'phone_number', values: ['01055550001'] }] };
  assert.equal((await send('7001')).body.added, 1);
  metaLead = { ...metaLead, campaign_id: '120999', campaign_name: 'Not ours', field_data: [{ name: 'full_name', values: ['عميل تاني'] }, { name: 'phone_number', values: ['01055550002'] }] };
  assert.equal((await send('7002')).body.added, 0, 'a Meta campaign linked to none of ours is not added');
  const l = (await h.db.query(`SELECT campaign_id FROM leads WHERE full_name = 'عميل فيسبوك'`)).rows[0];
  assert.equal(l.campaign_id, camp1);
  const seen = (await h.call(c.t.acc, 'GET', '/integrations')).body.metaSeen;
  assert.ok(seen.some((x: any) => x.id === '120999' && x.skipped === 1 && x.name === 'Not ours'));
  // a Meta campaign feeds one of ours only
  await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${camp2}/partner`, { metaCampaignIds: ['120001'] });
  assert.deepEqual((await h.db.query(`SELECT meta_campaign_ids FROM lead_campaigns WHERE id = $1`, [camp1])).rows[0].meta_campaign_ids, []);
  // the company sees the Meta lead of its campaign
  assert.ok((await h.call(pt, 'GET', '/partner/leads')).body.leads.some((x: any) => x.fullName === 'عميل فيسبوك'));
});

test('stopping the company or a new password signs it out', async () => {
  assert.equal((await h.call(c.t.owner, 'PATCH', `/marketing-companies/${companyId}`, { status: 'inactive' })).status, 200);
  assert.equal((await h.call(pt, 'GET', '/partner/dashboard')).status, 401);
  assert.equal((await h.call(null, 'POST', '/auth/login', { identifier: 'ads@media.com', password: 'Mine#2026yy', deviceId: 'device-main-0000000000000' })).status, 403);
});

test('the company\'s file: general / direct manager (an «مسؤول إداري»), contract date, campaigns, its three documents', async () => {
  const mk = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة الملف', kind: 'fixed', monthlyFee: 5000 });
  assert.equal(mk.status, 201);
  const id = mk.body.company.id;
  assert.equal((await h.call(c.t.e1, 'GET', `/marketing-companies/${id}`)).status, 403);
  const f0 = await h.call(c.t.owner, 'GET', `/marketing-companies/${id}`);
  assert.equal(f0.status, 200, JSON.stringify(f0.body));
  assert.ok(f0.body.options.managers.some((x: any) => x.id === c.ids.acc), 'the administrative officers to choose from');
  assert.equal((await h.call(c.t.owner, 'PATCH', `/marketing-companies/${id}/profile`, { managerId: c.ids.e1 })).status, 400, 'the direct manager is an «مسؤول إداري»');
  const p = await h.call(c.t.owner, 'PATCH', `/marketing-companies/${id}/profile`, { managerId: c.ids.acc, generalManagerId: c.ids.owner, contractDate: '2026-11-01', campaignIds: [other] });
  assert.equal(p.status, 200, JSON.stringify(p.body));
  const pdf = Buffer.from('%PDF-1.4 test').toString('base64');
  assert.equal((await h.call(c.t.owner, 'PUT', `/marketing-companies/${id}/files/contract`, { fileName: 'x.pdf', mime: 'application/pdf', data: Buffer.from('not a pdf').toString('base64') })).status, 400);
  assert.equal((await h.call(c.t.owner, 'PUT', `/marketing-companies/${id}/files/passport`, { fileName: 'x.pdf', mime: 'application/pdf', data: pdf })).status, 404);
  for (const k of ['contract', 'financial_plan', 'execution_vision']) {
    const u = await h.call(c.t.owner, 'PUT', `/marketing-companies/${id}/files/${k}`, { fileName: `${k}.pdf`, mime: 'application/pdf', data: pdf });
    assert.equal(u.status, 200, JSON.stringify(u.body));
  }
  const f1 = (await h.call(c.t.owner, 'GET', `/marketing-companies/${id}`)).body.company;
  assert.equal(f1.manager.id, c.ids.acc);
  assert.equal(f1.contractDate, '2026-11-01');
  assert.deepEqual(f1.campaignIds, [other]);
  assert.deepEqual(Object.keys(f1.files).sort(), ['contract', 'execution_vision', 'financial_plan']);
  const g = await h.call(c.t.owner, 'GET', `/marketing-companies/${id}/files/contract`);
  assert.equal(Buffer.from(g.body.data, 'base64').toString(), '%PDF-1.4 test');
});

test('«ربط الحساب بالجهاز» and «حالة تسجيل الدخول» for a company', async () => {
  const mk = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة الجهاز', kind: 'commission', defaultPct: 1 });
  const id = mk.body.company.id;
  assert.equal((await h.call(c.t.owner, 'PATCH', `/leads/partners/${id}/login`, { phone: '01200000777', password: 'Start#2026x' })).status, 200);
  const dev = (x: string) => `device-${x}-0000000000000`;
  const login = (d?: string) => h.call(null, 'POST', '/auth/login', { identifier: '01200000777', password: 'Start#2026x', ...(d ? { deviceId: d } : {}) });
  assert.equal((await login()).status, 403, 'a device id is needed');
  assert.equal((await login(dev('a'))).status, 200, 'the first device is its device');
  assert.equal((await login(dev('b'))).status, 403, 'another device is refused');
  assert.equal((await login(dev('a'))).status, 200);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/marketing-companies/${id}/profile`, { resetDevice: true })).status, 200);
  assert.equal((await login(dev('b'))).status, 200, 'freed: the next device becomes its device');
  assert.equal((await h.call(c.t.owner, 'PATCH', `/marketing-companies/${id}/profile`, { loginActive: false })).status, 200);
  assert.equal((await login(dev('b'))).status, 403, 'login off');
  const f = (await h.call(c.t.owner, 'GET', `/marketing-companies/${id}`)).body.company;
  assert.equal(f.loginActive, false);
  assert.equal(f.deviceLock, true);
});

test('a campaign is created / edited with its marketing company (leads settings → الحملات)', async () => {
  const mk = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة الحملة', kind: 'commission', defaultPct: 1 });
  const co = mk.body.company.id;
  const ch = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
  const r = await h.call(c.t.acc, 'POST', '/leads/campaigns', { name: 'حملة بشركة', channelId: ch, projectId: pid, companyId: co });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const s = (await h.call(c.t.acc, 'GET', '/leads/config')).body;
  const x = s.campaigns.find((k: any) => k.id === r.body.campaign.id);
  assert.equal(x.companyId, co);
  assert.equal(x.companyName, 'شركة الحملة');
  assert.ok(s.companies.some((k: any) => k.id === co));
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${x.id}`, { name: 'حملة بشركة', channelId: ch, projectId: pid })).status, 200);
  assert.equal((await h.db.query(`SELECT marketing_company_id FROM lead_campaigns WHERE id = $1`, [x.id])).rows[0].marketing_company_id, co, 'absent = unchanged');
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${x.id}`, { name: 'حملة بشركة', channelId: ch, projectId: pid, companyId: null })).status, 200);
  assert.equal((await h.db.query(`SELECT marketing_company_id FROM lead_campaigns WHERE id = $1`, [x.id])).rows[0].marketing_company_id, null);
  // the Meta campaigns it tracks, set with the campaign (one Meta campaign → one of ours)
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${x.id}`, { name: 'حملة بشركة', channelId: ch, projectId: pid, metaCampaignIds: ['55501'] })).status, 200);
  assert.deepEqual((await h.call(c.t.acc, 'GET', '/leads/config')).body.campaigns.find((k: any) => k.id === x.id).metaCampaignIds, ['55501']);
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/campaigns/${x.id}`, { name: 'حملة بشركة', channelId: ch, projectId: pid, metaCampaignIds: ['x1'] })).status, 400);
  const meta = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.campaigns;
  assert.ok(meta.some((k: any) => k.id === camp1 && k.company === 'آدز ميديا'), 'the lead form shows the company with the campaign');
});

test('a company adds a lead that exists: «الليد ده موجود»; «إضافة» → not distributed, the managers are told', async () => {
  const mk = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة المكرر', kind: 'commission', defaultPct: 1 });
  const id = mk.body.company.id;
  await h.call(c.t.owner, 'PATCH', `/leads/partners/${id}/login`, { email: 'dup@co.com', password: 'Start#2026x' });
  await h.db.query(`UPDATE marketing_companies SET must_change_password = false, device_lock = false WHERE id = $1`, [id]);
  await h.call(c.t.owner, 'PATCH', `/marketing-companies/${id}/profile`, { campaignIds: [other] });
  const tok = (await h.call(null, 'POST', '/auth/login', { identifier: 'dup@co.com', password: 'Start#2026x' })).body.token;
  const first = await h.call(tok, 'POST', '/partner/leads', { campaignId: other, fullName: 'عميل مكرر', phone: '01099990000' });
  assert.equal(first.status, 201, JSON.stringify(first.body));
  // the next day, the same number again
  h.now.value = new Date(h.now.value.getTime() + 26 * 3600_000);
  const again = await h.call(tok, 'POST', '/partner/leads', { campaignId: other, fullName: 'عميل مكرر', phone: '01099990000' });
  assert.equal(again.status, 409);
  assert.equal(again.body.error.message, 'الليد ده موجود بالفعل');
  assert.equal(again.body.error.details?.reason, 'duplicate');
  const ok2 = await h.call(tok, 'POST', '/partner/leads', { campaignId: other, fullName: 'عميل مكرر', phone: '01099990000', confirmDuplicate: true });
  assert.equal(ok2.status, 201, JSON.stringify(ok2.body));
  const row = (await h.db.query(`SELECT assigned_to, duplicate_of FROM leads WHERE id = $1`, [ok2.body.lead.id])).rows[0];
  assert.equal(row.assigned_to, null, 'not distributed');
  assert.ok(row.duplicate_of);
  const n = (await h.db.query(`SELECT count(*)::int AS n FROM notifications WHERE type = 'lead_duplicate_partner' AND entity_id = $1`, [ok2.body.lead.id])).rows[0].n;
  assert.ok(n >= 1);
});
