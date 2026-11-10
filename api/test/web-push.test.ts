import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createDecipheriv, createECDH, createHmac, createPublicKey, createVerify, randomBytes } from 'node:crypto';
import { harness, cast, type Harness } from './helpers.ts';
import { encryptPayload, vapidKeys, webPushPublicKey } from '../src/lib/webpush.ts';

/** Web Push for the web app (iPhone Home Screen app / browsers): key, subscription, RFC 8291 encryption. */
process.env.BACKUP_TOKEN ??= 'test-backup-token-for-vapid-derivation';
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

test('the VAPID key is a valid P-256 pair (no new secret needed) and signs ES256', () => {
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
