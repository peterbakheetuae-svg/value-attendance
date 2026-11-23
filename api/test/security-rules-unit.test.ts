// Pure rules of the 2026-11-24 security patch (no database): client platform (G1), tracking health (G2/T2),
// Meta signature (fail closed in production), the scheduler token. Runs anywhere with `node --test`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { browserPunchPolicy, isBrowserRequest } from '../src/lib/client-platform.ts';
import { boardInside, isWeakFix, neverPingedDue, silentCause, weakStreakDue, WEAK_GPS_M, WEAK_STREAK_MIN } from '../src/lib/tracking-health.ts';
import { isProductionRuntime, metaSignatureOk } from '../src/lib/meta-signature.ts';
import { hasBackupToken } from '../src/lib/backup-token.ts';

test('G1: a browser is recognised by Origin only; client claims are ignored', () => {
  assert.equal(isBrowserRequest({ origin: 'https://jaurea.com' }), true);
  assert.equal(isBrowserRequest({ origin: 'null' }), true, 'opaque origin is still a browser');
  assert.equal(isBrowserRequest({}), false, 'the phone app sends no Origin');
  assert.equal(isBrowserRequest({ origin: '' }), false);
  assert.equal(isBrowserRequest({ 'x-client-platform': 'android', 'user-agent': 'Dalvik/2.1.0' } as any), false);
  assert.equal(isBrowserRequest({ origin: 'https://evil.example', 'x-client-platform': 'android' } as any), true, 'forged claim + Origin = browser');
  assert.equal(isBrowserRequest({ 'sec-fetch-mode': 'cors' } as any), false, 'Node fetch / tools add sec-fetch-mode: not used as a signal');
});

test('G1: policy values — unset = approved_device, explicit values, anything else = deny', () => {
  assert.equal(browserPunchPolicy({}), 'approved_device');
  assert.equal(browserPunchPolicy({ ATTENDANCE_BROWSER_PUNCH: '' }), 'approved_device');
  assert.equal(browserPunchPolicy({ ATTENDANCE_BROWSER_PUNCH: ' Approved_Device ' }), 'approved_device');
  assert.equal(browserPunchPolicy({ ATTENDANCE_BROWSER_PUNCH: 'deny' }), 'deny');
  assert.equal(browserPunchPolicy({ ATTENDANCE_BROWSER_PUNCH: 'ALLOW' }), 'allow');
  assert.equal(browserPunchPolicy({ ATTENDANCE_BROWSER_PUNCH: 'true' }), 'deny');
  assert.equal(browserPunchPolicy({ ATTENDANCE_BROWSER_PUNCH: 'alow' }), 'deny', 'a typo never opens it');
});

test('G2: accuracy boundary — 200 m usable, above it weak; missing accuracy keeps the old meaning', () => {
  assert.equal(WEAK_GPS_M, 200);
  assert.equal(isWeakFix(200), false);
  assert.equal(isWeakFix(200.01), true);
  assert.equal(isWeakFix(201), true);
  assert.equal(isWeakFix(5), false);
  assert.equal(isWeakFix(null), false);
  assert.equal(isWeakFix(undefined), false);
  assert.equal(isWeakFix(Number.NaN), false);
});

test('G2: the board never shows «inside» on a weak last fix; «outside» stays outside', () => {
  assert.equal(boardInside(true, 10), true);
  assert.equal(boardInside(true, 200), true);
  assert.equal(boardInside(true, 201), null);
  assert.equal(boardInside(null, 900), null);
  assert.equal(boardInside(false, 900), false, 'a weak fix after an exit proves no return');
  assert.equal(boardInside(false, 10), false);
  assert.equal(boardInside(true, null), true);
});

test('G2: a weak-fix warning needs a run (≥ 3) AND the stale time since the last usable fix', () => {
  const ci = new Date('2026-03-10T08:00:00Z');
  const now = new Date('2026-03-10T09:00:00Z');
  assert.equal(WEAK_STREAK_MIN, 3);
  assert.equal(weakStreakDue({ lastGoodAt: new Date('2026-03-10T08:30:00Z'), checkInAt: ci, now, staleMin: 20, weakSince: 1 }), false, 'one sample');
  assert.equal(weakStreakDue({ lastGoodAt: new Date('2026-03-10T08:30:00Z'), checkInAt: ci, now, staleMin: 20, weakSince: 2 }), false, 'two samples');
  assert.equal(weakStreakDue({ lastGoodAt: new Date('2026-03-10T08:30:00Z'), checkInAt: ci, now, staleMin: 20, weakSince: 3 }), true);
  assert.equal(weakStreakDue({ lastGoodAt: new Date('2026-03-10T08:45:00Z'), checkInAt: ci, now, staleMin: 20, weakSince: 9 }), false, 'usable fix 15 min ago');
  assert.equal(weakStreakDue({ lastGoodAt: null, checkInAt: ci, now, staleMin: 20, weakSince: 3 }), true, 'never a usable fix: counted from check-in');
  assert.equal(weakStreakDue({ lastGoodAt: null, checkInAt: new Date('2026-03-10T08:50:00Z'), now, staleMin: 20, weakSince: 3 }), false);
  assert.equal(weakStreakDue({ lastGoodAt: new Date('2026-03-10T08:00:00Z'), checkInAt: ci, now, staleMin: 0, weakSince: 99 }), false, 'alerts off (stale 0)');
});

