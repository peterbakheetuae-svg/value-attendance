import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, regrantAppRole, type Harness } from './helpers.ts';
import { migrate } from '../src/migrate-core.ts';
import { WIPE, WIPE_IF_PRESENT, WIPE_ACTIVITY_IF_PRESENT, approvedWipeSet, externalDependentTables } from '../src/modules/data-reset.ts';

/**
 * The owner's data reset on the real schemas, before and after migration 092 (marketing intelligence).
 * This file's database is built from db/migrations with everything except 092 — production's state before the release
 * (001–091, the release files included: e.g. 089's brokerage_deals.lead_id → leads) — and later the real runner applies
 * 092 to it, as a deploy would.
 *
 * Rules under test: tables outside the approved scope that reference what the reset empties (found from the catalogs)
 * are emptied only when they hold no rows; any holding rows refuses the whole reset (409) and nothing changes.
 */
const M092 = '092_marketing_intelligence.sql';
const NEW_092 = [...WIPE_IF_PRESENT, ...WIPE_ACTIVITY_IF_PRESENT];

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
// TEST_APP_ROLE=1 (api-ci's least-privilege run): the API connects as the runtime role, which has no TRUNCATE by
// design — a confirmed reset is refused there and must leave everything as it was (least-privilege.test.ts covers the role)
const APP_ROLE = process.env.TEST_APP_ROLE === '1';
before(async () => { h = await harness('2026-11-26T10:00:00Z', { migrationsExcept: [M092] }); c = await cast(h); });
after(async () => { await h.close(); });

const CONFIRM = 'امسح البيانات';
const reset = (token: string | null, extra: Record<string, unknown> = {}) =>
  h.call(token, 'POST', '/admin/data-reset', { employees: [], attendance: [], ...extra });
const confirmed = () => reset(c.t.owner, { dryRun: false, confirm: CONFIRM });
const count = async (t: string) => Number((await h.db.query(`SELECT count(*)::int AS n FROM ${t}`)).rows[0].n);
const exists = async (t: string) => (await h.db.query(`SELECT to_regclass($1) AS r`, [`public.${t}`])).rows[0].r !== null;
const rowsOf = async (t: string) => (await h.db.query(`SELECT * FROM ${t} ORDER BY 1`)).rows;
/** the WIPE tables a table references through a foreign key */
const referencedWipeTables = async (t: string) => (await h.db.query(`
    SELECT DISTINCT confrelid::regclass::text AS ref FROM pg_constraint WHERE contype = 'f' AND conrelid = $1::regclass`, [t]))
  .rows.map((r) => String(r.ref)).filter((r) => WIPE.includes(r)).sort();
const external = async () => externalDependentTables(h.db, await approvedWipeSet(h.db));

/** under the runtime role: the confirmed reset is refused (409) and nothing is deleted */
async function refusedUnderRuntimeRole(tables: string[]) {
  const before = await Promise.all(tables.map(count));
  const r = await confirmed();
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.deepEqual(await Promise.all(tables.map(count)), before, 'nothing deleted');
}

/** a company, a campaign of it and a lead of that campaign */
async function activity() {
  const company = (await h.db.query(`INSERT INTO marketing_companies (name, kind, created_by) VALUES ($1, 'commission', $2) RETURNING id`,
    [`شركة ${Math.random().toString(36).slice(2, 8)}`, c.ids.owner])).rows[0].id;
  const campaign = (await h.db.query(`INSERT INTO lead_campaigns (name, marketing_company_id) VALUES ('حملة', $1) RETURNING id`, [company])).rows[0].id;
  const lead = (await h.db.query(`INSERT INTO leads (full_name, phone, phone_norm, campaign_id) VALUES ('عميل', '01011112222', '01011112222', $1) RETURNING id`,
    [campaign])).rows[0].id;
  return { company, campaign, lead };
}

/** a brokerage deal (089: lead_id → leads) — a record outside the reset's scope */
const brokerageDeal = async (lead: string) => (await h.db.query(`INSERT INTO brokerage_deals (kind, property, owner_name, client_name,
    price_egp, arrangement, owner_commission_egp, contributor_id, closer_id, proposed_by, lead_id)
    VALUES ('rental', 'شقة اختبار', 'مالك', 'مستأجر', 10000, 'owner_month', 10000, $1, $1, $1, $2) RETURNING id`, [c.ids.e1, lead])).rows[0].id;

