import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/** مراحل الليدز (custom stages with alert / delay), the stars and the WhatsApp tab, the deals board */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let pid: string; let channel: string; let lead: any;
const at = (iso: string) => { h.now.value = new Date(iso); };
before(async () => {
  h = await harness('2026-11-14T08:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج المراحل', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  channel = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
  lead = (await h.call(c.t.acc, 'POST', '/leads', { fullName: 'عميل المراحل', phone: '01077700001', projectId: pid, channelId: channel, assignees: [c.ids.e1] })).body.lead;
});
after(async () => { await h.close(); });

test('stages: add one, rename a built-in, alert before the time, late only after the delay', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', '/leads/stages', { name: 'معاينة' })).status, 403);
  const add = await h.call(c.t.acc, 'POST', '/leads/stages', { name: 'معاينة', alertMinutes: 30, delayMinutes: 120, color: '#123456' });
  assert.equal(add.status, 201, JSON.stringify(add.body));
  const key = add.body.stage.key;
  assert.equal((await h.call(c.t.acc, 'POST', '/leads/stages', { name: 'معاينة' })).status, 409);
  assert.equal((await h.call(c.t.acc, 'PATCH', '/leads/stages/following', { name: 'متابعة تليفون', active: false })).status, 200);
  const meta = (await h.call(c.t.e1, 'GET', '/leads/meta')).body;
  const st = meta.stages.find((x: any) => x.key === key);
  assert.ok(st.action && st.alertMinutes === 30 && st.delayMinutes === 120);
  const fol = meta.stages.find((x: any) => x.key === 'following');
  assert.equal(fol.name, 'متابعة تليفون');
  assert.equal(fol.active, true, 'a built-in stage is never switched off');
  // the salesman uses the new stage
  const act = await h.call(c.t.e1, 'POST', `/leads/${lead.id}/actions`, { stage: key, comment: 'معاينة بكرة', nextAt: '2026-11-14T12:00:00Z' });
  assert.equal(act.status, 201, JSON.stringify(act.body));
  const one = (await h.call(c.t.e1, 'GET', `/leads/${lead.id}`)).body;
  assert.equal(one.lead.stageAr, 'معاينة');
  // alert 30 minutes before
  const { leadsSweep } = await import('../src/modules/leads.ts');
  await leadsSweep(h.db, new Date('2026-11-14T11:25:00Z'));
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM notifications WHERE type = 'lead_due' AND entity_id = $1`, [lead.id])).rows[0].n, 0);
  await leadsSweep(h.db, new Date('2026-11-14T11:31:00Z'));
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM notifications WHERE type = 'lead_due' AND entity_id = $1`, [lead.id])).rows[0].n, 1, 'rang 30 minutes before');
  // late only 120 minutes after the time
  at('2026-11-14T13:00:00Z');
  assert.equal((await h.call(c.t.e1, 'GET', `/leads/${lead.id}`)).body.lead.overdue, false);
  at('2026-11-14T14:05:00Z');
  assert.equal((await h.call(c.t.e1, 'GET', `/leads/${lead.id}`)).body.lead.overdue, true);
  const d = (await h.call(c.t.e1, 'GET', '/leads/dashboard')).body;
  assert.ok(d.counts.delay >= 1);
  // switched off → not offered any more
  await h.call(c.t.acc, 'PATCH', `/leads/stages/${key}`, { active: false });
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${lead.id}/actions`, { stage: key, comment: 'x', nextAt: '2026-11-15T12:00:00Z' })).status, 400);
});

test('stars and the WhatsApp tab', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${lead.id}/stars`, { stars: 4 })).status, 200);
  assert.equal((await h.call(c.t.e2, 'POST', `/leads/${lead.id}/stars`, { stars: 1 })).status, 404);
  assert.equal((await h.call(c.t.e1, 'GET', `/leads/${lead.id}`)).body.lead.stars, 4);
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${lead.id}/whatsapp`, { body: 'أهلا يا فندم' })).status, 201);
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${lead.id}/whatsapp`, { direction: 'in', body: '' })).status, 400);
  assert.equal((await h.call(c.t.e1, 'POST', `/leads/${lead.id}/whatsapp`, { direction: 'in', body: 'تمام ابعتلي التفاصيل' })).status, 201);
  const w = (await h.call(c.t.e1, 'GET', `/leads/${lead.id}/whatsapp`)).body.messages;
  assert.deepEqual(w.map((x: any) => x.direction), ['out', 'in']);
  assert.equal((await h.call(c.t.e2, 'GET', `/leads/${lead.id}/whatsapp`)).status, 404);
});

test('deals: convert a lead, move on the board, won / lost, who sees what, delete', async () => {
  const d = await h.call(c.t.e1, 'POST', '/deals', { leadId: lead.id, value: 2500000, unit: 'A-12' });
  assert.equal(d.status, 201, JSON.stringify(d.body));
  assert.equal(d.body.deal.stage, 'open');
  assert.equal(d.body.deal.owner.id, c.ids.e1);
  assert.equal(d.body.deal.title, 'عميل المراحل');
  const d2 = (await h.call(c.t.acc, 'POST', '/deals', { title: 'صفقة مباشرة', value: 100 })).body.deal;
  assert.equal((await h.call(c.t.e2, 'POST', '/deals', { leadId: lead.id })).status, 404, 'not his lead');
  // the salesman sees his own; the distributor sees all
  const mine = (await h.call(c.t.e1, 'GET', '/deals')).body;
  assert.ok(mine.deals.some((x: any) => x.id === d.body.deal.id) && !mine.deals.some((x: any) => x.id === d2.id));
  const all = (await h.call(c.t.acc, 'GET', '/deals')).body;
  assert.equal(all.totals.open.count, 2);
  // drag to «ناجحة»
  const won = await h.call(c.t.e1, 'PATCH', `/deals/${d.body.deal.id}`, { stage: 'won' });
  assert.equal(won.status, 200);
  assert.ok(won.body.deal.closedAt);
  // drop d2 above d in «ناجحة»
  const moved = await h.call(c.t.acc, 'PATCH', `/deals/${d2.id}`, { stage: 'won', beforeId: d.body.deal.id });
  assert.ok(moved.body.deal.sort < won.body.deal.sort);
  const t = (await h.call(c.t.acc, 'GET', '/deals')).body.totals;
  assert.equal(t.won.count, 2);
  assert.equal(t.won.value, 2500100);
  assert.equal((await h.call(c.t.e1, 'POST', `/deals/${d2.id}/delete`, {})).status, 403, 'a salesman cannot delete');
  assert.equal((await h.call(c.t.acc, 'POST', `/deals/${d2.id}/delete`, {})).status, 200);
  assert.equal((await h.call(c.t.acc, 'GET', '/deals')).body.deals.length, 1);
});
