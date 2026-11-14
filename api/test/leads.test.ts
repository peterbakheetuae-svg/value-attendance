import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { leadsSweep, phoneNorm } from '../src/modules/leads.ts';

/**
 * نظام الليدز: the distributor (المحاسب / المدير العام) adds leads and picks the salesmen (several → their turn),
 * the salesman works his own leads («إضافة أكشن»), his manager is told when nobody acted within 25 minutes,
 * «حجز» from a lead follows the normal reservation (confirmed when the deposit is received), the contract = تم البيع.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let pid: string; let channel: string;
const at = (iso: string) => { h.now.value = new Date(iso); };
before(async () => {
  h = await harness('2026-11-14T08:00:00Z'); c = await cast(h);
  // the leads distributor is «مسؤول إداري» (the accountant alone has no sales board)
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  const pr = await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج الليدز', ownerName: 'أ. سامي', ownerPhone: '0100' });
  assert.equal(pr.status, 201, JSON.stringify(pr.body));
  pid = pr.body.project.id;
  const meta = await h.call(c.t.acc, 'GET', '/leads/meta');
  assert.equal(meta.status, 200, JSON.stringify(meta.body));
  channel = meta.body.channels[0].id;
});
after(async () => { await h.close(); });

test('phone numbers are compared in one form', () => {
  assert.equal(phoneNorm('+20 100 123 4567'), '01001234567');
  assert.equal(phoneNorm('00201001234567'), '01001234567');
  assert.equal(phoneNorm('1001234567'), '01001234567');
  assert.equal(phoneNorm('٠١٠٠١٢٣٤٥٦٧'), '01001234567');
});

test('who sees what: the meta and the menu permissions', async () => {
  assert.equal((await h.call(c.t.hr, 'GET', '/leads/meta')).status, 403, 'HR has no leads');
  // the accountant alone has no sales board either; «مسؤول إداري» (accountant + HR + sales manager) has it
  await h.db.query(`UPDATE employees SET position_key = NULL WHERE id = $1`, [c.ids.acc]);
  assert.equal((await h.call(c.t.acc, 'GET', '/leads/meta')).status, 403, 'the accountant alone has no leads');
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  const pos = (await h.db.query(`SELECT name_ar FROM roles WHERE key = 'admin_officer'`)).rows[0];
  assert.equal(pos.name_ar, 'مسؤول إداري');
  const rep = (await h.call(c.t.e1, 'GET', '/leads/meta')).body;
  assert.equal(rep.can.distribute, false);
  assert.equal(rep.can.own, true);
  assert.deepEqual(rep.assignees, []);
  const acc = (await h.call(c.t.acc, 'GET', '/leads/meta')).body;
  assert.equal(acc.can.distribute, true);
  assert.ok(acc.assignees.some((e: any) => e.id === c.ids.e1) && acc.assignees.some((e: any) => e.id === c.ids.sm1));
  assert.ok(!acc.assignees.some((e: any) => e.id === c.ids.hr), 'only people who work leads');
  assert.equal(acc.pendingMinutes, 25);
  assert.ok(acc.stages.some((s: any) => s.key === 'reservation' && !s.action), 'حجز comes from the reservation, not a manual action');
});

test('distribution: the distributor picks the salesmen and they take turns', async () => {
  const add = (name: string, phone: string, assignees: string[]) =>
    h.call(c.t.acc, 'POST', '/leads', { fullName: name, phone, projectId: pid, channelId: channel, assignees });
  assert.equal((await h.call(c.t.acc, 'POST', '/leads', { fullName: 'بدون مشروع', phone: '01000000001' })).status, 400);
  const a1 = await add('عميل ١', '01000000001', [c.ids.e1, c.ids.e2]);
  assert.equal(a1.status, 201, JSON.stringify(a1.body));
  at('2026-11-14T08:01:00Z');
  const a2 = await add('عميل ٢', '01000000002', [c.ids.e1, c.ids.e2]);
  at('2026-11-14T08:02:00Z');
  const a3 = await add('عميل ٣', '01000000003', [c.ids.e1, c.ids.e2]);
  const got = [a1, a2, a3].map((x) => x.body.lead.assignedTo.id);
  assert.notEqual(got[0], got[1], 'the second goes to the other salesman');
  assert.equal(got[2], got[0], 'then back to the first');
  const told = await h.db.query(`SELECT count(*)::int AS n FROM notifications WHERE type = 'lead_assigned'`);
  assert.equal(told.rows[0].n, 3);
  // nobody picked → it waits unassigned
  const u = await add('عميل بدون سيلز', '01000000004', []);
  assert.equal(u.body.lead.assignedTo, null);
  const list = (await h.call(c.t.acc, 'GET', '/leads?tab=unassigned')).body;
  assert.equal(list.total, 1);
  // a salesman sees his own only; his manager sees the team
  const e1 = (await h.call(c.t.e1, 'GET', '/leads')).body;
  assert.ok(e1.leads.every((l: any) => l.assignedTo?.id === c.ids.e1));
  assert.equal(e1.total, got.filter((x: string) => x === c.ids.e1).length);
  const sm1 = (await h.call(c.t.sm1, 'GET', '/leads')).body;
  assert.equal(sm1.total, 3, 'both of his salesmen');
  assert.equal((await h.call(c.t.e3, 'GET', '/leads')).body.total, 0);
  assert.equal((await h.call(c.t.e3, 'GET', `/leads/${a1.body.lead.id}`)).status, 404, 'not his lead');
  // a salesman can't give leads to others, nor import
  assert.equal((await h.call(c.t.e1, 'POST', '/leads/assign', { ids: [a1.body.lead.id], to: [c.ids.e2] })).status, 403);
  assert.equal((await h.call(c.t.sm1, 'POST', '/leads/assign', { ids: [a1.body.lead.id], to: [c.ids.e3] })).status, 400, 'not his team');
});

test('a salesman adds his own lead; a repeated number', async () => {
  const own = await h.call(c.t.e3, 'POST', '/leads', { fullName: 'عميل شخصي', phone: '+20 111 222 3333', projectId: pid });
  assert.equal(own.status, 201, JSON.stringify(own.body));
  assert.equal(own.body.lead.assignedTo.id, c.ids.e3);
  // the same number by another salesman: refused, it is someone's client
  const again = await h.call(c.t.e1, 'POST', '/leads', { fullName: 'نفس العميل', phone: '01112223333', projectId: pid });
  assert.equal(again.status, 409);
  assert.match(again.body.error.message, /موجود/);
  // by the distributor: a duplicate, given to the old salesman
  const dup = await h.call(c.t.acc, 'POST', '/leads', { fullName: 'نفس العميل', phone: '00201112223333', projectId: pid, assignees: [c.ids.e1] });
  assert.equal(dup.status, 201);
  assert.equal(dup.body.duplicate, true);
  assert.equal(dup.body.lead.assignedTo.id, c.ids.e3, 'the original salesman keeps his client');
  assert.equal(dup.body.lead.duplicateOf.id, own.body.lead.id);
  assert.equal((await h.call(c.t.acc, 'GET', '/leads?tab=duplicated')).body.total, 1);
});

test('«إضافة أكشن», the follow-up reminder and the 25 minutes alert', async () => {
  at('2026-11-14T09:00:00Z');
  const l = (await h.call(c.t.acc, 'POST', '/leads', { fullName: 'عميل المتابعة', phone: '01009998887', projectId: pid, assignees: [c.ids.e2] })).body.lead;
  // nobody acted: after 25 minutes his manager (and whoever gave it) are told — once
  at('2026-11-14T09:20:00Z');
  await h.db.tx((q) => leadsSweep(q, h.now.value));
  let alerts = await h.db.query(`SELECT recipient_id FROM notifications WHERE type = 'lead_pending' AND entity_id = $1`, [l.id]);
  assert.equal(alerts.rowCount, 0, 'not yet');
  at('2026-11-14T09:26:00Z');
  await h.db.tx((q) => leadsSweep(q, h.now.value));
  await h.db.tx((q) => leadsSweep(q, h.now.value));
  alerts = await h.db.query(`SELECT recipient_id FROM notifications WHERE type = 'lead_pending' AND entity_id = $1`, [l.id]);
  assert.deepEqual(alerts.rows.map((x) => x.recipient_id).sort(), [c.ids.acc, c.ids.sm1].sort());
  assert.equal((await h.call(c.t.sm1, 'GET', '/leads?tab=pending')).body.leads.some((x: any) => x.id === l.id), true);

  // the action: stage + comment + the next follow-up
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${l.id}/actions`, { stage: 'following', comment: 'x', nextAt: '2026-11-15T10:00:00Z' })).status, 404, 'not his');
  assert.equal((await h.call(c.t.e2, 'POST', `/leads/${l.id}/actions`, { stage: 'following', comment: 'كلمته' })).status, 400, 'needs the next date');
  assert.equal((await h.call(c.t.e2, 'POST', `/leads/${l.id}/actions`, { stage: 'reservation', comment: 'حجز' })).status, 400, 'حجز is from the reservation');
  assert.equal((await h.call(c.t.e2, 'POST', `/leads/${l.id}/actions`, { stage: 'cancelled', comment: 'مش عايز' })).status, 400, 'a cancel needs its reason');
  const na = await h.call(c.t.e2, 'POST', `/leads/${l.id}/actions`, { stage: 'no_answer', answered: false, comment: 'مردّش', nextAt: '2026-11-14T11:00:00Z' });
  assert.equal(na.status, 201, JSON.stringify(na.body));
  at('2026-11-14T09:30:00Z');
  const ok = await h.call(c.t.e2, 'POST', `/leads/${l.id}/actions`, { stage: 'meeting', answered: true, callSeconds: 95, comment: 'ميعاد معاينة',
    nextAt: '2026-11-14T13:00:00Z', meetingKind: 'معاينة', meetingPlace: 'المشروع' });
  assert.equal(ok.status, 201);
  let d = (await h.call(c.t.e2, 'GET', `/leads/${l.id}`)).body;
  assert.equal(d.lead.stage, 'meeting');
  assert.equal(d.lead.noAnswerCount, 1);
  assert.equal(d.actions.length, 2);
  assert.equal(d.actions[0].meetingPlace, 'المشروع');
  assert.equal(d.logs.length, 0, 'the salesman doesn\'t see the log');
  assert.equal(d.can.reserve, true);
  // the manager comments, the salesman is told and sees the reply
  const rep = await h.call(c.t.sm1, 'POST', `/leads/actions/${d.actions[0].id}/reply`, { comment: 'اتأكد إنه جاي' });
  assert.equal(rep.status, 201);
  assert.equal((await h.db.query(`SELECT 1 FROM notifications WHERE type = 'lead_reply' AND recipient_id = $1`, [c.ids.e2])).rowCount, 1);
  const m = (await h.call(c.t.sm1, 'GET', `/leads/${l.id}`)).body;
  assert.equal(m.actions[0].replies[0].comment, 'اتأكد إنه جاي');
  assert.ok(m.logs.some((g: any) => g.kind === 'view' && g.byName === 'موظف ٢'), 'who opened the lead');
  assert.ok(m.logs.some((g: any) => g.kind === 'assign' && g.data.toName === 'موظف ٢'));
  // its time comes: the salesman is reminded once
  at('2026-11-14T13:00:30Z');
  await h.db.tx((q) => leadsSweep(q, h.now.value));
  await h.db.tx((q) => leadsSweep(q, h.now.value));
  assert.equal((await h.db.query(`SELECT 1 FROM notifications WHERE type = 'lead_due' AND entity_id = $1`, [l.id])).rowCount, 1);
  at('2026-11-14T14:00:00Z');
  const late = (await h.call(c.t.e2, 'GET', '/leads?tab=delay')).body;
  assert.ok(late.leads.some((x: any) => x.id === l.id && x.overdue));
  const dash = (await h.call(c.t.e2, 'GET', '/leads/dashboard')).body;
  assert.equal(dash.view, 'me');
  for (const period of ['today', 'week', 'month', 'all']) {   // «الأفضل» — every period answers (الكل used to fail)
    const r = await h.call(c.t.e2, 'GET', `/leads/dashboard?period=${period}`);
    assert.equal(r.status, 200, period);
  }
  assert.ok(dash.counts.delay >= 1);
  assert.equal(dash.delayByStage.meeting, 1);
  assert.ok(dash.best.some((b: any) => b.me && b.actions === 2));
});

test('re-assign, share and cancel', async () => {
  at('2026-11-14T15:00:00Z');
  const l = (await h.call(c.t.acc, 'POST', '/leads', { fullName: 'عميل يتنقل', phone: '01005556667', projectId: pid, assignees: [c.ids.e1] })).body.lead;
  await h.call(c.t.e1, 'POST', `/leads/${l.id}/actions`, { stage: 'interested', comment: 'مهتم', nextAt: '2026-11-16T10:00:00Z' });
  const mv = await h.call(c.t.sm1, 'POST', '/leads/assign', { ids: [l.id], to: [c.ids.e2], mode: 'fresh' });
  assert.equal(mv.status, 200, JSON.stringify(mv.body));
  let d = (await h.call(c.t.e2, 'GET', `/leads/${l.id}`)).body;
  assert.equal(d.lead.assignedTo.id, c.ids.e2);
  assert.equal(d.lead.stage, 'new', 'as fresh: from the start');
  assert.equal((await h.call(c.t.e1, 'GET', `/leads/${l.id}`)).status, 404, 'no longer his');
  const sh = await h.call(c.t.e2, 'POST', `/leads/${l.id}/referral`, { to: [c.ids.e3] });
  assert.equal(sh.status, 200);
  assert.equal((await h.call(c.t.e3, 'GET', `/leads/${l.id}`)).status, 200, 'shared with him');
  const reasons = (await h.call(c.t.e2, 'GET', '/leads/meta')).body.cancelReasons;
  const cn = await h.call(c.t.e2, 'POST', `/leads/${l.id}/actions`, { stage: 'cancelled', comment: 'اشترى من حد تاني', cancelReasonId: reasons[2].id });
  assert.equal(cn.status, 201);
  d = (await h.call(c.t.e2, 'GET', `/leads/${l.id}`)).body;
  assert.equal(d.lead.cancelReason.name, reasons[2].name);
  assert.equal(d.lead.nextAt, null);
  // the salesman can't change the number or the source
  assert.equal((await h.call(c.t.e2, 'PATCH', `/leads/${l.id}`, { phone: '01000000099' })).status, 403);
  assert.equal((await h.call(c.t.e2, 'PATCH', `/leads/${l.id}`, { budget: 2_000_000, notes: 'بيدور على محل' })).status, 200);
});

test('«حجز» from a lead: reserved → deposit received → contract = تم البيع', async () => {
  at('2026-11-14T16:00:00Z');
  const l = (await h.call(c.t.acc, 'POST', '/leads', { fullName: 'عميل الحجز', phone: '01007778889', projectId: pid, assignees: [c.ids.e1] })).body.lead;
  assert.equal((await h.call(c.t.e2, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'L-1', clientName: 'عميل الحجز', unitPrice: 2_000_000,
    depositAmount: 50_000, leadId: l.id })).status, 400, 'not his lead');
  const u = await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'L-1', clientName: 'عميل الحجز', clientPhone: '01007778889',
    unitPrice: 2_000_000, depositAmount: 50_000, leadId: l.id });
  assert.equal(u.status, 201, JSON.stringify(u.body));
  assert.equal(u.body.unit.leadId, l.id);
  let d = (await h.call(c.t.e1, 'GET', `/leads/${l.id}`)).body;
  assert.equal(d.lead.stage, 'reservation');
  assert.equal(d.units[0].status, 'reserving');
  assert.match(d.actions[0].comment, /مستني تأكيد استلام العربون/);
  // the accountant confirms receiving the deposit (the existing flow)
  at('2026-11-14T16:10:00Z');
  const pend = (await h.call(c.t.hr, 'GET', '/exclusive/payments')).body.payments.find((p: any) => p.unitId === u.body.unit.id || p.unit?.id === u.body.unit.id)
    ?? (await h.call(c.t.hr, 'GET', '/exclusive/payments')).body.payments[0];
  const rcv = await h.call(c.t.hr, 'POST', `/exclusive/payments/${pend.id}/receive`, {});
  assert.equal(rcv.status, 200, JSON.stringify(rcv.body));
  d = (await h.call(c.t.e1, 'GET', `/leads/${l.id}`)).body;
  assert.equal(d.units[0].status, 'reserved');
  assert.match(d.actions[0].comment, /اتأكد استلام عربون/);
  at('2026-11-14T16:20:00Z');
  const k = await h.call(c.t.e1, 'POST', `/exclusive/units/${u.body.unit.id}/contract`, { paymentType: 'cash' });
  assert.equal(k.status, 200, JSON.stringify(k.body));
  d = (await h.call(c.t.e1, 'GET', `/leads/${l.id}`)).body;
  assert.equal(d.lead.stage, 'done_deal');
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${l.id}/actions`, { stage: 'following', comment: 'x', nextAt: '2026-11-20T10:00:00Z' })).status, 409);
  const rep = (await h.call(c.t.acc, 'GET', '/leads/reports?from=2026-11-01&to=2026-11-30')).body;
  const e1 = rep.sales.find((s: any) => s.id === c.ids.e1);
  assert.equal(e1.reservations, 1);
  assert.equal(e1.deals, 1);
  assert.equal(e1.dealsValue, 2_000_000);
  assert.equal(rep.funnel.done_deal, 1);
  assert.equal((await h.call(c.t.e1, 'GET', '/leads/reports')).status, 403, 'reports are the managers\'');
});

test('import, campaigns and the campaign report', async () => {
  const camp = await h.call(c.t.acc, 'POST', '/leads/campaigns', { name: 'حملة نوفمبر', channelId: channel, projectId: pid, cost: 1000, startsOn: '2026-11-01' });
  assert.equal(camp.status, 201, JSON.stringify(camp.body));
  assert.equal((await h.call(c.t.e1, 'POST', '/leads/import', { rows: [{ fullName: 'x', phone: '01011111111' }] })).status, 403);
  const imp = await h.call(c.t.acc, 'POST', '/leads/import', {
    projectId: pid, channelId: channel, campaignId: camp.body.campaign.id, kind: 'cold', assignees: [c.ids.e1, c.ids.e3],
    rows: [
      { fullName: 'مستورد ١', phone: '01020000001', budget: '1,500,000' },
      { fullName: 'مستورد ٢', phone: 1020000002 },
      { fullName: 'مستورد ٣', phone: '01020000001' },
      { fullName: '', phone: '01020000004' },
      { fullName: 'مستورد ٥', phone: '01020000005', project: 'مشروع مش موجود' },
      { fullName: 'مكرر قديم', phone: '01112223333' },
    ],
  });
  assert.equal(imp.status, 201, JSON.stringify(imp.body));
  assert.equal(imp.body.created, 4);
  assert.equal(imp.body.duplicates, 1);
  assert.deepEqual(imp.body.failed.map((f: any) => f.row), [3, 4]);
  const cold = (await h.call(c.t.acc, 'GET', `/leads?campaignId=${camp.body.campaign.id}`)).body;
  assert.equal(cold.total, 4);
  assert.ok(cold.leads.every((l: any) => l.kind === 'cold'));
  const rep = (await h.call(c.t.acc, 'GET', '/leads/reports?from=2026-11-01&to=2026-11-30')).body;
  const cr = rep.campaigns.find((x: any) => x.id === camp.body.campaign.id);
  assert.equal(cr.leads, 4);
  assert.equal(cr.cpl, 250);
  assert.ok(rep.channels.length >= 1);
  // the search: by name / number
  assert.equal((await h.call(c.t.acc, 'GET', '/leads?q=مستورد ٢')).body.total, 1);
  assert.equal((await h.call(c.t.acc, 'GET', '/leads?q=1020000002')).body.total, 1);
});

test('tasks', async () => {
  const t = await h.call(c.t.sm1, 'POST', '/tasks', { title: 'كلّم العملاء القدام', assignedTo: c.ids.e1, dueAt: '2026-11-15T09:00:00Z' });
  assert.equal(t.status, 201, JSON.stringify(t.body));
  assert.equal((await h.call(c.t.e1, 'POST', '/tasks', { title: 'مهمة لزميل', assignedTo: c.ids.e2 })).status, 400, 'a salesman gives tasks to himself only');
  assert.equal((await h.call(c.t.e1, 'POST', '/tasks', { title: 'مهمة ليا' })).status, 201);
  const mine = (await h.call(c.t.e1, 'GET', '/tasks')).body;
  assert.equal(mine.tasks.length, 2);
  at('2026-11-15T09:01:00Z');
  await h.db.tx((q) => leadsSweep(q, h.now.value));
  assert.equal((await h.db.query(`SELECT 1 FROM notifications WHERE type = 'task_due' AND recipient_id = $1`, [c.ids.e1])).rowCount, 1);
  const done = await h.call(c.t.e1, 'PATCH', `/tasks/${t.body.task.id}`, { status: 'done' });
  assert.equal(done.status, 200);
  assert.equal(done.body.task.status, 'done');
  assert.equal((await h.call(c.t.e1, 'PATCH', `/tasks/${t.body.task.id}`, { status: 'cancelled' })).status, 403);
  assert.equal((await h.db.query(`SELECT 1 FROM notifications WHERE type = 'task_done' AND recipient_id = $1`, [c.ids.sm1])).rowCount, 1);
  const team = (await h.call(c.t.sm1, 'GET', '/tasks?view=team&status=all')).body;
  assert.ok(team.tasks.some((x: any) => x.id === t.body.task.id));
});

test('settings: channels and cancel reasons', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', '/leads/channels', { name: 'لينكدإن' })).status, 403);
  const ch = await h.call(c.t.acc, 'POST', '/leads/channels', { name: 'لينكدإن', sort: 5 });
  assert.equal(ch.status, 201);
  assert.equal((await h.call(c.t.acc, 'POST', '/leads/channels', { name: 'لينكدإن' })).status, 409);
  assert.equal((await h.call(c.t.acc, 'PATCH', `/leads/channels/${ch.body.item.id}`, { active: false })).status, 200);
  assert.ok(!(await h.call(c.t.e1, 'GET', '/leads/meta')).body.channels.some((x: any) => x.id === ch.body.item.id), 'a stopped channel is not offered');
  assert.equal((await h.call(c.t.acc, 'PATCH', '/leads/settings', { pendingMinutes: 30 })).body.pendingMinutes, 30);
});
