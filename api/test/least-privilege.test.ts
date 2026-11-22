import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/**
 * Runs only with TEST_APP_ROLE=1 (the whole suite then talks to the API through a least-privilege role: no CREATE,
 * no TRUNCATE, DELETE on the 19 runtime tables only, no UPDATE on audit_log). The one feature that needs more — the
 * owner-only data reset (TRUNCATE) — must then refuse cleanly and change nothing.
 */
const on = process.env.TEST_APP_ROLE === '1';
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { if (on) { h = await harness(); c = await cast(h); } });
after(async () => { if (on) await h.close(); });

test('least privilege: the destructive data reset is refused and changes nothing', { skip: !on }, async () => {
  const before = (await h.db.query(`SELECT (SELECT count(*) FROM employees) AS e, (SELECT count(*) FROM audit_log) AS a`)).rows[0];
  const r = await h.call(c.t.owner, 'POST', '/admin/data-reset', { employees: [], attendance: [], dryRun: false, confirm: 'امسح البيانات' });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error.message, 'Operation not allowed', 'no table name in the answer');
  const after = (await h.db.query(`SELECT (SELECT count(*) FROM employees) AS e, (SELECT count(*) FROM audit_log) AS a`)).rows[0];
  assert.equal(after.e, before.e);
});

test('least privilege: the runtime role cannot change the schema or the audit trail', { skip: !on }, async () => {
  const r = await h.db.query(`SELECT has_schema_privilege('va_app_test', 'public', 'CREATE') AS c,
    has_table_privilege('va_app_test', 'audit_log', 'UPDATE') AS u, has_table_privilege('va_app_test', 'audit_log', 'DELETE') AS d,
    has_table_privilege('va_app_test', 'employees', 'TRUNCATE') AS t, has_table_privilege('va_app_test', 'cash_receipts', 'DELETE') AS cd`);
  assert.deepEqual(r.rows[0], { c: false, u: false, d: false, t: false, cd: false });
});
