import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { harness, cast, type Harness } from './helpers.ts';
import { evidenceFlags } from '../src/modules/attendance-evidence.ts';

/** SEC-06: attendance evidence — phone claims vs server facts, replay-safe punches, flags for HR, old records untouched. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const OFFICE = { lat: 30.0286, lng: 31.4085 };
const at = (iso: string) => { h.now.value = new Date(iso); };
const here = { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 12 };
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ('المكتب', $1, $2, 100)`, [OFFICE.lat, OFFICE.lng]);
  await h.call(c.t.owner, 'PATCH', '/settings', { gpsRequired: true });
});
after(async () => { await h.close(); });
const events = async (emp: string) => (await h.db.query(`SELECT * FROM attendance_events WHERE employee_id = $1 ORDER BY created_at, server_received_at`, [emp])).rows;

test('historical compatibility: a punch from an older app (no clientId / deviceTime) works as before and is recorded', async () => {
  const before = (await h.db.query(`SELECT count(*)::int n FROM attendance`)).rows[0].n;
  const r = await h.call(c.t.e1, 'POST', '/attendance/check-in', here);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM attendance`)).rows[0].n, before + 1);
  const [e] = await events(c.ids.e1);
  assert.equal(e.state, 'accepted'); assert.equal(e.client_id, null); assert.equal(e.step, 'check_in');
  assert.equal(new Date(e.server_received_at).toISOString(), '2026-03-10T08:00:00.000Z');
  assert.equal(new Date(e.used_time).toISOString(), '2026-03-10T08:00:00.000Z');
  assert.deepEqual(e.flags, []);
});

test('duplicate submission / replay: the same clientId returns the first reply and adds nothing; another step with it is refused', async () => {
  at('2026-03-10T08:05:00Z');
  const id = randomUUID();
  const first = await h.call(c.t.e2, 'POST', '/attendance/check-in', { ...here, clientId: id });
  assert.equal(first.status, 201);
  at('2026-03-10T08:07:00Z');
  const again = await h.call(c.t.e2, 'POST', '/attendance/check-in', { ...here, clientId: id });
  assert.equal(again.status, 201, 'the retry is answered like the first time (not «already checked in»)');
  assert.deepEqual(again.body, first.body);
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM attendance WHERE employee_id = $1`, [c.ids.e2])).rows[0].n, 1);
  assert.equal((await events(c.ids.e2)).length, 1);
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM audit_log WHERE action = 'attendance.replayed'`)).rows[0].n, 1);
  const other = await h.call(c.t.e2, 'POST', '/attendance/check-out', { ...here, clientId: id });
  assert.equal(other.status, 409); assert.equal(other.body.error.details.reason, 'client_id_reused');
  // parallel duplicates: exactly one attendance row
  const pid = randomUUID();
  const par = await Promise.all(Array.from({ length: 6 }, () => h.call(c.t.e3, 'POST', '/attendance/check-in', { ...here, clientId: pid })));
  assert.ok(par.every((x) => x.status === 201 || x.status === 409), JSON.stringify(par.map((x) => x.status)));
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM attendance WHERE employee_id = $1`, [c.ids.e3])).rows[0].n, 1);
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM attendance_events WHERE client_id = $1`, [pid])).rows[0].n, 1);
  assert.equal((await h.call(c.t.e3, 'POST', '/attendance/check-in', { ...here, clientId: pid })).status, 201, 'a later retry gets the reply');
  assert.equal((await h.call(c.t.e3, 'POST', '/attendance/check-in', { ...here, clientId: 'not-a-uuid' })).status, 400);
});

test('timestamp manipulation: the client cannot set the server time; drift is flagged; offline late arrival flagged; future refused', async () => {
  at('2026-03-10T12:00:00Z');
  // online with a phone clock 30 minutes ahead: the server time is used, the drift is flagged
  const r = await h.call(c.t.e1, 'POST', '/attendance/check-out', { ...here, clientId: randomUUID(), deviceTime: '2026-03-10T12:30:00Z',
    serverReceivedAt: '2020-01-01T00:00:00Z', server_received_at: '2020-01-01T00:00:00Z', usedTime: '2020-01-01T00:00:00Z' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const e = (await events(c.ids.e1)).at(-1);
  assert.equal(new Date(e.server_received_at).toISOString(), '2026-03-10T12:00:00.000Z', 'never taken from the request');
  assert.equal(new Date(e.used_time).toISOString(), '2026-03-10T12:00:00.000Z');
  assert.equal(new Date(e.device_time).toISOString(), '2026-03-10T12:30:00.000Z', 'the phone claim is kept as a claim');
  assert.ok(e.flags.includes('clock_drift'));
  // offline punch sent 40 minutes late: the device time is used (existing rule), offline + late_arrival flagged
  at('2026-03-10T08:50:00Z');
  const sm = await h.call(c.t.sm1, 'POST', '/attendance/check-in', { ...here, clientId: randomUUID(), offlineAt: '2026-03-10T08:10:00Z' });
  assert.equal(sm.status, 201, JSON.stringify(sm.body));
  const o = (await events(c.ids.sm1)).at(-1);
  assert.deepEqual([o.offline, new Date(o.used_time).toISOString()], [true, '2026-03-10T08:10:00.000Z']);
  assert.ok(o.flags.includes('offline') && o.flags.includes('late_arrival'), JSON.stringify(o.flags));
  // a future claim is refused (existing rule) and the refusal is on record
  const f = await h.call(c.t.sm2, 'POST', '/attendance/check-in', { ...here, clientId: randomUUID(), offlineAt: '2026-03-10T10:00:00Z' });
  assert.equal(f.status, 400);
  const fr = (await events(c.ids.sm2)).at(-1);
  assert.equal(fr.state, 'refused'); assert.equal(fr.used_time, null);
});

test('offline sync of yesterday stays refused (HR corrects) and is recorded; a refused punch may be sent again with its id', async () => {
  at('2026-03-11T09:00:00Z');
  const id = randomUUID();
  const y = await h.call(c.t.solo, 'POST', '/attendance/check-in', { ...here, clientId: id, offlineAt: '2026-03-10T08:00:00Z' });
  assert.equal(y.status, 409); assert.equal(y.body.error.details.reason, 'offline_other_day');
  let ev = (await events(c.ids.solo)).at(-1);
  assert.deepEqual([ev.state, ev.refusal], ['refused', 'offline_other_day']);
  const now = await h.call(c.t.solo, 'POST', '/attendance/check-in', { ...here, clientId: id });
  assert.equal(now.status, 201, 'the same id after a refusal: allowed');
  ev = (await events(c.ids.solo)).at(-1);
  assert.equal(ev.state, 'accepted');
  assert.equal((await events(c.ids.solo)).length, 1, 'one evidence row per punch id');
});

test('location evidence and fake-GPS: a mocked location is still refused (as before) and recorded with mock_reported; weak signal flagged', async () => {
  at('2026-03-11T09:05:00Z');
  const m = await h.call(c.t.acc, 'POST', '/attendance/check-in', { ...here, mocked: true, clientId: randomUUID() });
  assert.equal(m.status, 422); assert.equal(m.body.error.details.reason, 'mock_location');
  const e = (await events(c.ids.acc)).at(-1);
  assert.equal(e.state, 'refused'); assert.equal(e.mocked, true); assert.ok(e.flags.includes('mock_reported'));
  assert.equal(e.lat, OFFICE.lat); assert.equal(e.accuracy_m, 12);
  const weak = await h.call(c.t.acc, 'POST', '/attendance/check-in', { ...here, accuracyM: 500, clientId: randomUUID() });
  assert.equal(weak.status, 422);
  assert.ok((await events(c.ids.acc)).at(-1).flags.includes('low_accuracy'));
  const none = await h.call(c.t.acc, 'POST', '/attendance/check-in', { clientId: randomUUID() });
  assert.equal(none.status, 400);
  assert.ok((await events(c.ids.acc)).at(-1).flags.includes('no_location'));
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM attendance WHERE employee_id = $1`, [c.ids.acc])).rows[0].n, 0, 'nothing recorded as attendance');
});

test('HR reads the evidence (with flags); an employee cannot', async () => {
  const r = await h.call(c.t.hr, 'GET', `/attendance/events?employeeId=${c.ids.acc}&date=2026-03-11`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.body.events.length >= 3);
  assert.ok(r.body.events.some((x: any) => x.flags.includes('mock_reported')));
  assert.equal((await h.call(c.t.e1, 'GET', `/attendance/events?employeeId=${c.ids.acc}&date=2026-03-11`)).status, 403);
});

test('flags: ordering and device change are computed from server facts', () => {
  const base = { offline: true, deviceTime: new Date('2026-03-10T08:00:00Z'), receivedAt: new Date('2026-03-10T08:01:00Z'), usedTime: null,
    claimOverridden: false, previousUsed: new Date('2026-03-10T09:00:00Z'), mocked: false, accuracyM: 10, hasLocation: true, deviceChanged: true };
  assert.deepEqual(evidenceFlags(base), ['offline', 'ordering', 'device_changed']);
  assert.deepEqual(evidenceFlags({ ...base, offline: false, deviceTime: null, previousUsed: null, deviceChanged: false }), []);
});
