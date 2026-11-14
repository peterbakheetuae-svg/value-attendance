import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { leadsAutoReassign } from '../src/modules/leads2.ts';

/** نظام الليدز — المرحلة التانية */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let pid: string; let channel: string;
const at = (iso: string) => { h.now.value = new Date(iso); };
const add = async (name: string, phone: string, assignees: string[]) =>
  (await h.call(c.t.acc, 'POST', '/leads', { fullName: name, phone, projectId: pid, channelId: channel, assignees })).body.lead;
before(async () => {
  h = await harness('2026-11-14T08:00:00Z'); c = await cast(h);
  // the leads distributor is «مسؤول إداري» (the accountant alone has no sales board)
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج المرحلة التانية', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  channel = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
});
after(async () => { await h.close(); });

test('rating, bulk edit and the calendar', async () => {
  const a = await add('عميل ١', '01030000001', [c.ids.e1]);
  const b = await add('عميل ٢', '01030000002', [c.ids.e1]);
  assert.equal((await h.call(c.t.e1, 'PATCH', `/leads/${a.id}`, { rating: 'hot' })).body.lead.rating, 'hot');
  assert.equal((await h.call(c.t.e1, 'GET', '/leads?rating=hot')).body.total, 1);
  assert.equal((await h.call(c.t.e1, 'POST', '/leads/bulk', { ids: [a.id, b.id], kind: 'cold' })).status, 403);
  assert.equal((await h.call(c.t.sm1, 'POST', '/leads/bulk', { ids: [a.id, b.id], channelId: channel })).status, 403, 'the source is the distributor\'s');
  const bk = await h.call(c.t.sm1, 'POST', '/leads/bulk', { ids: [a.id, b.id], kind: 'cold', rating: 'warm' });
  assert.equal(bk.status, 200, JSON.stringify(bk.body));
  assert.equal(bk.body.updated, 2);
  assert.equal((await h.call(c.t.e1, 'GET', '/leads?tab=cold')).body.total, 2);
  await h.call(c.t.e1, 'POST', `/leads/${a.id}/actions`, { stage: 'meeting', comment: 'معاينة', nextAt: '2026-11-16T10:00:00Z' });
  await h.call(c.t.e1, 'POST', '/tasks', { title: 'ابعت العرض', dueAt: '2026-11-17T09:00:00Z', leadId: a.id });
  const cal = (await h.call(c.t.e1, 'GET', '/leads/calendar?from=2026-11-01&to=2026-11-30')).body;
  assert.deepEqual(cal.items.map((x: any) => x.kind), ['lead', 'task']);
  assert.equal(cal.items[0].stage, 'meeting');
  assert.equal((await h.call(c.t.e2, 'GET', '/leads/calendar?from=2026-11-01&to=2026-11-30')).body.items.length, 0, 'not his');
  assert.equal((await h.call(c.t.sm1, 'GET', '/leads/calendar?from=2026-11-01&to=2026-11-30&view=team')).body.items.length, 2);
});

