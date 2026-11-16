import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { PERMISSIONS } from '../src/lib/permission-registry.ts';

// Security regression tests for the central permission engine and the «الصلاحيات» administration (throwaway database).
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness(); c = await cast(h); });
after(async () => { await h.close(); });
const me = async (t: string) => (await h.call(t, 'GET', '/me')).body.permissions as string[];

test('registry: every key required with another one (requiresAll) is a registered, already-migrated key', () => {
  const reg = new Map(PERMISSIONS.map((p) => [p.key, p]));
  for (const p of PERMISSIONS) for (const k of p.requiresAll ?? []) {
    assert.ok(reg.has(k), `${p.key} requires unregistered ${k}`);
    assert.ok(!reg.get(k)!.since, `${p.key} requires ${k}, itself pending a migration`);
  }
  assert.deepEqual(reg.get('finance.company_income')?.requiresAll, ['cash.office', 'commission.company_view']);
});

test('the registry matches the database: every database key is registered; only not-yet-migrated keys are missing', async () => {
  const db = new Set((await h.db.query(`SELECT key FROM permissions`)).rows.map((x) => x.key));
  const reg = new Set(PERMISSIONS.map((p) => p.key));
  assert.deepEqual([...db].filter((k) => !reg.has(k)), [], 'database keys missing from the registry');
  for (const p of PERMISSIONS) if (!db.has(p.key)) assert.ok(p.since, `${p.key} is registered but not in the database and not pending a migration`);
});

