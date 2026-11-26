import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { WIPE, WIPE_IF_PRESENT } from '../src/modules/data-reset.ts';

/**
 * The owner's data reset on both schemas: before migration 092 (marketing intelligence) and after it.
 * 092 is not part of this branch; the two tables it adds that reference WIPE tables are created below with 092's exact
 * column and foreign-key definitions (db/proposed/092_marketing_intelligence.sql on feat/marketing-intelligence).
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
// TEST_APP_ROLE=1 (api-ci's least-privilege run): the API connects as the runtime role, which has no TRUNCATE by
// design — the reset is refused there and must leave everything as it was (least-privilege.test.ts covers the role)
const APP_ROLE = process.env.TEST_APP_ROLE === '1';
/** under the runtime role: the confirmed reset is refused (409) and nothing is deleted */
async function refusedUnderRuntimeRole(tables: string[]) {
  const before = await Promise.all(tables.map(count));
  const r = await reset(c.t.owner, { dryRun: false, confirm: CONFIRM });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.deepEqual(await Promise.all(tables.map(count)), before, 'nothing deleted');
}
before(async () => { h = await harness('2026-11-26T10:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

const CONFIRM = 'امسح البيانات';
const reset = (token: string | null, extra: Record<string, unknown> = {}) =>
  h.call(token, 'POST', '/admin/data-reset', { employees: [], attendance: [], ...extra });
const count = async (t: string) => Number((await h.db.query(`SELECT count(*)::int AS n FROM ${t}`)).rows[0].n);

/** a company, a campaign of it and a lead of that campaign (the rows the new tables point at) */
async function activity() {
  const company = (await h.db.query(`INSERT INTO marketing_companies (name, kind, created_by) VALUES ($1, 'commission', $2) RETURNING id`,
    [`شركة ${Math.random().toString(36).slice(2, 8)}`, c.ids.owner])).rows[0].id;
  const campaign = (await h.db.query(`INSERT INTO lead_campaigns (name, marketing_company_id) VALUES ('حملة', $1) RETURNING id`, [company])).rows[0].id;
  const lead = (await h.db.query(`INSERT INTO leads (full_name, phone, phone_norm, campaign_id) VALUES ('عميل', '01011112222', '01011112222', $1) RETURNING id`,
    [campaign])).rows[0].id;
  return { company, campaign, lead };
}

/** the two 092 tables that hold foreign keys to WIPE tables — 092's own definitions */
const CREATE_092_DEPENDENTS = `
  CREATE TABLE lead_campaign_owners (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id          uuid NOT NULL REFERENCES lead_campaigns(id) ON DELETE CASCADE ON UPDATE CASCADE,
    marketing_company_id uuid REFERENCES marketing_companies(id) ON DELETE SET NULL ON UPDATE CASCADE,
    from_at              timestamptz NOT NULL,
    to_at                timestamptz,
    CONSTRAINT lead_campaign_owners_period CHECK (to_at IS NULL OR to_at >= from_at));
  CREATE TABLE lead_quality_events (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id    uuid NOT NULL REFERENCES leads(id) ON DELETE CASCADE ON UPDATE CASCADE,
    from_q     text NOT NULL,
    to_q       text NOT NULL CHECK (to_q IN ('unreviewed', 'qualified', 'not_qualified', 'invalid_contact', 'duplicate', 'unreachable')),
    reason     text NOT NULL DEFAULT '' CHECK (length(reason) <= 500),
    evidence   jsonb,
    by_id      uuid REFERENCES employees(id) ON DELETE SET NULL ON UPDATE CASCADE,
    at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT lead_quality_events_reason CHECK (to_q IN ('unreviewed', 'qualified') OR length(trim(reason)) >= 3));`;

test('the dependent-table list is exactly the two 092 tables with foreign keys to WIPE tables, never a WIPE table itself', () => {
  assert.deepEqual(WIPE_IF_PRESENT, ['lead_quality_events', 'lead_campaign_owners']);
  assert.ok(WIPE_IF_PRESENT.every((t) => !WIPE.includes(t)));
  assert.ok(['leads', 'lead_campaigns', 'marketing_companies'].every((t) => WIPE.includes(t)), 'the tables they reference are wiped');
});

test('pre-092 schema: authorization unchanged and the reset succeeds exactly as before (no extra table)', async () => {
  for (const t of WIPE_IF_PRESENT) assert.equal((await h.db.query(`SELECT to_regclass($1) AS r`, [`public.${t}`])).rows[0].r, null, `${t} absent`);
  await activity();
  // the unchanged list truncates fine on this schema (done inside a transaction that is then rolled back)
  const leadsBefore = await count('leads');
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

test('post-092 schema: the old TRUNCATE list is refused by PostgreSQL; the reset empties the dependent tables in the same statement', async () => {
  await h.db.query(CREATE_092_DEPENDENTS);
  const a = await activity();
  await h.db.query(`INSERT INTO lead_campaign_owners (campaign_id, marketing_company_id, from_at) VALUES ($1, $2, now())`, [a.campaign, a.company]);
  await h.db.query(`INSERT INTO lead_quality_events (lead_id, from_q, to_q, reason, by_id) VALUES ($1, 'unreviewed', 'not_qualified', 'رقم غلط', $2)`, [a.lead, c.ids.owner]);
  // the defect being fixed: the unchanged list alone cannot be truncated once 092's tables exist
  const leadsBefore = await count('leads');
  await assert.rejects(h.db.tx(async (q) => { await q.query(`TRUNCATE ${WIPE.join(', ')}`); }), /cannot truncate a table referenced in a foreign key constraint/);
  assert.equal(await count('leads'), leadsBefore, 'that refusal changed nothing');
  if (APP_ROLE) return refusedUnderRuntimeRole(['leads', 'lead_campaigns', 'marketing_companies', 'lead_quality_events', 'lead_campaign_owners']);
  const empsBefore = (await h.db.query(`SELECT * FROM employees ORDER BY id`)).rows;
  const r = await reset(c.t.owner, { dryRun: false, confirm: CONFIRM });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body.wiped).sort(), [...WIPE, ...WIPE_IF_PRESENT].sort());
  assert.equal(r.body.wiped.lead_quality_events, 1);
  assert.equal(r.body.wiped.lead_campaign_owners, 1);
  for (const t of ['leads', 'lead_campaigns', 'marketing_companies', 'lead_quality_events', 'lead_campaign_owners']) assert.equal(await count(t), 0, t);
  assert.deepEqual((await h.db.query(`SELECT * FROM employees ORDER BY id`)).rows, empsBefore, 'employees untouched (by_id is SET NULL only on delete; nothing deleted)');
  const audit = (await h.db.query(`SELECT before FROM audit_log WHERE action = 'data.reset' ORDER BY at DESC LIMIT 1`)).rows[0].before;
  assert.equal(audit.lead_quality_events, 1, 'the audit record counts them too');
});

test('a failure after the TRUNCATE rolls the whole reset back — nothing is deleted (post-092 schema)', { skip: APP_ROLE && 'the runtime role cannot TRUNCATE (refusal covered above)' }, async () => {
  const a = await activity();
  await h.db.query(`INSERT INTO lead_quality_events (lead_id, from_q, to_q, reason) VALUES ($1, 'unreviewed', 'qualified', '')`, [a.lead]);
  await h.db.query(`INSERT INTO lead_campaign_owners (campaign_id, marketing_company_id, from_at) VALUES ($1, $2, now())`, [a.campaign, a.company]);
  const before = Object.fromEntries(await Promise.all(['leads', 'lead_campaigns', 'marketing_companies', 'lead_quality_events', 'lead_campaign_owners', 'audit_log']
    .map(async (t) => [t, await count(t)])));
  // a step after the TRUNCATE inside the same transaction fails (test-only trigger)
  await h.db.query(`CREATE FUNCTION test_fail_reset() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated failure'; END $$`);
  await h.db.query(`CREATE TRIGGER test_fail_reset BEFORE UPDATE ON form_counters FOR EACH STATEMENT EXECUTE FUNCTION test_fail_reset()`);
  try {
    const r = await reset(c.t.owner, { dryRun: false, confirm: CONFIRM });
    assert.ok(r.status >= 500, `the reset failed (${r.status})`);
  } finally {
    await h.db.query(`DROP TRIGGER test_fail_reset ON form_counters; DROP FUNCTION test_fail_reset()`);
  }
  for (const [t, n] of Object.entries(before)) assert.equal(await count(t), n, `${t}: nothing deleted, no audit record`);
  // and with the failure gone the same reset completes
  assert.equal((await reset(c.t.owner, { dryRun: false, confirm: CONFIRM })).status, 200);
  assert.equal(await count('lead_quality_events'), 0);
});