test('the lists: WIPE unchanged; foreign-key dependents and 092 activity tables are separate, present-only, never in WIPE', () => {
  assert.deepEqual(WIPE_IF_PRESENT, ['lead_quality_events', 'lead_campaign_owners']);
  assert.deepEqual(WIPE_ACTIVITY_IF_PRESENT, ['meta_insights_daily']);
  assert.ok(NEW_092.every((t) => !WIPE.includes(t)));
  assert.ok(!WIPE.includes('brokerage_deals'), 'brokerage deals are outside the reset');
});

test('no CASCADE in any SQL statement of the reset module', () => {
  const src = readFileSync(new URL('../src/modules/data-reset.ts', import.meta.url), 'utf8');
  const sql = [...src.matchAll(/`([^`]*)`/g)].map((m) => m[1]);
  assert.ok(sql.some((s) => /TRUNCATE/.test(s)), 'the TRUNCATE statement is found');
  assert.deepEqual(sql.filter((s) => /\bCASCADE\b/i.test(s)), []);
});

test('pre-092 schema: authorization and confirmation unchanged; the dependency graph is read from the catalogs', async () => {
  for (const t of NEW_092) assert.equal(await exists(t), false, `${t} absent`);
  assert.equal((await h.db.query(`SELECT 1 FROM information_schema.columns WHERE table_name = 'leads' AND column_name = 'quality'`)).rowCount, 0, 'the real pre-092 schema');
  assert.deepEqual(await referencedWipeTables('brokerage_deals'), ['leads'], '089');
  const ext = await external();
  assert.ok(ext.includes('brokerage_deals'));
  assert.ok(ext.every((t) => !WIPE.includes(t)));
  // the defect being fixed: the WIPE list alone cannot be truncated on production's schema (089), even before 092
  await assert.rejects(h.db.tx(async (q) => { await q.query(`TRUNCATE ${WIPE.join(', ')}`); }), /cannot truncate a table referenced in a foreign key constraint/);
  await activity();
  const leadsBefore = await count('leads');
  assert.equal((await reset(null, { dryRun: false, confirm: CONFIRM })).status, 401);
  assert.equal((await reset(c.t.hr, { dryRun: false, confirm: CONFIRM })).status, 403, 'not the owner');
  assert.equal((await reset(c.t.owner, { dryRun: false })).status, 400, 'needs the confirmation words');
  const dry = await reset(c.t.owner);
  assert.equal(dry.status, 200);
  assert.equal(dry.body.dryRun, true);
  assert.deepEqual(dry.body.dependents.map((d: any) => d.table), ext, 'the dry run lists the dependents');
  assert.ok(dry.body.dependents.every((d: any) => d.rows === 0));
  assert.deepEqual(dry.body.dependencyBlockers, []);
  assert.equal(await count('leads'), leadsBefore, 'dry run changed nothing');
});

test('pre-092 schema: brokerage_deals holding a deal of a lead refuses the reset (409) — the deal, the lead and everything else unchanged', async () => {
  const a = await activity();
  const deal = await brokerageDeal(a.lead);
  const dealBefore = await rowsOf('brokerage_deals');
  const leadsBefore = await count('leads');
  const dry = await reset(c.t.owner);
  assert.deepEqual(dry.body.dependencyBlockers, [{ table: 'brokerage_deals', rows: 1 }], 'the dry run shows the blocker and its rows');
  const r = await confirmed();
  assert.equal(r.status, 409, JSON.stringify(r.body));
  if (!APP_ROLE) {
    assert.equal(r.body.error.details.reason, 'dependent_records');
    assert.deepEqual(r.body.error.details.dependents, [{ table: 'brokerage_deals', rows: 1 }]);
  }
  assert.deepEqual(await rowsOf('brokerage_deals'), dealBefore, 'the brokerage deal is untouched');
  assert.equal(await count('leads'), leadsBefore, 'nothing was wiped');
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM audit_log WHERE action = 'data.reset'`)).rows[0].n, 0, 'no reset recorded');
  // the record is the owner's to handle; once it is gone the reset can run (test cleanup only)
  await h.db.query(`DELETE FROM brokerage_deals WHERE id = $1`, [deal]);
});

