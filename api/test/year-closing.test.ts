import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, PW, type Harness } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';
import { CHECKLIST } from '../src/modules/year-closing.ts';

/**
 * تقفيل السنة (db/proposed/083, applied here to a throwaway database only): the figures come from the existing records,
 * the rules find the problems, the closing is blocked until they are dealt with, the owner approves and closes, the snapshot
 * is frozen, the balances are carried, the closed year takes no back-dated money, and reopening keeps the old version.
 * The module never writes to a source table.
 */
const SQL = readFileSync(new URL('../../db/proposed/083_financial_year_closing.sql', import.meta.url), 'utf8');
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let tGm = '';
const at = (iso: string) => { h.now.value = new Date(iso); };
const get = async (tok = c.t.owner, y = 2025) => (await h.call(tok, 'GET', `/closing/${y}`)).body;
const ledger = async () => (await h.db.query(`SELECT count(*)::int AS n, COALESCE(sum(amount), 0)::numeric AS s FROM cash_ledger`)).rows[0];
let pendingId = '';
const r2 = (x: number) => Math.round(x * 100) / 100;

before(async () => {
  h = await harness('2025-03-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gm.body.id]);
  tGm = await h.login('GM1', PW);
  // a year of ordinary activity (2025), through the existing API
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/adjustments', { cashbox: 'office', kind: 'opening', amount: 50000, reason: 'رصيد افتتاحي' })).status, 201);
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/adjustments', { cashbox: 'hr', kind: 'opening', amount: 5000, reason: 'رصيد افتتاحي' })).status, 201);
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'other', amount: 1000, payerName: 'عميل', purpose: 'تحصيل' })).status, 201);
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 800, category: 'ضيافة', reason: 'بوفيه', beneficiary: 'محل' })).status, 201);
  const big = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 4000, category: 'إيجار', reason: 'إيجار المكتب', beneficiary: 'المالك' });
  assert.equal(big.status, 201, JSON.stringify(big.body));
  pendingId = big.body.expense.id;
  // the database's own now() is the real date: the opening balances belong to the start of 2025
  // (test database only: the «adjustments are final» trigger is paused for this one fix-up)
  await h.db.tx(async (q) => {
    await q.query(`SET LOCAL session_replication_role = replica`);
    await q.query(`UPDATE cash_adjustments SET created_at = '2025-01-01T08:00:00Z'`);
  });
  await h.db.query(`INSERT INTO company_owners (employee_id, pct) VALUES ($1, 100)`, [c.ids.owner]);
  at('2026-01-10T08:00:00Z');
});
after(async () => { await h.close(); });

test('before 083 runs: the figures are shown read-only; every write says the module is not installed; permissions', async () => {
  const r = await get();
  assert.equal(r.installed, false);
  assert.equal(r.status, 'not_started');
  assert.equal(r.figures.treasury.office.closing, 50000);
  assert.equal(r.figures.treasury.hr.closing, 5000 + 1000 - 800, 'the pending expense is not in the ledger');
  assert.ok(r.preview.some((d: any) => d.key === `pending_expense:${pendingId}` && d.blocking), 'the problems are shown before a review starts');
  const s = await h.call(c.t.owner, 'POST', '/closing/2025/start', {});
  assert.equal(s.status, 409); assert.equal(s.body.error.details.reason, 'module_not_installed');
  for (const t of [c.t.e1, c.t.hr, c.t.sm1]) assert.equal((await h.call(t, 'GET', '/closing/2025')).status, 403, 'no cash.office → nothing');
  assert.equal((await h.call(c.t.owner, 'GET', '/closing/2027')).status, 404, 'a future year');
  await h.db.query(SQL);
});

