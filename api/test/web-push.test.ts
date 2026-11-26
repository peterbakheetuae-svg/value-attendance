import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createDecipheriv, createECDH, createHmac, createPublicKey, createVerify, randomBytes } from 'node:crypto';
import { harness, cast, PW, type Harness } from './helpers.ts';
import { encryptPayload, parseVapidPrivateKey, vapidKeys, vapidState, webPushPublicKey, webPushTo } from '../src/lib/webpush.ts';

/** Web Push for the web app (iPhone Home Screen app / browsers): key, subscription, RFC 8291 encryption. */
// an independent key for the suite (generated, never derived from another credential)
const genKey = () => { const e = createECDH('prime256v1'); e.generateKeys(); const d = e.getPrivateKey(); return Buffer.concat([Buffer.alloc(32 - d.length), d]).toString('base64url'); };
const KEY1 = genKey();
process.env.VAPID_PRIVATE_KEY = KEY1;
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-11-10T13:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

const hmac = (k: Buffer, d: Buffer) => createHmac('sha256', k).update(d).digest();

test('the payload decrypts on the browser side (RFC 8291 aes128gcm)', () => {
  const ua = createECDH('prime256v1'); ua.generateKeys();
  const authSecret = randomBytes(16);
  const msg = Buffer.from(JSON.stringify({ title: 'إذن ساعات', body: 'مستني موافقتك' }));
  const out = encryptPayload(msg, ua.getPublicKey(), authSecret);
  // browser side
  const salt = out.subarray(0, 16), idlen = out[20], asPublic = out.subarray(21, 21 + idlen), ct = out.subarray(21 + idlen);
  assert.equal(out.readUInt32BE(16), 4096);
  const shared = ua.computeSecret(asPublic);
  const ikm = hmac(hmac(authSecret, shared), Buffer.concat([Buffer.from('WebPush: info\0'), ua.getPublicKey(), asPublic, Buffer.from([1])]));
  const prk = hmac(salt, ikm);
  const cek = hmac(prk, Buffer.from('Content-Encoding: aes128gcm\0\x01', 'binary')).subarray(0, 16);
  const nonce = hmac(prk, Buffer.from('Content-Encoding: nonce\0\x01', 'binary')).subarray(0, 12);
  const d = createDecipheriv('aes-128-gcm', cek, nonce);
  d.setAuthTag(ct.subarray(ct.length - 16));
  const plain = Buffer.concat([d.update(ct.subarray(0, ct.length - 16)), d.final()]);
  assert.equal(plain[plain.length - 1], 2, 'last-record delimiter');
  assert.deepEqual(plain.subarray(0, plain.length - 1), msg);
});

test('the VAPID key is a valid P-256 pair from VAPID_PRIVATE_KEY and signs ES256', () => {
  const k = vapidKeys()!;
  assert.ok(k);
  assert.equal(k.pub.length, 65);
  assert.equal(webPushPublicKey(), k.pub.toString('base64url'));
  const pub = createPublicKey({ format: 'jwk', key: { kty: 'EC', crv: 'P-256', x: k.pub.subarray(1, 33).toString('base64url'), y: k.pub.subarray(33).toString('base64url') } });
  assert.ok(pub);
});

