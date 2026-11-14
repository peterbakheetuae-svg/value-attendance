import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, dev, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });
const login = (identifier: string, password: string, deviceId?: string) =>
  h.call(null, 'POST', '/auth/login', { identifier, password, ...(deviceId ? { deviceId } : {}) });

test('device binding: first device sticks, another phone is refused until HR unlinks', async () => {
  assert.equal((await login('E2', PW)).status, 403, 'no device id');
  const r = await login('E2', PW, dev('OTHER'));
  assert.equal(r.status, 403, 'E2 was bound to its test device by cast()');
  assert.equal(r.body.error.details.reason, 'device_pending', 'another phone asks for approval');
  const prof = await h.call(c.t.hr, 'GET', `/employees/${c.ids.e2}`);
  assert.equal(prof.body.employee.device_bound, true);
  assert.equal(prof.body.employee.devices_pending, 1);
  assert.equal((await h.call(c.t.e1, 'POST', `/employees/${c.ids.e2}/unbind-device`)).status, 403, 'employees cannot unlink');
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.e2}/unbind-device`)).status, 200);
  assert.equal((await login('E2', PW, dev('OTHER'))).status, 200, 'new phone binds after unlinking');
  assert.equal((await login('E2', PW, dev('E2'))).body.error.details.reason, 'device_pending', 'old phone now has to ask');
});

test('more than one phone: approved by the general manager or the administrative officer, never by himself', async () => {
  // E3 is linked to its own phone (cast); a second phone asks
  const ask = await login('E3', PW, dev('E3-TABLET'));
  assert.equal(ask.body.error.details.reason, 'device_pending');
  assert.equal((await login('E3', PW, dev('E3-TABLET'))).body.error.details.reason, 'device_pending', 'asking again just repeats');
  const mine = await h.call(c.t.e3, 'GET', `/employees/${c.ids.e3}/devices`);
  assert.equal(mine.status, 200);
  assert.equal(mine.body.canApprove, false);
  const pend = mine.body.devices.find((d: any) => d.status === 'pending');
  assert.ok(pend && mine.body.devices.some((d: any) => d.status === 'approved'));
  assert.equal((await h.call(c.t.e3, 'POST', `/employees/${c.ids.e3}/devices/${pend.id}/approve`)).status, 403, 'not his own phone');
  assert.equal((await h.call(c.t.e1, 'POST', `/employees/${c.ids.e3}/devices/${pend.id}/approve`)).status, 403, 'a colleague cannot');
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.e3}/devices/${pend.id}/approve`)).status, 403, 'HR alone cannot');
  // the administrative officer is asked (notified) and approves
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  const notes = await h.db.query(`SELECT 1 FROM notifications WHERE recipient_id = $1 AND type = 'device_request'`, [c.ids.owner]);
  assert.ok(notes.rows.length >= 1, 'the owner was asked');
  const list = await h.call(c.t.acc, 'GET', '/devices/pending');
  assert.ok(list.body.devices.some((d: any) => d.id === pend.id));
  assert.equal((await h.call(c.t.acc, 'POST', `/employees/${c.ids.e3}/devices/${pend.id}/approve`)).status, 200);
  assert.equal((await login('E3', PW, dev('E3-TABLET'))).status, 200, 'the tablet signs in');
  assert.equal((await login('E3', PW, dev('E3'))).status, 200, 'and the first phone still does');
  // a third phone refused by the general manager
  await h.db.query(`UPDATE employees SET general_manager_id = $2 WHERE id = $1`, [c.ids.e3, c.ids.sm1]);
  await login('E3', PW, dev('E3-THIRD'));
  const third = (await h.call(c.t.sm1, 'GET', `/employees/${c.ids.e3}/devices`)).body;
  assert.equal(third.canApprove, true, 'his general manager may decide');
  const t3 = third.devices.find((d: any) => d.status === 'pending');
  assert.equal((await h.call(c.t.sm1, 'POST', `/employees/${c.ids.e3}/devices/${t3.id}/reject`)).status, 200);
  assert.equal((await login('E3', PW, dev('E3-THIRD'))).body.error.details.reason, 'device_rejected');
  // removing the tablet signs it out and it has to ask again
  const tab = (await h.call(c.t.owner, 'GET', `/employees/${c.ids.e3}/devices`)).body.devices.find((d: any) => d.id === pend.id);
  assert.equal((await h.call(c.t.owner, 'POST', `/employees/${c.ids.e3}/devices/${tab.id}/remove`)).status, 200);
  assert.equal((await login('E3', PW, dev('E3-TABLET'))).body.error.details.reason, 'device_pending');
});

test('owner is never bound; binding can be switched off', async () => {
  assert.equal((await login('OWNER', PW)).status, 200);
  assert.equal((await login('OWNER', PW, dev('ANY-PHONE'))).status, 200);
  await h.call(c.t.owner, 'PATCH', '/settings', { deviceBinding: false });
  assert.equal((await login('E3', PW)).status, 200);
  await h.call(c.t.owner, 'PATCH', '/settings', { deviceBinding: true });
});