test('the review: problems block approval; a system problem is fixed at its source, not by a click', async () => {
  const before = await ledger();
  assert.equal((await h.call(c.t.hr, 'POST', '/closing/2025/start', {})).status, 403);
  const s = await h.call(tGm, 'POST', '/closing/2025/start', {});
  assert.equal(s.status, 201, JSON.stringify(s.body));
  assert.equal((await h.call(tGm, 'POST', '/closing/2025/start', {})).status, 409, 'one live closing per year');
  let r = await get();
  assert.equal(r.status, 'needs_attention');
  const pend = r.issues.find((i: any) => i.key === `pending_expense:${pendingId}`);
  assert.ok(pend && pend.blocking && pend.status === 'open');
  assert.ok(r.blockers.some((b: any) => b.code === 'items_incomplete') && r.blockers.some((b: any) => b.code === 'blocking_issues'));
  const ap = await h.call(c.t.owner, 'POST', '/closing/2025/approve', { confirm: true });
  assert.equal(ap.status, 409); assert.equal(ap.body.error.details.reason, 'blocked');
  const fix = await h.call(c.t.owner, 'POST', `/closing/issues/${pend.id}`, { action: 'resolve', note: 'خلاص اتحلت' });
  assert.equal(fix.status, 409); assert.equal(fix.body.error.details.reason, 'fix_at_source');
  // the expense is decided in its own system (posted on the day of approval — 2026, not the closed year)
  assert.equal((await h.call(c.t.owner, 'POST', `/cash/expenses/${pendingId}/decision`, { decision: 'approve' })).status, 200);
  r = await get();
  const after = r.issues.find((i: any) => i.key === `pending_expense:${pendingId}`);
  assert.equal(after.status, 'resolved', 'resolved by its source, kept in the list');
  assert.equal(after.resolvedBy, 'السيستم');
  assert.equal(r.figures.treasury.hr.closing, 5200, 'the 2025 figures did not move');
  // the module itself wrote nothing to the money (the one approval above is the cash system's own, dated 2026)
  const now = await ledger();
  assert.equal(now.n, before.n + 1);
});

