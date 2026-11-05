import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, dev, PW, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const sent: any[] = [];
const realFetch = globalThis.fetch;
before(async () => {
  h = await harness(); c = await cast(h);
  await h.db.query(`UPDATE employees SET email = 'e1@value.test' WHERE code = 'E1'`);
  process.env.BREVO_API_KEY = 'k'; process.env.MAIL_FROM = 'hr@value.test';
  globalThis.fetch = (async (url: any, init: any) => {
    if (String(url).startsWith('https://api.brevo.com/')) { sent.push(JSON.parse(init.body)); return new Response('{}', { status: 201 }); }
    return realFetch(url, init);
  }) as typeof fetch;
});
after(async () => { globalThis.fetch = realFetch; delete process.env.BREVO_API_KEY; delete process.env.MAIL_FROM; await h.close(); });

const codeOf = () => /(\d{6})/.exec(sent.at(-1).textContent)![1];

test('forgot password: OTP by email → reset token → new password; wrong codes burn after 5 tries', async () => {
  const unknown = await h.call(null, 'POST', '/auth/forgot', { identifier: 'NOBODY' });
  assert.equal(unknown.status, 200, 'no account enumeration');
  assert.equal(sent.length, 0);
  assert.equal((await h.call(null, 'POST', '/auth/forgot', { identifier: 'e1' })).status, 200);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].to[0].email, 'e1@value.test');
  const code = codeOf();
  const wrong = code === '000000' ? '111111' : '000000';
  assert.equal((await h.call(null, 'POST', '/auth/forgot/verify', { identifier: 'E1', code: wrong })).status, 400);
  const v = await h.call(null, 'POST', '/auth/forgot/verify', { identifier: 'E1', code });
  assert.equal(v.status, 200);
  assert.equal((await h.call(null, 'POST', '/auth/forgot/verify', { identifier: 'E1', code })).status, 400, 'single use');
  assert.equal((await h.call(null, 'POST', '/auth/forgot/reset', { resetToken: v.body.resetToken, newPassword: 'short' })).status, 400);
  assert.equal((await h.call(null, 'POST', '/auth/forgot/reset', { resetToken: v.body.resetToken, newPassword: 'NewPassw0rd!' })).status, 200);
  assert.equal((await h.call(null, 'POST', '/auth/forgot/reset', { resetToken: v.body.resetToken, newPassword: 'NewPassw0rd!2' })).status, 400, 'token used');
  assert.equal((await h.call(null, 'POST', '/auth/login', { identifier: 'E1', password: PW, deviceId: dev('E1') })).status, 401);
  assert.equal((await h.call(null, 'POST', '/auth/login', { identifier: 'E1', password: 'NewPassw0rd!', deviceId: dev('E1') })).status, 200);
  // brute force: 5 wrong tries burn the code
  await h.call(null, 'POST', '/auth/forgot', { identifier: 'E1' });
  const good = codeOf();
  for (let i = 0; i < 5; i++) await h.call(null, 'POST', '/auth/forgot/verify', { identifier: 'E1', code: good === '222222' ? '333333' : '222222' });
  assert.equal((await h.call(null, 'POST', '/auth/forgot/verify', { identifier: 'E1', code: good })).status, 400, 'burned');
  // rate limit: 3 codes per 15 minutes
  assert.equal((await h.call(null, 'POST', '/auth/forgot', { identifier: 'E1' })).status, 200);
  assert.equal((await h.call(null, 'POST', '/auth/forgot', { identifier: 'E1' })).status, 409);
});
