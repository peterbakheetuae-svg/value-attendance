import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

// Attendance module: scope on every read, corrections within scope, locations and exports by permission
// (throwaway database; before migration 066 the fine keys resolve to the keys they were split from).
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const OFFICE = { lat: 30.0286, lng: 31.4085 };
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ('المكتب', $1, $2, 100)`, [OFFICE.lat, OFFICE.lng]);
  for (const t of [c.t.e1, c.t.e3]) assert.equal((await h.call(t, 'POST', '/attendance/check-in', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 })).status, 201);
});
after(async () => { await h.close(); });
const me = async (t: string) => (await h.call(t, 'GET', '/me')).body.permissions as string[];

test('/me: location for attendance readers only, export for everyone (as before)', async () => {
  assert.ok((await me(c.t.sm1)).includes('attendance.view_location'));
  assert.ok(!(await me(c.t.e1)).includes('attendance.view_location'));
  for (const t of [c.t.owner, c.t.hr, c.t.sm1, c.t.e1]) assert.ok((await me(t)).includes('report.export'));
});

test('every attendance read is scoped on the server (direct API access)', async () => {
  for (const [p, ok] of [[`/attendance?employeeId=${c.ids.e1}`, 200], [`/attendance/range?employeeId=${c.ids.e1}&from=2026-03-01&to=2026-03-31`, 200],
    [`/tracking/employee/${c.ids.e1}`, 200]] as const) {
    assert.equal((await h.call(c.t.sm1, 'GET', p)).status, ok, `team manager: ${p}`);
    assert.equal((await h.call(c.t.sm2, 'GET', p)).status, 404, `other team: ${p}`);
    assert.equal((await h.call(c.t.e2, 'GET', p)).status, 404, `colleague: ${p}`);
  }
  for (const p of ['/attendance/board', '/attendance/issues', '/tracking/live']) assert.equal((await h.call(c.t.e1, 'GET', p)).status, 403, p);
  const board = (await h.call(c.t.sm1, 'GET', '/attendance/board')).body;
  assert.ok(!JSON.stringify(board).includes(c.ids.e3), 'the board lists his teams only');
});

test('check-in place: own and readers with the location permission; restricted at once with it', async () => {
  const day = async (t: string) => (await h.call(t, 'GET', `/attendance/range?employeeId=${c.ids.e1}&from=2026-03-10&to=2026-03-10`)).body.days[0];
  assert.equal(Number((await day(c.t.e1)).checkInLat), OFFICE.lat);
  assert.equal(Number((await day(c.t.sm1)).checkInLat), OFFICE.lat);
  // before 066 the location permission follows attendance.read_team: restricting that closes the page for him
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'attendance.read_team', false)`, [c.ids.sm1]);
  assert.equal((await h.call(c.t.sm1, 'GET', `/tracking/employee/${c.ids.e1}`)).status, 404);
  assert.equal((await h.call(c.t.sm1, 'GET', '/tracking/live')).status, 403);
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.sm1]);
});

test('corrections: only with attendance.correct, never your own, and only within your reading scope', async () => {
  const body = (id: string) => ({ employeeId: id, workDate: '2026-03-09', checkIn: '10:00', checkOut: '18:00', reason: 'نسي البصمة' });
  assert.equal((await h.call(c.t.sm1, 'POST', '/attendance/corrections', body(c.ids.e1))).status, 403, 'no attendance.correct');
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'attendance.correct', true)`, [c.ids.sm1]);
  assert.equal((await h.call(c.t.sm1, 'POST', '/attendance/corrections', body(c.ids.e3))).status, 404, 'other team');
  assert.equal((await h.call(c.t.sm1, 'POST', '/attendance/corrections', body(c.ids.sm1))).status, 403, 'own');
  assert.equal((await h.call(c.t.sm1, 'POST', '/attendance/corrections', body(c.ids.e1))).status, 201, 'his team');
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.sm1]);
  assert.equal((await h.call(c.t.hr, 'POST', '/attendance/corrections', { ...body(c.ids.e3), workDate: '2026-03-08' })).status, 201, 'HR: everyone');
});

test('exports and configuration need their permissions', async () => {
  assert.equal((await h.call(c.t.e1, 'GET', '/reports/monthly.xlsx?month=2026-03')).status, 200, 'his own report, as before');
  assert.equal((await h.call(c.t.e1, 'GET', '/reports/payroll.xlsx?month=2026-03')).status, 403);
  for (const [m, p, b] of [['POST', '/holidays', { date: '2026-04-01', name: 'x' }], ['POST', '/work-locations', { name: 'x', lat: 30, lng: 31, radiusM: 50 }],
    ['POST', '/schedules', { name: 'x' }]] as const) {
    assert.equal((await h.call(c.t.sm1, m, p, b)).status, 403, p);
  }
});
