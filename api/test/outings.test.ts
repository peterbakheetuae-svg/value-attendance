import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
// 2026-03-10 Tue; Cairo = UTC+2. E1 is in team A (manager SM1). Office at (30.0286, 31.4085), 100 m.
const OFFICE = { lat: 30.0286, lng: 31.4085 };
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ('المكتب', $1, $2, 100)`, [OFFICE.lat, OFFICE.lng]);
  await h.call(c.t.owner, 'PATCH', '/settings', { trackingEnabled: true, awayMarginM: 50, checkinReminderMinutes: 0, trackingStaleMinutes: 0 });
});
after(async () => { await h.close(); });
const at = (iso: string) => { h.now.value = new Date(iso); };
const types = async (tok: string) => (await h.call(tok, 'GET', '/notifications')).body.notifications.map((n: any) => n.type) as string[];

test('validation: allowed before check-in, both fields required, return time later today', async () => {
  at('2026-03-10T08:00:00Z');
  const early = await h.call(c.t.e1, 'POST', '/outings', { kind: 'permission', expectedReturn: '13:00', reason: 'مشوار قبل الحضور' });
  assert.equal(early.status, 201, 'a permission works even before checking in');
  assert.equal((await h.call(c.t.e1, 'POST', `/outings/${early.body.outing.id}/cancel`, {})).status, 200);
  await h.call(c.t.e1, 'POST', '/attendance/check-in', {});
  assert.equal((await h.call(c.t.e1, 'POST', '/outings', { kind: 'visit', reason: 'معاينة شقة' })).status, 400, 'no return time');
  assert.equal((await h.call(c.t.e1, 'POST', '/outings', { kind: 'visit', expectedReturn: '13:00' })).status, 400, 'no reason');
  assert.equal((await h.call(c.t.e1, 'POST', '/outings', { kind: 'visit', expectedReturn: '09:00', reason: 'معاينة شقة' })).status, 400, 'in the past');
  assert.equal((await h.call(c.t.e1, 'POST', '/outings', { kind: 'trip', expectedReturn: '13:00', reason: 'معاينة' })).status, 400, 'bad kind');
});

test('approval: SM1 and HR are told; owner only after approval; employee gets the result', async () => {
  const r = await h.call(c.t.e1, 'POST', '/outings', { kind: 'visit', expectedReturn: '12:00', reason: 'معاينة شقة للعميل' });
  assert.equal(r.status, 201);
  const id = r.body.outing.id;
  assert.equal((await h.call(c.t.e1, 'POST', '/outings', { kind: 'permission', expectedReturn: '12:00', reason: 'مشوار' })).status, 409, 'overlapping times are refused');
  assert.ok((await types(c.t.sm1)).includes('outing_awaiting'));
  assert.ok((await types(c.t.hr)).includes('outing_awaiting'));
  assert.ok(!(await types(c.t.sm2)).includes('outing_awaiting'), 'other team manager');
  assert.ok(!(await types(c.t.owner)).some((t) => t.startsWith('outing')), 'owner not told while pending');
  assert.equal((await h.call(c.t.sm2, 'POST', `/outings/${id}/decision`, { decision: 'approve' })).status, 403, 'other manager');
  assert.equal((await h.call(c.t.e1, 'POST', `/outings/${id}/decision`, { decision: 'approve' })).status, 403, 'own');
  const [x, y] = await Promise.all([
    h.call(c.t.sm1, 'POST', `/outings/${id}/decision`, { decision: 'approve' }),
    h.call(c.t.hr, 'POST', `/outings/${id}/decision`, { decision: 'approve' })]);
  assert.deepEqual([x.status, y.status].sort(), [200, 409], 'only one decision wins');
  assert.ok((await types(c.t.e1)).includes('outing_approved'));
  assert.ok((await types(c.t.owner)).includes('outing_visit_approved_owner'));
  const today = await h.call(c.t.e1, 'GET', '/outings/today');
  assert.equal(today.body.active.id, id);
});

test('geofence: approved visit is not a violation; back inside closes it', async () => {
  at('2026-03-10T08:30:00Z');
  await h.call(c.t.e1, 'POST', '/tracking/ping', { lat: OFFICE.lat + 0.01, lng: OFFICE.lng, accuracyM: 10 });
  assert.ok(!(await types(c.t.hr)).includes('unauthorized_exit'));
  at('2026-03-10T09:30:00Z');
  await h.call(c.t.e1, 'POST', '/tracking/ping', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 });
  const today = await h.call(c.t.e1, 'GET', '/outings/today');
  assert.equal(today.body.active, null);
  assert.ok(today.body.history.find((x: any) => x.status === 'approved').returned_at);
});

test('unauthorized exit alerts HR, the manager and the employee; weak GPS never does', async () => {
  at('2026-03-10T10:00:00Z');
  await h.call(c.t.e1, 'POST', '/tracking/ping', { lat: OFFICE.lat + 0.01, lng: OFFICE.lng, accuracyM: 900 });
  assert.ok(!(await types(c.t.sm1)).includes('unauthorized_exit'), 'weak GPS');
  await h.call(c.t.e1, 'POST', '/tracking/ping', { lat: OFFICE.lat + 0.01, lng: OFFICE.lng, accuracyM: 10 });
  assert.ok((await types(c.t.sm1)).includes('unauthorized_exit'));
  assert.ok((await types(c.t.hr)).includes('unauthorized_exit'));
  assert.ok((await types(c.t.e1)).includes('unauthorized_exit_self'));
  at('2026-03-10T10:05:00Z');
  await h.call(c.t.e1, 'POST', '/tracking/ping', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 });
});

test('overdue: rings once; extension follows the same workflow; owner told only after approval', async () => {
  at('2026-03-10T11:00:00Z');
  const r = await h.call(c.t.e1, 'POST', '/outings', { kind: 'permission', expectedReturn: '13:30', reason: 'مشوار بنك' });
  const id = r.body.outing.id;
  await h.call(c.t.hr, 'POST', `/outings/${id}/decision`, { decision: 'approve' });
  assert.ok((await types(c.t.owner)).includes('outing_permission_approved_owner'));
  at('2026-03-10T11:45:00Z'); // 13:45 local, 15 min late
  await h.call(c.t.hr, 'GET', '/tracking/live');
  at('2026-03-10T11:55:00Z');
  await h.call(c.t.hr, 'GET', '/tracking/live');
  const mine = await types(c.t.e1);
  assert.equal(mine.filter((t) => t === 'outing_overdue').length, 1, 'once');
  assert.ok((await types(c.t.sm1)).includes('outing_overdue_watch'));
  assert.equal((await h.call(c.t.e1, 'POST', '/outings', { kind: 'permission', parentId: id, expectedReturn: '13:00', reason: 'زحمة' })).status, 400, 'earlier than now');
  const ext = await h.call(c.t.e1, 'POST', '/outings', { kind: 'permission', parentId: id, expectedReturn: '15:00', reason: 'البنك زحمة' });
  assert.equal(ext.status, 201);
  assert.equal(ext.body.outing.isExtension, true);
  assert.ok((await types(c.t.sm1)).includes('outing_extension_awaiting'));
  const ownerBefore = (await types(c.t.owner)).filter((t) => t === 'outing_extension_approved_owner').length;
  assert.equal(ownerBefore, 0);
  await h.call(c.t.sm1, 'POST', `/outings/${ext.body.outing.id}/decision`, { decision: 'approve' });
  assert.ok((await types(c.t.owner)).includes('outing_extension_approved_owner'));
  const today = await h.call(c.t.e1, 'GET', '/outings/today');
  assert.equal(today.body.active.id, ext.body.outing.id);
  assert.equal(today.body.history.find((x: any) => x.id === id).status, 'superseded');
  assert.equal((await h.call(c.t.e1, 'POST', '/outings/return')).status, 200);
});

test('rejection reaches the employee; history is immutable in the database', async () => {
  at('2026-03-10T13:30:00Z');
  const r = await h.call(c.t.e1, 'POST', '/outings', { kind: 'visit', expectedReturn: '17:00', reason: 'زيارة عميل' });
  await h.call(c.t.sm1, 'POST', `/outings/${r.body.outing.id}/decision`, { decision: 'reject', comment: 'محتاجينك في المكتب' });
  assert.ok((await types(c.t.e1)).includes('outing_rejected'));
  await assert.rejects(h.db.query(`UPDATE outing_requests SET status = 'approved' WHERE id = $1`, [r.body.outing.id]));
  await assert.rejects(h.db.query(`DELETE FROM outing_requests`));
  const list = await h.call(c.t.e2, 'GET', '/outings');
  assert.ok(list.body.outings.every((x: any) => x.employee_id === c.ids.e2), 'employees see only their own');
});

test('company page: HR and owner edit, changes are logged, employees read only; contact defaults', async () => {
  const r = await h.call(c.t.e1, 'GET', '/company');
  assert.equal(r.status, 200);
  assert.equal(r.body.company.phone, '01080660100');
  assert.equal(r.body.company.email, 'info@valueaqar.com');
  assert.equal(r.body.canEdit, false);
  assert.equal(r.body.offices.length, 1);
  assert.equal((await h.call(c.t.e1, 'PUT', '/company', { address: 'x' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'PUT', '/company', { address: 'التجمع الخامس، القاهرة الجديدة', description: 'مكتب تسويق عقاري' })).status, 200);
  assert.equal((await h.call(c.t.hr, 'PUT', '/company', { phone: 'abc' })).status, 400);
  const after = await h.call(c.t.owner, 'GET', '/company');
  assert.equal(after.body.company.address, 'التجمع الخامس، القاهرة الجديدة');
  assert.equal(after.body.company.updatedByName, 'مديرة الموارد البشرية');
  const log = await h.db.query(`SELECT 1 FROM audit_log WHERE action = 'company.update'`);
  assert.equal(log.rowCount, 1);
});

test('admin overview: today and month totals; employees cannot read it', async () => {
  const r = await h.call(c.t.owner, 'GET', '/dashboard/overview');
  assert.equal(r.status, 200);
  assert.ok(r.body.today.present >= 1, 'E1 checked in today');
  assert.equal(typeof r.body.month.lateDays, 'number');
  assert.equal((await h.call(c.t.e1, 'GET', '/dashboard/overview')).status, 403);
  const sm = await h.call(c.t.sm1, 'GET', '/dashboard/overview');
  assert.equal(sm.body.scope, 'team');
});

test('hourly permission keeps its own start and end; a visit starts when requested', async () => {
  at('2026-03-10T12:00:00Z'); // 14:00 Cairo
  const bad = await h.call(c.t.e2, 'POST', '/outings', { kind: 'permission', startAt: '17:00', expectedReturn: '16:00', reason: 'مشوار' });
  assert.equal(bad.status, 400);
  const p = await h.call(c.t.e2, 'POST', '/outings', { kind: 'permission', startAt: '15:00', expectedReturn: '16:30', reason: 'مشوار بنك' });
  assert.equal(p.status, 201);
  assert.ok(p.body.outing.starts_at, 'start saved');
  await h.call(c.t.e2, 'POST', `/outings/${p.body.outing.id}/cancel`, {});
  const v = await h.call(c.t.e2, 'POST', '/outings', { kind: 'visit', startAt: '15:00', expectedReturn: '16:30', reason: 'معاينة' });
  assert.equal(v.status, 201);
  assert.equal(v.body.outing.starts_at, null, 'a visit starts now');
  await h.call(c.t.e2, 'POST', `/outings/${v.body.outing.id}/cancel`, {});
});

test('"I am back" counts only inside the office when GPS is required', async () => {
  at('2026-03-10T13:00:00Z');
  await h.call(c.t.owner, 'PATCH', '/settings', { gpsRequired: true });
  await h.db.query(`UPDATE attendance SET check_out_at = NULL WHERE employee_id = $1`, [c.ids.e3]);
  const o = await h.call(c.t.e3, 'POST', '/outings', { kind: 'visit', expectedReturn: '17:30', reason: 'معاينة عميل' });
  assert.equal(o.status, 201);
  await h.call(c.t.hr, 'POST', `/outings/${o.body.outing.id}/decision`, { decision: 'approve' });
  const far = await h.call(c.t.e3, 'POST', '/outings/return', { lat: OFFICE.lat + 0.02, lng: OFFICE.lng, accuracyM: 10 });
  assert.equal(far.status, 422, 'still away from the office');
  const near = await h.call(c.t.e3, 'POST', '/outings/return', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 });
  assert.equal(near.status, 200);
  await h.call(c.t.owner, 'PATCH', '/settings', { gpsRequired: false });
});

test('several permissions a day are allowed when they do not overlap; a later one is not "out" before it starts', async () => {
  at('2026-03-10T09:00:00Z'); // 11:00 Cairo
  const late = await h.call(c.t.e2, 'POST', '/outings', { kind: 'permission', startAt: '15:00', expectedReturn: '15:30', reason: 'مشوار أول' });
  assert.equal(late.status, 201);
  const dup = await h.call(c.t.e2, 'POST', '/outings', { kind: 'visit', expectedReturn: '16:30', reason: 'مكرر' });
  assert.equal(dup.status, 409, 'no new request while one still waits');
  assert.equal(dup.body.error.details.reason, 'pending_exists');
  await h.call(c.t.hr, 'POST', `/outings/${late.body.outing.id}/decision`, { decision: 'approve' });
  const second = await h.call(c.t.e2, 'POST', '/outings', { kind: 'permission', startAt: '16:00', expectedReturn: '16:30', reason: 'مشوار تاني' });
  assert.equal(second.status, 201, 'a second one after the first was decided');
  await h.call(c.t.hr, 'POST', `/outings/${second.body.outing.id}/decision`, { decision: 'approve' });
  const clash = await h.call(c.t.e2, 'POST', '/outings', { kind: 'permission', startAt: '15:15', expectedReturn: '15:45', reason: 'متداخل' });
  assert.equal(clash.status, 409);
  assert.equal(clash.body.error.details.reason, 'overlap');
  const today = (await h.call(c.t.e2, 'GET', '/outings/today')).body;
  assert.equal(today.active, null, 'approved for 15:00 — not out at 11:00');
  assert.ok(today.upcoming.length >= 2);
  for (const id of [late.body.outing.id, second.body.outing.id]) await h.call(c.t.e2, 'POST', `/outings/${id}/cancel`, {});
});
