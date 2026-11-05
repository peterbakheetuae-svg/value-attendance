import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
// 2026-03-10 is a Tuesday; Cairo is UTC+2 in March. Default schedule 10:00–18:00, grace 15.
before(async () => { h = await harness('2026-03-10T08:10:00Z'); c = await cast(h); });
after(async () => { await h.close(); });
const at = (iso: string) => { h.now.value = new Date(iso); };

test('check-in, duplicate check-in refused, check-out computes metrics', async () => {
  at('2026-03-10T08:40:00Z'); // 10:40 local → 40 min late (beyond grace)
  const r = await h.call(c.t.e1, 'POST', '/attendance/check-in', {});
  assert.equal(r.status, 201);
  assert.equal(r.body.attendance.lateMinutes, 40);
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-in', {})).status, 409);
  at('2026-03-10T15:30:00Z'); // 17:30 local → 30 min early
  const out = await h.call(c.t.e1, 'POST', '/attendance/check-out', {});
  assert.equal(out.status, 200);
  assert.equal(out.body.attendance.earlyMinutes, 30);
  assert.equal(out.body.attendance.workedMinutes, 410);
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-out', {})).status, 409, 'double check-out');
});

test('check-out without check-in is refused; arrival within grace is not late', async () => {
  at('2026-03-10T08:12:00Z');
  assert.equal((await h.call(c.t.e2, 'POST', '/attendance/check-out', {})).status, 409);
  const r = await h.call(c.t.e2, 'POST', '/attendance/check-in', {});
  assert.equal(r.body.attendance.lateMinutes, 0, '10:12 is within the 15-minute grace');
});

test('concurrent double tap creates one record', async () => {
  at('2026-03-10T08:05:00Z');
  const [a, b] = await Promise.all([
    h.call(c.t.e3, 'POST', '/attendance/check-in', {}), h.call(c.t.e3, 'POST', '/attendance/check-in', {})]);
  assert.deepEqual([a.status, b.status].sort(), [201, 409]);
  const n = await h.db.query(`SELECT count(*)::int AS n FROM attendance WHERE employee_id = $1`, [c.ids.e3]);
  assert.equal(n.rows[0].n, 1);
});

test('geofence: required + configured office → outside refused, inside accepted, weak signal refused', async () => {
  assert.equal((await h.call(c.t.owner, 'PATCH', '/settings', { gpsRequired: true })).status, 200);
  at('2026-03-10T08:00:00Z');
  assert.equal((await h.call(c.t.hr, 'POST', '/work-locations', { name: 'المكتب الرئيسي', lat: 30.0444, lng: 31.2357, radiusM: 150 })).status, 201);
  assert.equal((await h.call(c.t.solo, 'POST', '/attendance/check-in', {})).status, 400, 'location required');
  assert.equal((await h.call(c.t.solo, 'POST', '/attendance/check-in', { lat: 30.06, lng: 31.25, accuracyM: 10 })).status, 422);
  assert.equal((await h.call(c.t.solo, 'POST', '/attendance/check-in', { lat: 30.0445, lng: 31.2358, accuracyM: 900 })).status, 422);
  const ok = await h.call(c.t.solo, 'POST', '/attendance/check-in', { lat: 30.0445, lng: 31.2358, accuracyM: 12 });
  assert.equal(ok.status, 201);
  assert.equal(ok.body.attendance.geofence, 'inside');
  // check-out only records the place: leaving from outside the office is fine
  at('2026-03-10T16:00:00Z');
  assert.equal((await h.call(c.t.solo, 'POST', '/attendance/check-out', { lat: 30.06, lng: 31.25, accuracyM: 10 })).status, 200);
  assert.equal((await h.call(c.t.owner, 'PATCH', '/settings', { gpsRequired: false })).status, 200);
});

test('scoping: employee sees only self, manager only team, HR all', async () => {
  const own = await h.call(c.t.e1, 'GET', `/attendance?month=2026-03`);
  assert.equal(own.status, 200);
  assert.equal((await h.call(c.t.e1, 'GET', `/attendance?month=2026-03&employeeId=${c.ids.e2}`)).status, 404);
  assert.equal((await h.call(c.t.sm1, 'GET', `/attendance?month=2026-03&employeeId=${c.ids.e1}`)).status, 200);
  assert.equal((await h.call(c.t.sm1, 'GET', `/attendance?month=2026-03&employeeId=${c.ids.e3}`)).status, 404, 'other team');
  assert.equal((await h.call(c.t.hr, 'GET', `/attendance?month=2026-03&employeeId=${c.ids.e3}`)).status, 200);
  const board = await h.call(c.t.sm1, 'GET', '/attendance/board');
  assert.deepEqual(board.body.board.map((x: any) => x.employeeId).sort(), [c.ids.e1, c.ids.e2, c.ids.sm1].sort());
  assert.equal((await h.call(c.t.e1, 'GET', '/attendance/board')).status, 403);
});

