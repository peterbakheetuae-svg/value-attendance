import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, insertEmployee, PW, type Harness } from './helpers.ts';

// Per-employee «تتبع أثناء العمل» × «حضور وانصراف», and who hears an unauthorized exit.
// 2026-03-10 Tue, Cairo UTC+2, schedule 10:00–18:00. Office radius 100 m.
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let gm: string, gm2: string, ao: string; const tk: Record<string, string> = {};
const OFFICE = { lat: 30.0286, lng: 31.4085 };
const AWAY = { lat: OFFICE.lat + 0.01, lng: OFFICE.lng, accuracyM: 10 }; // ~1.1 km
const IN = { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 };
const at = (iso: string) => { h.now.value = new Date(iso); };
const count = async (to: string, type: string) =>
  (await h.db.query(`SELECT count(*)::int AS n FROM notifications WHERE recipient_id = $1 AND type = $2`, [to, type])).rows[0].n as number;

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ('المكتب', $1, $2, 100)`, [OFFICE.lat, OFFICE.lng]);
  gm = await insertEmployee(h.db, { code: 'GM1', name: 'المدير العام', role: 'manager' });
  gm2 = await insertEmployee(h.db, { code: 'GM2', name: 'مدير تاني', role: 'manager' });
  const aoKey = (await h.db.query(`SELECT key FROM roles WHERE key = 'admin_officer' OR name_ar = 'مسؤول إداري' LIMIT 1`)).rows[0].key;
  ao = await insertEmployee(h.db, { code: 'AO1', name: 'المسؤول الإداري', role: 'sales_employee' });
  await h.db.query(`UPDATE employees SET position_key = $2 WHERE id = $1`, [ao, aoKey]).catch(async () => {
    await h.db.query(`UPDATE employees SET role_key = $2 WHERE id = $1`, [ao, aoKey]);
  });
  // E1, E2, E3 report to GM1
  await h.db.query(`UPDATE employees SET general_manager_id = $1 WHERE id = ANY($2)`, [gm, [c.ids.e1, c.ids.e2, c.ids.e3]]);
  for (const k of ['GM1', 'GM2', 'AO1']) tk[k] = await h.login(k, PW);
  await h.call(c.t.owner, 'PATCH', '/settings', { trackingEnabled: true, trackingStaleMinutes: 20, awayMarginM: 50 });
});
after(async () => { await h.close(); });

test('the profile shows «تتبع أثناء العمل» on by default (existing employees keep being followed)', async () => {
  const r = await h.call(c.t.owner, 'GET', `/employees/${c.ids.e1}`);
  assert.equal(r.body.employee.work_tracking, true);
  assert.equal(r.body.employee.attendance_exempt, false);
  assert.equal((await h.call(c.t.e1, 'GET', '/tracking/config')).body.enabled, true);
});

test('only employee.manage can switch «تتبع أثناء العمل»; it survives a later legacyFields save', async () => {
  assert.equal((await h.call(c.t.e2, 'PATCH', `/employees/${c.ids.e2}`, { workTracking: false })).status, 403);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.e2}`, { workTracking: false })).status, 200);
  // the edit screen re-sends the extra fields it knows (without workTracking): the switch is kept
  assert.equal((await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.e2}`, { legacyFields: { nationality: 'مصري' } })).status, 200);
  assert.equal((await h.call(c.t.owner, 'GET', `/employees/${c.ids.e2}`)).body.employee.work_tracking, false);
  // «حضور وانصراف» off for E3 (the existing attendance_exempt), both off for SOLO
  assert.equal((await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.e3}`, { attendanceExempt: true })).status, 200);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.solo}`, { attendanceExempt: true, workTracking: false })).status, 200);
});

test('the 4 combinations: config + ping say who is followed, and why not', async () => {
  const cfg = async (t: string) => (await h.call(t, 'GET', '/tracking/config')).body;
  assert.deepEqual([(await cfg(c.t.e1)).enabled, (await cfg(c.t.e1)).reason], [true, null], 'tracking on + attendance on');
  assert.deepEqual([(await cfg(c.t.e2)).enabled, (await cfg(c.t.e2)).reason], [false, 'employee_off'], 'tracking off + attendance on');
  assert.deepEqual([(await cfg(c.t.e3)).enabled, (await cfg(c.t.e3)).reason], [false, 'no_attendance'], 'tracking on + attendance off');
  assert.equal((await cfg(c.t.solo)).enabled, false, 'both off');
  at('2026-03-10T08:00:00Z');
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-in', {})).status, 201);
  assert.equal((await h.call(c.t.e2, 'POST', '/attendance/check-in', {})).status, 201, 'check-in itself is untouched by «تتبع أثناء العمل»');
  assert.notEqual((await h.call(c.t.e3, 'POST', '/attendance/check-in', {})).status, 201, 'no attendance: the button stays refused as before');
  for (const t of [c.t.e2, c.t.e3, c.t.solo]) {
    const r = await h.call(t, 'POST', '/tracking/ping', AWAY);
    assert.equal(r.status, 200);
    assert.equal(r.body.tracking, false, 'the app is told to stop');
  }
  assert.equal((await h.call(c.t.e1, 'POST', '/tracking/ping', IN)).body.inside, true);
});

test('unauthorized exit: the employee, his general manager and the administrative officer — once each', async () => {
  at('2026-03-10T08:30:00Z');
  const r = await h.call(c.t.e1, 'POST', '/tracking/ping', { ...AWAY, localAlarm: true });
  assert.equal(r.body.inside, false);
  assert.equal(await count(c.ids.e1, 'unauthorized_exit_self'), 1, 'the employee');
  assert.equal(await count(gm, 'unauthorized_exit'), 1, 'his general manager');
  assert.equal(await count(ao, 'unauthorized_exit'), 1, 'the administrative officer');
  assert.equal(await count(c.ids.sm2, 'unauthorized_exit'), 0, 'another team\'s sales manager is not told');
  assert.equal(await count(c.ids.e1, 'unauthorized_exit'), 0, 'not sent to himself as a manager alert');
  assert.equal(await count(c.ids.e3, 'unauthorized_exit'), 0, 'colleagues never see it');
  // still outside: no new event, no repeat
  at('2026-03-10T08:36:00Z');
  await h.call(c.t.e1, 'POST', '/tracking/ping', AWAY);
  assert.equal(await count(gm, 'unauthorized_exit'), 1);
  assert.equal(await count(ao, 'unauthorized_exit'), 1);
  // the stages are logged without coordinates in the dispatch record
  const d = (await h.db.query(`SELECT after FROM audit_log WHERE action = 'tracking.alert_dispatch' AND entity_id = $1`, [c.ids.e1])).rows;
  assert.equal(d.length, 1);
  assert.ok(d[0].after.recipients >= 2);
  assert.ok(!('lat' in d[0].after) && !('lng' in d[0].after));
  const ex = (await h.db.query(`SELECT after FROM audit_log WHERE action = 'tracking.unauthorized_exit' AND entity_id = $1`, [c.ids.e1])).rows[0].after;
  assert.equal(ex.permission, 'none');
  assert.equal(ex.localAlarm, true);
  // location stays with the people who already could see it
  assert.ok([403, 404].includes((await h.call(c.t.e3, 'GET', `/tracking/employee/${c.ids.e1}`)).status));
});

test('back in the office, then out again: a new event alerts again', async () => {
  at('2026-03-10T08:45:00Z');
  await h.call(c.t.e1, 'POST', '/tracking/ping', IN);
  at('2026-03-10T09:00:00Z');
  await h.call(c.t.e1, 'POST', '/tracking/ping', AWAY);
  assert.equal(await count(gm, 'unauthorized_exit'), 2);
  assert.equal(await count(c.ids.e1, 'unauthorized_exit_self'), 2);
});

test('an approved visit: no alarm', async () => {
  at('2026-03-10T09:10:00Z');
  await h.call(c.t.e1, 'POST', '/tracking/ping', IN);
  const v = await h.call(c.t.e1, 'POST', '/outings', { kind: 'visit', expectedReturn: '13:00', reason: 'معاينة شقة للعميل' });
  assert.equal(v.status, 201);
  assert.equal((await h.call(c.t.hr, 'POST', `/outings/${v.body.outing.id}/decision`, { decision: 'approve' })).status, 200);
  at('2026-03-10T09:20:00Z');
  await h.call(c.t.e1, 'POST', '/tracking/ping', AWAY);
  assert.equal(await count(gm, 'unauthorized_exit'), 2, 'unchanged');
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM audit_log WHERE action = 'tracking.authorized_exit' AND actor_id = $1`, [c.ids.e1])).rows[0].n, 1);
});

