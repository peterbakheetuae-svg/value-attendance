import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, regrantAppRole, type Harness } from './helpers.ts';
import { WIPE, approvedWipeSet, externalDependentTables } from '../src/modules/data-reset.ts';

/**
 * The owner's data reset on production's schema (every file of db/migrations: 001–091). 089 added
 * brokerage_deals.lead_id → leads and brokerage_deals is outside the reset: an empty one joins the TRUNCATE, one holding
 * deals refuses the reset (409) and nothing changes. A brokerage deal can never be deleted (087's guard), so the refusal
 * runs last.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const APP_ROLE = process.env.TEST_APP_ROLE === '1';   // the runtime role has no TRUNCATE by design
before(async () => { h = await harness('2026-11-26T10:00:00Z', { migrationsExcept: [] }); c = await cast(h); });
after(async () => { await h.close(); });

const CONFIRM = 'امسح البيانات';
const reset = (extra: Record<string, unknown> = {}, token = c.t.owner) => h.call(token, 'POST', '/admin/data-reset', { employees: [], attendance: [], ...extra });
const confirmed = () => reset({ dryRun: false, confirm: CONFIRM });
const count = async (t: string) => Number((await h.db.query(`SELECT count(*)::int AS n FROM ${t}`)).rows[0].n);
const external = async () => externalDependentTables(h.db, await approvedWipeSet(h.db));
async function lead() {
  const company = (await h.db.query(`INSERT INTO marketing_companies (name, kind, created_by) VALUES ($1, 'commission', $2) RETURNING id`,
    [`شركة ${Math.random().toString(36).slice(2, 8)}`, c.ids.owner])).rows[0].id;
  const campaign = (await h.db.query(`INSERT INTO lead_campaigns (name, marketing_company_id) VALUES ('حملة', $1) RETURNING id`, [company])).rows[0].id;
  return (await h.db.query(`INSERT INTO leads (full_name, phone, phone_norm, campaign_id) VALUES ('عميل', '01011112222', '01011112222', $1) RETURNING id`, [campaign])).rows[0].id;
}

test('no CASCADE in any SQL statement of the reset module', () => {
  const sql = [...readFileSync(new URL('../src/modules/data-reset.ts', import.meta.url), 'utf8').matchAll(/`([^`]*)`/g)].map((m) => m[1]);
  assert.ok(sql.some((s) => /TRUNCATE/.test(s)));
  assert.deepEqual(sql.filter((s) => /\bCASCADE\b/i.test(s)), []);
});

test('production schema: WIPE alone is refused by PostgreSQL (089); the catalogs give the dependents; owner rules unchanged', async () => {
  assert.ok(!WIPE.includes('brokerage_deals'));
  const ext = await external();
  assert.ok(ext.includes('brokerage_deals') && ext.every((t) => !WIPE.includes(t)));
  await assert.rejects(h.db.tx(async (q) => { await q.query(`TRUNCATE ${WIPE.join(', ')}`); }), /cannot truncate a table referenced in a foreign key constraint/);
  await lead();
  assert.equal((await h.call(null, 'POST', '/admin/data-reset', { dryRun: false, confirm: CONFIRM })).status, 401);
  assert.equal((await reset({ dryRun: false, confirm: CONFIRM }, c.t.hr)).status, 403);
  assert.equal((await reset({ dryRun: false })).status, 400, 'needs the confirmation words');
  const dry = await reset();
  assert.equal(dry.status, 200);
  assert.deepEqual(dry.body.dependents.map((d: any) => d.table), ext);
  assert.deepEqual(dry.body.dependencyBlockers, []);
});

test('production schema: several dependencies, also through each other — empty ones included, any with rows refuses', async () => {
  await h.db.query(`CREATE TABLE test_dep_a (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), lead_id uuid REFERENCES leads(id));
    CREATE TABLE test_dep_b (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), a_id uuid REFERENCES test_dep_a(id))`);
  if (APP_ROLE) await regrantAppRole(h);   // the runtime role reads the test-only tables like any other
  try {
    const l = await lead();
    const aId = (await h.db.query(`INSERT INTO test_dep_a (lead_id) VALUES ($1) RETURNING id`, [l])).rows[0].id;
    await h.db.query(`INSERT INTO test_dep_b (a_id) VALUES ($1)`, [aId]);
    const leadsBefore = await count('leads');
    assert.deepEqual((await reset()).body.dependencyBlockers, [{ table: 'test_dep_a', rows: 1 }, { table: 'test_dep_b', rows: 1 }]);
    const r = await confirmed();
    assert.equal(r.status, 409);
    assert.deepEqual(r.body.error.details.dependents, [{ table: 'test_dep_a', rows: 1 }, { table: 'test_dep_b', rows: 1 }]);
    assert.equal(await count('leads'), leadsBefore); assert.equal(await count('test_dep_b'), 1);
    await h.db.query(`DELETE FROM test_dep_b; DELETE FROM test_dep_a`);
  } finally {
    if (APP_ROLE) await h.db.query(`DROP TABLE IF EXISTS test_dep_b; DROP TABLE IF EXISTS test_dep_a`);
  }
  if (APP_ROLE) return;
  const ok = await confirmed();
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(ok.body.wiped.test_dep_a, 0); assert.equal(ok.body.wiped.test_dep_b, 0);
  assert.equal(await count('leads'), 0);
  await h.db.query(`DROP TABLE test_dep_b; DROP TABLE test_dep_a`);
});

test('production schema: empty brokerage_deals → the reset succeeds; it joins the TRUNCATE empty, nothing outside the scope is lost', async () => {
  const ext = await external();
  await lead();
  const r = await confirmed();
  if (APP_ROLE) { assert.equal(r.status, 409); return; }
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body.wiped).sort(), [...await approvedWipeSet(h.db), ...ext].sort());
  for (const t of ext) assert.equal(r.body.wiped[t], 0, `${t} was empty`);
  assert.equal(await count('leads'), 0);
});

test('production schema: a brokerage deal of a lead refuses the reset (409) — the deal, the leads and the audit log unchanged', async () => {
  const l = await lead();
  await h.db.query(`INSERT INTO brokerage_deals (kind, property, owner_name, client_name, price_egp, arrangement, owner_commission_egp,
      contributor_id, closer_id, proposed_by, lead_id) VALUES ('rental', 'شقة اختبار', 'مالك', 'مستأجر', 10000, 'owner_month', 10000, $1, $1, $1, $2)`, [c.ids.e1, l]);
  const dealBefore = (await h.db.query(`SELECT * FROM brokerage_deals`)).rows;
  const leadsBefore = await count('leads');
  const resetsBefore = (await h.db.query(`SELECT count(*)::int n FROM audit_log WHERE action = 'data.reset'`)).rows[0].n;
  assert.deepEqual((await reset()).body.dependencyBlockers, [{ table: 'brokerage_deals', rows: 1 }], 'the dry run shows it');
  const r = await confirmed();
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error.details.reason, 'dependent_records');
  assert.deepEqual(r.body.error.details.dependents, [{ table: 'brokerage_deals', rows: 1 }]);
  assert.deepEqual((await h.db.query(`SELECT * FROM brokerage_deals`)).rows, dealBefore, 'the brokerage deal is untouched');
  assert.equal(await count('leads'), leadsBefore);
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM audit_log WHERE action = 'data.reset'`)).rows[0].n, resetsBefore);
});

test('protected financial records still refuse first (unchanged)', async () => {
  assert.equal((await h.call(c.t.owner, 'POST', '/admin/opening-advance', { employeeId: c.ids.e1, amount: 500, month: '2026-11', note: 'سلفة' })).status, 201);
  const r = await confirmed();
  assert.equal(r.status, 409);
  assert.equal(r.body.error.details.reason, 'protected_data');
  assert.equal(await count('advance_requests'), 1);
});