test('files, the client\'s request and the matching units, the check-in', async () => {
  const l = await add('عميل الطلب', '01030000003', [c.ids.e2]);
  // the available units of the project
  for (const [no, type, area, price] of [['A-1', 'محل', 30, 1_500_000], ['A-2', 'محل', 60, 3_000_000], ['B-1', 'عيادة', 45, 2_000_000]] as const) {
    const u = await h.call(c.t.owner, 'POST', `/exclusive/projects/${pid}/inventory`, { unitNo: no, unitType: type, areaM2: area, unitPrice: price });
    assert.equal(u.status, 201, JSON.stringify(u.body));
  }
  const rq = await h.call(c.t.e2, 'POST', `/leads/${l.id}/request`, { projectId: pid, unitType: 'محل', maxPrice: 2_000_000, payment: 'installments' });
  assert.equal(rq.status, 200, JSON.stringify(rq.body));
  assert.deepEqual(rq.body.matches.map((m: any) => m.unitNo), ['A-1']);
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${l.id}/request`, { unitType: 'محل' })).status, 404, 'not his');
  const f = await h.call(c.t.e2, 'POST', `/leads/${l.id}/attachments`, { fileName: 'بطاقة.jpg', mime: 'image/jpeg', data: Buffer.from('x'.repeat(500)).toString('base64') });
  assert.equal(f.status, 201);
  assert.equal((await h.call(c.t.e2, 'POST', `/leads/${l.id}/attachments`, { fileName: 'big.pdf', data: Buffer.alloc(3_100_000).toString('base64') })).status, 400);
  at('2026-11-14T12:00:00Z');
  await h.call(c.t.e2, 'POST', `/leads/${l.id}/actions`, { stage: 'meeting', comment: 'في المشروع', nextAt: '2026-11-14T13:00:00Z' });
  at('2026-11-14T13:05:00Z');
  const ck = await h.call(c.t.e2, 'POST', `/leads/${l.id}/checkins`, { lat: 30.1, lng: 31.2, accuracy: 12, note: 'عند البوابة' });
  assert.equal(ck.status, 201, JSON.stringify(ck.body));
  const x = (await h.call(c.t.e2, 'GET', `/leads/${l.id}/extra`)).body;
  assert.equal(x.attachments.length, 1);
  assert.equal(x.request.payment, 'installments');
  assert.equal(x.checkins.length, 1);
  const d = (await h.call(c.t.e2, 'GET', `/leads/${l.id}`)).body;
  assert.equal(d.lead.stage, 'after_meeting', 'the check-in moves the meeting on');
  const file = (await h.call(c.t.sm1, 'GET', `/leads/attachments/${x.attachments[0].id}`)).body;
  assert.equal(Buffer.from(file.data, 'base64').length, 500);
  assert.equal((await h.call(c.t.e3, 'GET', `/leads/attachments/${x.attachments[0].id}`)).status, 404);
  // a unit reserved is no longer offered
  const units = (await h.call(c.t.e2, 'GET', `/leads/available-units?projectId=${pid}`)).body.units;
  assert.equal(units.length, 3);
});

test('templates and targets', async () => {
  const t = (await h.call(c.t.e1, 'GET', '/leads/templates')).body;
  assert.ok(t.templates.length >= 3);
  assert.equal((await h.call(c.t.e1, 'POST', '/leads/templates', { name: 'x', body: 'y' })).status, 403);
  assert.equal((await h.call(c.t.acc, 'POST', '/leads/templates', { name: 'عرض سعر', body: 'أهلاً {الاسم}' })).status, 201);
  const set = await h.call(c.t.acc, 'POST', '/leads/targets', { month: '2026-11', items: [{ employeeId: c.ids.e1, calls: 10, meetings: 2, reservations: 1, deals: 1 }] });
  assert.equal(set.status, 200, JSON.stringify(set.body));
  const me = (await h.call(c.t.e1, 'GET', '/leads/targets/me?month=2026-11')).body.me;
  assert.equal(me.target.calls, 10);
  assert.equal(me.actual.calls, 1);
  assert.equal(me.pct.calls, 10);
  assert.equal(me.pct.meetings, 50);
  assert.equal((await h.call(c.t.e1, 'GET', '/leads/targets')).status, 403);
  assert.ok((await h.call(c.t.sm1, 'GET', '/leads/targets?month=2026-11')).body.people.some((p: any) => p.id === c.ids.e1));
});

test('reports: hourly, yearly, distribution; the export log', async () => {
  const hr = (await h.call(c.t.acc, 'GET', '/leads/reports/hourly?from=2026-11-14&to=2026-11-14')).body;
  assert.ok(hr.people.some((p: any) => p.total > 0 && p.hours.length === 24));
  const yr = (await h.call(c.t.e1, 'GET', '/leads/reports/yearly?year=2026')).body;
  assert.equal(yr.months.length, 12);
  assert.equal(yr.months[10].month, '2026-11');
  assert.ok(yr.months[10].leads >= 2);
  assert.equal((await h.call(c.t.e1, 'GET', `/leads/reports/yearly?year=2026&employeeId=${c.ids.e2}`)).status, 403);
  const dist = (await h.call(c.t.acc, 'GET', '/leads/reports/distribution?from=2026-11-01&to=2026-11-30')).body;
  assert.ok(dist.people.some((p: any) => p.id === c.ids.e1 && p.total >= 2));
  assert.equal((await h.call(c.t.e1, 'POST', '/leads/exports', { kind: 'leads', rows: 3 })).status, 403);
  assert.equal((await h.call(c.t.acc, 'POST', '/leads/exports', { kind: 'leads', rows: 3, filters: { tab: 'all' } })).status, 201);
  assert.equal((await h.call(c.t.acc, 'GET', '/leads/exports')).body.exports[0].rows, 3);
});

test('the public form of a campaign: leads come in and take turns', async () => {
  const camp = (await h.call(c.t.acc, 'POST', '/leads/campaigns', { name: 'إعلان فيسبوك', channelId: channel, projectId: pid, cost: 500 })).body.campaign;
  const f = await h.call(c.t.acc, 'POST', `/leads/campaigns/${camp.id}/form`, { assignees: [c.ids.e1, c.ids.e2], title: 'احجز وحدتك' });
  assert.equal(f.status, 200, JSON.stringify(f.body));
  const page = await h.call(null as any, 'GET', f.body.path);
  assert.equal(page.status, 200);
  assert.match(page.raw.toString('utf8'), /احجز وحدتك/);
  const token = f.body.token;
  at('2026-11-14T14:00:00Z');
  assert.equal((await h.call(null as any, 'POST', `/public/leads/${token}`, { fullName: 'من الإعلان', phone: '01040000001' })).status, 201);
  at('2026-11-14T14:01:00Z');
  assert.equal((await h.call(null as any, 'POST', `/public/leads/${token}`, { fullName: 'من الإعلان ٢', phone: '01040000002' })).status, 201);
  assert.equal((await h.call(null as any, 'POST', `/public/leads/${token}`, { fullName: 'نفس الرقم', phone: '01040000002' })).status, 201);
  assert.equal((await h.call(null as any, 'POST', `/public/leads/${token}`, { fullName: 'بوت', phone: '01040000009', website: 'spam' })).status, 201);
  const got = (await h.call(c.t.acc, 'GET', `/leads?campaignId=${camp.id}`)).body;
  assert.equal(got.total, 2, 'the repeat and the bot are not added');
  assert.notEqual(got.leads[0].assignedTo.id, got.leads[1].assignedTo.id, 'in turn');
  assert.equal((await h.call(null as any, 'POST', '/public/leads/nonexistent1', { fullName: 'x', phone: '01040000003' })).status, 404);
});

test('the automatic pull to the next salesman of the pool', async () => {
  at('2026-11-15T08:00:00Z');
  const l = await add('عميل يتسحب', '01050000001', [c.ids.e1, c.ids.e2]);
  const first = l.assignedTo.id;
  assert.equal((await h.call(c.t.acc, 'PATCH', '/leads/settings', { autoReassignMinutes: 20 })).status, 400, 'after the 25 minutes alert');
  assert.equal((await h.call(c.t.acc, 'PATCH', '/leads/settings', { autoReassignMinutes: 60 })).body.autoReassignMinutes, 60);
  at('2026-11-15T08:50:00Z');
  await h.db.tx((q) => leadsAutoReassign(q, h.now.value));
  assert.equal((await h.call(c.t.acc, 'GET', `/leads/${l.id}`)).body.lead.assignedTo.id, first, 'not yet');
  at('2026-11-15T09:01:00Z');
  await h.db.tx((q) => leadsAutoReassign(q, h.now.value));
  const d = (await h.call(c.t.acc, 'GET', `/leads/${l.id}`)).body;
  assert.notEqual(d.lead.assignedTo.id, first);
  assert.ok(d.logs.some((g: any) => g.kind === 'assign' && g.data.mode === 'auto'));
  // one salesman only → never pulled
  const one = await add('عميل لواحد', '01050000002', [c.ids.e1]);
  at('2026-11-15T12:00:00Z');
  await h.db.tx((q) => leadsAutoReassign(q, h.now.value));
  assert.equal((await h.call(c.t.acc, 'GET', `/leads/${one.id}`)).body.lead.assignedTo.id, c.ids.e1);
  await h.call(c.t.acc, 'PATCH', '/leads/settings', { autoReassignMinutes: null });
});

test('the sales board cards: delay list, latest, comments, activity, calls / WhatsApp, created today, 7 days, online, to-do', async () => {
  const l = await add('عميل اللوحة', '01055500001', [c.ids.e1]);
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${l.id}/contact`, { via: 'call' })).status, 200);
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${l.id}/contact`, { via: 'whatsapp' })).status, 200);
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${l.id}/contact`, { via: 'sms' })).status, 400);
  assert.equal((await h.call(c.t.e2, 'POST', `/leads/${l.id}/contact`, { via: 'call' })).status, 404, 'not his lead');
  const d = (await h.call(c.t.acc, 'GET', '/leads/dashboard')).body;
  assert.ok(d.kpis.callsToday >= 1 && d.kpis.whatsappToday >= 1 && d.kpis.createdToday >= 1, JSON.stringify(d.kpis));
  assert.equal(d.created7.length, 7);
  assert.equal(d.response7.length, 7);
  assert.ok(d.latest.some((x: any) => x.id === l.id));
  assert.ok(d.activity.some((x: any) => x.kind === 'call' && x.lead.id === l.id));
  assert.ok(Array.isArray(d.delayList) && Array.isArray(d.lastComments) && Array.isArray(d.todo));
  assert.ok(d.online.some((x: any) => x.me), 'the accountant who just called is online');
  const mine = (await h.call(c.t.e1, 'GET', '/leads/dashboard')).body;
  assert.ok(mine.latest.every((x: any) => x.assignedTo?.id === c.ids.e1), 'a salesman sees only his own');
});

