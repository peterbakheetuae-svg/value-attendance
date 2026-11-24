// G1 (second review, 2026-11-24): an attendance step is allowed by the server's own device records — the employee's
// «ربط الحساب بالجهاز», the device id the session was created with and its approval — read on every step. No header can
// grant it: omitting Origin, forging Origin or adding platform claims changes nothing for a device-linked employee.
// Also: L2 (/healthz/latency).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, dev, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const BROWSER = { origin: 'https://jaurea.com' };
const FORGED = { origin: 'https://evil.example', 'x-client-platform': 'android', 'x-platform': 'android',
  'user-agent': 'Dalvik/2.1.0 (Linux; U; Android 14)' };
const OFFICE = { lat: 30.0444, lng: 31.2357 };
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.call(c.t.owner, 'PATCH', '/settings', { trackingEnabled: true, trackingStaleMinutes: 20 });
});
after(async () => { await h.close(); delete process.env.ATTENDANCE_DEVICE_POLICY; delete process.env.BACKUP_TOKEN; });

const refused = async (id: string) =>
  (await h.db.query(`SELECT count(*)::int AS n FROM audit_log WHERE action = 'attendance.device_refused' AND actor_id = $1`, [id])).rows[0].n as number;
const attendanceRows = async (id: string) =>
  (await h.db.query(`SELECT count(*)::int AS n FROM attendance WHERE employee_id = $1`, [id])).rows[0].n as number;
const setDevice = (employeeId: string, deviceId: string, status: string) =>
  h.db.query(`UPDATE employee_devices SET status = $3 WHERE employee_id = $1 AND device_id = $2`, [employeeId, deviceId, status]);
const why = (r: any) => [r.status, r.body?.error?.details?.reason, r.body?.error?.details?.why];

