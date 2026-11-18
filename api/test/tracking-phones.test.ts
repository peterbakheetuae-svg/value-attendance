import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

/** One account open on two phones: each phone is followed on its own; a signed-in phone that sends no location
 *  is rung (that phone only) so the app opens and its follow-up starts. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const OFFICE = { lat: 30.0286, lng: 31.4085 };
const at = (iso: string) => { h.now.value = new Date(iso); };
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ('المكتب', $1, $2, 100)`, [OFFICE.lat, OFFICE.lng]);
  await h.db.query(`UPDATE employees SET device_lock = false WHERE id = $1`, [c.ids.e1]);
  await h.call(c.t.owner, 'PATCH', '/settings', { trackingEnabled: true, trackingStaleMinutes: 20 });
});
after(async () => { await h.close(); });

const signIn = async (deviceId: string) => {
  const r = await h.call(null, 'POST', '/auth/login', { identifier: 'E1', password: PW, deviceId });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body.token as string;
};
const nudges = async () => (await h.db.query(
  `SELECT after FROM audit_log WHERE action = 'tracking.phone_nudged' AND entity_id = $1 ORDER BY at`, [c.ids.e1])).rows;

test('a second signed-in phone that sends no location is rung once (that phone only); a reporting phone never is', async () => {
  const phoneA = await signIn('phone-a-000000000001');
  const phoneB = await signIn('phone-b-000000000002');
  await h.call(phoneA, 'POST', '/me/push-token', { token: 'tokenA'.padEnd(40, 'a'), platform: 'android' });
  await h.call(phoneB, 'POST', '/me/push-token', { token: 'tokenB'.padEnd(40, 'b'), platform: 'android' });
  at('2026-03-10T08:00:00Z');
  assert.equal((await h.call(phoneA, 'POST', '/attendance/check-in', {})).status, 201);
  // checked in on phone A → phone B (only) rings like a call at once: «ابدأ عملك الآن»
  const call = (await h.db.query(`SELECT n.dedupe_key, n.body FROM notifications n WHERE n.recipient_id = $1 AND n.type = 'checkin_other_phone'`,
    [c.ids.e1])).rows;
  const sessB = (await h.db.query(`SELECT id FROM sessions WHERE device_id = 'phone-b-000000000002'`)).rows[0].id;
  assert.equal(call.length, 1, JSON.stringify(call));
  assert.ok(call[0].dedupe_key.includes(sessB), 'rung on phone B, not on phone A');
  assert.equal(call[0].body, 'ابدأ عملك الآن');
  // phone A reports every few minutes; phone B (left signed in) never opened the app
  for (const t of ['08:01', '08:06', '08:11', '08:16', '08:21', '08:26']) {
    at(`2026-03-10T${t}:00Z`);
    assert.equal((await h.call(phoneA, 'POST', '/tracking/ping', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 })).body.inside, true);
  }
  at('2026-03-10T08:27:00Z');
  await h.call(c.t.hr, 'GET', '/tracking/live'); // runs the sweep
  let n = await nudges();
  assert.equal(n.length, 1, JSON.stringify(n));
  const types = (await h.call(phoneB, 'GET', '/notifications')).body.notifications.map((x: any) => x.type);
  assert.ok(types.includes('tracking_phone_off'));
  // a minute later: not rung again (once every 3 hours per phone)
  at('2026-03-10T08:29:00Z');
  await h.call(c.t.hr, 'GET', '/tracking/live');
  assert.equal((await nudges()).length, 1);
  // phone B opens the app → it reports too → nothing more for it; phone A still never rung
  await h.call(phoneB, 'POST', '/tracking/ping', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 });
  for (let m = 8 * 60 + 35; m <= 11 * 60 + 30; m += 5) { const t = `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
    at(`2026-03-10T${t}:00Z`);
    await h.call(phoneB, 'POST', '/tracking/ping', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 });
    await h.call(phoneA, 'POST', '/tracking/ping', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 });
  }
  at('2026-03-10T11:31:00Z');
  await h.call(c.t.hr, 'GET', '/tracking/live');
  n = await nudges();
  assert.equal(n.length, 1, 'both phones reporting → no ring');
  // phone B leaves the office while A stays at the desk → the alarm is raised for B
  at('2026-03-10T11:35:00Z');
  const out = await h.call(phoneB, 'POST', '/tracking/ping', { lat: OFFICE.lat + 0.01, lng: OFFICE.lng, accuracyM: 10 });
  assert.equal(out.body.inside, false);
  const hr = (await h.call(c.t.hr, 'GET', '/notifications')).body.notifications.map((x: any) => x.type);
  assert.ok(hr.includes('unauthorized_exit'), 'the phone that left raises the alarm');
});
