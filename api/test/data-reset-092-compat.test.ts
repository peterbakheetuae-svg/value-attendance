import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { migrate } from '../src/migrate-core.ts';
import { WIPE, WIPE_IF_PRESENT, WIPE_ACTIVITY_IF_PRESENT } from '../src/modules/data-reset.ts';

/**
 * The owner's data reset on both schemas: before migration 092 (marketing intelligence) and after it.
 * This file's database is built from db/migrations with everything except 092 — production's state before the release
 * (all of 001–091, the release files included) — and later the real runner applies 092 to it, as a deploy would.
 */
const M092 = '092_marketing_intelligence.sql';
const NEW_092 = [...WIPE_IF_PRESENT, ...WIPE_ACTIVITY_IF_PRESENT];

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
// TEST_APP_ROLE=1 (api-ci's least-privilege run): the API connects as the runtime role, which has no TRUNCATE by
// design — the reset is refused there and must leave everything as it was (least-privilege.test.ts covers the role)
const APP_ROLE = process.env.TEST_APP_ROLE === '1';
before(async () => {
  h = await harness('2026-11-26T10:00:00Z', { migrationsExcept: [M092] }); c = await cast(h);
});
after(async () => { await h.close(); });

const CONFIRM = 'امسح البيانات';
const reset = (token: string | null, extra: Record<string, unknown> = {}) =>
  h.call(token, 'POST', '/admin/data-reset', { employees: [], attendance: [], ...extra });
const count = async (t: string) => Number((await h.db.query(`SELECT count(*)::int AS n FROM ${t}`)).rows[0].n);
const exists = async (t: string) => (await h.db.query(`SELECT to_regclass($1) AS r`, [`public.${t}`])).rows[0].r !== null;
/** the WIPE tables a table references through a foreign key */
const referencedWipeTables = async (t: string) => (await h.db.query(`
    SELECT DISTINCT confrelid::regclass::text AS ref FROM pg_constraint WHERE contype = 'f' AND conrelid = $1::regclass`, [t]))
  .rows.map((r) => String(r.ref)).filter((r) => WIPE.includes(r)).sort();

/** under the runtime role: the confirmed reset is refused (409) and nothing is deleted */
async function refusedUnderRuntimeRole(tables: string[]) {
  const before = await Promise.all(tables.map(count));
  const r = await reset(c.t.owner, { dryRun: false, confirm: CONFIRM });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.deepEqual(await Promise.all(tables.map(count)), before, 'nothing deleted');
}

/** a company, a campaign of it and a lead of that campaign (the rows the new tables point at) */
async function activity() {
  const company = (await h.db.query(`INSERT INTO marketing_companies (name, kind, created_by) VALUES ($1, 'commission', $2) RETURNING id`,
    [`شركة ${Math.random().toString(36).slice(2, 8)}`, c.ids.owner])).rows[0].id;
  const campaign = (await h.db.query(`INSERT INTO lead_campaigns (name, marketing_company_id) VALUES ('حملة', $1) RETURNING id`, [company])).rows[0].id;
  const lead = (await h.db.query(`INSERT INTO leads (full_name, phone, phone_norm, campaign_id) VALUES ('عميل', '01011112222', '01011112222', $1) RETURNING id`,
    [campaign])).rows[0].id;
  return { company, campaign, lead };
}

test('the lists: WIPE unchanged; foreign-key dependents and 092 activity tables are separate, present-only, never in WIPE', () => {
  assert.deepEqual(WIPE_IF_PRESENT, ['lead_quality_events', 'lead_campaign_owners']);
  assert.deepEqual(WIPE_ACTIVITY_IF_PRESENT, ['meta_insights_daily']);
  assert.ok(NEW_092.every((t) => !WIPE.includes(t)));
  assert.ok(['leads', 'lead_campaigns', 'marketing_companies'].every((t) => WIPE.includes(t)), 'the tables they reference are wiped');
});

test('pre-092 schema: authorization unchanged and the reset succeeds exactly as before (no extra table)', async () => {
  for (const t of NEW_092) assert.equal(await exists(t), false, `${t} absent`);
  assert.equal((await h.db.query(`SELECT 1 FROM information_schema.columns WHERE table_name = 'leads' AND column_name = 'quality'`)).rowCount, 0, 'the real pre-092 schema');
  await activity();
  const leadsBefore = await count('leads');
  // the unchanged list truncates fine on this schema (done inside a transaction that is then rolled back)
  await assert.rejects(h.db.tx(async (q) => { await q.query(`TRUNCATE ${WIPE.join(', ')}`); throw new Error('roll back'); }), /roll back/);
  assert.equal(await count('leads'), leadsBefore, 'rolled back');
  assert.equal((await reset(null, { dryRun: false, confirm: CONFIRM })).status, 401);
  assert.equal((await reset(c.t.hr, { dryRun: false, confirm: CONFIRM })).status, 403, 'not the owner');
  assert.equal((await reset(c.t.owner, { dryRun: false })).status, 400, 'needs the confirmation words');
  const dry = await reset(c.t.owner);
  assert.equal(dry.status, 200);
  assert.equal(dry.body.dryRun, true);
  assert.equal(await count('leads'), leadsBefore, 'dry run changed nothing');
  if (APP_ROLE) return refusedUnderRuntimeRole(['leads', 'lead_campaigns', 'marketing_companies']);
  const r = await reset(c.t.owner, { dryRun: false, confirm: CONFIRM });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body.wiped).sort(), [...WIPE].sort(), 'the same tables as before the change');
  for (const t of ['leads', 'lead_campaigns', 'marketing_companies']) assert.equal(await count(t), 0, t);
});

