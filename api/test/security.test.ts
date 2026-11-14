import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { buildRouter } from '../src/app.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness(); c = await cast(h); });
after(async () => { await h.close(); });

// /media is public by design but needs a valid HMAC signature (checked below)
const PUBLIC = new Set(['GET /healthz', 'GET /healthz/latency', 'GET /readyz', 'POST /auth/login', 'GET /media/:kind/:id',
  // forgot password: anonymous by nature, protected by emailed OTP + rate limits
  'POST /auth/forgot', 'POST /auth/forgot/verify', 'POST /auth/forgot/reset',
  // a campaign's public lead form: anonymous by nature, needs its secret token (tested in leads2.test.ts)
  'GET /f/:token', 'POST /public/leads/:token']);
const FAKE_ID = '00000000-0000-4000-8000-000000000000';

test('every non-public route rejects anonymous callers with 401', async () => {
  const routes = buildRouter({ db: h.db, clock: () => new Date() }).list();
  assert.ok(routes.length > 60, `expected a full route table, got ${routes.length}`);
  const failures: string[] = [];
  for (const r of routes) {
    if (PUBLIC.has(r)) continue;
    const [method, path] = r.split(' ');
    const url = path.replace(/:[a-zA-Z]+/g, (m) => (m === ':key' ? 'hr_manager' : FAKE_ID)) + (path.includes('month') ? '' : '?month=2026-03');
    const res = await h.call(null, method, url, method === 'GET' ? undefined : {});
    if (res.status !== 401) failures.push(`${r} → ${res.status}`);
  }
  assert.deepEqual(failures, []);
});

test('signed media: unsigned, forged or expired links are 404; a fresh link works', async () => {
  await h.db.query(`UPDATE employees SET photo = '\\xffd8ffd9', photo_mime = 'image/jpeg' WHERE id = $1`, [c.ids.e1]);
  assert.equal((await h.call(null, 'GET', `/media/photo/${c.ids.e1}`)).status, 404);
  assert.equal((await h.call(null, 'GET', `/media/photo/${c.ids.e1}?exp=9999999999&sig=AAAA`)).status, 404);
  const links = await h.call(c.t.e2, 'POST', '/media/links', { photos: [c.ids.e1] });
  const url = links.body.links[`photo:${c.ids.e1}`];
  assert.ok(url);
  const r = await h.call(null, 'GET', url);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('content-type'), 'image/jpeg');
  assert.equal((await h.call(null, 'GET', url.replace(/exp=\d+/, 'exp=1000'))).status, 404, 'expired / tampered');
});

test('a sales employee is refused (403/404) on every management route', async () => {
  const mgmt: [string, string, unknown?][] = [
    ['POST', '/employees', { code: 'ZZ', fullName: 'zz', role: 'sales_employee' }],
    ['PATCH', `/employees/${c.ids.e2}`, { fullName: 'hack' }],
    ['POST', `/employees/${c.ids.e2}/status`, { status: 'inactive' }],
    ['POST', `/employees/${c.ids.e2}/reset-password`, {}],
    ['PUT', `/employees/${c.ids.e2}/salary`, { baseSalary: 1 }],
    ['GET', `/employees/${c.ids.e2}/history`],
    ['POST', '/departments', { nameAr: 'قسم' }],
    ['POST', '/teams', { name: 'فريق' }],
    ['POST', '/schedules', { name: 'x', startTime: '09:00', endTime: '17:00' }],
    ['POST', '/holidays', { day: '2026-04-01', name: 'x' }],
    ['POST', '/work-locations', { name: 'x', lat: 1, lng: 1, radiusM: 100 }],
    ['PATCH', '/settings', { gpsRequired: true }],
    ['GET', '/roles'],
    ['PUT', '/roles/accountant/permissions', { permissions: [] }],
    ['GET', '/audit'],
    ['GET', '/attendance/board'],
    ['GET', '/attendance/issues'],
    ['POST', '/attendance/corrections', { employeeId: c.ids.e2, workDate: '2026-03-09', checkIn: '10:00', reason: 'xxx' }],
    ['POST', '/kpi/definitions', { key: 'zz', nameAr: 'zz', measurementType: 'count' }],
    ['POST', '/kpi/sets', {}],
    ['GET', '/kpi/sets'],
    ['GET', '/kpi/overview'],
    ['GET', '/reports/payroll?month=2026-03'],
    ['GET', '/reports/payroll.xlsx?month=2026-03'],
    ['GET', '/finance/adjustments'],
    ['POST', '/finance/adjustments', { employeeId: c.ids.e2, month: '2026-03', kind: 'bonus', amountEgp: 1, reason: 'xxx' }],
    ['PUT', `/leave-balances/${c.ids.e2}`, { year: 2026, annualDays: 1, casualDays: 1, sickDays: 1 }],
    ['GET', `/kpi/employees/${c.ids.e2}`],
    ['GET', `/evaluations?employeeId=${c.ids.e2}`],
    ['GET', `/attendance?month=2026-03&employeeId=${c.ids.e2}`],
  ];
  const leaks: string[] = [];
  for (const [m, p, b] of mgmt) {
    const r = await h.call(c.t.e1, m, p, b);
    if (![403, 404].includes(r.status)) leaks.push(`${m} ${p} → ${r.status}`);
  }
  assert.deepEqual(leaks, []);
  // the employee's own report list never contains anyone else
  const rep = await h.call(c.t.e1, 'GET', '/reports/monthly?month=2026-03');
  assert.deepEqual(rep.body.reports.map((x: any) => x.employee.id), [c.ids.e1]);
  assert.equal(rep.body.reports[0].money, undefined);
});

test('malformed input is rejected cleanly, never 500', async () => {
  const cases: [string, string, unknown][] = [
    ['POST', '/requests', { type: 'hourly_permission', day: 'not-a-date', fromTime: '10:00', toTime: '11:00', reason: 'xxx' }],
    ['POST', '/requests', { type: 'teleport', reason: 'xxx' }],
    ['POST', '/requests', 'just a string'],
    ['GET', '/attendance?month=2026-13', undefined],
    ['GET', `/employees/not-a-uuid`, undefined],
    ['POST', '/attendance/check-in', { lat: 'north' }],
  ];
  for (const [m, p, b] of cases) {
    const r = await h.call(c.t.e1, m, p, b);
    assert.ok(r.status >= 400 && r.status < 500, `${m} ${p} → ${r.status}`);
  }
  const res = await fetch(h.base + '/requests', { method: 'POST', headers: { authorization: `Bearer ${c.t.e1}`, 'content-type': 'application/json' }, body: '{bad json' });
  assert.equal(res.status, 400);
});

test('CORS: only configured origins are echoed', async () => {
  const ok = await fetch(h.base + '/healthz', { headers: { origin: 'http://ok.test' } });
  assert.equal(ok.headers.get('access-control-allow-origin'), 'http://ok.test');
  const bad = await fetch(h.base + '/healthz', { headers: { origin: 'http://evil.test' } });
  assert.equal(bad.headers.get('access-control-allow-origin'), null);
});

test('passwords are stored as scrypt hashes and never returned', async () => {
  const r = await h.db.query(`SELECT password_hash FROM employees LIMIT 1`);
  assert.match(r.rows[0].password_hash, /^scrypt\$/);
  const me = await h.call(c.t.hr, 'GET', `/employees/${c.ids.e1}`);
  assert.equal(JSON.stringify(me.body).includes('scrypt$'), false);
  const list = await h.call(c.t.hr, 'GET', '/employees');
  assert.equal(JSON.stringify(list.body).includes('password'), false);
});
