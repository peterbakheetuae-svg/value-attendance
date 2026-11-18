import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, dev, PW, type Harness } from './helpers.ts';

/** Suspicious-activity alerts to the owners, photo-only attachments by real content, HSTS, safe paging. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness(); c = await cast(h); });
after(async () => { delete process.env.TRUST_PLATFORM_IP; await h.close(); });

const alerts = async () => (await h.db.query(
  `SELECT title, body FROM notifications WHERE recipient_id = $1 AND type = 'security_alert' ORDER BY created_at`, [c.ids.owner])).rows;

test('an account locked after 5 wrong passwords → the owners get one security alert (no password in it)', async () => {
  for (let i = 0; i < 5; i++) await h.call(null, 'POST', '/auth/login', { identifier: 'E3', password: 'wrong-pass-' + i, deviceId: dev('E3') });
  const six = await h.call(null, 'POST', '/auth/login', { identifier: 'E3', password: PW, deviceId: dev('E3') });
  assert.equal(six.status, 423, 'locked even with the right password');
  const a = await alerts();
  assert.equal(a.length, 1, JSON.stringify(a));
  assert.match(a[0].title, /حساب اتقفل/);
  assert.doesNotMatch(a[0].body, /wrong-pass/);
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM audit_log WHERE action = 'auth.locked'`)).rows[0].n, 1);
});

test('a network hitting the sign-in limit → one alert per hour, not one per try', async () => {
  process.env.TRUST_PLATFORM_IP = '1';
  for (let i = 0; i < 33; i++) await h.call(null, 'POST', '/auth/login', { identifier: 'GHOST' + i, password: 'x-wrong-1' }, { 'x-real-ip': '6.6.6.6' });
  const a = (await alerts()).filter((x) => /6\.6\.6\.6/.test(x.body));
  assert.equal(a.length, 1, JSON.stringify(a));
  delete process.env.TRUST_PLATFORM_IP;
});

test('attachments that must be photos: an HTML / script file renamed as an image is refused', async () => {
  const html = Buffer.from('<html><script>alert(1)</script></html>').toString('base64');
  const r = await h.call(c.t.hr, 'POST', '/finance/adjustments', { employeeId: c.ids.e2, month: '2026-03', kind: 'raise', amountEgp: 500,
    reason: 'زيادة سنوية', attachment: html });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  const jpg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(16, 1)]).toString('base64');
  const ok = await h.call(c.t.hr, 'POST', '/finance/adjustments', { employeeId: c.ids.e2, month: '2026-03', kind: 'raise', amountEgp: 500,
    reason: 'زيادة سنوية', attachment: jpg });
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
  // the selfie: its real content decides, not the mime the phone claims
  await h.call(c.t.owner, 'PATCH', '/settings', { selfieRequired: true });
  const bad = await h.call(c.t.e1, 'POST', '/attendance/check-in', { selfie: html, selfieMime: 'image/jpeg' });
  assert.equal(bad.status, 400, JSON.stringify(bad.body));
  await h.call(c.t.owner, 'PATCH', '/settings', { selfieRequired: false });
});

test('every answer forces HTTPS (HSTS); odd paging values never reach SQL as an error', async () => {
  const r = await h.call(c.t.owner, 'GET', '/leads?page=-5&size=1e9');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.match(r.headers.get('strict-transport-security') ?? '', /max-age=31536000/);
});