test('1+2: a device refused after sign-in cannot punch — not without Origin, not with a forged Origin or platform claims', async () => {
  // E1 is device-linked and signed in from his approved phone; the administration then refuses that phone
  await setDevice(c.ids.e1, dev('E1'), 'rejected');
  assert.deepEqual(why(await h.call(c.t.e1, 'POST', '/attendance/check-in', {})), [403, 'device_not_authorized', 'device_not_approved'], 'no Origin');
  assert.deepEqual(why(await h.call(c.t.e1, 'POST', '/attendance/check-in', {}, FORGED)), [403, 'device_not_authorized', 'device_not_approved'], 'forged');
  assert.deepEqual(why(await h.call(c.t.e1, 'POST', '/attendance/check-in', {}, BROWSER)), [403, 'device_not_authorized', 'device_not_approved'], 'browser');
  assert.equal(await attendanceRows(c.ids.e1), 0, 'nothing recorded');
  assert.equal(await refused(c.ids.e1), 3, 'every refusal audited');
  // its location is not taken either
  const p = await h.call(c.t.e1, 'POST', '/tracking/ping', { ...OFFICE, accuracyM: 10 });
  assert.deepEqual([p.status, p.body.tracking, p.body.reason], [200, false, 'device_not_authorized']);
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM tracking_pings WHERE employee_id = $1`, [c.ids.e1])).rows[0].n, 0);
  // pending is not approved either
  await setDevice(c.ids.e1, dev('E1'), 'pending');
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-in', {})).status, 403, 'pending');
  // 4+5: approved again → the Android app punches as before
  await setDevice(c.ids.e1, dev('E1'), 'approved');
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-in', {})).status, 201, 'approved Android app');
});

test('9: session device edge cases — no device, a device approved for someone else', async () => {
  const sess = async (code: string) => (await h.db.query(`SELECT s.id FROM sessions s JOIN employees e ON e.id = s.employee_id
    WHERE e.code = $1 AND s.revoked_at IS NULL ORDER BY s.expires_at DESC LIMIT 1`, [code])).rows[0].id as string;
  const e3 = await sess('E3');
  await h.db.query(`UPDATE sessions SET device_id = NULL WHERE id = $1`, [e3]);
  assert.deepEqual(why(await h.call(c.t.e3, 'POST', '/attendance/check-in', {})), [403, 'device_not_authorized', 'device_not_approved'], 'no device on the session');
  await h.db.query(`UPDATE sessions SET device_id = $2 WHERE id = $1`, [e3, dev('E1')]);
  assert.deepEqual(why(await h.call(c.t.e3, 'POST', '/attendance/check-in', {}, BROWSER)), [403, 'device_not_authorized', 'device_not_approved'],
    'a device approved for another employee');
  await h.db.query(`UPDATE sessions SET device_id = $2 WHERE id = $1`, [e3, dev('E3')]);
  // 4: his own approved device — also from a browser (the iPhone web app as his linked device)
  assert.equal((await h.call(c.t.e3, 'POST', '/attendance/check-in', {}, BROWSER)).status, 201);
});

test('3: an employee whose device-link is off — the phone app works, a browser is refused, every step alike', async () => {
  await h.db.query(`UPDATE employees SET device_lock = false WHERE id = $1`, [c.ids.e2]);
  const e2 = await h.login('E2', PW);
  assert.deepEqual(why(await h.call(e2, 'POST', '/attendance/check-in', {}, BROWSER)), [403, 'device_not_authorized', 'device_link_off_browser']);
  assert.equal((await h.call(e2, 'POST', '/attendance/check-in', {}, { origin: 'null' })).status, 403, 'Origin: null');
  assert.equal(await attendanceRows(c.ids.e2), 0);
  assert.equal((await h.call(e2, 'POST', '/attendance/check-in', {})).status, 201, 'phone app');
  h.now.value = new Date('2026-03-10T09:00:00Z');
  assert.equal((await h.call(e2, 'POST', '/attendance/check-out', {}, BROWSER)).status, 403, 'check-out');
  assert.equal((await h.call(e2, 'POST', '/outings/return', {}, BROWSER)).status, 403, '«I am back» refused before anything else');
  assert.equal((await h.call(e2, 'POST', '/outings/return', {})).status, 409, 'the app reaches the normal rule (not out)');
  assert.equal((await h.call(e2, 'POST', '/attendance/check-out', {})).status, 200);
});

test('9: ATTENDANCE_DEVICE_POLICY=strict refuses accounts without the device-link; a typo is strict; the old variable opens nothing', async () => {
  h.now.value = new Date('2026-03-10T08:10:00Z');
  await h.db.query(`UPDATE employees SET device_lock = false WHERE id = $1`, [c.ids.solo]);
  const solo = await h.login('SOLO', PW);
  try {
    process.env.ATTENDANCE_DEVICE_POLICY = 'strict';
    assert.deepEqual(why(await h.call(solo, 'POST', '/attendance/check-in', {})), [403, 'device_not_authorized', 'device_link_required']);
    process.env.ATTENDANCE_DEVICE_POLICY = 'allow';
    assert.equal((await h.call(solo, 'POST', '/attendance/check-in', {})).status, 403, 'unknown value → strict');
    delete process.env.ATTENDANCE_DEVICE_POLICY;
    process.env.ATTENDANCE_BROWSER_PUNCH = 'allow';
    assert.equal((await h.call(solo, 'POST', '/attendance/check-in', {}, BROWSER)).status, 403, 'first-version variable ignored');
    delete process.env.ATTENDANCE_BROWSER_PUNCH;
    assert.equal((await h.call(solo, 'POST', '/attendance/check-in', {})).status, 201, 'default: the phone app of a non-linked account');
  } finally { delete process.env.ATTENDANCE_DEVICE_POLICY; delete process.env.ATTENDANCE_BROWSER_PUNCH; }
});

test('6+7: the Windows app keeps working; sign-in and device approval stay enforced', async () => {
  // a Windows app session (dart:io: no Origin) of the non-linked E2 — signs in and reads as before
  const win = (await h.call(null, 'POST', '/auth/login', { identifier: 'E2', password: PW, deviceId: dev('E2-WINDOWS-PC'),
    deviceLabel: 'Windows' }, { 'user-agent': 'Dart/3.5 (dart:io)' })).body.token;
  assert.ok(win, 'Windows sign-in');
  assert.equal((await h.call(win, 'GET', '/me')).status, 200);
  assert.equal((await h.call(win, 'GET', '/notifications')).status, 200);
  // a device-linked employee's new Windows PC waits for approval, then a refused one is refused at sign-in
  const pend = await h.call(null, 'POST', '/auth/login', { identifier: 'HR1', password: PW, deviceId: dev('HR1-WINDOWS-PC') }, { 'user-agent': 'Dart/3.5 (dart:io)' });
  assert.deepEqual([pend.status, pend.body.error.details.reason], [403, 'device_pending']);
  await setDevice(c.ids.hr, dev('HR1-WINDOWS-PC'), 'rejected');
  const rej = await h.call(null, 'POST', '/auth/login', { identifier: 'HR1', password: PW, deviceId: dev('HR1-WINDOWS-PC') });
  assert.deepEqual([rej.status, rej.body.error.details.reason], [403, 'device_rejected']);
  // no / bad token: 401 on every attendance step
  for (const path of ['/attendance/check-in', '/attendance/check-out', '/outings/return', '/tracking/ping']) {
    assert.equal((await h.call(null, 'POST', path, {})).status, 401, `${path} anonymous`);
    assert.equal((await h.call('not-a-real-token', 'POST', path, {})).status, 401, `${path} bad token`);
  }
});

test('8: GPS and geofence rules are unchanged for an approved device', async () => {
  h.now.value = new Date('2026-03-10T08:20:00Z');
  assert.equal((await h.call(c.t.owner, 'PATCH', '/settings', { gpsRequired: true })).status, 200);
  assert.equal((await h.call(c.t.hr, 'POST', '/work-locations', { name: 'المكتب', ...OFFICE, radiusM: 150 })).status, 201);
  assert.equal((await h.call(c.t.sm1, 'POST', '/attendance/check-in', {})).status, 400, 'location required');
  assert.equal((await h.call(c.t.sm1, 'POST', '/attendance/check-in', { lat: 30.06, lng: 31.25, accuracyM: 10 })).status, 422, 'outside');
  assert.equal((await h.call(c.t.sm1, 'POST', '/attendance/check-in', { ...OFFICE, accuracyM: 900 })).status, 422, 'weak signal');
  const m = await h.call(c.t.sm1, 'POST', '/attendance/check-in', { ...OFFICE, accuracyM: 10, mocked: true });
  assert.deepEqual([m.status, m.body.error.details.reason], [422, 'mock_location']);
  const ok = await h.call(c.t.sm1, 'POST', '/attendance/check-in', { ...OFFICE, accuracyM: 10 });
  assert.deepEqual([ok.status, ok.body.attendance.geofence], [201, 'inside']);
  // an unapproved device is refused before any location rule runs (403, not 422)
  await setDevice(c.ids.sm2, dev('SM2'), 'rejected');
  assert.equal((await h.call(c.t.sm2, 'POST', '/attendance/check-in', { lat: 30.06, lng: 31.25, accuracyM: 10 })).status, 403);
  await setDevice(c.ids.sm2, dev('SM2'), 'approved');
  assert.equal((await h.call(c.t.owner, 'PATCH', '/settings', { gpsRequired: false })).status, 200);
});

test('L2: /healthz/latency tells anyone only ok + round trips; regions only with the scheduler token', async () => {
  const anon = await h.call(null, 'GET', '/healthz/latency');
  assert.equal(anon.status, 200);
  assert.deepEqual(Object.keys(anon.body).sort(), ['dbRoundTripMs', 'ok']);
  process.env.BACKUP_TOKEN = 'latency-test-token-0123456789abc';
  try {
    assert.deepEqual(Object.keys((await h.call(null, 'GET', '/healthz/latency', undefined, { 'x-backup-token': 'wrong-token-wrong-token-wrong' })).body).sort(),
      ['dbRoundTripMs', 'ok'], 'a wrong token sees no more');
    const full = await h.call(null, 'GET', '/healthz/latency', undefined, { 'x-backup-token': process.env.BACKUP_TOKEN });
    assert.ok('dbRegion' in full.body && 'apiRegion' in full.body && 'pooled' in full.body);
  } finally { delete process.env.BACKUP_TOKEN; }
});
