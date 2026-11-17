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
  for (const [m, p] of [['GET', '/employees'], ['GET', '/leads/partners'], ['GET', '/leads/reports'], ['GET', '/leads/permissions'],
    ['POST', '/leads/import'], ['POST', '/leads/assign'], ['GET', '/notifications/sent'], ['POST', '/notifications/send'], ['GET', '/deals']] as const) {
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

test('the company\'s profile, its documents and its bell (its campaigns\' leads only)', async () => {
  const mk = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة الجرس', kind: 'fixed', monthlyFee: 7000 });
  const id = mk.body.company.id;
  await h.call(c.t.owner, 'PATCH', `/leads/partners/${id}/login`, { email: 'bell@co.com', password: 'Start#2026x' });
  await h.db.query(`UPDATE marketing_companies SET must_change_password = false, device_lock = false WHERE id = $1`, [id]);
  await h.call(c.t.owner, 'PATCH', `/marketing-companies/${id}/profile`, { campaignIds: [camp1], managerId: c.ids.acc, contractDate: '2026-10-01' });
  await h.call(c.t.owner, 'PUT', `/marketing-companies/${id}/files/contract`, { fileName: 'c.pdf', mime: 'application/pdf', data: Buffer.from('%PDF-1 x').toString('base64') });
  const tok = (await h.call(null, 'POST', '/auth/login', { identifier: 'bell@co.com', password: 'Start#2026x' })).body.token;
  const pr = await h.call(tok, 'GET', '/partner/profile');
  assert.equal(pr.status, 200, JSON.stringify(pr.body));
  assert.equal(pr.body.profile.name, 'شركة الجرس');
  assert.equal(pr.body.profile.contractDate, '2026-10-01');
  assert.ok(pr.body.profile.manager);
  assert.ok(pr.body.profile.files.contract);
  assert.equal((await h.call(tok, 'GET', '/partner/files/contract')).status, 200);
  const n1 = await h.call(tok, 'GET', '/partner/notifications');
  assert.equal(n1.status, 200, JSON.stringify(n1.body));
  assert.ok(n1.body.items.length > 0 && n1.body.unread > 0, 'its campaign already has leads');
  assert.equal((await h.call(tok, 'POST', '/partner/notifications/seen', {})).status, 200);
  assert.equal((await h.call(tok, 'GET', '/partner/notifications')).body.unread, 0);
});

test('the company opens the sales dashboard itself — read-only, its leads only — and the same notifications page', async () => {
  await h.db.query(`UPDATE marketing_companies SET status = 'active', login_active = true, device_lock = false WHERE id = $1`, [companyId]);
  pt = (await h.call(null, 'POST', '/auth/login', { identifier: 'ads@media.com', password: 'Mine#2026yy' })).body.token;
  await h.db.query(`UPDATE lead_campaigns SET marketing_company_id = $2 WHERE id = ANY($1::uuid[])`, [[camp1, camp2], companyId]);
  assert.ok(pt);
  const lead1 = (await h.db.query(`SELECT id FROM leads WHERE full_name = 'عميل حملة 1'`)).rows[0].id;
  const other1 = (await h.db.query(`SELECT id FROM leads WHERE full_name = 'عميل حملة تانية'`)).rows[0].id;
  const meta = await h.call(pt, 'GET', '/leads/meta');
  assert.equal(meta.status, 200, JSON.stringify(meta.body));
  assert.equal(meta.body.can.create, true);
  assert.equal(meta.body.can.distribute, false);
  assert.ok(meta.body.campaigns.every((x: any) => [camp1, camp2].includes(x.id)), 'its campaigns only');
  const dash = await h.call(pt, 'GET', '/leads/dashboard', undefined);
  assert.equal(dash.status, 200, JSON.stringify(dash.body));
  assert.ok(dash.body.counts.total >= 2, JSON.stringify(dash.body.counts));
  const list = await h.call(pt, 'GET', '/leads');
  assert.equal(list.status, 200, JSON.stringify(list.body));
  const ids = list.body.leads.map((x: any) => x.id);
  assert.ok(ids.includes(lead1) && !ids.includes(other1));
  const d = await h.call(pt, 'GET', `/leads/${lead1}`);
  assert.equal(d.status, 200, JSON.stringify(d.body));
  assert.equal(d.body.can.act, false); assert.equal(d.body.can.edit, false); assert.equal(d.body.can.reply, false);
  assert.ok(d.body.actions.some((a: any) => a.comment === 'كلمته وهيرد'));
  assert.equal((await h.call(pt, 'GET', `/leads/${other1}`)).status, 404);
  assert.equal((await h.call(pt, 'GET', `/leads/${lead1}/extra`)).status, 200);
  assert.equal((await h.call(pt, 'GET', '/tasks')).status, 200);
  // writing anything: refused
  assert.equal((await h.call(pt, 'POST', `/leads/${lead1}/actions`, { stage: 'cancelled', comment: 'x' })).status, 403);
  assert.equal((await h.call(pt, 'PATCH', `/leads/${lead1}`, { fullName: 'y' })).status, 403);
  assert.equal((await h.call(pt, 'POST', '/tasks', { title: 'x' })).status, 403);
  assert.equal((await h.call(pt, 'PATCH', `/leads/campaigns/${camp1}`, { name: 'x' })).status, 403);
  // adding from the dashboard's form: on its campaign
  const add = await h.call(pt, 'POST', '/leads', { fullName: 'من اللوحة', phone: '01011119999', campaignId: camp1, projectId: pid });
  assert.equal(add.status, 201, JSON.stringify(add.body));
  assert.equal((await h.db.query(`SELECT partner_company_id FROM leads WHERE id = $1`, [add.body.lead.id])).rows[0].partner_company_id, companyId);
  assert.equal((await h.call(pt, 'POST', '/leads', { fullName: 'غلط', phone: '01011119998', campaignId: other, projectId: pid })).status, 400);
  // settings (read-only): its campaigns; الربط: its campaigns, no tokens / salesmen
  const cfg = await h.call(pt, 'GET', '/leads/config');
  assert.equal(cfg.status, 200, JSON.stringify(cfg.body));
  assert.equal(cfg.body.readOnly, true);
  assert.deepEqual(cfg.body.campaigns.map((x: any) => x.id).sort(), [camp1, camp2].sort());
  const it = await h.call(pt, 'GET', '/integrations');
  assert.equal(it.status, 200, JSON.stringify(it.body));
  assert.equal(it.body.partner, true);
  assert.ok(!('verifyToken' in it.body.meta) && it.body.people.length === 0 && it.body.campaigns.length === 2);
  // it picks Meta campaigns for its own campaign only
  const link = await h.call(pt, 'PATCH', `/leads/campaigns/${camp2}/partner`, { metaCampaignIds: ['5550001'] });
  assert.equal(link.status, 200, JSON.stringify(link.body));
  assert.equal((await h.call(pt, 'PATCH', `/leads/campaigns/${other}/partner`, { metaCampaignIds: ['5550002'] })).status, 404);
  assert.equal((await h.call(pt, 'PATCH', `/leads/campaigns/${camp2}/partner`, { companyId: null })).status, 403);
  // the notifications: the same endpoints as everyone's
  const n = await h.call(pt, 'GET', '/notifications');
  assert.equal(n.status, 200, JSON.stringify(n.body));
  assert.ok(n.body.notifications.length > 0 && n.body.unread > 0);
  const first = n.body.notifications[0];
  assert.equal(first.entity, 'lead');
  assert.equal((await h.call(pt, 'POST', `/notifications/${first.id}/read`, {})).status, 200);
  assert.equal((await h.call(pt, 'DELETE', `/notifications/${first.id}`)).status, 200);
  const n2 = await h.call(pt, 'GET', '/notifications');
  assert.ok(!n2.body.notifications.some((x: any) => x.id === first.id), 'deleted stays deleted');
  assert.equal((await h.call(pt, 'POST', '/notifications/read-all', {})).status, 200);
  assert.equal((await h.call(pt, 'GET', '/notifications')).body.unread, 0);
  // an employee's notifications are untouched by it
  assert.equal((await h.call(c.t.e1, 'GET', '/notifications')).status, 200);
});

test('«تعديل الحساب»: name and mobile; a new e-mail only after its code', async () => {
  const sent: any[] = [];
  const prev = globalThis.fetch;
  process.env.BREVO_API_KEY = 'k'; process.env.MAIL_FROM = 'hr@value.test';
  globalThis.fetch = (async (url: any, init: any) => {
    if (String(url).startsWith('https://api.brevo.com/')) { sent.push(JSON.parse(init.body)); return new Response('{}', { status: 201 }); }
    return prev(url, init);
  }) as typeof fetch;
  try {
    const ed = await h.call(pt, 'PATCH', '/partner/account', { name: 'آدز ميديا جروب', phone: '01234567899' });
    assert.equal(ed.status, 200, JSON.stringify(ed.body));
    assert.equal(ed.body.account.name, 'آدز ميديا جروب');
    const empPhone = (await h.db.query(`SELECT phone FROM employees WHERE phone IS NOT NULL AND length(phone) >= 10 LIMIT 1`)).rows[0]?.phone;
    if (empPhone) assert.equal((await h.call(pt, 'PATCH', '/partner/account', { phone: empPhone })).status, 409);
    assert.equal((await h.call(null, 'POST', '/auth/login', { identifier: '01234567899', password: 'Mine#2026yy' })).status, 200, 'signs in with the new mobile');
    const r = await h.call(pt, 'POST', '/partner/account/email', { email: 'new@ads.com' });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(sent.at(-1).to[0].email, 'new@ads.com');
    assert.equal((await h.db.query(`SELECT login_email FROM marketing_companies WHERE id = $1`, [companyId])).rows[0].login_email, 'ads@media.com', 'not yet');
    const code = /(\d{4})/.exec(sent.at(-1).textContent)![1];
    assert.equal((await h.call(pt, 'POST', '/partner/account/email/verify', { code: code === '0000' ? '1111' : '0000' })).status, 400);
    const v = await h.call(pt, 'POST', '/partner/account/email/verify', { code });
    assert.equal(v.status, 200, JSON.stringify(v.body));
    assert.equal((await h.db.query(`SELECT login_email FROM marketing_companies WHERE id = $1`, [companyId])).rows[0].login_email, 'new@ads.com');
    assert.equal((await h.call(pt, 'POST', '/partner/account/email/verify', { code })).status, 400, 'single use');
    assert.equal((await h.call(c.t.e1, 'PATCH', '/partner/account', { name: 'x' })).status, 401, 'an employee is not a company');
    // its photo (logo): an image only, the content checked; then it reads it back
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(32)]).toString('base64');
    assert.equal((await h.call(pt, 'PUT', '/partner/files/logo', { fileName: 'x.pdf', mime: 'application/pdf', data: png })).status, 400);
    assert.equal((await h.call(pt, 'PUT', '/partner/files/logo', { fileName: 'x.png', mime: 'image/jpeg', data: png })).status, 400, 'not a JPEG');
    const lg = await h.call(pt, 'PUT', '/partner/files/logo', { fileName: 'logo.png', mime: 'image/png', data: png });
    assert.equal(lg.status, 200, JSON.stringify(lg.body));
    assert.equal((await h.call(pt, 'GET', '/partner/files/logo')).body.data, png);
    assert.equal((await h.call(c.t.e1, 'PUT', '/partner/files/logo', { fileName: 'logo.png', mime: 'image/png', data: png })).status, 401);
  } finally {
    globalThis.fetch = prev; delete process.env.BREVO_API_KEY; delete process.env.MAIL_FROM;
  }
});

