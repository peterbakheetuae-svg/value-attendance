import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

const hourly = (day = '2026-03-12', from = '12:00', to = '14:30') => ({ type: 'hourly_permission', day, fromTime: from, toTime: to, reason: 'مشوار بنك' });

test('hourly permission: duration computed, routed to the team sales manager', async () => {
  const r = await h.call(c.t.e1, 'POST', '/requests', hourly());
  assert.equal(r.status, 201);
  assert.equal(r.body.request.duration_minutes, 150);
  assert.equal(r.body.request.status, 'pending_manager');
  assert.equal(r.body.request.manager_id, c.ids.sm1);
  const dup = await h.call(c.t.e1, 'POST', '/requests', hourly());
  assert.equal(dup.status, 409, 'duplicate pending request');
  const n = await h.call(c.t.sm1, 'GET', '/notifications');
  assert.ok(n.body.notifications.some((x: any) => x.type === 'request_awaiting' && x.entity_id === r.body.request.id));
});

test('full dual approval: manager → HR → approved, with immutable history', async () => {
  const r = await h.call(c.t.e1, 'POST', '/requests', { type: 'full_day_absence', startDate: '2026-03-15', endDate: '2026-03-17', absenceType: 'annual', reason: 'ظرف عائلي' });
  assert.equal(r.status, 201);
  assert.equal(r.body.request.days_count, 3);
  const id = r.body.request.id;
  // HR cannot jump the manager stage
  const early = await h.call(c.t.hr, 'POST', `/requests/${id}/decision`, { decision: 'approve' });
  assert.equal(early.status, 403);
  // another team's manager cannot see/decide it
  assert.equal((await h.call(c.t.sm2, 'POST', `/requests/${id}/decision`, { decision: 'approve' })).status, 404);
  // accountant cannot decide
  assert.equal((await h.call(c.t.acc, 'POST', `/requests/${id}/decision`, { decision: 'approve' })).status, 404);
  const m = await h.call(c.t.sm1, 'POST', `/requests/${id}/decision`, { decision: 'approve', comment: 'موافق' });
  assert.equal(m.body.status, 'pending_hr');
  // manager cannot approve twice / act at HR stage
  assert.equal((await h.call(c.t.sm1, 'POST', `/requests/${id}/decision`, { decision: 'approve' })).status, 403);
  const f = await h.call(c.t.hr, 'POST', `/requests/${id}/decision`, { decision: 'approve' });
  assert.equal(f.body.status, 'approved');
  assert.equal((await h.call(c.t.hr, 'POST', `/requests/${id}/decision`, { decision: 'reject', comment: 'later' })).status, 409);
  const detail = await h.call(c.t.e1, 'GET', `/requests/${id}`);
  assert.deepEqual(detail.body.actions.map((a: any) => `${a.stage}:${a.action}`), ['employee:submit', 'manager:approve', 'hr:approve']);
  await assert.rejects(h.db.query(`DELETE FROM request_actions WHERE request_id = $1`, [id]), /append-only/);
  await assert.rejects(h.db.query(`UPDATE requests SET status = 'pending_hr' WHERE id = $1`, [id]), /final/);
  const notes = await h.call(c.t.e1, 'GET', '/notifications');
  assert.ok(notes.body.notifications.some((x: any) => x.type === 'request_approved' && x.entity_id === id));
  // calendar now shows approved absence
  h.now.value = new Date('2026-03-18T08:00:00Z');
  const cal = await h.call(c.t.e1, 'GET', '/attendance?month=2026-03');
  assert.equal(cal.body.days.find((d: any) => d.date === '2026-03-16').status, 'approved_absence');
  h.now.value = new Date('2026-03-10T08:00:00Z');
});

test('rejection requires a reason, ends the workflow and notifies the employee', async () => {
  const r = await h.call(c.t.e2, 'POST', '/requests', hourly('2026-03-13'));
  const id = r.body.request.id;
  assert.equal((await h.call(c.t.sm1, 'POST', `/requests/${id}/decision`, { decision: 'reject' })).status, 400);
  const rej = await h.call(c.t.sm1, 'POST', `/requests/${id}/decision`, { decision: 'reject', comment: 'ضغط عمل' });
  assert.equal(rej.body.status, 'rejected');
  assert.equal((await h.call(c.t.hr, 'POST', `/requests/${id}/decision`, { decision: 'approve' })).status, 409, 'HR cannot revive it');
  const notes = await h.call(c.t.e2, 'GET', '/notifications');
  const n = notes.body.notifications.find((x: any) => x.type === 'request_rejected');
  assert.equal(n.body, 'ضغط عمل');
});

test('HR rejection after manager approval also rejects', async () => {
  const r = await h.call(c.t.e2, 'POST', '/requests', hourly('2026-03-14', '10:00', '11:00'));
  const id = r.body.request.id;
  await h.call(c.t.sm1, 'POST', `/requests/${id}/decision`, { decision: 'approve' });
  const x = await h.call(c.t.hr, 'POST', `/requests/${id}/decision`, { decision: 'reject', comment: 'رصيد غير كافٍ' });
  assert.equal(x.body.status, 'rejected');
});

