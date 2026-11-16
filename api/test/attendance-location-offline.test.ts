import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, type Harness } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

/**
 * Location privacy after migration 066, offline punches included: another employee's location (check-in place,
 * tracking) needs attendance.view_location; attendance.correct lets you correct times but never shows a location.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const OFFICE = { lat: 30.0286, lng: 31.4085 };
const range = (t: string, id: string) => h.call(t, 'GET', `/attendance/range?employeeId=${id}&from=2026-03-10&to=2026-03-10`);
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ('المكتب', $1, $2, 100)`, [OFFICE.lat, OFFICE.lng]);
  // an OFFLINE punch: recorded on the phone 30 minutes ago, sent now
  const r = await h.call(c.t.e2, 'POST', '/attendance/check-in', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 12, offlineAt: '2026-03-10T07:30:00Z' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const sql = readFileSync(new URL('../../db/proposed/066_fine_grained_permissions.sql', import.meta.url), 'utf8');
  await h.db.tx(async (q) => { await q.query(sql); });
  forgetPermissionKeys();
});
after(async () => { await h.close(); });

test('offline punch: stored as offline with its place; the employee and location readers see it', async () => {
  const own = (await range(c.t.e2, c.ids.e2)).body.days[0];
  assert.equal(own.checkInOffline, true);
  assert.equal(Number(own.checkInLat), OFFICE.lat, 'own location');
  const mgr = (await range(c.t.sm1, c.ids.e2)).body.days[0];
  assert.equal(Number(mgr.checkInLat), OFFICE.lat, 'team manager holds attendance.view_location after 066');
});

test('attendance.correct without attendance.view_location: corrects times, never sees a location (offline or not)', async () => {
  assert.equal((await h.call(c.t.owner, 'PUT', `/permissions/employees/${c.ids.sm1}`, { perm: 'attendance.view_location', value: 'deny', confirm: true })).status, 200);
  assert.equal((await h.call(c.t.owner, 'PUT', `/permissions/employees/${c.ids.sm1}`, { perm: 'attendance.correct', value: 'allow', confirm: true })).status, 200);
  const day = (await range(c.t.sm1, c.ids.e2)).body.days[0];
  assert.equal(day.checkInOffline, true, 'still sees the record itself');
  assert.equal(day.checkInLat, null); assert.equal(day.checkInLng, null);
  assert.equal(day.checkOutLat, null); assert.equal(day.checkOutLng, null);
  assert.equal((await h.call(c.t.sm1, 'GET', `/tracking/employee/${c.ids.e2}`)).status, 403, 'no location history');
  const live = await h.call(c.t.sm1, 'GET', '/tracking/live');
  assert.ok(live.status === 403 || !/"lat":\s*-?\d/.test(JSON.stringify(live.body)), 'no live locations');
  for (const p of [`/attendance?employeeId=${c.ids.e2}&month=2026-03`, '/attendance/board', '/attendance/issues']) {
    const r = await h.call(c.t.sm1, 'GET', p);
    assert.equal(r.status, 200, p);
    assert.ok(!/check_?in_?lat|checkInLat"\s*:\s*\d/i.test(JSON.stringify(r.body)), `no coordinates in ${p}`);
  }
  const corr = await h.call(c.t.sm1, 'POST', '/attendance/corrections', { employeeId: c.ids.e2, workDate: '2026-03-09', checkIn: '10:00', checkOut: '18:00', reason: 'نسي' });
  assert.equal(corr.status, 201, JSON.stringify(corr.body));
  assert.ok(!/lat|lng/i.test(JSON.stringify(corr.body)), 'a correction response carries no location');
  // the employee keeps his own
  assert.equal(Number((await range(c.t.e2, c.ids.e2)).body.days[0].checkInLat), OFFICE.lat);
});

test('attendance.view_location without reading scope shows nothing outside the scope', async () => {
  // e1 (no reading scope) given the location permission: other people's attendance stays closed
  assert.equal((await h.call(c.t.owner, 'PUT', `/permissions/employees/${c.ids.e1}`, { perm: 'attendance.view_location', value: 'allow', confirm: true })).status, 200);
  assert.equal((await range(c.t.e1, c.ids.e2)).status, 404);
  assert.equal((await h.call(c.t.e1, 'GET', `/tracking/employee/${c.ids.e2}`)).status, 404);
});