test('صلاحيات الأدوار: the owner turns a leads permission off for a role, then gives it back to one employee', async () => {
  assert.equal((await h.call(c.t.acc, 'GET', '/leads/permissions')).status, 403, 'owner only');
  const p = (await h.call(c.t.owner, 'GET', '/leads/permissions')).body;
  assert.ok(p.perms.some((x: any) => x.key === 'leads.create'));
  const se = p.roles.find((x: any) => x.key === 'sales_employee');
  assert.ok(se.perms.includes('leads.create') && se.perms.includes('leads.own'), 'nothing changed for anyone');
  assert.ok(!p.roles.some((x: any) => x.key === 'owner'));
  const add = (t: string) => h.call(t, 'POST', '/leads', { fullName: 'عميل صلاحيات', phone: '0105' + Math.floor(1e6 + Math.random() * 8e6), projectId: pid, channelId: channel });
  assert.equal((await h.call(c.t.owner, 'PUT', '/leads/permissions/role', { role: 'sales_employee', perm: 'leads.create', on: false })).status, 200);
  assert.equal((await add(c.t.e1)).status, 403, 'the role lost «إضافة العملاء»');
  assert.equal((await h.call(c.t.owner, 'PUT', '/leads/permissions/employee', { employeeId: c.ids.e1, perm: 'leads.create', value: 'allow' })).status, 200);
  assert.equal((await add(c.t.e1)).status, 201, 'his own exception');
  assert.equal((await add(c.t.e2)).status, 403, 'the others in the role still cannot');
  assert.equal((await h.call(c.t.owner, 'PUT', '/leads/permissions/employee', { employeeId: c.ids.e1, perm: 'leads.own', value: 'deny' })).status, 200);
  const meta = (await h.call(c.t.acc, 'GET', '/leads/meta')).body;
  assert.ok(!meta.assignees.some((x: any) => x.id === c.ids.e1), 'denied «يشتغل على ليدز» → not offered for leads');
  assert.equal((await h.call(c.t.owner, 'PUT', '/leads/permissions/employee', { employeeId: c.ids.owner, perm: 'leads.own', value: 'deny' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'PUT', '/leads/permissions/role', { role: 'owner', perm: 'leads.own', on: false })).status, 403);
  assert.equal((await h.call(c.t.owner, 'PUT', '/leads/permissions/role', { role: 'sales_employee', perm: 'roles.manage', on: true })).status, 400, 'only leads permissions here');
  // back as it was
  await h.call(c.t.owner, 'PUT', '/leads/permissions/role', { role: 'sales_employee', perm: 'leads.create', on: true });
  await h.call(c.t.owner, 'PUT', '/leads/permissions/employee', { employeeId: c.ids.e1, perm: 'leads.create', value: 'inherit' });
  await h.call(c.t.owner, 'PUT', '/leads/permissions/employee', { employeeId: c.ids.e1, perm: 'leads.own', value: 'inherit' });
});
