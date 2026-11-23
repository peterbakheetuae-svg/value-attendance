// G1 (security re-verification 2026-11-24): attendance is recorded from the phone app; a browser only where the policy
// allows it — decided on the server from the Origin header (a browser cannot drop it) and the server's own device records,
// never from what the client says about itself. Also the Low findings L2 (/healthz/latency) checked here.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, dev, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const BROWSER = { origin: 'https://jaurea.com' };
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
});
after(async () => { await h.close(); delete process.env.ATTENDANCE_BROWSER_PUNCH; delete process.env.BACKUP_TOKEN; });

const refusedAudits = async (id: string) =>
  (await h.db.query(`SELECT count(*)::int AS n FROM audit_log WHERE action = 'attendance.browser_refused' AND actor_id = $1`, [id])).rows[0].n as number;

test('default policy: a browser of an employee without an approved linked device is refused; the phone app is not', async () => {
  // E2 without «ربط الحساب بالجهاز»: any browser signs him in, so no browser of his is an approved device
  await h.db.query(`UPDATE employees SET device_lock = false WHERE id = $1`, [c.ids.e2]);
  const e2 = await h.login('E2', PW);
  const r = await h.call(e2, 'POST', '/attendance/check-in', {}, BROWSER);
  assert.equal(r.status, 403, JSON.stringify(r.body));
  assert.equal(r.body.error.details.reason, 'browser_punch_refused');
  assert.equal(await refusedAudits(c.ids.e2), 1, 'audited');
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM attendance WHERE employee_id = $1`, [c.ids.e2])).rows[0].n, 0, 'nothing recorded');
  // forged client claims change nothing: the server does not read them
  const forged = await h.call(e2, 'POST', '/attendance/check-in', {}, { ...BROWSER, 'x-client-platform': 'android',
    'x-platform': 'android', 'user-agent': 'Dalvik/2.1.0 (Linux; U; Android 14)' });
  assert.equal(forged.status, 403, 'forged platform headers');
  // Origin "null" (sandboxed page / file) is a browser too
  assert.equal((await h.call(e2, 'POST', '/attendance/check-in', {}, { origin: 'null' })).status, 403, 'Origin: null');
  // the phone app (no Origin) records normally
  const phone = await h.call(e2, 'POST', '/attendance/check-in', {});
  assert.equal(phone.status, 201, JSON.stringify(phone.body));
  // check-out and «I'm back» follow the same rule
  h.now.value = new Date('2026-03-10T09:00:00Z');
  assert.equal((await h.call(e2, 'POST', '/attendance/check-out', {}, BROWSER)).status, 403, 'browser check-out');
  assert.equal((await h.call(e2, 'POST', '/outings/return', {}, BROWSER)).status, 403, 'browser «I am back» refused before anything else');
  assert.equal((await h.call(e2, 'POST', '/outings/return', {})).status, 409, 'the phone app reaches the normal rule (not out)');
  assert.equal((await h.call(e2, 'POST', '/attendance/check-out', {})).status, 200, 'phone check-out');
});

test('default policy: a browser that IS the employee\'s approved linked device may punch (e.g. an iPhone Home Screen app)', async () => {
  // E1: device lock on (helpers default), his first sign-in device was approved by itself — that session punches from a browser
  h.now.value = new Date('2026-03-10T08:05:00Z');
  const r = await h.call(c.t.e1, 'POST', '/attendance/check-in', {}, BROWSER);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  // a second browser with another device id cannot even sign in without the administration's approval
  const other = await h.call(null, 'POST', '/auth/login', { identifier: 'E1', password: PW, deviceId: dev('E1-OTHER-BROWSER') }, BROWSER);
  assert.equal(other.status, 403);
  assert.equal(other.body.error.details.reason, 'device_pending');
  // the device refused later → its session is signed out, nothing more is recorded from it
  const d = (await h.db.query(`SELECT id FROM employee_devices WHERE employee_id = $1 AND device_id = $2`, [c.ids.e1, dev('E1')])).rows[0];
  await h.db.query(`UPDATE employee_devices SET status = 'rejected' WHERE id = $1`, [d.id]);
  h.now.value = new Date('2026-03-10T09:00:00Z');
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-out', {}, BROWSER)).status, 403, 'approval withdrawn → refused');
  await h.db.query(`UPDATE employee_devices SET status = 'approved' WHERE id = $1`, [d.id]);
});

test('ATTENDANCE_BROWSER_PUNCH=deny refuses every browser; =allow is the old behaviour; a typo counts as deny', async () => {
  h.now.value = new Date('2026-03-10T08:10:00Z');
  try {
    process.env.ATTENDANCE_BROWSER_PUNCH = 'deny';
    assert.equal((await h.call(c.t.e3, 'POST', '/attendance/check-in', {}, BROWSER)).status, 403, 'deny: even an approved device');
    process.env.ATTENDANCE_BROWSER_PUNCH = 'yes please';
    assert.equal((await h.call(c.t.e3, 'POST', '/attendance/check-in', {}, BROWSER)).status, 403, 'unknown value → deny');
    process.env.ATTENDANCE_BROWSER_PUNCH = 'allow';
    await h.db.query(`UPDATE employees SET device_lock = false WHERE id = $1`, [c.ids.solo]);
    const solo = await h.login('SOLO', PW);
    assert.equal((await h.call(solo, 'POST', '/attendance/check-in', {}, BROWSER)).status, 201, 'allow');
  } finally { delete process.env.ATTENDANCE_BROWSER_PUNCH; }
  // the phone app is never affected by the policy
  process.env.ATTENDANCE_BROWSER_PUNCH = 'deny';
  try {
    assert.equal((await h.call(c.t.e3, 'POST', '/attendance/check-in', {})).status, 201, 'phone app under deny');
  } finally { delete process.env.ATTENDANCE_BROWSER_PUNCH; }
});

test('a browser that may not punch does not feed the location follow-up either', async () => {
  await h.call(c.t.owner, 'PATCH', '/settings', { trackingEnabled: true, trackingStaleMinutes: 20 });
  h.now.value = new Date('2026-03-10T08:20:00Z');
  process.env.ATTENDANCE_BROWSER_PUNCH = 'deny';
  try {
    const r = await h.call(c.t.e3, 'POST', '/tracking/ping', { lat: 30.0286, lng: 31.4085, accuracyM: 10 }, BROWSER);
    assert.equal(r.status, 200);
    assert.deepEqual([r.body.tracking, r.body.reason], [false, 'browser_not_allowed']);
    assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM tracking_pings WHERE employee_id = $1`, [c.ids.e3])).rows[0].n, 0, 'nothing kept');
    const phone = await h.call(c.t.e3, 'POST', '/tracking/ping', { lat: 30.0286, lng: 31.4085, accuracyM: 10 });
    assert.equal(phone.body.tracking, true, 'the phone app is followed');
  } finally { delete process.env.ATTENDANCE_BROWSER_PUNCH; }
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