test('checklist, counted cash, a difference explained by an approved reconciliation, approval, closing', async () => {
  const keys = CHECKLIST.flatMap((x) => x.items).filter((i) => !i.verify).map((i) => i.key);
  assert.equal((await h.call(c.t.e1, 'POST', '/closing/2025/items', { keys, status: 'reviewed' })).status, 403);
  assert.equal((await h.call(tGm, 'POST', '/closing/2025/items', { keys, status: 'reviewed' })).status, 200);
  assert.equal((await h.call(tGm, 'POST', '/closing/2025/items', { key: 'treasury.office_count', status: 'reviewed' })).status, 400, 'a count needs the amount');
  assert.equal((await h.call(tGm, 'POST', '/closing/2025/items', { key: 'treasury.office_count', status: 'reviewed', verifiedAmount: 50000 })).status, 200);
  assert.equal((await h.call(tGm, 'POST', '/closing/2025/items', { key: 'treasury.hr_count', status: 'reviewed', verifiedAmount: 5100 })).status, 400, 'a difference needs its reason');
  assert.equal((await h.call(tGm, 'POST', '/closing/2025/items', { key: 'treasury.hr_count', status: 'reviewed', verifiedAmount: 5100, note: 'ناقص 100 فكة' })).status, 200);
  let r = await get();
  const diff = r.issues.find((i: any) => i.key === 'treasury_diff:hr');
  assert.ok(diff && diff.blocking && diff.amount === -100, JSON.stringify(diff));
  // the reconciliation explains it; it changes no cashbox
  const rec = await h.call(tGm, 'POST', '/closing/2025/reconciliations', { type: 'treasury', source: 'cash_ledger', sourceId: 'hr', amount: -100, reason: 'عجز فكة متفق عليه' });
  assert.equal(rec.status, 201);
  assert.equal((await h.call(tGm, 'POST', `/closing/reconciliations/${rec.body.reconciliation.id}/decision`, { decision: 'approve' })).status, 403, 'not his own');
  assert.equal((await h.call(c.t.owner, 'POST', `/closing/reconciliations/${rec.body.reconciliation.id}/decision`, { decision: 'approve' })).status, 200);
  r = await get();
  assert.equal(r.issues.find((i: any) => i.key === 'treasury_diff:hr').status, 'resolved');
  assert.equal(r.figures.treasury.hr.closing, 5200, 'the ledger is untouched by the reconciliation');
  assert.equal(r.status, 'ready_for_approval', JSON.stringify(r.blockers));
  assert.equal(r.summary.readinessPct, 100);
  assert.equal(r.figures.profit.allocations[0].pct, 100);
  // approval: the owner, explicitly
  assert.equal((await h.call(tGm, 'POST', '/closing/2025/approve', { confirm: true })).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', '/closing/2025/approve', {})).status, 400);
  assert.equal((await h.call(c.t.owner, 'POST', '/closing/2025/approve', { confirm: true, notes: 'تمام' })).status, 200);
  // a review change after the approval takes it back
  await h.call(tGm, 'POST', '/closing/2025/items', { key: 'general.pending', status: 'reviewed', note: 'تاني' });
  assert.equal((await get()).status, 'ready_for_approval');
  assert.equal((await h.call(c.t.owner, 'POST', '/closing/2025/close', { confirm: 'CLOSE 2025' })).body.error.details.reason, 'not_approved');
  assert.equal((await h.call(c.t.owner, 'POST', '/closing/2025/approve', { confirm: true })).status, 200);
  // a figure of the year changes after the approval (a 2025 deduction written directly, no rule catches it) → refused
  await h.db.query(`INSERT INTO salary_adjustments (employee_id, period, kind, amount_egp, reason, status, created_by, decided_by, decided_at)
                    VALUES ($1, '2025-06-01', 'deduction', 100, 'جزاء متأخر', 'approved', $2, $3, now())`, [c.ids.e1, c.ids.hr, c.ids.owner]);
  const ch = await h.call(c.t.owner, 'POST', '/closing/2025/close', { confirm: 'CLOSE 2025' });
  assert.equal(ch.status, 409); assert.equal(ch.body.error.details.reason, 'figures_changed');
  assert.equal((await h.call(c.t.owner, 'POST', '/closing/2025/close', { confirm: 'yes' })).status, 400);
  assert.equal((await h.call(c.t.owner, 'POST', '/closing/2025/approve', { confirm: true })).status, 200);
  const both = await Promise.all([1, 2].map(() => h.call(c.t.owner, 'POST', '/closing/2025/close', { confirm: 'CLOSE 2025' })));
  assert.deepEqual(both.map((x) => x.status).sort(), [200, 409], 'closed once, even in parallel');
});

test('a closed year: frozen snapshot, read-only review, no back-dated money, balances carried', async () => {
  const r = await get();
  assert.equal(r.status, 'closed');
  assert.ok(r.snapshot.hash);
  assert.equal(r.figures.treasury.office.closing, 50000);
  assert.equal(r.figures.employees.adjustments.deductions, 100);
  const w = await h.call(tGm, 'POST', '/closing/2025/items', { key: 'general.pending', status: 'reviewed' });
  assert.equal(w.status, 409); assert.equal(w.body.error.details.reason, 'year_closed');
  await assert.rejects(h.db.query(`UPDATE fy_closings SET snapshot = '{}' WHERE fiscal_year = 2025`), /لا تتغير/);
  await assert.rejects(h.db.query(`DELETE FROM fy_closings`), /لا تُحذف/);
  await assert.rejects(h.db.query(`UPDATE fy_opening_balances SET carry_balance = 1`), /لا تتعدل/);
  // money dated inside the closed year is refused; after it, accepted
  const back = await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'other', amount: 50, payerName: 'عميل', purpose: 'متأخر', occurredAt: '2025-12-30T10:00:00Z' });
  assert.equal(back.status, 409, JSON.stringify(back.body));
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/receipts', { recipient: 'hr', kind: 'other', amount: 50, payerName: 'عميل', purpose: 'جديد' })).status, 201);
  const ob = (await h.call(c.t.owner, 'GET', '/closing/2026/opening-balances')).body.carriedIn;
  assert.equal(ob.find((x: any) => x.entityType === 'cashbox' && x.entityId === 'office').carryBalance, 50000);
  assert.equal(ob.find((x: any) => x.entityType === 'cashbox' && x.entityId === 'hr').carryBalance, 5200);
  const y26 = await get(c.t.owner, 2026);
  assert.equal(y26.figures.treasury.office.opening, 50000, 'next year opens where the closed one ended');
  assert.ok(!y26.preview.some((d: any) => d.key.startsWith('opening_mismatch')));
  assert.equal(y26.figures.partners.list[0].openingSource, 'closing');
  const years = (await h.call(c.t.owner, 'GET', '/closing/years')).body.years;
  assert.equal(years.find((x: any) => x.year === 2025).status, 'closed');
});

