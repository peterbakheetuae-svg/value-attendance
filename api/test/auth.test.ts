import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, dev, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness(); c = await cast(h); });
after(async () => { await h.close(); });

test('unauthenticated requests are rejected', async () => {
  for (const p of ['/me', '/employees', '/dashboard', '/requests', '/reports/monthly?month=2026-03']) {
    assert.equal((await h.call(null, 'GET', p)).status, 401, p);
  }
  assert.equal((await h.call('garbage-token', 'GET', '/me')).status, 401);
});

test('login accepts code (any case), wrong password is generic, lockout after 5 failures', async () => {
  assert.equal((await h.call(null, 'POST', '/auth/login', { identifier: 'e1', password: PW, deviceId: dev('E1') })).status, 200);
  const bad = await h.call(null, 'POST', '/auth/login', { identifier: 'E2', password: 'nope' });
  assert.equal(bad.status, 401);
  const unknown = await h.call(null, 'POST', '/auth/login', { identifier: 'NOBODY', password: 'nope' });
  assert.equal(unknown.body.error.message, bad.body.error.message, 'no user enumeration');
  for (let i = 0; i < 4; i++) await h.call(null, 'POST', '/auth/login', { identifier: 'E2', password: 'nope' });
  const locked = await h.call(null, 'POST', '/auth/login', { identifier: 'E2', password: PW });
  assert.equal(locked.status, 423, 'locked even with the right password');
  await h.db.query(`UPDATE employees SET locked_until = NULL, failed_logins = 0 WHERE code = 'E2'`);
});

test('/me exposes permissions per role; sales employee only reserves exclusive units', async () => {
  const me = await h.call(c.t.e1, 'GET', '/me');
  assert.equal(me.status, 200);
  assert.deepEqual(me.body.permissions.sort(), ['exclusive.reserve', 'leads.own']);
  const owner = await h.call(c.t.owner, 'GET', '/me');
  assert.ok(owner.body.permissions.includes('roles.manage'));
  const sm = await h.call(c.t.sm1, 'GET', '/me');
  assert.ok(sm.body.permissions.includes('request.approve_manager'));
  assert.ok(!sm.body.permissions.includes('request.approve_hr'), 'sales manager gets no HR rights');
  assert.ok(!sm.body.permissions.includes('employee.salary_read'), 'sales manager gets no accounting rights');
  const acc = await h.call(c.t.acc, 'GET', '/me');
  assert.ok(!acc.body.permissions.includes('request.approve_hr'), 'accountant cannot approve HR requests');
});

test('new employee must change temporary password before using the API', async () => {
  const created = await h.call(c.t.hr, 'POST', '/employees', { code: 'NEW1', fullName: 'موظف جديد', role: 'sales_employee', jobTitle: 'مستشار عقاري', teamId: c.ids.teamA });
  assert.equal(created.status, 201);
  const tmp = created.body.temporaryPassword;
  const tok = await h.login('NEW1', tmp);
  const blocked = await h.call(tok, 'GET', '/dashboard');
  assert.equal(blocked.status, 403);
  assert.equal(blocked.body.error.details.reason, 'must_change_password');
  assert.equal((await h.call(tok, 'POST', '/auth/change-password', { currentPassword: tmp, newPassword: 'short' })).status, 400);
  assert.equal((await h.call(tok, 'POST', '/auth/change-password', { currentPassword: tmp, newPassword: 'NewPass123' })).status, 200);
  assert.equal((await h.call(tok, 'GET', '/dashboard')).status, 200);
});

test('logout revokes the session; deactivation revokes all sessions', async () => {
  const tok = await h.login('E3', PW);
  assert.equal((await h.call(tok, 'POST', '/auth/logout')).status, 200);
  assert.equal((await h.call(tok, 'GET', '/me')).status, 401);
  const tok2 = await h.login('E3', PW);
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.e3}/status`, { status: 'inactive' })).status, 200);
  assert.equal((await h.call(tok2, 'GET', '/me')).status, 401);
  assert.equal((await h.call(null, 'POST', '/auth/login', { identifier: 'E3', password: PW })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.e3}/status`, { status: 'active' })).status, 200);
});

