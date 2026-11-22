// 085: the ownership-share history starts at the real operational baseline — the first month (Cairo time) with any
// recorded money movement, or the month the migration runs on a database with none — never at an invented 2000-01.
// Today's percentages are kept as they are; nothing earlier than the baseline is claimed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, insertEmployee } from './helpers.ts';

const file = (n: string) => readFileSync(new URL(`../../db/proposed/${n}`, import.meta.url), 'utf8');
const history = async (h: any) => (await h.db.query(`SELECT employee_id, pct::float8 AS pct, to_char(effective_from, 'YYYY-MM-DD') AS f
  FROM company_owner_shares ORDER BY effective_from, employee_id`)).rows;

test('085 on a database with no money movement yet (after the pre-launch clean-up): the history starts this month', async () => {
  const h = await harness('2026-03-10T08:00:00Z'); const c = await cast(h);
  try {
    const o2 = await insertEmployee(h.db, { code: 'OWB', name: 'مالك ب', role: 'owner' });
    await h.db.query(`INSERT INTO company_owners (employee_id, pct) VALUES ($1, 70), ($2, 30)
      ON CONFLICT (employee_id) DO UPDATE SET pct = EXCLUDED.pct`, [c.ids.owner, o2]);
    for (const t of ['cash_receipts', 'cash_expenses', 'payouts']) {
      assert.equal(Number((await h.db.query(`SELECT count(*) n FROM ${t}`)).rows[0].n), 0, `${t} is empty here`);
    }
    await h.db.tx(async (q) => { await q.query(file('085_financial_integrity.sql')); });
    const month = (await h.db.query(`SELECT to_char(date_trunc('month', now() AT TIME ZONE 'Africa/Cairo'), 'YYYY-MM-DD') m`)).rows[0].m;
    const rows = await history(h);
    assert.equal(rows.length, 2);
    assert.ok(rows.every((r: any) => r.f === month), `every share from ${month}: ${JSON.stringify(rows)}`);
    assert.deepEqual(rows.map((r: any) => r.pct).sort(), [30, 70], 'today\'s percentages, unchanged');
    // a second run adds nothing
    await h.db.tx(async (q) => { await q.query(file('085_financial_integrity.sql')); });
    assert.deepEqual(await history(h), rows);
  } finally { await h.close(); }
});

test('085 with recorded money: the history starts at the first recorded month (Cairo time), not 2000-01', async () => {
  const h = await harness('2026-01-31T23:30:00Z'); // 1 February 01:30 in Cairo
  const c = await cast(h);
  try {
    // the earliest movement: an expense recorded at 2026-01-31 23:30 UTC = February in Cairo
    const e = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 50, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل' });
    assert.equal(e.status, 201, JSON.stringify(e.body));
    // a later payout (March)
    await h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, created_by, status)
      VALUES ($1, 'salary', 100, '2026-03-01', $2, 'pending')`, [c.ids.e1, c.ids.hr]);
    await h.db.query(`INSERT INTO company_owners (employee_id, pct) VALUES ($1, 100)
      ON CONFLICT (employee_id) DO UPDATE SET pct = EXCLUDED.pct`, [c.ids.owner]);
    await h.db.tx(async (q) => { await q.query(file('085_financial_integrity.sql')); });
    const rows = await history(h);
    assert.deepEqual(rows.map((r: any) => [r.pct, r.f]), [[100, '2026-02-01']], 'from the first recorded month, in Cairo time');
    assert.equal(Number((await h.db.query(`SELECT count(*) n FROM company_owner_shares WHERE effective_from < '2026-02-01'`)).rows[0].n), 0,
      'no earlier (invented) history');
  } finally { await h.close(); }
});