test('closed year: the employees\' money of its months is final too (add / change / move / delete refused); a payout after it is fine', async () => {
  const adj = (await h.db.query(`SELECT id FROM salary_adjustments WHERE period = '2025-06-01'`)).rows[0].id;
  await assert.rejects(h.db.query(`INSERT INTO salary_adjustments (employee_id, period, kind, amount_egp, reason, status, created_by)
                                    VALUES ($1, '2025-07-01', 'bonus', 50, 'علاوة متأخرة', 'pending', $2)`, [c.ids.e2, c.ids.hr]), /مقفولة/, 'insert');
  await assert.rejects(h.db.query(`UPDATE salary_adjustments SET amount_egp = 1 WHERE id = $1`, [adj]), /مقفولة/, 'amount');
  await assert.rejects(h.db.query(`UPDATE salary_adjustments SET status = 'rejected' WHERE id = $1`, [adj]), /مقفولة/, 'status');
  await assert.rejects(h.db.query(`UPDATE salary_adjustments SET period = '2026-01-01' WHERE id = $1`, [adj]), /مقفولة/, 'moved out of the closed year');
  await assert.rejects(h.db.query(`DELETE FROM salary_adjustments WHERE id = $1`, [adj]), /مقفولة/, 'delete');
  await h.db.query(`UPDATE salary_adjustments SET reason = 'جزاء متأخر (تصحيح الوصف)' WHERE id = $1`, [adj]); // a text-only change is fine
  // a 2026 row can not be moved INTO the closed year either
  const n26 = (await h.db.query(`INSERT INTO salary_adjustments (employee_id, period, kind, amount_egp, reason, status, created_by)
                                  VALUES ($1, '2026-01-01', 'bonus', 50, 'علاوة يناير', 'pending', $2) RETURNING id`, [c.ids.e2, c.ids.hr])).rows[0].id;
  await assert.rejects(h.db.query(`UPDATE salary_adjustments SET period = '2025-12-01' WHERE id = $1`, [n26]), /مقفولة/, 'moved into the closed year');
  await assert.rejects(h.db.query(`INSERT INTO advance_requests (employee_id, kind, period, amount_egp, status, created_by)
                                    VALUES ($1, 'advance', '2025-12-01', 500, 'pending', $1)`, [c.ids.e1]), /مقفولة/, 'advance');
  await assert.rejects(h.db.query(`INSERT INTO payroll_batches (period, prepared_by) VALUES ('2025-12-01', $1)`, [c.ids.hr]), /مقفولة/, 'payroll sheet');
  // December's money handed over in January: a payment of the open year (dated when received) — never blocked
  await h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, created_by) VALUES ($1, 'salary', 1000, '2025-12-01', $2)`, [c.ids.e1, c.ids.hr]);
  // the existing salary-adjustment workflow of the open year still works through its API
  const ok26 = await h.call(c.t.hr, 'POST', '/finance/adjustments', { employeeId: c.ids.e3, kind: 'bonus', amountEgp: 100, reason: 'علاوة', month: '2026-01' });
  assert.ok(ok26.status < 300, JSON.stringify(ok26.body));
});

test('partners: the closing uses the ownerAccounts definition (a loss counts), carried once — no separate «undistributed» balance', async () => {
  const r = await get();
  const net = r.figures.result.net;
  assert.ok(net < 0, 'the test year ended with a loss');
  const p = r.figures.partners.list[0];
  assert.equal(r.figures.partners.definition, 'ownerAccounts');
  assert.equal(p.allocated, net, 'share of the year = pct × net, a loss too');
  assert.equal(p.closing, r2(p.opening + p.contributions + p.allocated - p.withdrawals));
  const ob = (await h.call(c.t.owner, 'GET', '/closing/2026/opening-balances')).body.carriedIn;
  assert.equal(ob.filter((x: any) => x.entityType.startsWith('partner')).length, r.figures.partners.list.length, 'one carried row per partner');
  assert.ok(!ob.some((x: any) => x.entityType === 'partner_distribution'));
  assert.equal(ob.find((x: any) => x.entityType === 'partner').carryBalance, p.closing);
  const y26 = await get(c.t.owner, 2026);
  assert.equal(y26.figures.partners.list[0].opening, p.closing, 'next year opens with the carried balance');
  assert.ok(!y26.preview.some((d: any) => d.key.startsWith('partner_opening_mismatch')));
});

test('permissions: a closed year\'s snapshot shows only what the person may see; salaries need «عرض المرتبات»', async () => {
  // the fine-grained keys (proposed 066) in this throwaway database, and the manager kept to the main cashbox only
  await h.db.tx(async (q) => { await q.query(readFileSync(new URL('../../db/proposed/066_fine_grained_permissions.sql', import.meta.url), 'utf8')); });
  forgetPermissionKeys();
  const gm = (await h.db.query(`SELECT id FROM employees WHERE code = 'GM1'`)).rows[0].id;
  for (const k of ['finance.company_income', 'cash.owner_funds', 'exclusive.view_finance', 'employee.salary_read']) {
    await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, $2, false)
                      ON CONFLICT (employee_id, perm_key) DO UPDATE SET allow = false`, [gm, k]);
  }
  const r = await get(tGm);
  assert.equal(r.status, 'closed');
  assert.equal(r.figures.result, null, 'no office profit');
  assert.equal(r.figures.profit.available, false);
  assert.equal(r.figures.revenue.commissions, undefined, 'no partial revenue in its place');
  assert.equal(r.figures.revenue.commissionReceived, undefined);
  assert.equal(r.figures.partners.available, false, 'no owners\' accounts');
  assert.equal(r.figures.payables.ownersTrust, null);
  assert.deepEqual(r.figures.employees.advancesOutstanding.byEmployee, []);
  assert.ok(!r.snapshot.openingBalances.some((o: any) => o.entityType.startsWith('partner') || o.entityType.startsWith('employee_')));
  const ob = (await h.call(tGm, 'GET', '/closing/2026/opening-balances')).body.carriedIn;
  assert.ok(ob.length > 0 && !ob.some((o: any) => o.entityType.startsWith('partner')));
  assert.ok(r.figures.treasury.office.closing === 50000, 'the cashboxes stay visible to the main cashbox');
  assert.equal((await h.call(tGm, 'GET', '/closing/2025/transactions?kind=payouts')).status, 403);
  assert.equal((await h.call(tGm, 'GET', '/closing/2025/transactions?kind=ledger')).status, 200);
  // the owner still sees everything
  const o = await get();
  assert.ok(o.figures.result && o.figures.partners.available === true);
  assert.equal((await h.call(c.t.owner, 'GET', '/closing/2025/transactions?kind=payouts')).status, 200);
});

