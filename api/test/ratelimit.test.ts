import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, dev, PW, type Harness } from './helpers.ts';

/** VA-06: per-IP throttling of sign-in, shared through the database; only failures count; spoofed headers ignored off-platform */
let h: Harness;
before(async () => { h = await harness(); await cast(h); });
after(async () => { delete process.env.TRUST_PLATFORM_IP; await h.close(); });

test('VA-06: 30 wrong passwords from one IP → 429 for that IP only; good sign-ins never count; untrusted hosts ignore the header', async () => {
  const login = (ip: string, identifier: string, password: string) =>
    h.call(null, 'POST', '/auth/login', { identifier, password, deviceId: dev(identifier) }, { 'x-real-ip': ip });
  // not on the platform: a forged header is not trusted (no IP throttling, account lockout still applies)
  for (let i = 0; i < 3; i++) await login('9.9.9.9', 'NOBODY' + i, 'wrong-pass-1');
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM audit_log WHERE action = 'auth.ip_failed'`)).rows[0].n, 0);
  process.env.TRUST_PLATFORM_IP = '1';
  // correct sign-ins from a busy office IP are never throttled
  for (let i = 0; i < 35; i++) assert.equal((await login('10.0.0.1', 'E1', PW)).status, 200);
  // spraying wrong passwords over many accounts from one IP
  for (let i = 0; i < 30; i++) assert.equal((await login('6.6.6.6', 'GHOST' + i, 'wrong-pass-1')).status, 401);
  const blocked = await login('6.6.6.6', 'E2', PW);
  assert.equal(blocked.status, 429, 'that IP is now refused, even with a right password');
  assert.equal((await login('7.7.7.7', 'E2', PW)).status, 200, 'other IPs unaffected');
  // the forgot-password e-mail: every request counts (its reply never changes)
  for (let i = 0; i < 20; i++) await h.call(null, 'POST', '/auth/forgot', { identifier: 'NOBODY' }, { 'x-real-ip': '5.5.5.5' });
  assert.equal((await h.call(null, 'POST', '/auth/forgot', { identifier: 'NOBODY' }, { 'x-real-ip': '5.5.5.5' })).status, 429);
  // nothing secret is logged: only the IP and the kind
  const row = (await h.db.query(`SELECT after FROM audit_log WHERE action = 'auth.ip_failed' LIMIT 1`)).rows[0].after;
  assert.deepEqual(Object.keys(row).sort(), ['ip', 'kind']);
});
