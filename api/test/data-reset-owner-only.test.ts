import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, PW, type Harness } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

/**
 * data.reset («استيراد / مسح البيانات») is strictly owner-only and never delegable — before AND after migration 066:
 * nobody can grant it (not even an owner), a job title / individual row never gives it to a non-owner, and an owner
 * account cannot be taken over (email + forgot password, reset password, role, status, devices) by another administrator.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const reset = { employees: [], attendance: [] };
const me = async (t: string) => ((await h.call(t, 'GET', '/me')).body.permissions ?? []) as string[];
before(async () => {
  h = await harness('2026-11-10T13:00:00Z'); c = await cast(h);
  // an HR manager trusted with the permissions page and employee management (the strongest non-owner administrator)
  await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) VALUES ('hr_manager','roles.manage'), ('hr_manager','employee.manage')
                    ON CONFLICT DO NOTHING`);
});
after(async () => { await h.close(); });

test('before 066: only the owner may import / reset; nobody else, whatever they hold', async () => {
  assert.equal((await h.call(c.t.owner, 'POST', '/admin/data-reset', reset)).status, 200, 'owner dry run');
  for (const t of [c.t.hr, c.t.acc, c.t.sm1, c.t.e1]) {
    assert.equal((await h.call(t, 'POST', '/admin/data-reset', reset)).status, 403);
    assert.equal((await h.call(t, 'POST', '/admin/import-permissions', reset)).status, 403);
  }
});

test('after migration 066 (run on this test database): still owner-only; never grantable, delegable or inherited', async () => {
  const sql = readFileSync(new URL('../../db/proposed/066_fine_grained_permissions.sql', import.meta.url), 'utf8');
  await h.db.tx(async (q) => { await q.query(sql); });
  forgetPermissionKeys();   // the server re-reads the permission keys (it caches them for a minute)
  assert.ok((await me(c.t.owner)).includes('data.reset'), 'the owner holds it after 066');
  assert.equal((await h.call(c.t.owner, 'POST', '/admin/data-reset', reset)).status, 200);
  assert.ok(!(await me(c.t.hr)).includes('data.reset'));

  // nobody can give it — not the HR administrator, not even the owner
  for (const t of [c.t.hr, c.t.owner]) {
    assert.equal((await h.call(t, 'PUT', '/permissions/roles/accountant', { grant: ['data.reset'], confirm: true })).status, 403);
    assert.equal((await h.call(t, 'PUT', `/permissions/employees/${c.ids.acc}`, { perm: 'data.reset', value: 'allow', confirm: true })).status, 403);
    assert.equal((await h.call(t, 'PUT', '/roles/accountant/permissions', { permissions: ['data.reset'] })).status, 403);
  }
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM role_permissions WHERE perm_key = 'data.reset' AND role_key <> 'owner'`)).rows[0].n, 0);
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM employee_permissions ep JOIN employees e ON e.id = ep.employee_id
                                    WHERE ep.perm_key = 'data.reset' AND e.role_key <> 'owner'`)).rows[0].n, 0);

  // even a row written straight into the database gives a non-owner nothing
  await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) VALUES ('accountant','data.reset')`);
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1,'data.reset',true)`, [c.ids.e1]);
  for (const t of [c.t.acc, c.t.e1]) {
    assert.ok(!(await me(t)).includes('data.reset'), 'not listed for a non-owner');
    assert.equal((await h.call(t, 'POST', '/admin/data-reset', reset)).status, 403);
  }
  // …and such a stray row can always be removed («رجوع لصلاحيات المسمى»)
  assert.equal((await h.call(c.t.owner, 'POST', `/permissions/employees/${c.ids.e1}/reset`, { confirm: true })).status, 200);
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM employee_permissions WHERE employee_id = $1 AND perm_key = 'data.reset'`, [c.ids.e1])).rows[0].n, 0);
  await h.db.query(`DELETE FROM role_permissions WHERE role_key = 'accountant' AND perm_key = 'data.reset'`);

  // a second run of 066 changes nothing
  const count = async () => (await h.db.query(`SELECT (SELECT count(*) FROM role_permissions) + (SELECT count(*) FROM employee_permissions)
                                                + (SELECT count(*) FROM permissions) AS n`)).rows[0].n;
  const n1 = await count();
  await h.db.tx(async (q) => { await q.query(sql); });
  assert.equal(await count(), n1, '066 is idempotent');
});

test('an owner account cannot be taken over by another administrator (the way to data.reset)', async () => {
  // HR holds roles.manage + employee.manage, yet:
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.owner}`, { email: 'attacker@example.com' })).status, 403, 'new email + forgot password');
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.owner}`, { phone: '01099999999' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.owner}/reset-password`, {})).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.owner}/status`, { status: 'inactive' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.owner}/unbind-device`, {})).status, 403);
  assert.equal((await h.db.query(`SELECT email, status FROM employees WHERE id = $1`, [c.ids.owner])).rows[0].email, null);
  // …nor make a (new or existing) account an owner
  assert.equal((await h.call(c.t.hr, 'POST', '/employees', { code: 'OWN2', fullName: 'مالك مزيف', role: 'owner' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e1}`, { role: 'owner' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', '/roles', { nameAr: 'مالك ٢', baseKey: 'owner' })).status, 400, 'no position on the owner role');
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM employees WHERE role_key = 'owner'`)).rows[0].n, 1);

  // the owner still manages owners and himself exactly as before
  assert.equal((await h.call(c.t.owner, 'PATCH', `/employees/${c.ids.owner}`, { email: 'owner@example.com' })).status, 200);
  const two = await h.call(c.t.owner, 'POST', '/employees', { code: 'OWN2', fullName: 'شريك', role: 'owner' });
  assert.equal(two.status, 201, JSON.stringify(two.body));
  assert.equal((await h.call(c.t.owner, 'PATCH', `/employees/${two.body.id}`, { phone: '01011112222' })).status, 200);
  // and HR keeps managing everyone else
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e1}`, { phone: '01033334444' })).status, 200);
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.e2}/reset-password`, {})).status, 200);
  assert.ok(PW);
});