test('PIN: HR issues a PIN for sales staff (no forced change); admin roles keep passwords', async () => {
  const r = await h.call(c.t.hr, 'POST', `/employees/${c.ids.e1}/reset-password`, { kind: 'pin' });
  assert.equal(r.status, 200);
  assert.match(r.body.pin, /^\d{6}$/);
  const s = await login('E1', r.body.pin, dev('E1'));
  assert.equal(s.status, 200);
  assert.equal(s.body.mustChangePassword, false);
  const tok = s.body.token;
  assert.equal((await h.call(tok, 'POST', '/auth/change-password', { currentPassword: r.body.pin, newPassword: '12' })).status, 400);
  assert.equal((await h.call(tok, 'POST', '/auth/change-password', { currentPassword: r.body.pin, newPassword: '4321' })).status, 200);
  assert.equal((await h.call(c.t.owner, 'POST', `/employees/${c.ids.acc}/reset-password`, { kind: 'pin' })).status, 400, 'accountant needs a password');
  assert.equal((await h.call(c.t.acc, 'POST', '/auth/change-password', { currentPassword: PW, newPassword: '123456' })).status, 400, 'admin role cannot pick a PIN');
  await h.call(c.t.owner, 'PATCH', '/settings', { allowPin: false });
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.e3}/reset-password`, { kind: 'pin' })).status, 400, 'PINs off');
});

test('new employee can be created with a PIN', async () => {
  await h.call(c.t.owner, 'PATCH', '/settings', { allowPin: true });
  const r = await h.call(c.t.hr, 'POST', '/employees', { code: 'NEWPIN', fullName: 'موظف جديد', role: 'sales_employee', phone: '01000000001', loginKind: 'pin' });
  assert.equal(r.status, 201);
  assert.match(r.body.pin, /^\d{6}$/);
  assert.equal(r.body.temporaryPassword, undefined);
  assert.equal((await login('01000000001', r.body.pin, dev('NEWPIN'))).status, 200, 'mobile number + PIN');
});

test('password reset is emailed to the employee when email is configured (not shown to the admin)', async () => {
  await h.db.query(`UPDATE employees SET email = 'e2@value.test' WHERE id = $1`, [c.ids.e2]);
  // without Brevo configured: shown on screen once
  const plain = await h.call(c.t.hr, 'POST', `/employees/${c.ids.e2}/reset-password`, {});
  assert.equal(plain.status, 200);
  assert.ok(plain.body.temporaryPassword);
  assert.equal(plain.body.emailed, false);
  // with Brevo configured: sent by email, never returned
  const sent: any[] = [];
  const realFetch = globalThis.fetch;
  process.env.BREVO_API_KEY = 'test-key'; process.env.MAIL_FROM = 'hr@value.test';
  globalThis.fetch = (async (url: any, init: any) => {
    if (String(url).startsWith('https://api.brevo.com/')) { sent.push(JSON.parse(init.body)); return new Response('{}', { status: 201 }); }
    return realFetch(url, init);
  }) as typeof fetch;
  try {
    const r = await h.call(c.t.hr, 'POST', `/employees/${c.ids.e2}/reset-password`, {});
    assert.equal(r.status, 200);
    assert.equal(r.body.emailed, true);
    assert.equal(r.body.temporaryPassword, undefined, 'admin does not see it');
    assert.equal(r.body.emailTo, 'e***@value.test');
    assert.equal(sent.length, 1);
    assert.equal(sent[0].to[0].email, 'e2@value.test');
    assert.match(sent[0].textContent, /E2/);
  } finally {
    globalThis.fetch = realFetch; delete process.env.BREVO_API_KEY; delete process.env.MAIL_FROM;
  }
});

test('per-employee phone lock: HR turns it off/on; turning it on ends open sessions; owner never locked', async () => {
  await h.call(c.t.hr, 'POST', `/employees/${c.ids.e3}/unbind-device`);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e3}`, { deviceLock: false })).status, 200);
  assert.equal((await login('E3', PW, dev('PHONE-A'))).status, 200);
  assert.equal((await login('E3', PW, dev('PHONE-B'))).status, 200, 'unlocked: any phone');
  const s = await login('E3', PW, dev('PHONE-B'));
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e3}`, { deviceLock: true })).status, 200);
  assert.equal((await h.call(s.body.token, 'GET', '/me')).status, 401, 'sessions ended when the lock is switched on');
  assert.equal((await login('E3', PW, dev('PHONE-A'))).status, 200, 'first sign-in after locking binds this phone');
  assert.equal((await login('E3', PW, dev('PHONE-B'))).status, 403, 'another phone is refused');
  assert.equal((await h.call(c.t.hr, 'GET', `/employees/${c.ids.e3}`)).body.employee.device_lock, true);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.owner}`, { deviceLock: true })).status, 400);
  assert.equal((await h.call(c.t.sm1, 'PATCH', `/employees/${c.ids.e3}`, { deviceLock: false })).status, 404, 'no employee.manage');
});