test('T2: never-pinged alert only after the stale time from check-in; off when stale is 0', () => {
  const ci = new Date('2026-03-10T08:00:00Z');
  assert.equal(neverPingedDue(ci, new Date('2026-03-10T08:19:59Z'), 20), false);
  assert.equal(neverPingedDue(ci, new Date('2026-03-10T08:20:00Z'), 20), true);
  assert.equal(neverPingedDue(ci, new Date('2026-03-10T12:00:00Z'), 0), false);
});

test('T2: the likely cause from the server\'s own data', () => {
  assert.equal(silentCause({ androidPhones: 0, androidSeenRecently: false }), 'no_tracking_phone');
  assert.equal(silentCause({ androidPhones: 0, androidSeenRecently: true }), 'no_tracking_phone');
  assert.equal(silentCause({ androidPhones: 1, androidSeenRecently: true }), 'no_location');
  assert.equal(silentCause({ androidPhones: 2, androidSeenRecently: false }), 'phone_offline');
});

test('Meta: valid / invalid / missing / malformed signatures; missing configuration fails closed in production only', () => {
  const raw = Buffer.from(JSON.stringify({ entry: [{ id: '1001' }] }));
  const sig = (s: string, b: Buffer = raw) => 'sha256=' + createHmac('sha256', s).update(b).digest('hex');
  const env = { META_APP_SECRETS: 'one, two' };
  assert.equal(metaSignatureOk(raw, sig('one'), env), true, 'app one');
  assert.equal(metaSignatureOk(raw, sig('two'), env), true, 'app two');
  assert.equal(metaSignatureOk(raw, sig('two').toUpperCase().replace('SHA256=', 'sha256='), env), true, 'hex case');
  assert.equal(metaSignatureOk(raw, sig('three'), env), false, 'wrong secret');
  assert.equal(metaSignatureOk(Buffer.from(raw.toString().replace('1001', '1002')), sig('one'), env), false, 'modified body');
  assert.equal(metaSignatureOk(raw, undefined, env), false, 'missing');
  assert.equal(metaSignatureOk(raw, '', env), false, 'empty');
  assert.equal(metaSignatureOk(raw, 'sha256=zz', env), false, 'malformed');
  assert.equal(metaSignatureOk(raw, sig('one').slice(7), env), false, 'no prefix');
  assert.equal(metaSignatureOk(raw, 'sha1=' + 'a'.repeat(40), env), false, 'other algorithm');
  assert.equal(metaSignatureOk(raw, [sig('one')] as unknown, env), false, 'array header');
  assert.equal(metaSignatureOk(Buffer.alloc(0), sig('one', Buffer.alloc(0)), env), false, 'empty body');
  assert.equal(metaSignatureOk(undefined, sig('one'), env), false, 'no raw body');
  // no secrets configured
  assert.equal(metaSignatureOk(raw, undefined, {}), true, 'laptop / CI: unchanged');
  assert.equal(metaSignatureOk(raw, undefined, { VERCEL_ENV: 'preview' }), true, 'a preview is not production');
  assert.equal(metaSignatureOk(raw, undefined, { VERCEL_ENV: 'production' }), false, 'Vercel production: closed');
  assert.equal(metaSignatureOk(raw, sig('x'), { VERCEL_ENV: 'production', META_APP_SECRETS: ' , ' }), false, 'blank list = not configured');
  assert.equal(metaSignatureOk(raw, undefined, { CONTEXT: 'production' }), false, 'Netlify production: closed');
  assert.equal(metaSignatureOk(raw, undefined, { NODE_ENV: 'production' }), false, 'NODE_ENV production: closed');
  assert.equal(metaSignatureOk(raw, sig('one'), { VERCEL_ENV: 'production', META_APP_SECRETS: 'one' }), true, 'production configured');
  assert.equal(isProductionRuntime({ NODE_ENV: 'development' }), false);
});

test('scheduler token: ≥ 24 characters on the host, exact match, constant-time', () => {
  const env = { BACKUP_TOKEN: 'x'.repeat(32) };
  assert.equal(hasBackupToken({ 'x-backup-token': 'x'.repeat(32) }, env), true);
  assert.equal(hasBackupToken({ 'x-backup-token': 'x'.repeat(31) }, env), false);
  assert.equal(hasBackupToken({}, env), false);
  assert.equal(hasBackupToken({ 'x-backup-token': 'short' }, { BACKUP_TOKEN: 'short' }), false, 'a host token under 24 characters is off');
  assert.equal(hasBackupToken({ 'x-backup-token': 'anything-anything-anything' }, {}), false, 'no host token');
});