test('post-092 schema (the real 092): the old TRUNCATE list is refused; the reset empties the dependents and meta_insights_daily too', async () => {
  // the real runner on the production-shaped database: exactly 092 is pending, and only 092 is applied
  assert.deepEqual(await migrate(h.db), [M092]);
  assert.deepEqual(await migrate(h.db), [], 'applied once');
  for (const t of NEW_092) assert.equal(await exists(t), true, `${t} present`);
  // the classification follows the real foreign keys
  assert.deepEqual(await referencedWipeTables('lead_quality_events'), ['leads']);
  assert.deepEqual(await referencedWipeTables('lead_campaign_owners'), ['lead_campaigns', 'marketing_companies']);
  assert.deepEqual(await referencedWipeTables('meta_insights_daily'), [], 'no foreign key: not needed by the TRUNCATE, emptied as activity');
  const a = await activity();   // 092's trigger records the campaign's owner itself
  await h.db.query(`INSERT INTO lead_quality_events (lead_id, from_q, to_q, reason, by_id) VALUES ($1, 'unreviewed', 'not_qualified', 'رقم غلط', $2)`, [a.lead, c.ids.owner]);
  await h.db.query(`INSERT INTO meta_insights_daily (meta_campaign_id, day, spend, fetched_at) VALUES ('777', '2026-11-25', 90, now())`);
  assert.equal(await count('lead_campaign_owners'), 1, 'recorded by 092\'s trigger');
  // the defect the dynamic list fixes: the unchanged list alone cannot be truncated once 092's tables exist
  const leadsBefore = await count('leads');
  await assert.rejects(h.db.tx(async (q) => { await q.query(`TRUNCATE ${WIPE.join(', ')}`); }), /cannot truncate a table referenced in a foreign key constraint/);
  assert.equal(await count('leads'), leadsBefore, 'that refusal changed nothing');
  if (APP_ROLE) return refusedUnderRuntimeRole(['leads', 'lead_campaigns', 'marketing_companies', ...NEW_092]);
  const empsBefore = (await h.db.query(`SELECT * FROM employees ORDER BY id`)).rows;
  const r = await reset(c.t.owner, { dryRun: false, confirm: CONFIRM });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body.wiped).sort(), [...WIPE, ...NEW_092].sort());
  assert.equal(r.body.wiped.lead_quality_events, 1);
  assert.equal(r.body.wiped.lead_campaign_owners, 1);
  assert.equal(r.body.wiped.meta_insights_daily, 1);
  for (const t of ['leads', 'lead_campaigns', 'marketing_companies', ...NEW_092]) assert.equal(await count(t), 0, t);
  assert.deepEqual((await h.db.query(`SELECT * FROM employees ORDER BY id`)).rows, empsBefore, 'employees untouched');
  const audit = (await h.db.query(`SELECT before FROM audit_log WHERE action = 'data.reset' ORDER BY at DESC LIMIT 1`)).rows[0].before;
  assert.equal(audit.lead_quality_events, 1, 'the audit record counts them too');
  assert.equal(audit.meta_insights_daily, 1);
});

test('a failure after the TRUNCATE rolls the whole reset back — nothing is deleted (post-092 schema)', { skip: APP_ROLE && 'the runtime role cannot TRUNCATE (refusal covered above)' }, async () => {
  const a = await activity();
  await h.db.query(`INSERT INTO lead_quality_events (lead_id, from_q, to_q, reason) VALUES ($1, 'unreviewed', 'qualified', '')`, [a.lead]);
  await h.db.query(`INSERT INTO meta_insights_daily (meta_campaign_id, day, spend, fetched_at) VALUES ('777', '2026-11-25', 90, now())`);
  const tables = ['leads', 'lead_campaigns', 'marketing_companies', ...NEW_092, 'audit_log'];
  const before = await Promise.all(tables.map(count));
  // a step after the TRUNCATE inside the same transaction fails (test-only trigger)
  await h.db.query(`CREATE FUNCTION test_fail_reset() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated failure'; END $$`);
  await h.db.query(`CREATE TRIGGER test_fail_reset BEFORE UPDATE ON form_counters FOR EACH STATEMENT EXECUTE FUNCTION test_fail_reset()`);
  try {
    const r = await reset(c.t.owner, { dryRun: false, confirm: CONFIRM });
    assert.ok(r.status >= 500, `the reset failed (${r.status})`);
  } finally {
    await h.db.query(`DROP TRIGGER test_fail_reset ON form_counters; DROP FUNCTION test_fail_reset()`);
  }
  assert.deepEqual(await Promise.all(tables.map(count)), before, 'nothing deleted, no audit record');
  // and with the failure gone the same reset completes
  assert.equal((await reset(c.t.owner, { dryRun: false, confirm: CONFIRM })).status, 200);
  for (const t of NEW_092) assert.equal(await count(t), 0, t);
});
