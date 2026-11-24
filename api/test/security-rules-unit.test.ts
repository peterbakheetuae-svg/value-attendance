// Pure rules of the 2026-11-24 security patch (no database): client platform (G1), tracking health (G2/T2),
// Meta signature (fail closed in production), the scheduler token. Runs anywhere with `node --test`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { devicePolicy, isBrowserRequest, punchRefusal, type SessionDevice } from '../src/lib/client-platform.ts';
import { boardInside, isWeakFix, neverPingedDue, silentCause, weakStreakDue, WEAK_GPS_M, WEAK_STREAK_MIN } from '../src/lib/tracking-health.ts';
import { isProductionRuntime, metaSignatureOk } from '../src/lib/meta-signature.ts';
import { hasBackupToken } from '../src/lib/backup-token.ts';
// @ts-ignore — plain .mjs shared with the build script
import { deploymentStatus, REAL_API_DOMAINS, RETIRED_DOMAIN } from '../scripts/deployment-guard.mjs';
// @ts-ignore — plain .mjs build script
import { decide } from '../scripts/migrate-if-production.mjs';

test('G1: the decision rests on the server\'s device records; no header can grant a punch', () => {
  const approved: SessionDevice = { deviceLock: true, deviceId: 'dev-approved-1', approved: true };
  const unapproved: SessionDevice = { deviceLock: true, deviceId: 'dev-other-123', approved: false };
  const noDevice: SessionDevice = { deviceLock: true, deviceId: null, approved: false };
  const unlinked: SessionDevice = { deviceLock: false, deviceId: 'dev-x', approved: false };
  for (const browser of [false, true]) {
    // 1+2: without Origin or with any Origin, an unapproved device of a device-linked employee is refused
    assert.equal(punchRefusal(unapproved, browser, 'approved_device'), 'device_not_approved', `unapproved, browser=${browser}`);
    assert.equal(punchRefusal(noDevice, browser, 'approved_device'), 'device_not_approved', `no device, browser=${browser}`);
    // 4: the approved device punches from any client (Android app, iPhone web app)
    assert.equal(punchRefusal(approved, browser, 'approved_device'), null, `approved, browser=${browser}`);
    assert.equal(punchRefusal(approved, browser, 'strict'), null);
    // no session row → refused
    assert.equal(punchRefusal(null, browser, 'approved_device'), 'device_not_approved');
  }
  // the device-link is off for this employee: the app keeps working, a browser is refused (an Origin can only refuse more)
  assert.equal(punchRefusal(unlinked, false, 'approved_device'), null);
  assert.equal(punchRefusal(unlinked, true, 'approved_device'), 'device_link_off_browser');
  assert.equal(punchRefusal(unlinked, false, 'strict'), 'device_link_required');
  assert.equal(punchRefusal({ ...unlinked, approved: true }, false, 'strict'), 'device_link_required', 'an old approval without the link proves nothing');
  // an approved flag without a device id is not enough
  assert.equal(punchRefusal({ deviceLock: true, deviceId: null, approved: true }, false, 'approved_device'), 'device_not_approved');
});

test('G1: Origin is read only as an extra refusal signal (absent / empty / "null" / array / forged)', () => {
  assert.equal(isBrowserRequest({ origin: 'https://jaurea.com' }), true);
  assert.equal(isBrowserRequest({ origin: 'null' }), true, 'opaque origin');
  assert.equal(isBrowserRequest({}), false);
  assert.equal(isBrowserRequest({ origin: '' }), false);
  assert.equal(isBrowserRequest({ origin: '   ' }), false);
  assert.equal(isBrowserRequest({ origin: ['a', 'b'] } as any), true, 'repeated header');
  assert.equal(isBrowserRequest({ 'x-client-platform': 'android', 'user-agent': 'Dalvik/2.1.0' } as any), false, 'client claims are not read');
});

