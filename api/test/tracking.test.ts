import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
// 2026-03-10 Tue, Cairo UTC+2, schedule 10:00–18:00. Office at Cairo Festival City, radius 100 m.
const OFFICE = { lat: 30.0286, lng: 31.4085 };
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ('المكتب', $1, $2, 100)`, [OFFICE.lat, OFFICE.lng]);
});
after(async () => { await h.close(); });
const at = (iso: string) => { h.now.value = new Date(iso); };
const notes = async (tok: string) => (await h.call(tok, 'GET', '/notifications')).body.notifications.map((n: any) => n.type) as string[];

test('tracking is off by default and only runs between check-in and check-out', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', '/tracking/ping', { lat: OFFICE.lat, lng: OFFICE.lng })).body.tracking, false);
  await h.call(c.t.owner, 'PATCH', '/settings', { trackingEnabled: true, trackingStaleMinutes: 20, awayMarginM: 50, checkinReminderMinutes: 30 });
  assert.equal((await h.call(c.t.e1, 'POST', '/tracking/ping', { lat: OFFICE.lat, lng: OFFICE.lng })).status, 409, 'not checked in');
});

test('leaving and returning to the office alerts HR and the team manager, not other managers', async () => {
  at('2026-03-10T08:00:00Z');
  await h.call(c.t.e1, 'POST', '/attendance/check-in', {});
  assert.equal((await h.call(c.t.e1, 'POST', '/tracking/ping', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 })).body.inside, true);
  at('2026-03-10T09:00:00Z');
  const away = await h.call(c.t.e1, 'POST', '/tracking/ping', { lat: OFFICE.lat + 0.01, lng: OFFICE.lng, accuracyM: 10 }); // ~1.1 km
  assert.equal(away.body.inside, false);
  assert.ok((await notes(c.t.hr)).includes('left_office'));
  assert.ok((await notes(c.t.sm1)).includes('left_office'));
  assert.ok(!(await notes(c.t.sm2)).includes('left_office'), 'other team manager not told');
  at('2026-03-10T09:30:00Z');
  await h.call(c.t.e1, 'POST', '/tracking/ping', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 });
  assert.ok((await notes(c.t.sm1)).includes('back_in_office'));
  const live = await h.call(c.t.sm1, 'GET', '/tracking/live');
  const row = live.body.live.find((x: any) => x.employeeId === c.ids.e1);
  assert.equal(row.awayMinutesToday, 30);
  assert.equal(row.inside, true);
  assert.equal((await h.call(c.t.e2, 'GET', '/tracking/live')).status, 403, 'employees cannot see the board');
  assert.equal((await h.call(c.t.sm2, 'GET', `/tracking/employee/${c.ids.e1}`)).status, 404, 'other team');
  assert.equal((await h.call(c.t.sm1, 'GET', `/tracking/employee/${c.ids.e1}`)).body.points.length, 3);
});

test('weak GPS never counts as leaving', async () => {
  at('2026-03-10T09:40:00Z');
  const r = await h.call(c.t.e1, 'POST', '/tracking/ping', { lat: OFFICE.lat + 0.01, lng: OFFICE.lng, accuracyM: 900 });
  assert.equal(r.body.inside, null);
});

test('sweep: missing check-in reminder + tracking stopped alert (deduplicated)', async () => {
  at('2026-03-10T10:20:00Z'); // 12:20 local, 2h20m after start
  await h.call(c.t.hr, 'GET', '/tracking/live');
  assert.ok((await notes(c.t.e2)).includes('checkin_reminder'), 'E2 never checked in');
  assert.ok((await notes(c.t.sm1)).includes('not_checked_in'));
  assert.ok((await notes(c.t.hr)).includes('tracking_stopped'), 'E1 silent for 40 min');
  at('2026-03-10T10:30:00Z');
  await h.call(c.t.hr, 'GET', '/tracking/live');
  const n = (await notes(c.t.e2)).filter((x) => x === 'checkin_reminder').length;
  assert.equal(n, 1, 'reminded once per day');
});