test('employee without a sales manager routes straight to HR', async () => {
  const r = await h.call(c.t.solo, 'POST', '/requests', hourly());
  assert.equal(r.body.request.route, 'hr_only');
  assert.equal(r.body.request.status, 'pending_hr');
  const notes = await h.call(c.t.hr, 'GET', '/notifications');
  assert.ok(notes.body.notifications.some((x: any) => x.entity_id === r.body.request.id));
  assert.equal((await h.call(c.t.hr, 'POST', `/requests/${r.body.request.id}/decision`, { decision: 'approve' })).body.status, 'approved');
});

test('nobody approves their own request — not even HR or the owner', async () => {
  const mine = await h.call(c.t.hr, 'POST', '/requests', hourly());
  assert.equal(mine.body.request.status, 'pending_hr');
  const self = await h.call(c.t.hr, 'POST', `/requests/${mine.body.request.id}/decision`, { decision: 'approve' });
  assert.equal(self.status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', `/requests/${mine.body.request.id}/decision`, { decision: 'approve' })).body.status, 'approved');
  const own = await h.call(c.t.owner, 'POST', '/requests', hourly());
  assert.equal((await h.call(c.t.owner, 'POST', `/requests/${own.body.request.id}/decision`, { decision: 'approve' })).status, 403);
});

test('a sales manager request goes to HR (no self-routing)', async () => {
  const r = await h.call(c.t.sm1, 'POST', '/requests', hourly());
  assert.equal(r.body.request.route, 'hr_only');
});

test('attendance-correction request applies the correction only after final approval', async () => {
  const r = await h.call(c.t.e2, 'POST', '/requests', { type: 'attendance_correction', correctionDate: '2026-03-09', correctionIn: '10:00', correctionOut: '18:00', reason: 'نسيت التسجيل' });
  assert.equal(r.status, 201);
  const id = r.body.request.id;
  await h.call(c.t.sm1, 'POST', `/requests/${id}/decision`, { decision: 'approve' });
  let row = await h.db.query(`SELECT * FROM attendance WHERE employee_id = $1 AND work_date = '2026-03-09'`, [c.ids.e2]);
  assert.equal(row.rowCount, 0, 'manager approval alone changes nothing');
  await h.call(c.t.hr, 'POST', `/requests/${id}/decision`, { decision: 'approve' });
  row = await h.db.query(`SELECT * FROM attendance WHERE employee_id = $1 AND work_date = '2026-03-09'`, [c.ids.e2]);
  assert.equal(row.rows[0].source, 'correction');
  const corr = await h.db.query(`SELECT * FROM attendance_corrections WHERE request_id = $1`, [id]);
  assert.equal(corr.rows[0].requested_by, c.ids.e2);
  assert.equal(corr.rows[0].approved_by, c.ids.hr);
});

test('validation: backdating limit, reversed times, cancel only while pending, visibility', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', '/requests', hourly('2026-01-01'))).status, 400);
  assert.equal((await h.call(c.t.e1, 'POST', '/requests', hourly('2026-03-20', '14:00', '12:00'))).status, 400);
  assert.equal((await h.call(c.t.e1, 'POST', '/requests', { type: 'short_leave', day: '2026-03-20', fromTime: '10:00', toTime: '16:00', reason: 'طويل جدا' })).status, 400);
  const r = await h.call(c.t.e1, 'POST', '/requests', hourly('2026-03-21'));
  assert.equal((await h.call(c.t.e2, 'POST', `/requests/${r.body.request.id}/cancel`)).status, 404);
  assert.equal((await h.call(c.t.e2, 'GET', `/requests/${r.body.request.id}`)).status, 404, 'other employee cannot read');
  assert.equal((await h.call(c.t.e1, 'POST', `/requests/${r.body.request.id}/cancel`)).status, 200);
  assert.equal((await h.call(c.t.e1, 'POST', `/requests/${r.body.request.id}/cancel`)).status, 409);
  const list = await h.call(c.t.e1, 'GET', '/requests');
  assert.ok(list.body.requests.every((x: any) => x.employee_id === c.ids.e1));
  const sm = await h.call(c.t.sm1, 'GET', '/requests');
  assert.ok(sm.body.requests.every((x: any) => [c.ids.e1, c.ids.e2, c.ids.sm1].includes(x.employee_id)));
  const awaiting = await h.call(c.t.hr, 'GET', '/requests?awaitingMe=1');
  assert.ok(awaiting.body.requests.every((x: any) => x.status === 'pending_hr' && x.employee_id !== c.ids.hr));
});

test('leave balances: HR manages, employee reads own, used days derive from approved absences', async () => {
  const b = await h.call(c.t.e1, 'GET', `/leave-balances/${c.ids.e1}?year=2026`);
  assert.equal(b.body.used.annual, 3);
  assert.equal(b.body.remaining.annual, 18);
  assert.equal((await h.call(c.t.e1, 'PUT', `/leave-balances/${c.ids.e1}`, { year: 2026, annualDays: 99, casualDays: 0, sickDays: 0 })).status, 403);
  assert.equal((await h.call(c.t.hr, 'PUT', `/leave-balances/${c.ids.e1}`, { year: 2026, annualDays: 25, casualDays: 7, sickDays: 5 })).status, 200);
  assert.equal((await h.call(c.t.e2, 'GET', `/leave-balances/${c.ids.e1}`)).status, 404);
});
