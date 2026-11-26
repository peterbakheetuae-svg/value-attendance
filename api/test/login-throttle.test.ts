import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { harness, cast, dev, PW, type Harness } from './helpers.ts';
import { createDb } from '../src/db.ts';
import { accountBucket, pairBucket, reserve, clear, PAIR_FREE, ACCT_FREE, delayAfter, MAX_DELAY_S } from '../src/auth/throttle.ts';
import { mirrorSignature, verifiedMirrorIp } from '../src/auth/mirror-ip.ts';
import { upstreamRequest } from '../cloudflare-proxy/worker.js';

/** SEC-05: progressive account + network / device / account-wide sign-in throttling, and the signed mirror client IP. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const KEY = 'm'.repeat(40);
before(async () => { h = await harness(); c = await cast(h); });
after(async () => { delete process.env.TRUST_PLATFORM_IP; delete process.env.MIRROR_SIGNING_KEY; await h.close(); });

const login = (identifier: string, password: string, extra: Record<string, string> = {}, deviceId?: string) =>
  h.call(null, 'POST', '/auth/login', { identifier, password, ...(deviceId ? { deviceId } : {}) }, extra);
const elapse = (like: string) => h.db.query(`UPDATE login_throttle SET blocked_until = now() - interval '1 second' WHERE key LIKE $1`, [like]);
const empId = async (code: string) => (await h.db.query(`SELECT id FROM employees WHERE code = $1`, [code])).rows[0].id as string;

test('the delay grows 30 s, 60 s, 120 s … and is capped at 15 minutes; nothing locks for good', () => {
  assert.deepEqual([1, 4, 5, 6, 7, 8].map((n) => delayAfter(n, PAIR_FREE)), [0, 0, 30, 60, 120, 240]);
  assert.equal(delayAfter(40, PAIR_FREE), MAX_DELAY_S);
});

test('1. repeated wrong passwords from one network: 5 checked, then a wait (423, generic, retry time) — progressive', async () => {
  process.env.TRUST_PLATFORM_IP = '1';
  const ip = { 'x-real-ip': '20.0.0.1' };
  for (let i = 0; i < PAIR_FREE; i++) assert.equal((await login('E1', 'wrong-' + i, ip)).status, 401);
  const w = await login('E1', 'wrong-x', ip);
  assert.equal(w.status, 423);
  assert.equal(w.body.error.message, 'Too many failed attempts. Try again later');
  assert.ok(w.body.error.details.retryAfterS > 0 && w.body.error.details.retryAfterS <= 30);
  assert.equal((await login('E1', PW, ip)).status, 423, 'the same network waits even with the right password');
  await elapse('pair:%');
  assert.equal((await login('E1', 'wrong-y', ip)).status, 401, 'after the wait: one more try is checked');
  const w2 = await login('E1', 'wrong-z', ip);
  assert.equal(w2.status, 423); assert.ok(w2.body.error.details.retryAfterS > 30, 'the next wait is longer');
  await elapse('pair:%');
  assert.equal((await login('E1', PW, ip, dev('E1'))).status, 200, 'the right password signs in and resets');
  await elapse('%');
});

test('4. the real user is not locked out: another network, and his own approved phone, still sign in', async () => {
  const atk = { 'x-real-ip': '20.0.0.2' };
  for (let i = 0; i < 12; i++) await login('E2', 'guess-' + i, atk);
  assert.equal((await login('E2', PW, atk)).status, 423, 'the attacker network waits');
  assert.equal((await login('E2', PW, { 'x-real-ip': '30.0.0.9' })).status, 200, 'another network with the right password');
  assert.equal((await login('E2', PW, atk, dev('E2'))).status, 200, 'his approved phone, even on the same network');
});

test('2. many networks against one account: the account-wide bucket slows unknown devices; the approved phone still signs in; an alert', async () => {
  for (let i = 0; i < ACCT_FREE + 3; i++) await login('E3', 'spray-' + i, { 'x-real-ip': `40.0.${Math.floor(i / 4)}.${i}` });
  const fresh = await login('E3', PW, { 'x-real-ip': '50.5.5.5' });
  assert.equal(fresh.status, 423, 'a new network waits once the account-wide budget is spent');
  assert.equal((await login('E3', PW, { 'x-real-ip': '50.5.5.5' }, dev('E3'))).status, 200, 'the approved phone is not slowed');
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM audit_log WHERE action = 'auth.distributed_attempts' AND entity_id = $1`, [await empId('E3')])).rows[0].n, 1);
  const alerts = (await h.db.query(`SELECT title FROM notifications WHERE recipient_id = $1 AND type = 'security_alert'`, [c.ids.owner])).rows;
  assert.ok(alerts.some((a) => /شبكات كتير/.test(a.title)));
});

test('3. one network against many accounts: the per-IP limit (429) — and unknown names throttle exactly like real ones', async () => {
  const ip = { 'x-real-ip': '60.0.0.1' };
  for (let i = 0; i < PAIR_FREE; i++) assert.equal((await login('NOBODY-X', 'w' + i, ip)).status, 401);
  const u = await login('NOBODY-X', 'w', ip);
  const k = await login('SOLO', 'w', { 'x-real-ip': '60.0.0.2' });
  for (let i = 0; i < PAIR_FREE; i++) await login('SOLO', 'w' + i, { 'x-real-ip': '60.0.0.2' });
  const real = await login('SOLO', 'w', { 'x-real-ip': '60.0.0.2' });
  assert.equal(k.status, 401);
  assert.deepEqual([u.status, u.body.error.message], [real.status, real.body.error.message], 'unknown vs existing: identical replies');
  const spray = { 'x-real-ip': '61.0.0.1' };
  let last = 0;
  for (let i = 0; i < 31; i++) last = (await login('GHOST-' + i, 'w', spray)).status;
  assert.equal(last, 429);
  assert.equal((await login('SM1', PW, spray, dev('SM1'))).status, 429, 'that network is refused for every account');
  await elapse('%');
});

test('5. concurrent attempts: 30 parallel wrong passwords — at most 5 checked; then the right one waits', async () => {
  const ip = { 'x-real-ip': '70.0.0.1' };
  const all = await Promise.all(Array.from({ length: 30 }, (_, i) => login('ACC1', 'par-' + i, ip)));
  assert.ok(all.every((x) => x.status === 401 || x.status === 423), JSON.stringify(all.map((x) => x.status)));
  assert.ok(all.filter((x) => x.status === 401).length <= PAIR_FREE);
  assert.equal((await login('ACC1', PW, ip)).status, 423);
});

test('9. restart / several API instances: the state is in the database — a new pool sees the same block, parallel pools never exceed it', async () => {
  const u = new URL(process.env.TEST_PG_URL ?? 'postgres://postgres:dev@127.0.0.1:5433/postgres'); u.pathname = '/' + h.dbName;
  const a = createDb(u.toString(), 5), b = createDb(u.toString(), 5);
  try {
    const bk = pairBucket('e:instances-test', '80.0.0.1');
    const res = await Promise.all(Array.from({ length: 20 }, (_, i) => reserve(i % 2 ? a : b, bk)));
    assert.equal(res.filter((r) => r.ok).length, PAIR_FREE, 'exactly the free attempts pass across both instances');
    const c2 = createDb(u.toString(), 1); // «after a restart»
    try { assert.equal((await reserve(c2, bk)).ok, false); } finally { await c2.end(); }
    await clear(a, bk);
    assert.equal((await reserve(b, bk)).ok, true);
    const ab = accountBucket('e:instances-test');
    assert.equal((await Promise.all(Array.from({ length: 30 }, () => reserve(a, ab)))).filter((r) => r.ok).length, ACCT_FREE);
  } finally { await a.end(); await b.end(); }
});

test('6/7. mirror traffic: a signed client IP is used; forged, expired, replayed on another path, or unsigned headers are ignored', async () => {
  process.env.MIRROR_SIGNING_KEY = KEY;
  const now = Date.now();
  const req = (headers: Record<string, string>, method = 'POST', path = '/auth/login') => ({ headers, method, path });
  const ts = Math.floor(now / 1000);
  const good = { 'x-va-client-ip': '90.1.2.3', 'x-va-mirror-sig': mirrorSignature(KEY, '90.1.2.3', 'POST', '/auth/login', ts) };
  assert.equal(verifiedMirrorIp(req(good).headers, 'POST', '/auth/login', now), '90.1.2.3');
  assert.equal(verifiedMirrorIp({ ...good, 'x-va-client-ip': '90.1.2.4' }, 'POST', '/auth/login', now), null, 'another IP under the same signature');
  assert.equal(verifiedMirrorIp(good, 'POST', '/auth/forgot', now), null, 'replayed on another path');
  assert.equal(verifiedMirrorIp(good, 'GET', '/auth/login', now), null, 'another method');
  assert.equal(verifiedMirrorIp(good, 'POST', '/auth/login', now + 61_000), null, 'expired (replay window 60 s)');
  assert.equal(verifiedMirrorIp({ ...good, 'x-va-mirror-sig': mirrorSignature('x'.repeat(40), '90.1.2.3', 'POST', '/auth/login', ts) }, 'POST', '/auth/login', now), null, 'wrong key');
  assert.equal(verifiedMirrorIp({ 'x-va-client-ip': '90.1.2.3' }, 'POST', '/auth/login', now), null, 'unsigned');
  delete process.env.MIRROR_SIGNING_KEY;
  assert.equal(verifiedMirrorIp(good, 'POST', '/auth/login', now), null, 'no key configured: never trusted');
  process.env.MIRROR_SIGNING_KEY = KEY;

  // the Worker: strips caller-sent x-va-* / forwarding headers, signs CF-Connecting-IP, refuses unknown methods
  const fromCaller = new Request('https://mirror.example/auth/login?x=1', { method: 'POST', body: '{}', headers: {
    'cf-connecting-ip': '91.9.9.9', 'x-va-client-ip': '1.1.1.1', 'x-va-mirror-sig': 'v1.1.forged', 'x-forwarded-for': '2.2.2.2', 'x-real-ip': '3.3.3.3', 'content-type': 'application/json' } });
  const up = (await upstreamRequest(fromCaller, { MIRROR_SIGNING_KEY: KEY }, now))!;
  assert.equal(up.url, 'https://value-attendance.vercel.app/auth/login?x=1');
  const hd = Object.fromEntries(up.init.headers.entries());
  assert.equal(hd['x-va-client-ip'], '91.9.9.9');
  assert.equal(hd['x-forwarded-for'], undefined); assert.equal(hd['x-real-ip'], undefined); assert.equal(hd['cf-connecting-ip'], undefined);
  assert.equal(verifiedMirrorIp(hd, 'POST', '/auth/login', now), '91.9.9.9', 'the API verifies what the Worker signed');
  const noKey = (await upstreamRequest(new Request('https://mirror.example/me', { headers: { 'cf-connecting-ip': '91.9.9.9', 'x-va-client-ip': '1.1.1.1' } }), {}, now))!;
  assert.equal(noKey.init.headers.get('x-va-client-ip'), null, 'no key: nothing claimed, caller copy removed');
  assert.equal(await upstreamRequest(new Request('https://mirror.example/x', { method: 'TRACE' }), {}, now), null);

  // end to end: through the mirror the per-IP limit counts the caller, not Cloudflare's shared address
  const cf = '104.16.0.1';
  const viaMirror = (ip: string) => ({ 'x-real-ip': cf, 'x-va-client-ip': ip, 'x-va-mirror-sig': mirrorSignature(KEY, ip, 'POST', '/auth/login', Math.floor(Date.now() / 1000)) });
  for (let i = 0; i < 31; i++) await login('GHOST-M' + i, 'w', viaMirror('92.0.0.1'));
  assert.equal((await login('GHOST-MZ', 'w', viaMirror('92.0.0.1'))).status, 429, 'the guessing caller is limited');
  assert.equal((await login('E1', PW, viaMirror('92.0.0.2'), dev('E1'))).status, 200, 'another caller on the same mirror is not');
  const forged = { 'x-real-ip': cf, 'x-va-client-ip': '92.0.0.3', 'x-va-mirror-sig': 'v1.' + Math.floor(Date.now() / 1000) + '.' + '0'.repeat(64) };
  await login('GHOST-F', 'w', forged);
  const rows = (await h.db.query(`SELECT DISTINCT entity_id FROM audit_log WHERE action = 'auth.ip_failed' AND entity_id IN ('92.0.0.3', $1)`, [cf])).rows.map((r) => r.entity_id);
  assert.deepEqual(rows, [cf], 'a forged signature is counted against the platform address, never the claimed one');
});

test('8. OTP brute force: 5 wrong codes void a code (even the right one is then refused); 10 wrong a day stop the account', async () => {
  const id = c.ids.solo;
  await h.db.query(`UPDATE employees SET email = 'solo@example.test' WHERE id = $1`, [id]);
  const sha = (s: string) => createHash('sha256').update(s).digest('hex');
  await h.db.query(`INSERT INTO password_otps (employee_id, code_hash, expires_at) VALUES ($1, $2, now() + interval '10 minutes')`, [id, sha(`${id}:4321`)]);
  const verify = (code: string) => h.call(null, 'POST', '/auth/forgot/verify', { identifier: 'SOLO', code }, { 'x-real-ip': '93.0.0.1' });
  for (const code of ['0000', '1111', '2222', '3333', '5555']) assert.equal((await verify(code)).status, 400);
  assert.equal((await verify('4321')).status, 400, 'the code is void after 5 wrong tries');
  await h.db.query(`INSERT INTO password_otps (employee_id, code_hash, expires_at) VALUES ($1, $2, now() + interval '10 minutes')`, [id, sha(`${id}:8765`)]);
  for (const code of ['0001', '0002', '0003', '0004', '0005']) await h.call(null, 'POST', '/auth/forgot/verify', { identifier: 'SOLO', code }, { 'x-real-ip': '93.0.0.2' });
  await h.db.query(`INSERT INTO password_otps (employee_id, code_hash, expires_at) VALUES ($1, $2, now() + interval '10 minutes')`, [id, sha(`${id}:2468`)]);
  assert.equal((await h.call(null, 'POST', '/auth/forgot/verify', { identifier: 'SOLO', code: '2468' }, { 'x-real-ip': '93.0.0.3' })).status, 400, 'daily wrong-code budget spent: refused');
});

test('an HR password reset clears the account\'s waits', async () => {
  const ip = { 'x-real-ip': '94.0.0.1' };
  for (let i = 0; i < PAIR_FREE + 1; i++) await login('E2', 'x' + i, ip);
  assert.equal((await login('E2', PW, ip)).status, 423);
  const r = await h.call(c.t.hr, 'POST', `/employees/${c.ids.e2}/reset-password`, {});
  assert.ok([200, 201].includes(r.status), JSON.stringify(r.body));
  const n = (await h.db.query(`SELECT count(*)::int n FROM login_throttle WHERE key LIKE $1 AND blocked_until > now()`, [`%e:${c.ids.e2}%`])).rows[0].n;
  assert.equal(n, 0);
});
