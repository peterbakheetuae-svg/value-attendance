// G2 + T2 (security re-verification 2026-11-24):
//  - T2: checked in and not ONE location since → the watchers hear «التتبع مش شغال» (before: only his own phone rang);
//    once per day, delayed points count, a silence after pings resume is the usual «التتبع وقف», with the likely cause
//  - G2: a fix worse than 200 m is never «inside»: unknown on the board, no exit alarm from it, and a run of them since
//    the last usable fix warns the watchers (tracking_weak_gps) — one poor sample never does
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
// 2026-03-10 Tue, Cairo UTC+2, schedule 10:00–18:00 local. Office radius 100 m, margin 50 m.
const OFFICE = { lat: 30.0286, lng: 31.4085 };
const FAR = { lat: OFFICE.lat + 0.01, lng: OFFICE.lng }; // ~1.1 km
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ('المكتب', $1, $2, 100)`, [OFFICE.lat, OFFICE.lng]);
  await h.call(c.t.owner, 'PATCH', '/settings', { trackingEnabled: true, trackingStaleMinutes: 20, awayMarginM: 50, checkinReminderMinutes: 0 });
});
after(async () => { await h.close(); });
const at = (iso: string) => { h.now.value = new Date(iso); };
const sweep = () => h.call(c.t.hr, 'GET', '/tracking/live');
const count = async (to: string, type: string, about: string) =>
  (await h.db.query(`SELECT count(*)::int AS n FROM notifications WHERE recipient_id = $1 AND type = $2 AND entity_id = $3`, [to, type, about])).rows[0].n as number;
const bodies = async (to: string, type: string, about: string) =>
  (await h.db.query(`SELECT body FROM notifications WHERE recipient_id = $1 AND type = $2 AND entity_id = $3 ORDER BY created_at`, [to, type, about])).rows.map((r) => r.body as string);
const ping = (tok: string, p: { lat: number; lng: number }, accuracyM: number, extra: Record<string, unknown> = {}) =>
  h.call(tok, 'POST', '/tracking/ping', { ...p, accuracyM, ...extra });

test('accuracy boundary: 200 m is a usable fix, 201 m is unknown (never inside, never an exit)', async () => {
  at('2026-03-10T08:00:00Z');
  for (const t of [c.t.e1, c.t.e2, c.t.solo]) assert.equal((await h.call(t, 'POST', '/attendance/check-in', {})).status, 201);
  assert.equal((await ping(c.t.e2, OFFICE, 200)).body.inside, true, '200 m at the office');
  at('2026-03-10T08:01:00Z');
  assert.equal((await ping(c.t.e2, OFFICE, 201)).body.inside, null, '201 m at the office: unknown');
  at('2026-03-10T08:02:00Z');
  assert.equal((await ping(c.t.e2, FAR, 5000)).body.inside, null, 'far away with 5 km accuracy: unknown, not an exit');
  assert.equal(await count(c.ids.sm1, 'unauthorized_exit', c.ids.e2), 0, 'one poor sample raises no alarm');
  // evidence kept: every point with its accuracy and time
  const pts = (await h.call(c.t.sm1, 'GET', `/tracking/employee/${c.ids.e2}`)).body.points;
  assert.deepEqual(pts.map((p: any) => Number(p.accuracy_m)), [200, 201, 5000]);
  // the board does not show him «inside» on a weak last fix
  const row = (await h.call(c.t.sm1, 'GET', '/tracking/live')).body.live.find((x: any) => x.employeeId === c.ids.e2);
  assert.equal(row.inside, null);
  assert.equal(row.weakGps, true);
  at('2026-03-10T08:03:00Z');
  await ping(c.t.e2, OFFICE, 15);
  const back = (await h.call(c.t.sm1, 'GET', '/tracking/live')).body.live.find((x: any) => x.employeeId === c.ids.e2);
  assert.deepEqual([back.inside, back.weakGps], [true, false], 'a usable fix again');
});

test('T2: checked in, no location at all → the watchers are told once (with the likely cause); not before the stale time', async () => {
  // E1 checked in at 08:00 and never sent a location
  at('2026-03-10T08:10:00Z');
  await sweep();
  assert.equal(await count(c.ids.hr, 'tracking_stopped', c.ids.e1), 0, '10 min: not yet');
  at('2026-03-10T08:21:00Z');
  await sweep();
  assert.equal(await count(c.ids.hr, 'tracking_stopped', c.ids.e1), 1, 'HR told');
  assert.equal(await count(c.ids.sm1, 'tracking_stopped', c.ids.e1), 1, 'his team manager told');
  assert.equal(await count(c.ids.sm2, 'tracking_stopped', c.ids.e1), 0, 'another team manager not told');
  assert.match((await bodies(c.ids.hr, 'tracking_stopped', c.ids.e1))[0], /مفيش ولا موقع وصل/);
  assert.match((await bodies(c.ids.hr, 'tracking_stopped', c.ids.e1))[0], /مفيش موبايل أندرويد/, 'cause: no tracking phone signed in');
  // no spam: later sweeps the same day add nothing
  for (const t of ['2026-03-10T08:30:00Z', '2026-03-10T08:45:00Z']) { at(t); await sweep(); }
  assert.equal(await count(c.ids.hr, 'tracking_stopped', c.ids.e1), 1, 'deduplicated');
});

test('T2: recovery, then a delayed (offline) point, then a real silence → one new alert', async () => {
  at('2026-03-10T08:50:00Z');
  assert.equal((await ping(c.t.e1, OFFICE, 10)).body.inside, true, 'pings resume');
  let row = (await sweep()).body.live.find((x: any) => x.employeeId === c.ids.e1);
  assert.equal(row.stopped, false);
  // a point recorded offline at 09:05 arrives at 09:12: it counts as tracking at 09:05
  at('2026-03-10T09:12:00Z');
  assert.equal((await ping(c.t.e1, OFFICE, 10, { offlineAt: '2026-03-10T09:05:00Z' })).status, 200);
  at('2026-03-10T09:20:00Z');
  await sweep();
  assert.equal(await count(c.ids.hr, 'tracking_stopped', c.ids.e1), 1, '15 min after the delayed point: no alert');
  // then really silent: 21 minutes after the last point
  at('2026-03-10T09:26:00Z');
  await sweep();
  assert.equal(await count(c.ids.hr, 'tracking_stopped', c.ids.e1), 2, 'a new silence → a new alert');
  assert.match((await bodies(c.ids.hr, 'tracking_stopped', c.ids.e1))[1], /آخر موقع من 21 دقيقة/);
  at('2026-03-10T09:35:00Z');
  await sweep();
  assert.equal(await count(c.ids.hr, 'tracking_stopped', c.ids.e1), 2, 'deduplicated');
  row = (await sweep()).body.live.find((x: any) => x.employeeId === c.ids.e1);
  assert.equal(row.stopped, true);
});

test('T2: nobody is told about an employee who is not followed («تتبع أثناء العمل» off)', async () => {
  await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.e3}`, { workTracking: false });
  at('2026-03-10T09:40:00Z');
  assert.equal((await h.call(c.t.e3, 'POST', '/attendance/check-in', {})).status, 201);
  at('2026-03-10T10:30:00Z');
  await sweep();
  assert.equal(await count(c.ids.hr, 'tracking_stopped', c.ids.e3), 0);
});