test('pre-092 schema: with brokerage_deals empty the reset succeeds; the empty dependents join the TRUNCATE, nothing outside the scope is lost', async () => {
  const ext = await external();
  if (APP_ROLE) return refusedUnderRuntimeRole(['leads', 'lead_campaigns', 'marketing_companies']);
  const r = await confirmed();
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body.wiped).sort(), [...WIPE, ...ext].sort(), 'the approved list plus the (empty) dependents');
  for (const t of ext) assert.equal(r.body.wiped[t], 0, `${t} was empty`);
  for (const t of ['leads', 'lead_campaigns', 'marketing_companies']) assert.equal(await count(t), 0, t);
});

test('post-092 schema (the real 092 through the real runner): the 092 tables are wiped with their rows; brokerage_deals still guarded', async () => {
  assert.deepEqual(await migrate(h.db), [M092], 'exactly 092 is pending, and only 092 is applied');
  assert.deepEqual(await migrate(h.db), [], 'applied once');
  if (APP_ROLE) await regrantAppRole(h);   // the runtime role's grants on the tables 092 created
  for (const t of NEW_092) assert.equal(await exists(t), true, `${t} present`);
  assert.deepEqual(await referencedWipeTables('lead_quality_events'), ['leads']);
  assert.deepEqual(await referencedWipeTables('lead_campaign_owners'), ['lead_campaigns', 'marketing_companies']);
  assert.deepEqual(await referencedWipeTables('meta_insights_daily'), [], 'no foreign key: emptied as activity, not for the TRUNCATE');
  const ext = await external();
  assert.ok(ext.includes('brokerage_deals') && NEW_092.every((t) => !ext.includes(t)), 'the approved 092 tables are not "external"');

  const a = await activity();
  await h.db.query(`INSERT INTO lead_quality_events (lead_id, from_q, to_q, reason, by_id) VALUES ($1, 'unreviewed', 'not_qualified', 'رقم غلط', $2)`, [a.lead, c.ids.owner]);
  await h.db.query(`INSERT INTO meta_insights_daily (meta_campaign_id, day, spend, fetched_at) VALUES ('777', '2026-11-25', 90, now())`);
  // a brokerage deal still blocks, after 092 too
  const deal = await brokerageDeal(a.lead);
  const dealBefore = await rowsOf('brokerage_deals');
  const qBefore = await count('lead_quality_events');
  const blocked = await confirmed();
  assert.equal(blocked.status, 409);
  assert.deepEqual(await rowsOf('brokerage_deals'), dealBefore);
  assert.equal(await count('lead_quality_events'), qBefore, 'nothing wiped');
  await h.db.query(`DELETE FROM brokerage_deals WHERE id = $1`, [deal]);

  if (APP_ROLE) return refusedUnderRuntimeRole(['leads', 'lead_campaigns', 'marketing_companies', ...NEW_092]);
  const empsBefore = (await h.db.query(`SELECT * FROM employees ORDER BY id`)).rows;
  const r = await confirmed();
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body.wiped).sort(), [...WIPE, ...NEW_092, ...ext].sort());
  assert.equal(r.body.wiped.lead_quality_events, 1);
  assert.equal(r.body.wiped.lead_campaign_owners, 1, 'recorded by 092\'s trigger');
  assert.equal(r.body.wiped.meta_insights_daily, 1);
  for (const t of ext) assert.equal(r.body.wiped[t], 0, `${t} was empty`);
  for (const t of ['leads', 'lead_campaigns', 'marketing_companies', ...NEW_092]) assert.equal(await count(t), 0, t);
  assert.deepEqual((await h.db.query(`SELECT * FROM employees ORDER BY id`)).rows, empsBefore, 'employees untouched');
  const audit = (await h.db.query(`SELECT before FROM audit_log WHERE action = 'data.reset' ORDER BY at DESC LIMIT 1`)).rows[0].before;
  assert.equal(audit.lead_quality_events, 1, 'the audit record counts them');
});