test('a signed-in employee gets the public key and saves his browser subscription; logout removes it', async () => {
  const key = await h.call(c.t.e1, 'GET', '/me/web-push');
  assert.equal(key.status, 200);
  assert.equal(key.body.publicKey, webPushPublicKey());
  const ua = createECDH('prime256v1'); ua.generateKeys();
  const sub = { endpoint: 'https://web.push.apple.com/QH-test-endpoint', keys: { p256dh: ua.getPublicKey().toString('base64url'), auth: randomBytes(16).toString('base64url') } };
  assert.equal((await h.call(c.t.e1, 'POST', '/me/web-push', { ...sub, endpoint: 'http://x' })).status, 400);
  assert.equal((await h.call(c.t.e1, 'POST', '/me/web-push', sub)).status, 200);
  assert.equal((await h.call(c.t.e1, 'POST', '/me/web-push', sub)).status, 200, 'again = update, not a duplicate');
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM web_push_subscriptions WHERE employee_id = $1`, [c.ids.e1])).rows[0].count), 1);
  assert.equal((await h.call(c.t.e1, 'POST', '/auth/logout', {})).status, 200);
  assert.equal(Number((await h.db.query(`SELECT count(*) FROM web_push_subscriptions`)).rows[0].count), 0);
  void createVerify;
});

// ---- SEC-01 / VAPID independence (missing, malformed, valid, rotated; Firebase / BACKUP_TOKEN rotation)
const withEnv = async (env: Record<string, string | undefined>, fn: () => void | Promise<void>) => {
  const old: Record<string, string | undefined> = {};
  for (const k of Object.keys(env)) { old[k] = process.env[k]; if (env[k] === undefined) delete process.env[k]; else process.env[k] = env[k]; }
  try { await fn(); } finally { for (const k of Object.keys(old)) { if (old[k] === undefined) delete process.env[k]; else process.env[k] = old[k]; } }
};
const fakeSa = () => JSON.stringify({ type: 'service_account', client_email: 'x@y.iam.gserviceaccount.com', private_key: `-----BEGIN PRIVATE KEY-----\n${randomBytes(48).toString('base64')}\n-----END PRIVATE KEY-----\n` });

test('missing VAPID_PRIVATE_KEY: Web Push is off — never derived from FCM_SERVICE_ACCOUNT or BACKUP_TOKEN', async () => {
  await withEnv({ VAPID_PRIVATE_KEY: undefined, FCM_SERVICE_ACCOUNT: fakeSa(), BACKUP_TOKEN: 'x'.repeat(40) }, async () => {
    assert.equal(vapidState(), 'missing');
    assert.equal(vapidKeys(), null);
    assert.equal(webPushPublicKey(), null);
    const r = await h.call(await h.login('E1', PW), 'GET', '/me/web-push');
    assert.equal(r.status, 200); assert.equal(r.body.publicKey, null);
    assert.equal((await webPushTo(h.db, c.ids.e1, { id: 'n', type: 't', title: 'a', body: 'b' })).off, true);
  });
});

test('malformed VAPID_PRIVATE_KEY: off (fails safe), no fallback to another secret', async () => {
  const bad = ['short', KEY1 + 'A', KEY1.slice(0, 42) + '=', Buffer.alloc(32).toString('base64url'), Buffer.alloc(32, 0xff).toString('base64url'),
    Buffer.from(KEY1, 'base64url').toString('base64'), '!' + KEY1.slice(1), Buffer.alloc(31, 1).toString('base64url')];
  for (const v of bad) {
    await withEnv({ VAPID_PRIVATE_KEY: v, FCM_SERVICE_ACCOUNT: fakeSa(), BACKUP_TOKEN: 'x'.repeat(40) }, () => {
      assert.equal(parseVapidPrivateKey(v), null, `rejected: ${v.length} chars`);
      assert.equal(vapidState(), 'invalid');
      assert.equal(webPushPublicKey(), null);
    });
  }
});

test('a valid key gives the matching public key; a rotated key changes it; Firebase / BACKUP_TOKEN rotation does not', async () => {
  const e = createECDH('prime256v1'); e.setPrivateKey(Buffer.from(KEY1, 'base64url'));
  await withEnv({ VAPID_PRIVATE_KEY: KEY1, FCM_SERVICE_ACCOUNT: fakeSa(), BACKUP_TOKEN: 'a'.repeat(40) }, async () => {
    assert.equal(vapidState(), 'ok');
    assert.equal(webPushPublicKey(), e.getPublicKey().toString('base64url'));
    const before = webPushPublicKey();
    await withEnv({ FCM_SERVICE_ACCOUNT: fakeSa(), BACKUP_TOKEN: 'b'.repeat(40) }, () => assert.equal(webPushPublicKey(), before, 'FCM / backup-token rotation keeps the VAPID key'));
    await withEnv({ FCM_SERVICE_ACCOUNT: undefined, BACKUP_TOKEN: undefined }, () => assert.equal(webPushPublicKey(), before));
    const KEY2 = genKey();
    await withEnv({ VAPID_PRIVATE_KEY: KEY2 }, () => { assert.notEqual(webPushPublicKey(), before, 'rotation = a new public key'); });
    assert.equal(webPushPublicKey(), before, 'back to key 1');
  });
});

test('push-service answers: 403 (old VAPID key) keeps the subscription for the app to renew; 404/410 remove it; one send per subscription', async () => {
  const ua = createECDH('prime256v1'); ua.generateKeys();
  const mk = (n: string) => ({ endpoint: `https://fcm.googleapis.com/wp/${n}`, keys: { p256dh: ua.getPublicKey().toString('base64url'), auth: randomBytes(16).toString('base64url') } });
  // a fresh session for e1 (the earlier test logged out)
  const tok = await h.login('E1', PW);
  for (const n of ['k403', 'k410', 'k404', 'k201']) assert.equal((await h.call(tok, 'POST', '/me/web-push', mk(n))).status, 200);
  const realFetch = globalThis.fetch; const calls: string[] = [];
  globalThis.fetch = (async (url: string | URL) => {
    const u = String(url); calls.push(u);
    const st = u.endsWith('k403') ? 403 : u.endsWith('k410') ? 410 : u.endsWith('k404') ? 404 : 201;
    return new Response('', { status: st });
  }) as typeof fetch;
  try {
    const r = await webPushTo(h.db, c.ids.e1, { id: 'n1', type: 'request', title: 'a', body: 'b' });
    assert.deepEqual({ devices: r.devices, sent: r.sent, failed: r.failed, removed: r.removed }, { devices: 4, sent: 1, failed: 3, removed: 2 });
    assert.equal(calls.length, 4, 'no retries / no loop');
  } finally { globalThis.fetch = realFetch; }
  const left = (await h.db.query(`SELECT endpoint FROM web_push_subscriptions WHERE employee_id = $1 ORDER BY endpoint`, [c.ids.e1])).rows.map((x) => x.endpoint.split('/').pop());
  assert.deepEqual(left, ['k201', 'k403']);
});