test('G2: a run of weak fixes warns the watchers; one or two never do; a usable fix ends it', async () => {
  // SOLO checked in at 08:00 (no location until now — the T2 alert of the morning is not counted below);
  // one usable fix at the office, then weak ones far away
  const stoppedBefore = await count(c.ids.hr, 'tracking_stopped', c.ids.solo);
  at('2026-03-10T10:31:00Z');
  assert.equal((await ping(c.t.solo, OFFICE, 10)).body.inside, true);
  for (const t of ['2026-03-10T10:36:00Z', '2026-03-10T10:41:00Z']) { at(t); assert.equal((await ping(c.t.solo, FAR, 1500)).body.inside, null); }
  at('2026-03-10T10:52:00Z'); // 21 min since the usable fix, only 2 weak ones
  await sweep();
  assert.equal(await count(c.ids.hr, 'tracking_weak_gps', c.ids.solo), 0, 'two weak fixes: no warning');
  at('2026-03-10T10:53:00Z');
  await ping(c.t.solo, FAR, 1500); // the third
  at('2026-03-10T10:54:00Z');
  await sweep();
  assert.equal(await count(c.ids.hr, 'tracking_weak_gps', c.ids.solo), 1, 'a run of weak fixes → warning');
  assert.match((await bodies(c.ids.hr, 'tracking_weak_gps', c.ids.solo))[0], /مش معروف هو جوه ولا بره/);
  assert.equal(await count(c.ids.hr, 'unauthorized_exit', c.ids.solo), 0, 'never an exit alarm from weak fixes');
  assert.equal(await count(c.ids.hr, 'tracking_stopped', c.ids.solo), stoppedBefore, 'locations do arrive: not «stopped»');
  for (const t of ['2026-03-10T11:00:00Z', '2026-03-10T11:05:00Z']) { at(t); await ping(c.t.solo, FAR, 1500); await sweep(); }
  assert.equal(await count(c.ids.hr, 'tracking_weak_gps', c.ids.solo), 1, 'deduplicated');
  const row = (await h.call(c.t.hr, 'GET', '/tracking/live')).body.live.find((x: any) => x.employeeId === c.ids.solo);
  assert.deepEqual([row.inside, row.weakGps], [null, true], 'shown as unknown, not inside');
  // a usable fix ends it: the board is right again
  at('2026-03-10T11:06:00Z');
  assert.equal((await ping(c.t.solo, OFFICE, 12)).body.inside, true);
  const ok = (await h.call(c.t.hr, 'GET', '/tracking/live')).body.live.find((x: any) => x.employeeId === c.ids.solo);
  assert.deepEqual([ok.inside, ok.weakGps], [true, false]);
});

test('G2: a usable fix outside after weak ones is a real exit (the alarm still works)', async () => {
  at('2026-03-10T11:10:00Z');
  assert.equal((await ping(c.t.solo, FAR, 20)).body.inside, false);
  assert.equal(await count(c.ids.hr, 'unauthorized_exit', c.ids.solo), 1);
  // a weak fix after the exit proves no return: the board keeps him outside
  at('2026-03-10T11:12:00Z');
  await ping(c.t.solo, OFFICE, 900);
  const row = (await h.call(c.t.hr, 'GET', '/tracking/live')).body.live.find((x: any) => x.employeeId === c.ids.solo);
  assert.equal(row.inside, false);
});
