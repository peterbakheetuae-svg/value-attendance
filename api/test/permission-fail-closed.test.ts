import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { can, effectivePermissions, migrationApplied, forgetPermissionKeys, type Actor } from '../src/auth/context.ts';
import { PERMISSIONS } from '../src/lib/permission-registry.ts';
import { harness, cast, type Harness } from './helpers.ts';

/**
 * Release gate «security», original NO-GO 2: a failure or a gap in the permission information must never be read as a
 * grant. Pure rules first, then the real route on production's schema with one key removed from the table.
 */
const ALL = new Set(PERMISSIONS.map((p) => p.key));
const actor = (perms: string[], known?: ReadonlySet<string>, extra: Partial<Actor> = {}): Actor => ({
  id: 'x', code: 'X', fullName: 'x', role: 'sales_employee', perms: new Set(perms), sessionId: 's',
  mustChangePassword: false, known, ...extra,
});
const without = (...keys: string[]) => new Set([...ALL].filter((k) => !keys.includes(k)));
const pre066 = new Set(PERMISSIONS.filter((p) => p.since !== 66).map((p) => p.key)); // a database before migration 066

test('no key list (the permission table could not be read) → every fine check denies', () => {
  const a = actor(['report.read_all', 'employee.manage', 'cash.office']);
  for (const k of ['report.export', 'employee.create', 'cash.receipt_print', 'exclusive.view_client']) {
    assert.equal(can(a, k, null), false, k);
    assert.equal(can(a, k, 'employee.manage'), false, k);
  }
  assert.deepEqual(effectivePermissions(a).filter((k) => !a.perms.has(k)), [], 'nothing added beyond the rows');
});

test('a key missing after its migration ran (damaged table) → denied, never the open / broad rule from before', () => {
  const known = without('report.export', 'employee.create');
  assert.equal(migrationApplied(known, 'report.export'), true);
  const a = actor(['employee.manage', 'report.read_all'], known);
  assert.equal(can(a, 'report.export', null), false, 'open-before key is not open any more');
  assert.equal(can(a, 'employee.create', 'employee.manage'), false, 'split key does not fall back to the broad key');
  const eff = effectivePermissions(a);
  assert.ok(!eff.includes('report.export') && !eff.includes('employee.create'));
});

test('a core key (no migration of its own) missing from the table → denied', () => {
  const a = actor(['employee.read_all'], without('employee.read_all'));
  assert.equal(can(a, 'employee.read_all', 'employee.read_all'), false);
});

test('a database genuinely before 066 keeps exactly its old behaviour (compatibility)', () => {
  assert.equal(migrationApplied(pre066, 'report.export'), false);
  const a = actor(['employee.manage'], pre066);
  assert.equal(can(a, 'report.export', null), true, 'open before 066, as before');
  assert.equal(can(a, 'employee.create', 'employee.manage'), true, 'broad key decides before 066, as before');
  assert.equal(can(actor([], pre066), 'employee.create', 'employee.manage'), false);
  assert.equal(can(actor([], pre066, { settled: true }), 'report.export', null), false, 'a settled account never');
});

test('a complete table: only the fine key counts (individual denial respected)', () => {
  assert.equal(can(actor(['employee.manage'], ALL), 'employee.create', 'employee.manage'), false);
  assert.equal(can(actor(['employee.create'], ALL), 'employee.create', 'employee.manage'), true);
  assert.equal(can(actor([], ALL), 'report.export', null), false);
});

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z', { migrationsExcept: [] }); c = await cast(h); });
after(async () => { forgetPermissionKeys(); await h.close(); });

test('real route, production schema: report.export removed from the table → the export is refused, /me does not list it', async () => {
  // the owner holds report.export through his role today
  forgetPermissionKeys();
  assert.equal((await h.call(c.t.owner, 'GET', '/reports/monthly.xlsx?month=2026-03')).status, 200);
  await h.db.query(`DELETE FROM role_permissions WHERE perm_key = 'report.export'`);
  await h.db.query(`DELETE FROM employee_permissions WHERE perm_key = 'report.export'`);
  await h.db.query(`DELETE FROM permissions WHERE key = 'report.export'`);
  forgetPermissionKeys();
  for (const t of [c.t.owner, c.t.hr, c.t.e1]) {
    assert.equal((await h.call(t, 'GET', '/reports/monthly.xlsx?month=2026-03')).status, 403);
    const me = await h.call(t, 'GET', '/me');
    assert.equal(me.status, 200);
    assert.ok(!me.body.permissions.includes('report.export'));
  }
});