test('several external dependencies, also through each other: empty → included; any with rows → refused, rows kept', async () => {
  // test-only tables in this file's database: a → leads, b → a (b depends on the reset only through a)
  await h.db.query(`CREATE TABLE test_dep_a (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), lead_id uuid REFERENCES leads(id));
    CREATE TABLE test_dep_b (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), a_id uuid REFERENCES test_dep_a(id))`);
  if (APP_ROLE) await regrantAppRole(h);
  try {
    const ext = await external();
    assert.ok(ext.includes('test_dep_a') && ext.includes('test_dep_b') && ext.includes('brokerage_deals'), 'the whole graph');
    const a = await activity();
    const aId = (await h.db.query(`INSERT INTO test_dep_a (lead_id) VALUES ($1) RETURNING id`, [a.lead])).rows[0].id;
    await h.db.query(`INSERT INTO test_dep_b (a_id) VALUES ($1)`, [aId]);
    const leadsBefore = await count('leads');
    const dry = await reset(c.t.owner);
    assert.deepEqual(dry.body.dependencyBlockers, [{ table: 'test_dep_a', rows: 1 }, { table: 'test_dep_b', rows: 1 }]);
    const r = await confirmed();
    assert.equal(r.status, 409);
    if (!APP_ROLE) assert.deepEqual(r.body.error.details.dependents, [{ table: 'test_dep_a', rows: 1 }, { table: 'test_dep_b', rows: 1 }]);
    assert.equal(await count('test_dep_a'), 1); assert.equal(await count('test_dep_b'), 1); assert.equal(await count('leads'), leadsBefore, 'nothing wiped');
    await h.db.query(`DELETE FROM test_dep_b; DELETE FROM test_dep_a`);
    if (APP_ROLE) return;
    const ok = await confirmed();
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal(ok.body.wiped.test_dep_a, 0); assert.equal(ok.body.wiped.test_dep_b, 0);
    assert.equal(await count('leads'), 0);
  } finally {
    await h.db.query(`DROP TABLE IF EXISTS test_dep_b; DROP TABLE IF EXISTS test_dep_a`);
  }
});

test('a failure after the TRUNCATE rolls the whole reset back — nothing is deleted (post-092 schema)', { skip: APP_ROLE && 'the runtime role cannot TRUNCATE (refusal covered above)' }, async () => {
  const a = await activity();
  await h.db.query(`INSERT INTO lead_quality_events (lead_id, from_q, to_q, reason) VALUES ($1, 'unreviewed', 'qualified', '')`, [a.lead]);
  await h.db.query(`INSERT INTO meta_insights_daily (meta_campaign_id, day, spend, fetched_at) VALUES ('777', '2026-11-25', 90, now())`);
  const tables = ['leads', 'lead_campaigns', 'marketing_companies', ...NEW_092, 'audit_log'];
  const before = await Promise.all(tables.map(count));
  await h.db.query(`CREATE FUNCTION test_fail_reset() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated failure'; END $$`);
  await h.db.query(`CREATE TRIGGER test_fail_reset BEFORE UPDATE ON form_counters FOR EACH STATEMENT EXECUTE FUNCTION test_fail_reset()`);
  try {
    const r = await confirmed();
    assert.ok(r.status >= 500, `the reset failed (${r.status})`);
  } finally {
    await h.db.query(`DROP TRIGGER test_fail_reset ON form_counters; DROP FUNCTION test_fail_reset()`);
  }
  assert.deepEqual(await Promise.all(tables.map(count)), before, 'nothing deleted, no audit record');
  assert.equal((await confirmed()).status, 200, 'with the failure gone the same reset completes');
  for (const t of NEW_092) assert.equal(await count(t), 0, t);
});

test('protected financial records still refuse the reset first (unchanged), whatever the dependencies', async () => {
  const adv = await h.call(c.t.owner, 'POST', '/admin/opening-advance', { employeeId: c.ids.e1, amount: 500, month: '2026-11', note: 'سلفة' });
  assert.equal(adv.status, 201, JSON.stringify(adv.body));
  const advBefore = await rowsOf('advance_requests');
  const dry = await reset(c.t.owner);
  assert.ok(dry.body.blockers.some((b: any) => b.table === 'advance_requests' && b.rows >= 1), JSON.stringify(dry.body.blockers));
  const r = await confirmed();
  assert.equal(r.status, 409);
  assert.equal(r.body.error.details.reason, 'protected_data', 'the protected-record check comes first');
  assert.deepEqual(await rowsOf('advance_requests'), advBefore);
});