test('G1: policy values — unset = approved_device, strict, anything else = strict (fail closed)', () => {
  assert.equal(devicePolicy({}), 'approved_device');
  assert.equal(devicePolicy({ ATTENDANCE_DEVICE_POLICY: ' Approved_Device ' }), 'approved_device');
  assert.equal(devicePolicy({ ATTENDANCE_DEVICE_POLICY: 'strict' }), 'strict');
  for (const v of ['allow', 'audit', 'off', 'true', 'alow']) assert.equal(devicePolicy({ ATTENDANCE_DEVICE_POLICY: v }), 'strict', v);
  assert.equal(devicePolicy({ ATTENDANCE_BROWSER_PUNCH: 'allow' }), 'approved_device', 'the first version\'s variable opens nothing');
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

test('C1: fixed identities, secrets play no part, missing identity in production fails closed', () => {
  const T = 'x'.repeat(40);
  const base = { VERCEL: '1', VERCEL_ENV: 'production', VERCEL_GIT_COMMIT_REF: 'main' };
  const orphan = { ...base, VERCEL_PROJECT_PRODUCTION_URL: RETIRED_DOMAIN, VERCEL_URL: 'value-attendance-api-k3j2h1g0f-peter.vercel.app' };
  // retired project — with and without BACKUP_TOKEN, by any of its Vercel names, in production or preview
  assert.equal(deploymentStatus(orphan), 'retired', 'token absent');
  assert.equal(deploymentStatus({ ...orphan, BACKUP_TOKEN: T }), 'retired', 'token present');
  assert.equal(deploymentStatus({ ...base, VERCEL_URL: 'value-attendance-api-k3j2h1g0f-peter.vercel.app' }), 'retired', 'deployment URL only');
  assert.equal(deploymentStatus({ ...base, VERCEL_BRANCH_URL: 'value-attendance-api-git-main-peter.vercel.app' }), 'retired', 'branch URL only');
  assert.equal(deploymentStatus({ ...orphan, VERCEL_PROJECT_PRODUCTION_URL: 'https://VALUE-ATTENDANCE-API-EIGHT.vercel.app/' }), 'retired', 'case / scheme');
  assert.equal(deploymentStatus({ ...orphan, VERCEL_ENV: 'preview' }), 'retired', 'a preview of the retired project');
  // a real-API domain written next to a retired deployment URL never rescues it
  assert.equal(deploymentStatus({ ...orphan, VERCEL_PROJECT_PRODUCTION_URL: 'valunivo.vercel.app' }), 'retired', 'conflicting identity');
  // the real API
  for (const d of REAL_API_DOMAINS) {
    assert.equal(deploymentStatus({ ...base, VERCEL_PROJECT_PRODUCTION_URL: d, VERCEL_URL: 'value-attendance-k3j2h1g0f-peter.vercel.app' }), 'serve', d);
    assert.equal(deploymentStatus({ ...base, VERCEL_PROJECT_PRODUCTION_URL: d, BACKUP_TOKEN: T }), 'serve', `${d} + token`);
    assert.equal(deploymentStatus({ ...base, VERCEL_PROJECT_PRODUCTION_URL: d }), 'serve', `${d}, token absent: still served`);
  }
  assert.equal(deploymentStatus({ ...base, VERCEL_PROJECT_PRODUCTION_URL: 'value-attendance.vercel.app', VERCEL_URL: 'value-attendance-apixyz123-peter.vercel.app' }), 'serve',
    'a real deployment hash starting with «api» is not the retired project');
  // production without a known identity: fail closed
  assert.equal(deploymentStatus(base), 'unverified', 'no metadata');
  assert.equal(deploymentStatus({ ...base, BACKUP_TOKEN: T }), 'unverified', 'no metadata, token present');
  assert.equal(deploymentStatus({ ...base, VERCEL_PROJECT_PRODUCTION_URL: 'valunivo-copy.vercel.app' }), 'unverified', 'unexpected domain');
  assert.equal(deploymentStatus({ ...base, VERCEL_PROJECT_PRODUCTION_URL: 'evil.vercel.app.example.com' }), 'unverified');
  assert.equal(deploymentStatus({ VERCEL: '1' }), 'unverified', 'on Vercel, environment unknown → treated as production');
  assert.equal(deploymentStatus({ VERCEL_ENV: 'production' }), 'unverified');
  assert.equal(deploymentStatus({ VERCEL: '1', VERCEL_ENV: 'weird' }), 'unverified');
  // previews / development of the real project (no production secrets): served; not on Vercel: served by other rules
  assert.equal(deploymentStatus({ VERCEL: '1', VERCEL_ENV: 'preview', VERCEL_URL: 'value-attendance-k3j2h1g0f-peter.vercel.app' }), 'serve');
  assert.equal(deploymentStatus({ VERCEL: '1', VERCEL_ENV: 'development' }), 'serve');
  assert.equal(deploymentStatus({}), 'serve', 'a laptop / CI');
  assert.equal(deploymentStatus({ NETLIFY: 'true', CONTEXT: 'production' }), 'serve', 'Netlify has its own entry');
  // the build: only the real project's production build of main migrates
  assert.equal(decide({ ...base, VERCEL_PROJECT_PRODUCTION_URL: 'valunivo.vercel.app' }).allow, true);
  assert.equal(decide(orphan).allow, false);
  assert.equal(decide({ ...orphan, BACKUP_TOKEN: T }).allow, false);
  assert.equal(decide(base).allow, false, 'unidentified production build');
});