test('deny by default: a key the application does not register is never granted', async () => {
  await h.db.query(`INSERT INTO permissions (key, description) VALUES ('zzz.unregistered', 'x')`);
  await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) VALUES ('hr_manager', 'zzz.unregistered')`);
  assert.ok(!(await me(c.t.hr)).includes('zzz.unregistered'));
  await h.db.query(`DELETE FROM role_permissions WHERE perm_key = 'zzz.unregistered'`);
  await h.db.query(`DELETE FROM permissions WHERE key = 'zzz.unregistered'`);
});

test('the permissions administration needs roles.manage (direct API access included)', async () => {
  for (const t of [c.t.hr, c.t.acc, c.t.sm1, c.t.e1]) {
    for (const [m, p, b] of [['GET', '/permissions/registry'], ['GET', '/permissions/roles'], ['GET', '/permissions/employees'],
      ['GET', `/permissions/employees/${c.ids.e1}`], ['GET', '/permissions/audit'],
      ['PUT', '/permissions/roles/accountant', { grant: ['custody.read_all'] }],
      ['PUT', `/permissions/employees/${c.ids.e2}`, { perm: 'custody.read_all', value: 'allow' }]] as const) {
      assert.equal((await h.call(t, m, p, b)).status, 403, `${m} ${p}`);
    }
  }
  assert.equal((await h.call(null, 'GET', '/permissions/registry')).status, 401);
  const reg = await h.call(c.t.owner, 'GET', '/permissions/registry');
  assert.equal(reg.status, 200);
  assert.ok(reg.body.permissions.find((p: any) => p.key === 'roles.manage').sensitive);
});

test('job-title profile: a change applies to its employees on their next request, sensitive needs confirmation, audited', async () => {
  assert.ok(!(await me(c.t.acc)).includes('custody.read_all'));
  assert.equal((await h.call(c.t.owner, 'PUT', '/permissions/roles/accountant', { grant: ['custody.read_all'] })).status, 200);
  assert.ok((await me(c.t.acc)).includes('custody.read_all'), 'no stale cache: effective at once');
  const r = await h.call(c.t.owner, 'PUT', '/permissions/roles/accountant', { grant: ['cash.office'] });
  assert.equal(r.status, 409, 'sensitive needs confirm');
  assert.equal(r.body.error.details.reason, 'needs_confirmation');
  assert.equal((await h.call(c.t.owner, 'PUT', '/permissions/roles/accountant', { revoke: ['custody.read_all'] })).status, 200);
  assert.ok(!(await me(c.t.acc)).includes('custody.read_all'));
  assert.equal((await h.call(c.t.owner, 'PUT', '/permissions/roles/accountant', { grant: ['nope.nothing'] })).status, 400, 'unknown key');
  assert.equal((await h.call(c.t.owner, 'PUT', '/permissions/roles/owner', { revoke: ['custody.read_all'] })).status, 403, 'owner profile fixed');
  const log = (await h.call(c.t.owner, 'GET', '/permissions/audit')).body.entries;
  const e = log.find((x: any) => x.action === 'permission.role' && x.entityId === 'accountant' && x.after.perm === 'custody.read_all' && x.after.value === 'off');
  assert.ok(e && e.before.value === 'on' && e.after.source === 'permissions_page' && e.actorName);
});

test('individual exceptions: an explicit restriction beats the inherited grant; reset returns to the profile', async () => {
  assert.ok((await me(c.t.hr)).includes('employee.read_all'));
  assert.equal((await h.call(c.t.owner, 'PUT', `/permissions/employees/${c.ids.hr}`, { perm: 'employee.read_all', value: 'deny' })).status, 200);
  assert.ok(!(await me(c.t.hr)).includes('employee.read_all'));
  assert.equal((await h.call(c.t.hr, 'GET', `/employees/${c.ids.e1}`)).status, 404, 'enforced by the API, not only hidden');
  const view = (await h.call(c.t.owner, 'GET', `/permissions/employees/${c.ids.hr}`)).body;
  assert.equal(view.overrides['employee.read_all'], 'deny');
  assert.ok(view.inherited.includes('employee.read_all') && !view.effective.includes('employee.read_all'));
  assert.equal((await h.call(c.t.owner, 'POST', `/permissions/employees/${c.ids.hr}/reset`, {})).status, 200);
  assert.ok((await me(c.t.hr)).includes('employee.read_all'));
  assert.equal((await h.call(c.t.owner, 'PUT', `/permissions/employees/${c.ids.owner}`, { perm: 'roles.manage', value: 'deny', confirm: true })).status, 403,
    'owner accounts are never restricted (recovery path)');
});

test('delegation and self-modification: a non-owner administrator cannot escalate', async () => {
  // HR gets roles.manage individually (by the owner)
  assert.equal((await h.call(c.t.owner, 'PUT', `/permissions/employees/${c.ids.hr}`, { perm: 'roles.manage', value: 'allow', confirm: true })).status, 200);
  assert.equal((await h.call(c.t.hr, 'GET', '/permissions/registry')).status, 200);
  // not his own exceptions, not his own job title
  assert.equal((await h.call(c.t.hr, 'PUT', `/permissions/employees/${c.ids.hr}`, { perm: 'cash.office', value: 'allow', confirm: true })).status, 403);
  assert.equal((await h.call(c.t.hr, 'PUT', '/permissions/roles/hr_manager', { grant: ['custody.manage'] })).status, 403);
  // not a permission he does not hold, to anyone
  assert.ok(!(await me(c.t.hr)).includes('cash.office'));
  assert.equal((await h.call(c.t.hr, 'PUT', `/permissions/employees/${c.ids.acc}`, { perm: 'cash.office', value: 'allow', confirm: true })).status, 403);
  assert.equal((await h.call(c.t.hr, 'PUT', '/permissions/roles/accountant', { grant: ['cash.office'], confirm: true })).status, 403);
  // the older screens follow the same rules
  assert.equal((await h.call(c.t.hr, 'PUT', '/leads/permissions/employee', { employeeId: c.ids.hr, perm: 'leads.export', value: 'allow' })).status, 403);
  // what he holds he may delegate to someone else
  assert.equal((await h.call(c.t.hr, 'PUT', `/permissions/employees/${c.ids.acc}`, { perm: 'custody.read_all', value: 'allow' })).status, 200);
  assert.ok((await me(c.t.acc)).includes('custody.read_all'));
  await h.call(c.t.owner, 'POST', `/permissions/employees/${c.ids.acc}/reset`, {});
  await h.call(c.t.owner, 'POST', `/permissions/employees/${c.ids.hr}/reset`, { confirm: true });
  assert.equal((await h.call(c.t.hr, 'GET', '/permissions/registry')).status, 403, 'taken back at once');
});

test('lockout protection: at least one account keeps roles.manage', async () => {
  await h.db.query(`UPDATE employees SET status = 'inactive' WHERE role_key = 'owner'`);
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'roles.manage', true)`, [c.ids.hr]);
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'roles.manage', true)`, [c.ids.acc]);
  // HR removes the accountant's roles.manage: HR still holds it → allowed
  assert.equal((await h.call(c.t.hr, 'PUT', `/permissions/employees/${c.ids.acc}`, { perm: 'roles.manage', value: 'inherit', confirm: true })).status, 200);
  // the accountant's was the only other; HR cannot remove his own (self) — so the last holder can never be removed by himself
  assert.equal((await h.call(c.t.hr, 'PUT', `/permissions/employees/${c.ids.hr}`, { perm: 'roles.manage', value: 'deny', confirm: true })).status, 403);
  await h.db.query(`DELETE FROM employee_permissions WHERE perm_key = 'roles.manage'`);
  await h.db.query(`UPDATE employees SET status = 'active' WHERE role_key = 'owner'`);
});

test('notification recipients follow the same resolution (an individual restriction is respected)', async () => {
  const { holdersOf } = await import('../src/modules/notify.ts');
  assert.ok((await holdersOf(h.db, 'request.approve_hr')).includes(c.ids.hr));
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'request.approve_hr', false)`, [c.ids.hr]);
  assert.ok(!(await holdersOf(h.db, 'request.approve_hr')).includes(c.ids.hr));
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.hr]);
});