test('turning «تتبع أثناء العمل» off mid-shift stops the alarm and the «التتبع وقف» alert', async () => {
  at('2026-03-10T09:30:00Z');
  await h.call(c.t.e1, 'POST', '/tracking/ping', IN);
  await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.e1}`, { workTracking: false });
  at('2026-03-10T09:40:00Z');
  assert.equal((await h.call(c.t.e1, 'POST', '/tracking/ping', AWAY)).body.tracking, false);
  // E2 checked in with «تتبع أثناء العمل» off and never pinged: no «التتبع وقف» for him
  at('2026-03-10T11:00:00Z');
  await h.call(c.t.hr, 'GET', '/tracking/live');
  const stopped = (await h.db.query(`SELECT count(*)::int AS n FROM notifications WHERE type = 'tracking_stopped' AND entity_id = ANY($1)`,
    [[c.ids.e1, c.ids.e2]])).rows[0].n;
  assert.equal(stopped, 0);
  assert.equal(await count(gm, 'unauthorized_exit'), 2, 'unchanged');
  // the attendance record is untouched: check-out still works
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-out', {})).status, 200);
});

test('no general manager set: the «المدير» role holders hear it instead', async () => {
  await h.db.query(`UPDATE employees SET general_manager_id = NULL WHERE id = $1`, [c.ids.e2]);
  await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.e2}`, { workTracking: true });
  at('2026-03-10T11:10:00Z');
  await h.call(c.t.e2, 'POST', '/tracking/ping', IN);
  at('2026-03-10T11:20:00Z');
  await h.call(c.t.e2, 'POST', '/tracking/ping', AWAY);
  const n = (await h.db.query(`SELECT recipient_id FROM notifications WHERE type = 'unauthorized_exit' AND entity_id = $1`, [c.ids.e2])).rows.map((x) => x.recipient_id);
  assert.ok(n.includes(gm) && n.includes(gm2), 'both «المدير» holders');
  assert.ok(n.includes(ao), 'the administrative officer');
  assert.equal(new Set(n).size, n.length, 'one notification per person');
});