test('privileged roles: only the owner assigns owner/HR/accountant; nobody changes own role', async () => {
  const hrTry = await h.call(c.t.hr, 'POST', '/employees', { code: 'X1', fullName: 'X One', role: 'accountant' });
  assert.equal(hrTry.status, 403);
  const ownerOk = await h.call(c.t.owner, 'POST', '/employees', { code: 'ACC2', fullName: 'محاسب ٢', role: 'accountant' });
  assert.equal(ownerOk.status, 201);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.hr}`, { role: 'owner' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e1}`, { role: 'hr_manager' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.owner}`, { role: 'hr_manager' })).status, 403);
  assert.equal((await h.call(c.t.e1, 'PATCH', `/employees/${c.ids.e1}`, { jobTitle: 'مدير' })).status, 403, 'self-service is contact fields only');
  assert.equal((await h.call(c.t.e1, 'PATCH', `/employees/${c.ids.e1}`, { phone: '01000000001' })).status, 200);
});

test('the last active owner cannot be deactivated', async () => {
  const other = await h.call(c.t.owner, 'POST', '/employees', { code: 'OWN2', fullName: 'Owner Two', role: 'owner' });
  assert.equal(other.status, 201);
  // owner 2 deactivates owner 1 → allowed (one owner remains); then owner 2 alone cannot be deactivated by anyone
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code='OWNER') WHERE code = 'OWN2'`);
  const t2 = await h.login('OWN2', PW);
  assert.equal((await h.call(t2, 'POST', `/employees/${c.ids.owner}/status`, { status: 'inactive' })).status, 200);
  const r = await h.call(c.t.hr, 'POST', `/employees/${other.body.id}/status`, { status: 'inactive' });
  assert.equal(r.status, 403);
  assert.equal((await h.call(t2, 'POST', `/employees/${c.ids.owner}/status`, { status: 'active' })).status, 200);
  c.t.owner = await h.login('OWNER', PW); // deactivation revoked the old session
});

test('audit log is append-only at the database level', async () => {
  await assert.rejects(h.db.query(`UPDATE audit_log SET action = 'x'`), /append-only/);
  await assert.rejects(h.db.query(`DELETE FROM audit_log`), /append-only/);
});

test('role permissions are editable by owner only and owner role is immutable', async () => {
  assert.equal((await h.call(c.t.hr, 'PUT', '/roles/accountant/permissions', { permissions: [] })).status, 403);
  assert.equal((await h.call(c.t.owner, 'PUT', '/roles/owner/permissions', { permissions: [] })).status, 403);
  assert.equal((await h.call(c.t.owner, 'PUT', '/roles/sales_employee/permissions', { permissions: ['audit.read'] })).status, 400);
  const roles = await h.call(c.t.owner, 'GET', '/roles');
  assert.equal(roles.status, 200);
  assert.equal(roles.body.roles.length, 6);
});

test('login also accepts the mobile number in any common form and the email', async () => {
  await h.db.query(`UPDATE employees SET phone = '+201011112222', email = 'e3@value.test' WHERE code = 'E3'`);
  for (const id of ['01011112222', '+201011112222', '00201011112222', '0101 111 2222', 'E3@Value.test', 'e3']) {
    const r = await h.call(null, 'POST', '/auth/login', { identifier: id, password: PW, deviceId: dev('E3') });
    assert.equal(r.status, 200, id);
  }
  assert.equal((await h.call(null, 'POST', '/auth/login', { identifier: '01011112223', password: PW, deviceId: dev('E3') })).status, 401);
});

test('push token is tied to the session and removed on logout', async () => {
  const tok = await h.login('E1', PW);
  const r = await h.call(tok, 'POST', '/me/push-token', { token: 'fcm-token-'.padEnd(40, 'x'), platform: 'android' });
  assert.equal(r.status, 200);
  assert.equal(r.body.pushEnabled, false, 'no service account in tests');
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM push_tokens`)).rows[0].n, 1);
  await h.call(tok, 'POST', '/auth/logout', {});
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM push_tokens`)).rows[0].n, 0);
});
