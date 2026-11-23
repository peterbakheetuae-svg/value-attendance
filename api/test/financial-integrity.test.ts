import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, insertEmployee, PW, confirmPayout, type Harness } from './helpers.ts';
import { computePayroll, computePayrollMany, loadRules } from '../src/modules/payroll-calc.ts';
import { profitParts } from '../src/modules/cash.ts';

/**
 * Financial integrity (audit F1–F9, owner-approved Option A):
 *  F1 the payroll sheet pays the SALARY part only; commissions / work expenses settle on their own linked paths, never twice
 *     (and what an older full-net sheet already paid inside the salary is never paid again)
 *  F2 no free-form salary payout; a commission only against its entitlement
 *  F3 the HR cashbox summary never counts an office expense
 *  F4 an exclusive unit's money: one limit for the request and the direct receipt; retries; no money on a marketing unit
 *  F5 advances are receivables in the owner profit · F6 ownership-share history (proposed 085)
 *  F7 one salary-part rule everywhere · F8 no void of a settled commission · F9 payouts immutable (085)
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let tGm = '';
const file = (n: string) => readFileSync(new URL(`../../db/proposed/${n}`, import.meta.url), 'utf8');
const run = (sql: string) => h.db.tx(async (q) => { await q.query(sql); });

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE code = 'GM1'`);
  tGm = await h.login('GM1', PW);
  for (const id of [c.ids.e1, c.ids.e2, c.ids.e3]) {
    await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 9000, $2)`, [id, c.ids.owner]);
    await h.db.query(`UPDATE employees SET attendance_exempt = true WHERE id = $1`, [id]);
  }
});
after(async () => { await h.close(); });

async function approvedCommission(emp: string, token: string, unitNo: string, month: string) {
  const p = (await h.db.query(`SELECT id FROM commission_projects WHERE name = 'FI-P'`)).rows[0]?.id
    ?? (await h.call(tGm, 'POST', '/commissions/projects', { name: 'FI-P', totalPct: 3, salesPct: 0.5, managerPct: 0.1, companyPct: 2.4 })).body.project.id;
  const r = await h.call(token, 'POST', '/commissions/requests', { projectId: p, unitNo, pricePerM2: 20000, areaM2: 100 });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const d = await h.call(tGm, 'POST', `/commissions/requests/${r.body.request.id}/decision`, { decision: 'approve', month });
  assert.equal(d.status, 200, JSON.stringify(d.body));
  const ent = (await h.db.query(`SELECT id, amount_egp FROM commission_entitlements WHERE request_id = $1 AND role = 'sales'`, [r.body.request.id])).rows[0];
  return { requestId: r.body.request.id as string, entitlementId: ent.id as string, amount: Number(ent.amount_egp) };
}

test('F1: the payroll sheet pays the salary part only; the commission is paid once, on its own path', async () => {
  const com = await approvedCommission(c.ids.e2, c.t.e2, 'FI-1', '2026-03');
  const b = await h.call(c.t.hr, 'POST', '/payroll-batches', { month: '2026-03' });
  assert.equal(b.status, 201, JSON.stringify(b.body));
  const line = b.body.lines.find((l: any) => l.employeeId === c.ids.e2);
  assert.equal(line.snapshot.commissions, com.amount, 'the snapshot still shows the commission');
  assert.equal(line.net, line.snapshot.salaryDue, 'the line pays the salary part');
  assert.equal(line.net, Math.max(0, Math.round((line.snapshot.net - com.amount) * 100) / 100));
  assert.equal(line.settles, 'salary_only');
  assert.equal(line.components.commissions.status, 'unpaid');
  await h.call(c.t.hr, 'POST', `/payroll-batches/${b.body.batch.id}/submit`, {});
  await h.call(tGm, 'POST', `/payroll-batches/${b.body.batch.id}/decision`, { decision: 'approve' });
  const paid = await h.call(c.t.hr, 'POST', `/payroll-batches/${b.body.batch.id}/lines/${line.id}/pay`, {});
  assert.equal(paid.status, 200, JSON.stringify(paid.body));
  // the commission: still open after the sheet → paid once through صرف العمولة, then never again
  const p1 = await h.call(c.t.hr, 'POST', '/payouts', { kind: 'commission', employeeId: c.ids.e2, amount: com.amount, month: '2026-03', entitlementId: com.entitlementId });
  assert.equal(p1.status, 201, JSON.stringify(p1.body));
  const p2 = await h.call(c.t.hr, 'POST', '/payouts', { kind: 'commission', employeeId: c.ids.e2, amount: com.amount, month: '2026-03', entitlementId: com.entitlementId });
  assert.equal(p2.status, 409, 'never twice');
  const pr: any = await computePayroll(h.db, c.ids.e2, '2026-03-01', '2026-03-10', await loadRules(h.db));
  assert.equal(pr.components.commissions.status, 'paid');
  assert.equal(pr.components.salary.status, 'paid');
  // what left the boxes for him = salary part + commission, exactly once each
  const sum = Number((await h.db.query(`SELECT sum(amount_egp) s FROM payouts WHERE employee_id = $1 AND status <> 'cancelled'`, [c.ids.e2])).rows[0].s);
  assert.equal(Math.round(sum * 100) / 100, Math.round((line.net + com.amount) * 100) / 100);
  // F8: a paid commission is not voided
  assert.equal((await h.call(c.t.owner, 'POST', `/commissions/requests/${com.requestId}/void`, { reason: 'تجربة إلغاء' })).status, 409);
});

test('F1 legacy: a month an older sheet paid in full (commission inside the salary) — the commission is never paid again', async () => {
  const com = await approvedCommission(c.ids.e3, c.t.e3, 'FI-2', '2026-02');
  const pr0: any = await computePayroll(h.db, c.ids.e3, '2026-02-01', '2026-03-10', await loadRules(h.db));
  // an old-style sheet line (before the salary-only rule): its snapshot holds the whole net, commission included, and
  // its payout pays that whole net as «salary», linked to the line
  const bt = (await h.db.query(`INSERT INTO payroll_batches (period, status, prepared_by, submitted_at, decided_by, decided_at)
      VALUES ('2026-02-01','approved',$1,now(),$2,now()) RETURNING id`, [c.ids.hr, c.ids.owner])).rows[0];
  const ln = (await h.db.query(`INSERT INTO payroll_batch_lines (batch_id, employee_id, snapshot, net_egp) VALUES ($1,$2,$3,$4) RETURNING id`,
    [bt.id, c.ids.e3, JSON.stringify({ net: pr0.net, commissions: pr0.commissions, workExpenses: pr0.workExpenses }), pr0.net])).rows[0];
  const old = (await h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, note, created_by, batch_line_id) VALUES ($1,'salary',$2,'2026-02-01','مرتب (كشف قديم)',$3,$4) RETURNING id`,
    [c.ids.e3, pr0.net, c.ids.hr, ln.id])).rows[0];
  await confirmPayout(h, c.t.e3, c.t.hr, old.id);
  const pr: any = await computePayroll(h.db, c.ids.e3, '2026-02-01', '2026-03-10', await loadRules(h.db));
  assert.equal(pr.components.commissions.coveredBySalary, com.amount);
  assert.equal(pr.components.commissions.status, 'paid');
  const ent = (await h.call(c.t.hr, 'GET', '/commissions/entitlements?scope=all')).body.entitlements.find((x: any) => x.id === com.entitlementId);
  assert.equal(ent.payment, 'paid_in_payroll');
  const again = await h.call(c.t.hr, 'POST', '/payouts', { kind: 'commission', employeeId: c.ids.e3, amount: com.amount, month: '2026-02', entitlementId: com.entitlementId });
  assert.equal(again.status, 409);
  assert.equal(again.body.error.details.reason, 'settled_in_payroll');
  const v = await h.call(c.t.owner, 'POST', `/commissions/requests/${com.requestId}/void`, { reason: 'تجربة إلغاء' });
  assert.equal(v.body.error.details.reason, 'settled_in_payroll', 'F8');
});

test('F2: no free-form salary payout; a commission only against its entitlement', async () => {
  const s = await h.call(c.t.hr, 'POST', '/payouts', { kind: 'salary', employeeId: c.ids.e1, amount: 999999, month: '2026-03' });
  assert.equal(s.body.error.details.reason, 'salary_path_required');
  const k = await h.call(c.t.hr, 'POST', '/payouts', { kind: 'commission', employeeId: c.ids.e1, amount: 500, month: '2026-03' });
  assert.equal(k.body.error.details.reason, 'entitlement_required');
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM payouts WHERE employee_id = $1`, [c.ids.e1])).rows[0].n, 0);
});

test('F7: salaries list, payroll sheet and dashboards agree on the salary part', async () => {
  const rules = await loadRules(h.db);
  const pr: any = await computePayroll(h.db, c.ids.e2, '2026-03-01', '2026-03-10', rules);
  const row = (await h.call(c.t.hr, 'GET', '/payouts/salaries?month=2026-03')).body.salaries.find((x: any) => x.employeeId === c.ids.e2);
  assert.equal(row.due, pr.components.salary.due);
  assert.equal(row.remaining, pr.components.salary.remaining);
  const many: any = (await computePayrollMany(h.db, [c.ids.e1, c.ids.e2, c.ids.e3], '2026-03-01', '2026-03-10', rules)).get(c.ids.e2);
  assert.deepEqual(many, pr, 'one employee or many: the same result');
});

test('F3: an office expense waiting for approval never reaches the HR cashbox summary', async () => {
  await h.db.query(`INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, occurred_at, recorded_by, status)
                    VALUES ('office', 123456, 'مسحوبات الملاك', 'سحب', 'مالك', now(), $1, 'pending_approval')`, [c.ids.owner]);
  const hr = (await h.call(c.t.hr, 'GET', '/cash/summary')).body;
  assert.equal(hr.office, undefined);
  assert.equal(hr.hr.expensesAwaitingApproval.amount, 0);
  assert.equal(hr.hr.expensesAwaitingApproval.count, 0);
});

test('F4: an exclusive unit\'s deposit / down payment is collected once across both paths; retries; no money on a marketing unit', async () => {
  const pr = await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'FI-برج', ownerName: 'مالك العقار', ownerPhone: '0100' });
  assert.equal(pr.status, 201, JSON.stringify(pr.body));
  const u = await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pr.body.project.id, unitNo: 'X-1', clientName: 'عميل', unitPrice: 1_000_000,
    depositAmount: 50_000, paymentMethod: 'cash' });
  assert.equal(u.status, 201, JSON.stringify(u.body));
  const uid = u.body.unit.id;
  // the deposit recorded directly first, with a retry of the same form
  const ref = '0b6f1e2a-7c1d-4f7e-9a51-3c2b1d0e9f11';
  const d1 = await h.call(c.t.hr, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'reservation', amount: 50_000, clientRef: ref });
  assert.equal(d1.status, 201, JSON.stringify(d1.body));
  const d2 = await h.call(c.t.hr, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'reservation', amount: 50_000, clientRef: ref });
  assert.equal(d2.status, 200); assert.equal(d2.body.duplicate, true); assert.equal(d2.body.receipt.id, d1.body.receipt.id);
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'reservation', amount: 1 })).status, 400, 'nothing left of the deposit');
  // the pending request for the same deposit closed itself — it cannot be received a second time
  const pend = await h.db.query(`SELECT id, status FROM ex_payments WHERE unit_id = $1 AND kind = 'reservation'`, [uid]);
  assert.equal(pend.rows[0].status, 'cancelled');
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/payments/${pend.rows[0].id}/receive`, {})).status, 409);
  const sum = Number((await h.db.query(`SELECT sum(amount_egp) s FROM cash_receipts WHERE ex_unit_id = $1 AND status = 'posted'`, [uid])).rows[0].s);
  assert.equal(sum, 50_000, 'the deposit is in once');
  // a marketing (broker) project's unit holds no money of ours
  const mk = await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'FI-تسويق', ownerName: 'مطور', ownerPhone: '0101', developerName: 'مطور', kind: 'marketing' });
  const mu = await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: mk.body.project.id, unitNo: 'M-1', clientName: 'عميل٢', unitPrice: 900_000 });
  const x = await h.call(c.t.hr, 'POST', `/exclusive/units/${mu.body.unit.id}/receipts`, { kind: 'reservation', amount: 10_000 });
  assert.equal(x.body.error?.details?.reason, 'not_exclusive');
});

test('F4: a request is never received over what was already recorded directly', async () => {
  const pid = (await h.db.query(`SELECT id FROM commission_projects WHERE name = 'FI-برج'`)).rows[0].id;
  const u = await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'X-2', clientName: 'عميل٣', unitPrice: 1_000_000, depositAmount: 40_000, paymentMethod: 'cash' });
  const uid = u.body.unit.id;
  // part of the deposit recorded directly, then the full request confirmed → refused (it would collect 40k + 10k)
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'reservation', amount: 10_000 })).status, 201);
  const pend = (await h.db.query(`SELECT id FROM ex_payments WHERE unit_id = $1 AND kind = 'reservation' AND status = 'pending'`, [uid])).rows[0];
  const r = await h.call(c.t.hr, 'POST', `/exclusive/payments/${pend.id}/receive`, {});
  assert.equal(r.status, 409); assert.equal(r.body.error.details.reason, 'over_collect'); assert.equal(r.body.error.details.remaining, 30_000);
});

test('F5: an advance paid through the cashbox is a receivable — out of the profit costs until it is deducted from a salary', async () => {
  const ov0 = (await h.call(c.t.owner, 'GET', '/cash/overview')).body.result;
  const adv = (await h.db.query(`INSERT INTO advance_requests (employee_id, kind, period, amount_egp, status, created_by, decided_by, decided_at)
      VALUES ($1,'advance','2026-04-01',3000,'confirmed',$1,$2,now()) RETURNING id`, [c.ids.e1, c.ids.owner])).rows[0];
  const p = await h.call(c.t.hr, 'POST', '/payouts', { kind: 'advance', employeeId: c.ids.e1, amount: 3000, month: '2026-04', advanceId: adv.id });
  assert.equal(p.status, 201, JSON.stringify(p.body));
  await confirmPayout(h, c.t.e1, c.t.hr, p.body.payout.id);
  const ov1 = (await h.call(c.t.owner, 'GET', '/cash/overview')).body;
  assert.equal(ov1.expenses.payroll.advance, 3000, 'the cash movement is still shown as it happened');
  assert.equal(ov1.result.advancesPaid, 3000);
  assert.equal(ov1.result.costs, ov0.costs, 'but the office\'s costs (and so the owners\' profit) do not move');
  // April's salary handed over and received → the advance comes off it → it becomes a cost then
  h.now.value = new Date('2026-05-02T09:00:00Z');
  const sal = await h.call(c.t.hr, 'POST', '/payouts/salary', { employeeId: c.ids.e1, month: '2026-04' });
  assert.equal(sal.status, 201, JSON.stringify(sal.body));
  await confirmPayout(h, c.t.e1, c.t.hr, sal.body.payout.id);
  const ov2 = (await h.call(c.t.owner, 'GET', '/cash/overview')).body.result;
  assert.equal(ov2.advancesRecovered, 3000);
  assert.equal(Math.round((ov2.costs - ov0.costs) * 100) / 100, Math.round((Number(sal.body.payout.amount_egp) + 3000) * 100) / 100,
    'the salary cost = what he got + the advance deducted from it');
  h.now.value = new Date('2026-03-10T08:00:00Z');
});

test('085: one live payout per request; a payout\'s money is fixed; ownership-share history; second run changes nothing (forward-only)', async () => {
  await run(file('085_financial_integrity.sql'));
  await run(file('085_financial_integrity.sql')); // idempotent
  const p = (await h.db.query(`SELECT id FROM payouts WHERE status = 'received' LIMIT 1`)).rows[0];
  await assert.rejects(h.db.query(`UPDATE payouts SET amount_egp = amount_egp + 1 WHERE id = $1`, [p.id]), /cannot be changed/);
  await assert.rejects(h.db.query(`UPDATE payouts SET status = 'cancelled' WHERE id = $1`, [p.id]), /final/);
  const adv = (await h.db.query(`SELECT advance_id, employee_id, created_by FROM payouts WHERE advance_id IS NOT NULL AND status <> 'cancelled' LIMIT 1`)).rows[0];
  await assert.rejects(h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, created_by, advance_id) VALUES ($1,'advance',1,'2026-04-01',$2,$3)`,
    [adv.employee_id, adv.created_by, adv.advance_id]), /payouts_one_per_advance/);

  // shares: 60 / 40 since always; from May 2026 50 / 50 — earlier months keep 60 / 40
  const o2 = await insertEmployee(h.db, { code: 'OWN2', name: 'مالك ٢', role: 'owner' });
  await h.db.query(`DELETE FROM company_owner_shares`);
  await h.db.query(`INSERT INTO company_owners (employee_id, pct) VALUES ($1, 60), ($2, 40) ON CONFLICT (employee_id) DO UPDATE SET pct = EXCLUDED.pct`, [c.ids.owner, o2]);
  await h.db.query(`INSERT INTO company_owner_shares (employee_id, pct, effective_from) VALUES ($1, 60, '2000-01-01'), ($2, 40, '2000-01-01')`, [c.ids.owner, o2]);
  await h.db.query(`INSERT INTO cash_receipts (kind, amount_egp, cashbox, actual_recipient_id, payer_name, purpose, payment_method, occurred_at, recorded_by)
                    VALUES ('commission', 100000, 'office', $1, 'مطور', 'عمولة مارس', 'cash', '2026-03-05T10:00:00Z', $1)`, [c.ids.owner]);
  const before = (await h.call(c.t.owner, 'GET', '/cash/injections')).body.owners.find((x: any) => x.id === c.ids.owner).account.profit;
  h.now.value = new Date('2026-05-03T09:00:00Z');
  assert.equal((await h.call(c.t.owner, 'PUT', '/cash/owners', { owners: [{ employeeId: c.ids.owner, pct: 50 }, { employeeId: o2, pct: 50 }] })).status, 200);
  const hist = (await h.db.query(`SELECT pct, to_char(effective_from, 'YYYY-MM-DD') f FROM company_owner_shares WHERE employee_id = $1 ORDER BY effective_from`, [c.ids.owner])).rows;
  assert.deepEqual(hist.map((x) => [Number(x.pct), x.f]), [[60, '2000-01-01'], [50, '2026-05-01']]);
  const after = (await h.call(c.t.owner, 'GET', '/cash/injections')).body.owners.find((x: any) => x.id === c.ids.owner).account.profit;
  // only the months from May on use 50%: the difference is exactly May's (and later) net × (50% − 60%)
  const fromMay = (await profitParts(h.db, null, null)).months.filter((m) => m.month >= '2026-05-01').reduce((t, m) => t + m.net, 0);
  assert.equal(Math.round((after - before) * 100) / 100, Math.round(fromMay * -0.1 * 100) / 100, 'earlier months keep the 60% share');
  h.now.value = new Date('2026-03-10T08:00:00Z');

});
