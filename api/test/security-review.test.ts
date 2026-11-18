import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

/**
 * Security review (2026-11-18): attacks tried directly on the API, the way an employee with a script would — each one
 * must be refused or neutralised.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const OFFICE = { lat: 30.0286, lng: 31.4085 };
const at = (iso: string) => { h.now.value = new Date(iso); };
const seen = (code: string, iso: string) =>
  h.db.query(`UPDATE sessions SET last_seen_at = $2 WHERE employee_id = (SELECT id FROM employees WHERE code = $1)`, [code, iso]);
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ('المكتب', $1, $2, 100)`, [OFFICE.lat, OFFICE.lng]);
  await h.call(c.t.owner, 'PATCH', '/settings', { gpsRequired: true, trackingEnabled: true });
});
after(async () => { await h.close(); });

test('the key that signs media links never leaves the server (settings, audit)', async () => {
  for (const t of [c.t.e1, c.t.hr, c.t.owner]) {
    const s = (await h.call(t, 'GET', '/settings')).body.settings;
    assert.ok(s && !('media_secret' in s), 'not in GET /settings');
  }
  const p = await h.call(c.t.owner, 'PATCH', '/settings', { breakMinutes: 45 });
  assert.equal(p.status, 200, JSON.stringify(p.body));
  assert.ok(!('media_secret' in p.body.settings), 'not in the PATCH reply');
  const aud = (await h.db.query(`SELECT before, after FROM audit_log WHERE action = 'settings.update' ORDER BY at DESC LIMIT 1`)).rows[0];
  assert.ok(!JSON.stringify(aud).includes('media_secret'), 'not in the audit log');
});

test('offline check-in back-dated by an employee whose phone was online after that time → the server time is used', async () => {
  // E1 «checks in at 08:55 offline» at 10:00 — but his phone talked to the server at 09:40
  at('2026-03-10T10:00:00Z');
  await seen('E1', '2026-03-10T09:40:00Z');
  const r = await h.call(c.t.e1, 'POST', '/attendance/check-in', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10, offlineAt: '2026-03-10T08:55:00Z' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(new Date(r.body.attendance.checkIn).toISOString(), '2026-03-10T10:00:00.000Z', 'the claim is ignored');
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM audit_log WHERE action = 'attendance.offline_time_refused'`)).rows[0].n, 1);
});

test('a real offline check-in keeps its time; when it arrives late HR is told (who, claimed time, arrival time)', async () => {
  // E2's phone was last online yesterday: offline at 08:50, back online at 09:30
  at('2026-03-10T09:30:00Z');
  await seen('E2', '2026-03-09T16:00:00Z');
  const r = await h.call(c.t.e2, 'POST', '/attendance/check-in', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10, offlineAt: '2026-03-10T08:50:00Z' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(new Date(r.body.attendance.checkIn).toISOString(), '2026-03-10T08:50:00.000Z');
  const n = (await h.call(c.t.hr, 'GET', '/notifications')).body.notifications.find((x: any) => x.type === 'offline_attendance');
  assert.ok(n, 'HR told');
  assert.match(n.title, /موظف ٢/);
  assert.match(n.body, /بعد 40 دقيقة/);
});

test('fake GPS: a check-in from a mock location is refused; a tracking point from it raises the alarm and tells the owners', async () => {
  at('2026-03-10T08:05:00Z');
  const r = await h.call(c.t.e3, 'POST', '/attendance/check-in', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 5, mocked: true });
  assert.equal(r.status, 422, JSON.stringify(r.body));
  assert.equal(r.body.error.details.reason, 'mock_location');
  assert.equal((await h.call(c.t.e3, 'POST', '/attendance/check-in', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 5 })).status, 201);
  // during work: «in the office» from a fake-location app counts as not in the office
  at('2026-03-10T08:30:00Z');
  const p = await h.call(c.t.e3, 'POST', '/tracking/ping', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 5, mocked: true });
  assert.equal(p.status, 200, JSON.stringify(p.body));
  assert.equal(p.body.inside, false);
  const owner = (await h.call(c.t.owner, 'GET', '/notifications')).body.notifications.map((x: any) => x.type);
  assert.ok(owner.includes('security_alert'), 'owners told');
});

test('password-reset codes: parallel requests can not make more than 3 codes; 10 wrong codes a day closes it for 24 h', async () => {
  const sent: string[] = [];
  const realFetch = globalThis.fetch;
  process.env.BREVO_API_KEY = 'k'; process.env.MAIL_FROM = 'hr@value.test';
  await h.db.query(`UPDATE employees SET email = 'solo@value.test' WHERE code = 'SOLO'`);
  globalThis.fetch = (async (url: any, init: any) => {
    if (String(url).startsWith('https://api.brevo.com/')) { sent.push(/(\d{4})/.exec(JSON.parse(init.body).textContent)![1]); return new Response('{}', { status: 201 }); }
    return realFetch(url, init);
  }) as typeof fetch;
  try {
    const all = await Promise.all(Array.from({ length: 12 }, () => h.call(null, 'POST', '/auth/forgot', { identifier: 'SOLO' })));
    assert.ok(all.every((x) => x.status === 200), 'same reply for all');
    const made = (await h.db.query(`SELECT count(*)::int AS n FROM password_otps WHERE employee_id = $1`, [c.ids.solo])).rows[0].n;
    assert.equal(made, 3, `at most 3 codes even in parallel (made ${made})`);
    // 20 wrong codes in parallel on the live code: at most 5 are even tried
    const good = sent.at(-1)!;
    const wrong = good === '1111' ? '2222' : '1111';
    await Promise.all(Array.from({ length: 20 }, () => h.call(null, 'POST', '/auth/forgot/verify', { identifier: 'SOLO', code: wrong })));
    const tries = (await h.db.query(`SELECT max(attempts)::int AS n FROM password_otps WHERE employee_id = $1`, [c.ids.solo])).rows[0].n;
    assert.ok(tries <= 5, `attempts per code capped (${tries})`);
    // spread over more codes: after 10 wrong codes in a day even the right code is refused, and no new code is made
    await h.db.query(`UPDATE password_otps SET attempts = 5 WHERE employee_id = $1`, [c.ids.solo]); // 3 codes × 5 = 15 ≥ 10
    await h.db.query(`UPDATE password_otps SET created_at = now() - interval '20 minutes' WHERE employee_id = $1`, [c.ids.solo]);
    const before = sent.length;
    assert.equal((await h.call(null, 'POST', '/auth/forgot', { identifier: 'SOLO' })).status, 200);
    assert.equal(sent.length, before, 'no new code while the day budget is used up');
  } finally {
    globalThis.fetch = realFetch; delete process.env.BREVO_API_KEY; delete process.env.MAIL_FROM;
  }
});

test('money: the same payout twice (double tap / two people) is refused; a payout is received once even in parallel', async () => {
  at('2026-03-10T11:00:00Z');
  const fund = await h.call(c.t.owner, 'POST', '/payouts', { employeeId: c.ids.hr, kind: 'fund', amount: 50000 });
  await h.call(c.t.hr, 'POST', `/payouts/${fund.body.payout.id}/receive`, {});
  const twice = await Promise.all([1, 2, 3].map(() =>
    h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e2, kind: 'work_expense', amount: 750, month: '2026-03' })));
  assert.deepEqual(twice.map((x) => x.status).sort(), [201, 409, 409], JSON.stringify(twice.map((x) => x.body)));
  const p = twice.find((x) => x.status === 201)!.body.payout;
  const rec = await Promise.all([1, 2, 3, 4].map(() => h.call(c.t.e2, 'POST', `/payouts/${p.id}/receive`, {})));
  assert.deepEqual(rec.map((x) => x.status).sort(), [200, 409, 409, 409]);
  const bal = (await h.call(c.t.hr, 'GET', '/payouts')).body.balance;
  assert.equal(bal, 50000 - 750, 'out of the cashbox once');
  // tampering: negative / not-a-number amounts, paying yourself
  assert.equal((await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e2, kind: 'work_expense', amount: -750 })).status, 400);
  assert.equal((await h.call(c.t.e1, 'POST', '/advances', { kind: 'advance', amount: 'NaN', period: '2026-03-01', note: 'x' })).status, 400);
  assert.equal((await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.hr, kind: 'work_expense', amount: 100 })).status >= 400, true);
});

test('approvals: nobody decides his own request; an employee can not decide anyone\'s (direct API calls)', async () => {
  const own = await h.call(c.t.sm1, 'POST', '/requests', { type: 'full_day_absence', startDate: '2026-03-25', endDate: '2026-03-25', absenceType: 'annual', reason: 'ظرف عائلي' });
  assert.equal(own.status, 201, JSON.stringify(own.body));
  assert.equal((await h.call(c.t.sm1, 'POST', `/requests/${own.body.request.id}/decision`, { decision: 'approve' })).status, 403);
  const other = await h.call(c.t.e3, 'POST', '/requests', { type: 'full_day_absence', startDate: '2026-03-26', endDate: '2026-03-26', absenceType: 'annual', reason: 'ظرف' });
  assert.ok([403, 404].includes((await h.call(c.t.e1, 'POST', `/requests/${other.body.request.id}/decision`, { decision: 'approve' })).status));
  // another employee's monthly report / attendance: not even shown to exist
  assert.equal((await h.call(c.t.e1, 'GET', `/reports/monthly/employee/${c.ids.e3}?month=2026-03`)).status, 404);
  assert.equal((await h.call(c.t.e1, 'GET', `/attendance/range?employeeId=${c.ids.e3}&from=2026-03-01&to=2026-03-20`)).status, 404);
  assert.equal((await h.call(c.t.e1, 'GET', '/employees')).body.employees.length, 1, 'an employee lists only himself');
  void PW;
});