test('HR correction keeps originals and full history; nobody corrects themselves; DB guards originals', async () => {
  const before = (await h.db.query(`SELECT * FROM attendance WHERE employee_id = $1`, [c.ids.e1])).rows[0];
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/corrections', { employeeId: c.ids.e1, workDate: '2026-03-10', checkIn: '10:00', reason: 'test' })).status, 403);
  assert.equal((await h.call(c.t.sm1, 'POST', '/attendance/corrections', { employeeId: c.ids.e1, workDate: '2026-03-10', checkIn: '10:00', reason: 'test' })).status, 403, 'sales manager cannot edit attendance');
  const r = await h.call(c.t.hr, 'POST', '/attendance/corrections', { employeeId: c.ids.e1, workDate: '2026-03-10', checkIn: '10:05', checkOut: '18:00', reason: 'زحمة مرور موثقة' });
  assert.equal(r.status, 201);
  const after = (await h.db.query(`SELECT * FROM attendance WHERE id = $1`, [before.id])).rows[0];
  assert.equal(after.corrected, true);
  assert.equal(new Date(after.original_check_in_at).getTime(), new Date(before.original_check_in_at).getTime());
  assert.equal(new Date(after.original_check_out_at).getTime(), new Date(before.check_out_at).getTime());
  const hist = await h.call(c.t.e1, 'GET', `/attendance/${before.id}/corrections`);
  assert.equal(hist.body.corrections.length, 1);
  assert.equal(hist.body.corrections[0].reason, 'زحمة مرور موثقة');
  assert.ok(hist.body.corrections[0].original_in);
  await assert.rejects(h.db.query(`UPDATE attendance SET original_check_in_at = now() WHERE id = $1`, [before.id]), /immutable/);
  await assert.rejects(h.db.query(`DELETE FROM attendance WHERE id = $1`, [before.id]), /append-only/);
  await assert.rejects(h.db.query(`UPDATE attendance_corrections SET reason = 'x'`), /append-only/);
  const notes = await h.call(c.t.e1, 'GET', '/notifications');
  assert.ok(notes.body.notifications.some((n: any) => n.type === 'attendance_corrected'));
});

test('monthly calendar: weekend, holiday, missing check-out, unapproved absence, incomplete month', async () => {
  assert.equal((await h.call(c.t.hr, 'POST', '/holidays', { day: '2026-03-09', name: 'إجازة تجريبية' })).status, 201);
  at('2026-03-11T08:00:00Z'); // next day: e2 never checked out on the 10th
  const m = await h.call(c.t.e2, 'GET', '/attendance?month=2026-03');
  const day = (d: string) => m.body.days.find((x: any) => x.date === d);
  assert.equal(day('2026-03-06').status, 'weekend', 'Friday');
  assert.equal(day('2026-03-09').status, 'holiday');
  assert.equal(day('2026-03-10').attendance.missingCheckout, true);
  assert.equal(day('2026-03-02').status, 'absent');
  assert.equal(day('2026-03-20').status, 'future');
  assert.equal(m.body.summary.complete, false);
  assert.equal(m.body.summary.missingCheckouts, 1);
  assert.ok(m.body.summary.unapprovedAbsenceDays >= 7);
});

test('offline punches: device time within 48 h is accepted and flagged; older or future is refused', async () => {
  const t0 = h.now.value;
  try {
    h.now.value = new Date('2026-03-20T12:00:00Z');
    // phone checked in at 08:05 Cairo (06:05Z) without internet, sent at 14:00 Cairo
    const r = await h.call(c.t.e3, 'POST', '/attendance/check-in', { offlineAt: '2026-03-20T06:05:00Z' });
    assert.equal(r.status, 201, JSON.stringify(r.body));
    assert.equal(r.body.attendance.checkInOffline, true);
    assert.equal(new Date(r.body.attendance.checkIn).toISOString(), '2026-03-20T06:05:00.000Z');
    const out = await h.call(c.t.e3, 'POST', '/attendance/check-out', { offlineAt: '2026-03-20T11:30:00Z' });
    assert.equal(out.status, 200);
    assert.equal(out.body.attendance.checkOutOffline, true);
    assert.equal((await h.call(c.t.e2, 'POST', '/attendance/check-in', { offlineAt: '2026-03-17T06:00:00Z' })).status, 400, 'older than 48 h');
    assert.equal((await h.call(c.t.e2, 'POST', '/attendance/check-in', { offlineAt: '2026-03-20T13:00:00Z' })).status, 400, 'future');
  } finally { h.now.value = t0; }
});