test('reopening: owner only, with a reason; the old version and its snapshot stay; a new version starts', async () => {
  const hash = (await get()).snapshot.hash;
  assert.equal((await h.call(tGm, 'POST', '/closing/2025/reopen', { reason: 'غلطة في الجرد محتاجة تتصحح', confirm: 'REOPEN 2025' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', '/closing/2025/reopen', { reason: 'قصير', confirm: 'REOPEN 2025' })).status, 400);
  const ro = await h.call(c.t.owner, 'POST', '/closing/2025/reopen', { reason: 'غلطة في الجرد محتاجة تتصحح', confirm: 'REOPEN 2025' });
  assert.equal(ro.status, 200, JSON.stringify(ro.body));
  assert.ok(ro.body.impact.openingBalancesSuperseded >= 2);
  const old = (await h.db.query(`SELECT status, snapshot_hash FROM fy_closings WHERE fiscal_year = 2025 AND version = 1`)).rows[0];
  assert.deepEqual([old.status, old.snapshot_hash], ['reopened', hash]);
  assert.equal((await h.call(c.t.owner, 'GET', '/closing/2026/opening-balances')).body.carriedIn.every((x: any) => x.status === 'superseded'), true);
  // 4-A: the next year can not be approved / closed while this one is reopened and not closed again
  assert.equal((await h.call(tGm, 'POST', '/closing/2026/start', {})).status, 201);
  assert.ok((await get(c.t.owner, 2026)).blockers.some((b: any) => b.code === 'previous_year_reopened'));
  // the reopened year takes back-dated corrections again (only while it is not closed)
  assert.equal((await h.call(tGm, 'POST', '/closing/2025/start', {})).status, 201);
  const b26 = (await get(c.t.owner, 2026)).blockers.map((b: any) => b.code);
  assert.ok(b26.includes('previous_year_open') && !b26.includes('previous_year_reopened'));
  const r = await get();
  assert.equal(r.closing.version, 2);
  assert.equal(r.versions.length, 2);
  const ev = (await h.call(c.t.owner, 'GET', '/closing/2025/audit')).body.events.map((x: any) => x.action);
  for (const a of ['closing.start', 'closing.item', 'closing.reconciliation', 'closing.approve', 'closing.close', 'closing.reopen', 'closing.approval_withdrawn']) {
    assert.ok(ev.includes(a), `audit has ${a}`);
  }
});
