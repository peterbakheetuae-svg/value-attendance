import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

// 2026-03-10 Tue; Cairo = UTC+2.
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let gmId = ''; let tGm = '';
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير', role: 'manager' });
  gmId = gm.body.id;
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gmId]);
  tGm = await h.login('GM1', PW);
});
after(async () => { await h.close(); });
const at = (iso: string) => { h.now.value = new Date(iso); };
const types = async (tok: string) => (await h.call(tok, 'GET', '/notifications')).body.notifications.map((n: any) => n.type) as string[];

test('direct manager: sales manager, the manager or the owner; general manager: the manager or the owner', async () => {
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.solo}`, { salesManagerId: gmId })).status, 200, 'the manager can be a direct manager');
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.solo}`, { salesManagerId: c.ids.owner })).status, 200);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.solo}`, { salesManagerId: c.ids.hr })).status, 400, 'HR is not a direct manager');
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.solo}`, { generalManagerId: c.ids.sm1 })).status, 400);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.solo}`, { generalManagerId: c.ids.owner })).status, 200);
  const e = (await h.call(c.t.hr, 'GET', `/employees/${c.ids.solo}`)).body.employee;
  assert.equal(e.general_manager_id, c.ids.owner);
  await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.solo}`, { salesManagerId: null, generalManagerId: null });
});

test('"no attendance": only the owner switches it; such an account cannot check in and is not counted', async () => {
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e2}`, { attendanceExempt: true })).status, 403, 'HR cannot');
  assert.equal((await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.e2}`, { attendanceExempt: true })).status, 200);
  const r = await h.call(c.t.e2, 'POST', '/attendance/check-in', {});
  assert.equal(r.status, 422);
  assert.equal((await h.call(c.t.e2, 'GET', '/attendance/today')).body.attendanceExempt, true);
  const before = (await h.call(c.t.hr, 'GET', '/dashboard/overview')).body.today.employees;
  await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.e2}`, { attendanceExempt: false });
  const after = (await h.call(c.t.hr, 'GET', '/dashboard/overview')).body.today.employees;
  assert.equal(after, before + 1, 'counted again once attendance is required');
  // the owner starts without attendance and can turn it on for himself
  assert.equal((await h.call(c.t.owner, 'GET', '/attendance/today')).body.attendanceExempt, true);
});

test('personal work hours replace the company schedule for lateness', async () => {
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e3}`, { workStart: '12:00', workEnd: '11:00' })).status, 400);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e3}`, { workStart: '11:00', workEnd: '19:00' })).status, 200);
  at('2026-03-10T08:50:00Z'); // 10:50 Cairo: late for 10:00, on time for 11:00
  const r = await h.call(c.t.e3, 'POST', '/attendance/check-in', {});
  assert.equal(r.status, 201);
  const t = (await h.call(c.t.e3, 'GET', '/attendance/today')).body;
  assert.equal(t.schedule.start.slice(0, 5), '11:00');
  assert.equal(t.attendance.isLate, false);
});

test('approved non-financial requests are reported to the general manager', async () => {
  await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e1}`, { generalManagerId: gmId });
  const r = await h.call(c.t.e1, 'POST', '/requests', { type: 'full_day_absence', startDate: '2026-03-19', endDate: '2026-03-19', absenceType: 'casual', reason: 'ظرف عائلي' });
  assert.equal(r.status, 201);
  assert.ok(!(await types(tGm)).includes('request_approved_gm'), 'not told while pending');
  await h.call(c.t.sm1, 'POST', `/requests/${r.body.request.id}/decision`, { decision: 'approve' });
  await h.call(c.t.hr, 'POST', `/requests/${r.body.request.id}/decision`, { decision: 'approve' });
  assert.ok((await types(tGm)).includes('request_approved_gm'));
});

test('performance ring: 100% at the start, lower with lateness; evaluation averaged in', async () => {
  at('2026-03-01T08:00:00Z');
  const s0 = (await h.call(c.t.e1, 'GET', '/me/score')).body;
  assert.equal(s0.period, '2026-03-01');
  at('2026-03-10T09:00:00Z');
  const s1 = (await h.call(c.t.e3, 'GET', '/me/score')).body;
  assert.ok(s1.score <= 100 && s1.score >= 0);
  assert.equal(typeof s1.deductions.late, 'number');
  const ow = (await h.call(c.t.owner, 'GET', '/me/score')).body;
  assert.equal(ow.deductions.absence, 0, 'no attendance → nothing deducted for absence');
  assert.equal(ow.score, 100);
});
