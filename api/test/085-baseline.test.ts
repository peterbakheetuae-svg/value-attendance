// 085: the month from which today's ownership shares are in force is a business fact the owner states when 085 is
// applied (SET valunivo.owner_share_baseline = 'YYYY-MM-01'). 085 never guesses it — not 2000-01, not the first recorded
// transaction. Without it, it refuses (and changes nothing) whenever there are shares to copy. Today's percentages are
// kept as they are; nothing earlier than the stated month is claimed; the stated month is in the audit log.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, insertEmployee } from './helpers.ts';

const SQL = readFileSync(new URL('../../db/proposed/085_financial_integrity.sql', import.meta.url), 'utf8');
const apply = (h: any, baseline?: string) => h.db.tx(async (q: any) => {
  if (baseline !== undefined) await q.query(`SELECT set_config('valunivo.owner_share_baseline', $1, true)`, [baseline]);
  await q.query(SQL);
});
const installed = async (h: any) => (await h.db.query(`SELECT to_regclass('public.company_owner_shares') IS NOT NULL ok`)).rows[0].ok;
const history = async (h: any) => (await h.db.query(`SELECT employee_id, pct::float8 AS pct, to_char(effective_from, 'YYYY-MM-DD') AS f
  FROM company_owner_shares ORDER BY effective_from, employee_id`)).rows;
async function withOwners(at = '2026-03-10T08:00:00Z') {
  const h = await harness(at); const c = await cast(h);
  const o2 = await insertEmployee(h.db, { code: 'OWB', name: 'مالك ب', role: 'owner' });
  await h.db.query(`INSERT INTO company_owners (employee_id, pct) VALUES ($1, 70), ($2, 30)
    ON CONFLICT (employee_id) DO UPDATE SET pct = EXCLUDED.pct`, [c.ids.owner, o2]);
  return { h, c, o2 };
}

test('085 with owners and no stated month: refuses, names the setting, and changes nothing', async () => {
  const { h } = await withOwners();
  try {
    await assert.rejects(apply(h), /state the month today's ownership shares are in force from/);
    assert.equal(await installed(h), false, 'the whole migration rolled back: no history table, no guard');
    assert.equal((await h.db.query(`SELECT to_regclass('public.payouts_one_per_advance') t`)).rows[0].t, null);
  } finally { await h.close(); }
});

test('085: a stated month that is not a month start, is in the future, or is not a date is refused', async () => {
  const { h } = await withOwners();
  try {
    await assert.rejects(apply(h, '2026-02-15'), /first day of a month/);
    await assert.rejects(apply(h, '2099-01-01'), /in the future/);
    await assert.rejects(apply(h, 'since always'), /must be a date/);
    assert.equal(await installed(h), false);
  } finally { await h.close(); }
});

test('085 with a stated month: exactly today\'s shares from that month, nothing earlier, audited; a re-run changes nothing', async () => {
  const { h, c, o2 } = await withOwners();
  try {
    // money recorded before the stated month: 085 states it (warning), it does not move the stated month
    await h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, created_by, status) VALUES ($1, 'salary', 100, '2026-01-01', $2, 'pending')`,
      [c.ids.e1, c.ids.hr]);
    await apply(h, '2026-02-01');
    const rows = await history(h);
    assert.deepEqual(rows.map((r: any) => [r.employee_id, r.pct, r.f]).sort(),
      [[c.ids.owner, 70, '2026-02-01'], [o2, 30, '2026-02-01']].sort(), 'today\'s percentages, from the stated month only');
    assert.equal(Number((await h.db.query(`SELECT count(*) n FROM company_owner_shares WHERE effective_from < '2026-02-01'`)).rows[0].n), 0,
      'no earlier history — not 2000-01, not the January payout');
    const a = (await h.db.query(`SELECT after FROM audit_log WHERE action = 'owners.share_baseline'`)).rows;
    assert.equal(a.length, 1); assert.equal(a[0].after.effective_from, '2026-02-01'); assert.equal(a[0].after.source, 'migration_085');
    await apply(h); // a re-run needs no stated month (the history exists) and adds nothing
    assert.deepEqual(await history(h), rows);
    assert.equal(Number((await h.db.query(`SELECT count(*) n FROM audit_log WHERE action = 'owners.share_baseline'`)).rows[0].n), 1);
  } finally { await h.close(); }
});

test('085 with no owners yet (the state after the pre-launch clean-up): installs, copies and asks nothing', async () => {
  const h = await harness('2026-03-10T08:00:00Z'); await cast(h);
  try {
    assert.equal(Number((await h.db.query(`SELECT count(*) n FROM company_owners`)).rows[0].n), 0, 'no owner recorded yet');
    await apply(h);
    assert.equal(await installed(h), true);
    assert.deepEqual(await history(h), []);
  } finally { await h.close(); }
});