test('VA-11: company B never sees the Meta campaigns already feeding company A (seen list and ad-account list)', async () => {
  const mkB = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة ب', kind: 'fixed', monthlyFee: 1000 });
  const idB = mkB.body.company.id;
  await h.call(c.t.owner, 'PATCH', `/leads/partners/${idB}/login`, { email: 'b@co.com', password: 'Start#2026x' });
  await h.db.query(`UPDATE marketing_companies SET must_change_password = false, device_lock = false WHERE id = $1`, [idB]);
  const tokB = (await h.call(null, 'POST', '/auth/login', { identifier: 'b@co.com', password: 'Start#2026x' })).body.token;
  // A's campaign (camp2) feeds from Meta 5550001; Meta has also shown 5550001 and a free one 5559999
  await h.db.query(`UPDATE lead_campaigns SET marketing_company_id = $2, meta_campaign_ids = '{5550001}' WHERE id = $1`, [camp2, companyId]);
  await h.db.query(`INSERT INTO meta_seen_campaigns (campaign_id, name, leads, skipped, last_at) VALUES ('5550001','A only',1,0,now()), ('5559999','free',1,1,now())
                    ON CONFLICT (campaign_id) DO NOTHING`);
  const itB = await h.call(tokB, 'GET', '/integrations');
  assert.equal(itB.status, 200, JSON.stringify(itB.body));
  const seenB = itB.body.metaSeen.map((x: any) => x.id);
  assert.ok(!seenB.includes('5550001') && seenB.includes('5559999'));
  assert.equal(itB.body.campaigns.length, 0, 'B has no campaign of A');
  const prevLead = metaLead;
  metaLead = { data: [{ name: 'acc', campaigns: { data: [{ id: '5550001', name: 'A' }, { id: '5559999', name: 'free' }] } }] };
  try {
    const lsB = await h.call(tokB, 'GET', '/integrations/meta/campaigns');
    assert.deepEqual(lsB.body.campaigns.map((x: any) => x.id), ['5559999']);
    const lsA = await h.call(pt, 'GET', '/integrations/meta/campaigns');
    assert.deepEqual(lsA.body.campaigns.map((x: any) => x.id).sort(), ['5550001', '5559999'], 'A sees its own');
  } finally { metaLead = prevLead; }
  // B cannot take A's Meta campaign nor touch A's campaign by id
  assert.equal((await h.call(tokB, 'PATCH', `/leads/campaigns/${camp2}/partner`, { metaCampaignIds: ['5559999'] })).status, 404);
  assert.equal((await h.call(tokB, 'GET', `/leads?campaignId=${camp2}`)).body.leads?.length ?? 0, 0, 'no A lead through a filter');
});
