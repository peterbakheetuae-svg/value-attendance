import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, type Harness } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

/**
 * The PROPOSED migration 066 (db/proposed/, not applied anywhere) on a throw-away database at the current schema:
 * effective access identical before / after, a second run changes nothing, the rollback restores the exact rows.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const file = (n: string) => readFileSync(new URL(`../../db/proposed/${n}`, import.meta.url), 'utf8');
const run = async (sql: string) => { await h.db.tx(async (q) => { await q.query(sql); }); forgetPermissionKeys(); };
const snapshot = async () => {
  const t = async (sql: string) => JSON.stringify((await h.db.query(sql)).rows);
  return {
    permissions: await t(`SELECT key, description FROM permissions ORDER BY key`),
    roles: await t(`SELECT role_key, perm_key FROM role_permissions ORDER BY 1, 2`),
    employees: await t(`SELECT employee_id, perm_key, allow FROM employee_permissions ORDER BY 1, 2`),
  };
};
const everyone = () => Object.entries(c.t);
const effective = async () => {
  const out: Record<string, string[]> = {};
  for (const [k, t] of everyone()) out[k] = ((await h.call(t, 'GET', '/me')).body.permissions as string[]).slice().sort();
  return out;
};
before(async () => {
  h = await harness('2026-11-10T13:00:00Z'); c = await cast(h);
  // individual exceptions on broad keys (066 must carry them over to the fine keys)
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES
    ($1, 'employee.manage', true), ($2, 'cash.office', false), ($3, 'attendance.read_team', false)`, [c.ids.sm1, c.ids.acc, c.ids.sm2]);
  forgetPermissionKeys();
});
after(async () => { await h.close(); });

test('066: every account keeps exactly its effective permissions; a second run changes nothing; rollback restores the rows', async () => {
  const rows0 = await snapshot();
  const eff0 = await effective();
  await run(file('066_fine_grained_permissions.sql'));
  const rows1 = await snapshot();
  assert.notEqual(rows1.permissions, rows0.permissions, '066 added keys');
  assert.deepEqual(await effective(), eff0, 'effective access identical for every account after 066');
  await run(file('066_fine_grained_permissions.sql'));
  assert.deepEqual(await snapshot(), rows1, 'second run: no change');
  const audit = (await h.db.query(`SELECT count(*)::int AS n FROM audit_log WHERE after->>'source' = 'migration_066'`)).rows[0].n;
  await run(file('066_rollback.sql'));
  assert.deepEqual(await snapshot(), rows0, 'rollback: permissions, job titles and individual exceptions exactly as before');
  assert.deepEqual(await effective(), eff0, 'effective access identical after the rollback');
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM audit_log WHERE after->>'source' = 'migration_066'`)).rows[0].n, audit,
    'audit rows stay (append-only)');
});

test('066 preview is read-only', async () => {
  const s0 = await snapshot();
  const r = await h.db.query(file('066_preview.sql'));
  assert.ok(Array.isArray(r.rows));
  assert.deepEqual(await snapshot(), s0);
});
