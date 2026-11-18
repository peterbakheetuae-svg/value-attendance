import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { harness, cast, PW, type Harness } from './helpers.ts';

/**
 * Independent review (2026-11-18): each finding reproduced exactly as the reviewer ran it — now refused.
 */
const HOST_KEY = Buffer.alloc(32, 5).toString('base64');
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let tGm = '';
const OFFICE = { lat: 30.0286, lng: 31.4085 };
const at = (iso: string) => { h.now.value = new Date(iso); };
before(async () => {
  process.env.SECRETS_KEY = HOST_KEY;
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ('المكتب', $1, $2, 100)`, [OFFICE.lat, OFFICE.lng]);
  await h.call(c.t.owner, 'PATCH', '/settings', { gpsRequired: true });
  await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE code = 'GM1'`);
  tGm = await h.login('GM1', PW);
});
after(async () => { delete process.env.SECRETS_KEY; await h.close(); });

test('#1 media links: the leaked database key alone signs nothing; a link can not be made to live past 24 h', async () => {
  const ci = await h.call(c.t.e3, 'POST', '/attendance/check-in', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 });
  assert.equal(ci.status, 201, JSON.stringify(ci.body));
  const att = { id: ci.body.attendance.id as string };
  await h.db.query(`INSERT INTO attendance_selfies (attendance_id, employee_id, image, mime) VALUES ($1,$2,'\\xffd8ffd9','image/jpeg')`, [att.id, c.ids.e3]);
  const leaked = (await h.db.query(`SELECT media_secret FROM company_settings`)).rows[0].media_secret as string;
  const now = Math.floor(h.now.value.getTime() / 1000);
  const forge = (key: Buffer | string, exp: number) =>
    `/media/selfie/${att.id}?exp=${exp}&v=${c.ids.owner}&sig=${createHmac('sha256', key).update(`selfie:${att.id}:${exp}:${c.ids.owner}`).digest('base64url')}`;
  // signed with the leaked key (what an old backup / the old settings reply gave): refused
  assert.notEqual((await h.call(null, 'GET', forge(leaked, now + 3600))).status, 200);
  // even with the real key, a link that lives until 2100 is refused
  const real = createHmac('sha256', Buffer.from(HOST_KEY, 'base64')).update('media-links:' + leaked).digest();
  assert.equal((await h.call(null, 'GET', forge(real, now + 3600))).status, 200, 'control: a proper link works');
  assert.notEqual((await h.call(null, 'GET', forge(real, 4102444800))).status, 200);
  // old settings.update audit rows: the key is never shown
  await h.db.query(`INSERT INTO audit_log (actor_id, action, entity, before, after) VALUES ($1, 'settings.update', 'settings', $2, $2)`,
    [c.ids.owner, JSON.stringify({ media_secret: leaked, break_minutes: 60 })]);
  assert.ok(!JSON.stringify((await h.call(c.t.owner, 'GET', '/audit')).body).includes(leaked));
});

test('#2 offline: yesterday can not be filled in from the phone (HR is told); a small back-dating is reported to HR', async () => {
  at('2026-03-11T09:00:00Z');
  await h.call(c.t.e1, 'GET', '/me'); // the reviewer's bypass: be "seen" just before
  const y = await h.call(c.t.e1, 'POST', '/attendance/check-in', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10, offlineAt: '2026-03-10T06:00:00Z' });
  assert.equal(y.status, 409, JSON.stringify(y.body));
  assert.equal(y.body.error.details.reason, 'offline_other_day');
  // 14 minutes back on the same day: accepted (it may be real) but HR sees it
  await h.call(c.t.e2, 'GET', '/me');
  const r = await h.call(c.t.e2, 'POST', '/attendance/check-in', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10, offlineAt: '2026-03-11T08:46:00Z' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const hr = (await h.call(c.t.hr, 'GET', '/notifications')).body.notifications.filter((x: any) => x.type === 'offline_attendance');
  assert.ok(hr.some((x: any) => /موظف ١/.test(x.title)), 'yesterday refused → HR told');
  assert.ok(hr.some((x: any) => /موظف ٢/.test(x.title) && /بعد 14 دقيقة/.test(x.body)), 'small back-dating told');
});

test('#3 login: 40 parallel wrong passwords lock the account (no burst past the lock)', async () => {
  const all = await Promise.all(Array.from({ length: 40 }, () => h.call(null, 'POST', '/auth/login', { identifier: 'SM2', password: 'wrong-pass-x' })));
  assert.ok(all.every((x) => x.status === 401 || x.status === 423), JSON.stringify(all.map((x) => x.status)));
  assert.ok(all.filter((x) => x.status === 401).length <= 5, `at most 5 passwords checked (${all.filter((x) => x.status === 401).length})`);
  const right = await h.call(null, 'POST', '/auth/login', { identifier: 'SM2', password: PW });
  assert.equal(right.status, 423, 'locked even with the right password');
});

test('#4 «I\'m back» from 20 km away is refused, offline or not', async () => {
  at('2026-03-11T10:00:00Z');
  at('2026-03-11T08:00:00Z');
  await h.call(c.t.e3, 'POST', '/attendance/check-in', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 });
  const o = await h.call(c.t.e3, 'POST', '/outings', { kind: 'visit', expectedReturn: '13:00', reason: 'معاينة شقة' });
  assert.equal(o.status, 201, JSON.stringify(o.body));
  assert.equal((await h.call(c.t.sm2, 'POST', `/outings/${o.body.outing.id}/decision`, { decision: 'approve' })).status, 200);
  at('2026-03-11T10:00:00Z');
  const far = { lat: 30.2, lng: 31.6, accuracyM: 10 };
  const online = await h.call(c.t.e3, 'POST', '/outings/return', far);
  const offline = await h.call(c.t.e3, 'POST', '/outings/return', { ...far, offlineAt: '2026-03-11T09:59:00Z' });
  assert.equal(online.status, 422, JSON.stringify(online.body));
  assert.equal(offline.status, 422, `offline from outside: ${JSON.stringify(offline.body)}`);
  // from the office it works
  assert.equal((await h.call(c.t.e3, 'POST', '/outings/return', { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10, offlineAt: '2026-03-11T09:59:00Z' })).status, 200);
});

test('#5 a month\'s salary is never paid twice (صرف الراتب then the approved sheet\'s line)', async () => {
  at('2026-04-02T09:00:00Z');
  await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 8000, $2)`, [c.ids.e2, c.ids.owner]);
  const fund = await h.call(tGm, 'POST', '/payouts', { employeeId: c.ids.hr, kind: 'fund', amount: 100000 });
  await h.call(c.t.hr, 'POST', `/payouts/${fund.body.payout.id}/receive`, {});
  const first = await h.call(c.t.hr, 'POST', '/payouts/salary', { employeeId: c.ids.e2, month: '2026-03' });
  assert.equal(first.status, 201, JSON.stringify(first.body));
  const b = await h.call(c.t.hr, 'POST', '/payroll-batches', { month: '2026-03' });
  assert.equal(b.status, 201, JSON.stringify(b.body));
  await h.call(c.t.hr, 'POST', `/payroll-batches/${b.body.batch.id}/submit`, {});
  assert.equal((await h.call(tGm, 'POST', `/payroll-batches/${b.body.batch.id}/decision`, { decision: 'approve' })).status, 200);
  const line = b.body.lines.find((l: any) => l.employeeId === c.ids.e2);
  const second = await h.call(c.t.hr, 'POST', `/payroll-batches/${b.body.batch.id}/lines/${line.id}/pay`, {});
  assert.equal(second.status, 409, JSON.stringify(second.body));
  const total = (await h.db.query(`SELECT sum(amount_egp)::numeric AS s FROM payouts WHERE employee_id = $1 AND kind = 'salary' AND status <> 'cancelled'`, [c.ids.e2])).rows[0].s;
  assert.equal(Number(total), Number(first.body.payout.amount_egp ?? first.body.payout.amount));
});
