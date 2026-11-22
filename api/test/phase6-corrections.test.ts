import { test, before, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, insertEmployee, PW, confirmPayout, type Harness } from './helpers.ts';
import { advanceRecoveries, profitParts } from '../src/modules/cash.ts';
import { computePayroll, loadRules } from '../src/modules/payroll-calc.ts';

/**
 * Phase 6 v4 corrections, each proven on throw-away PostgreSQL databases:
 *  F1 commission coverage comes ONLY from an older payroll sheet line's own records (never from a salary amount)
 *  F4 exclusive collections under real concurrency: one limit, idempotent client references, no deadlock
 *  F5 advances are recovered amount by amount (partial / insufficient / several payments / several months / reversals)
 *  F9 (085) a payout's every field and its confirmation history are protected in the database
 *  F6 (085) ownership-share history month by month · F7 no component counted twice
 */
const file = (n: string) => readFileSync(new URL(`../../db/proposed/${n}`, import.meta.url), 'utf8');
const r2 = (n: number) => Math.round(n * 100) / 100;
const N = (v: unknown) => Number(v ?? 0);

// ===================================================================================================== F1 + F5 + F7
describe('payroll settlement and advances', () => {
  let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let tGm = '';
  before(async () => {
    h = await harness('2026-01-10T08:00:00Z'); c = await cast(h);
    await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
    await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE code = 'GM1'`);
    tGm = await h.login('GM1', PW);
  });
  after(async () => { await h.close(); });

  let n = 0;
  async function staff(teamless = true) {
    const code = `S${++n}`;
    const id = await insertEmployee(h.db, { code, role: 'sales_employee', jobTitle: 'مستشار عقاري', joining: '2025-01-01' });
    await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 9000, $2)`, [id, c.ids.owner]);
    await h.db.query(`UPDATE employees SET attendance_exempt = true WHERE id = $1`, [id]);
    void teamless;
    return { id, token: await h.login(code, PW) };
  }
  async function approved(emp: { id: string; token: string }, unit: string, month: string) {
    h.now.value = new Date(`${month}-10T08:00:00Z`);
    const p = (await h.db.query(`SELECT id FROM commission_projects WHERE name = 'P6'`)).rows[0]?.id
      ?? (await h.call(tGm, 'POST', '/commissions/projects', { name: 'P6', totalPct: 3, salesPct: 0.5, managerPct: 0.1, companyPct: 2.4 })).body.project.id;
    const r = await h.call(emp.token, 'POST', '/commissions/requests', { projectId: p, unitNo: unit, pricePerM2: 20000, areaM2: 100 });
    assert.equal(r.status, 201, JSON.stringify(r.body));
    const d = await h.call(tGm, 'POST', `/commissions/requests/${r.body.request.id}/decision`, { decision: 'approve', month });
    assert.equal(d.status, 200, JSON.stringify(d.body));
    const e = (await h.db.query(`SELECT id, amount_egp FROM commission_entitlements WHERE request_id = $1 AND role = 'sales'`, [r.body.request.id])).rows[0];
    return { requestId: r.body.request.id as string, id: e.id as string, amount: N(e.amount_egp) };
  }
  async function batch(period: string) {
    const x = (await h.db.query(`SELECT id FROM payroll_batches WHERE period = $1 AND status <> 'cancelled'`, [period])).rows[0];
    if (x) return x.id as string;
    return (await h.db.query(`INSERT INTO payroll_batches (period, status, prepared_by, submitted_at, decided_by, decided_at)
      VALUES ($1, 'approved', $2, now(), $3, now()) RETURNING id`, [period, c.ids.hr, c.ids.owner])).rows[0].id as string;
  }
  /** an OLD-rule sheet line (whole net incl. commissions / work expenses), paid `paid` (default: in full) */
  async function legacyLine(empId: string, period: string, paid?: number, status = 'received') {
    const p: any = await computePayroll(h.db, empId, period, '2026-12-31', await loadRules(h.db));
    const b = await batch(period);
    const l = (await h.db.query(`INSERT INTO payroll_batch_lines (batch_id, employee_id, snapshot, net_egp) VALUES ($1,$2,$3,$4) RETURNING id`,
      [b, empId, JSON.stringify({ net: p.net, commissions: p.commissions, workExpenses: p.workExpenses }), Math.max(0, p.net)])).rows[0];
    await h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, note, created_by, batch_line_id, status, received_at)
      VALUES ($1,'salary',$2,$3,'مرتب',$4,$5,$6,$7)`, [empId, paid ?? Math.max(0, p.net), period, c.ids.hr, l.id, status, status === 'received' ? new Date() : null]);
    return { net: N(p.net), salaryPart: r2(N(p.net) - N(p.commissions) - N(p.workExpenses)) };
  }
  const payCommission = (empId: string, ent: { id: string }, amount: number, month: string) =>
    h.call(c.t.hr, 'POST', '/payouts', { kind: 'commission', employeeId: empId, amount, month, entitlementId: ent.id });
  const entOf = async (id: string) => (await h.call(c.t.hr, 'GET', '/commissions/entitlements?scope=all')).body.entitlements.find((x: any) => x.id === id);

  test('F1 a: a commission paid inside an OLD full-net sheet line is paid_in_payroll — never paid again, never voided', async () => {
    const e = await staff(); const com = await approved(e, 'L-1', '2025-10');
    await legacyLine(e.id, '2025-10-01');
    assert.equal((await entOf(com.id)).payment, 'paid_in_payroll');
    const again = await payCommission(e.id, com, com.amount, '2025-10');
    assert.equal(again.status, 409); assert.equal(again.body.error.details.reason, 'settled_in_payroll');
    assert.equal((await h.call(c.t.owner, 'POST', `/commissions/requests/${com.requestId}/void`, { reason: 'تجربة إلغاء' })).body.error.details.reason, 'settled_in_payroll');
  });

  test('F1 b: the new salary-only sheet leaves the commission unpaid; it is paid once on its own path', async () => {
    const e = await staff(); const com = await approved(e, 'N-1', '2025-11');
    h.now.value = new Date('2025-11-20T08:00:00Z');
    const b = await h.call(c.t.hr, 'POST', '/payroll-batches', { month: '2025-11' });
    const line = b.body.lines.find((l: any) => l.employeeId === e.id);
    assert.equal(line.settles, 'salary_only');
    assert.equal(line.snapshot.components, undefined, 'the frozen snapshot carries no stale settlement status');
    assert.equal(line.components.commissions.status, 'unpaid', 'the live status is attached instead');
    await h.call(c.t.hr, 'POST', `/payroll-batches/${b.body.batch.id}/submit`, {});
    await h.call(tGm, 'POST', `/payroll-batches/${b.body.batch.id}/decision`, { decision: 'approve' });
    assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${b.body.batch.id}/lines/${line.id}/pay`, {})).status, 200);
    assert.equal((await entOf(com.id)).payment, 'unpaid');
    assert.equal((await payCommission(e.id, com, com.amount, '2025-11')).status, 201);
    assert.equal((await payCommission(e.id, com, com.amount, '2025-11')).status, 409, 'F1 f: a repeated attempt is refused');
    // F7: each part counted once — what left the boxes = salary part + commission, and the components say the same
    const p: any = await computePayroll(h.db, e.id, '2025-11-01', '2025-11-20', await loadRules(h.db));
    const out = N((await h.db.query(`SELECT sum(amount_egp) s FROM payouts WHERE employee_id = $1 AND status <> 'cancelled'`, [e.id])).rows[0].s);
    assert.equal(r2(p.components.salary.paid + p.components.commissions.paid + p.components.workExpenses.paid), r2(out));
    assert.equal(r2(out), r2(p.components.salary.due + com.amount));
  });

  test('F1 c: a salary simply paid ABOVE its salary part settles no commission — the commission stays payable', async () => {
    const e = await staff(); const com = await approved(e, 'O-1', '2025-12');
    const p: any = await computePayroll(h.db, e.id, '2025-12-01', '2026-12-31', await loadRules(h.db));
    // an over-payment through a non-sheet salary payout (e.g. an old free-form one) — the whole net and more
    await h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, note, created_by, status, received_at)
      VALUES ($1,'salary',$2,'2025-12-01','مرتب',$3,'received',now())`, [e.id, p.net + 500, c.ids.hr]);
    const ent = await entOf(com.id);
    assert.equal(ent.payment, 'unpaid'); assert.equal(ent.coveredInPayroll, 0);
    assert.equal((await payCommission(e.id, com, com.amount, '2025-12')).status, 201, 'not blocked by an unrelated salary over-payment');
    const q: any = await computePayroll(h.db, e.id, '2025-12-01', '2026-12-31', await loadRules(h.db));
    assert.equal(q.components.commissions.coveredBySalary, 0);
    assert.equal(q.components.salary.status, 'paid');
  });

  test('F1 d/e: commission already paid separately → refused; an old sheet line that paid PART → only the rest is payable', async () => {
    const e = await staff(); const com = await approved(e, 'P-1', '2026-01');
    // the sheet line paid the salary part + 4,000 of the 10,000 commission
    const b = await batch('2026-01-01');
    const p: any = await computePayroll(h.db, e.id, '2026-01-01', '2026-12-31', await loadRules(h.db));
    const salaryPart = r2(N(p.net) - N(p.commissions) - N(p.workExpenses));
    const l = (await h.db.query(`INSERT INTO payroll_batch_lines (batch_id, employee_id, snapshot, net_egp) VALUES ($1,$2,$3,$4) RETURNING id`,
      [b, e.id, JSON.stringify({ net: p.net, commissions: p.commissions, workExpenses: p.workExpenses }), p.net])).rows[0];
    await h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, note, created_by, batch_line_id, status, received_at)
      VALUES ($1,'salary',$2,'2026-01-01','مرتب',$3,$4,'received',now())`, [e.id, salaryPart + 4000, c.ids.hr, l.id]);
    const ent = await entOf(com.id);
    assert.equal(ent.payment, 'partly_in_payroll'); assert.equal(ent.coveredInPayroll, 4000); assert.equal(ent.leftToPay, com.amount - 4000);
    assert.equal((await payCommission(e.id, com, com.amount, '2026-01')).status, 400, 'the full amount is refused');
    assert.equal((await payCommission(e.id, com, com.amount - 4000, '2026-01')).status, 201, 'the rest is paid');
    assert.equal((await payCommission(e.id, com, com.amount - 4000, '2026-01')).status, 409, 'and only once');
    const q: any = await computePayroll(h.db, e.id, '2026-01-01', '2026-12-31', await loadRules(h.db));
    assert.equal(q.components.commissions.status, 'paid');
    assert.equal(q.components.commissions.paid, com.amount, 'covered 4,000 + paid 6,000 = the commission, not more');
  });

  test('F1 g/h: mixed history — an old sheet in one month, the new rule in the next; a commission approved after the old sheet was frozen is not covered', async () => {
    const e = await staff();
    const jan = await approved(e, 'M-1', '2026-02');
    // the old sheet was frozen and its line handed over (not yet confirmed, so the month is still open for approvals)
    await legacyLine(e.id, '2026-02-01', undefined, 'pending');
    await new Promise((r) => setTimeout(r, 20));
    const late = await approved(e, 'M-2', '2026-02'); // approved AFTER the sheet was frozen
    const mar = await approved(e, 'M-3', '2026-03');
    assert.equal((await entOf(jan.id)).payment, 'paid_in_payroll');
    assert.equal((await entOf(late.id)).payment, 'unpaid', 'not in the frozen sheet → not covered by it');
    assert.equal((await entOf(mar.id)).payment, 'unpaid');
    assert.equal((await payCommission(e.id, late, late.amount, '2026-02')).status, 201);
    assert.equal((await payCommission(e.id, mar, mar.amount, '2026-03')).status, 201);
    assert.equal((await payCommission(e.id, jan, jan.amount, '2026-02')).status, 409);
  });

  // ---------------------------------------------------------------------------------------------------------- F5
  const T = '2026-12-31';
  async function advance(empId: string, period: string, amount: number, { paid = true, deductions = [] as [string, number][] } = {}) {
    const a = (await h.db.query(`INSERT INTO advance_requests (employee_id, kind, period, amount_egp, status, created_by, decided_by, decided_at)
      VALUES ($1,'advance',$2,$3,'confirmed',$1,$4,now()) RETURNING id`, [empId, period, amount, c.ids.owner])).rows[0].id as string;
    if (paid) await h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, created_by, advance_id, status, received_at)
      VALUES ($1,'advance',$2,$3,$4,$5,'received','2026-01-05T10:00:00Z')`, [empId, amount, period, c.ids.hr, a]);
    for (const [m, amt] of deductions) await h.db.query(`INSERT INTO advance_deductions (advance_id, employee_id, period, amount_egp, created_by) VALUES ($1,$2,$3,$4,$5)`,
      [a, empId, m, amt, c.ids.hr]);
    return a;
  }
  const salary = (empId: string, period: string, amount: number, status = 'received', at = '2026-04-28T10:00:00Z') =>
    h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, created_by, status, received_at)
      VALUES ($1,'salary',$2,$3,$4,$5,$6) RETURNING id`, [empId, amount, period, c.ids.hr, status, status === 'received' ? at : null]);
  const recovered = async (empId: string) => r2((await advanceRecoveries(h.db, T)).events.filter((x) => x.employeeId === empId).reduce((t, x) => t + x.amount, 0));
  const outstanding = async (empId: string) => {
    const paid = N((await h.db.query(`SELECT sum(p.amount_egp) s FROM payouts p WHERE p.employee_id = $1 AND p.kind = 'advance' AND p.status = 'received' AND p.advance_id IS NOT NULL`, [empId])).rows[0].s);
    return r2(paid - await recovered(empId));
  };

  test('F5 1/2/4: full salary → fully recovered; half received → half; two payments → two parts', async () => {
    const full = await staff(); await advance(full.id, '2026-04-01', 3000); await salary(full.id, '2026-04-01', 6000);
    assert.equal(await recovered(full.id), 3000); assert.equal(await outstanding(full.id), 0);
    const half = await staff(); await advance(half.id, '2026-04-01', 3000); await salary(half.id, '2026-04-01', 3000);
    assert.equal(await recovered(half.id), 1500); assert.equal(await outstanding(half.id), 1500, 'never "fully recovered" on a partial salary');
    const two = await staff(); await advance(two.id, '2026-04-01', 3000);
    await salary(two.id, '2026-04-01', 2000, 'received', '2026-04-20T10:00:00Z'); await salary(two.id, '2026-04-01', 4000, 'received', '2026-05-03T10:00:00Z');
    const ev = (await advanceRecoveries(h.db, T)).events.filter((x) => x.employeeId === two.id).map((x) => [x.date, x.amount]);
    assert.deepEqual(ev, [['2026-04-20', 1000], ['2026-05-03', 2000]]);
  });

  test('F5 3: a salary too small to absorb the advance recovers only what it absorbed — the rest stays a receivable', async () => {
    const e = await staff(); await advance(e.id, '2026-04-01', 12000); // 9,000 salary − 12,000 advance → shortfall 3,000
    const p: any = await computePayroll(h.db, e.id, '2026-04-01', T, await loadRules(h.db));
    assert.equal(p.salaryShortfall, 3000);
    assert.equal(await recovered(e.id), 9000); assert.equal(await outstanding(e.id), 3000);
    // nothing is recognised while the month is still running
    assert.equal(r2((await advanceRecoveries(h.db, '2026-04-15')).events.filter((x) => x.employeeId === e.id).reduce((t, x) => t + x.amount, 0)), 0);
  });

  test('F5 5/6: several advances in one month; one advance recovered over two months', async () => {
    const two = await staff(); await advance(two.id, '2026-04-01', 1000); await advance(two.id, '2026-04-01', 2000);
    await salary(two.id, '2026-04-01', 6000);
    assert.equal(await recovered(two.id), 3000); assert.equal(await outstanding(two.id), 0);
    const split = await staff(); await advance(split.id, '2026-04-01', 6000, { deductions: [['2026-04-01', 2000], ['2026-05-01', 4000]] });
    await salary(split.id, '2026-04-01', 7000);
    assert.equal(await recovered(split.id), 2000); assert.equal(await outstanding(split.id), 4000, 'May not received yet');
    await salary(split.id, '2026-05-01', 5000, 'received', '2026-06-01T10:00:00Z');
    assert.equal(await recovered(split.id), 6000); assert.equal(await outstanding(split.id), 0);
  });

  test('F5 7/8: the same data twice gives the same figures; a cancelled salary or deduction recovers nothing; an advance not paid through the cashbox is not a receivable here', async () => {
    const a1 = JSON.stringify(await advanceRecoveries(h.db, T)), a2 = JSON.stringify(await advanceRecoveries(h.db, T));
    assert.equal(a1, a2);
    assert.equal(JSON.stringify(await profitParts(h.db, null, null, T)), JSON.stringify(await profitParts(h.db, null, null, T)));
    const e = await staff(); await advance(e.id, '2026-04-01', 3000);
    const s = (await salary(e.id, '2026-04-01', 6000, 'pending')).rows[0].id;
    assert.equal(await recovered(e.id), 0, 'a salary not received recovers nothing');
    await h.db.query(`UPDATE payouts SET status = 'cancelled', cancelled_at = now() WHERE id = $1`, [s]);
    assert.equal(await recovered(e.id), 0);
    const d = await staff(); const adv = await advance(d.id, '2026-04-01', 4000, { deductions: [['2026-05-01', 4000]] });
    await salary(d.id, '2026-04-01', 9000, 'received', '2026-04-29T10:00:00Z');
    assert.equal(await recovered(d.id), 0, 'deducted in May, May not paid');
    await h.db.query(`UPDATE advance_deductions SET status = 'cancelled' WHERE advance_id = $1`, [adv]);
    // back to the payroll's own rule: the whole advance in its own month (April: 9,000 − 4,000 = 5,000 due, 9,000 received)
    assert.equal(await recovered(d.id), 4000);
    const out = await staff(); await advance(out.id, '2026-04-01', 2000, { paid: false }); await salary(out.id, '2026-04-01', 7000);
    assert.equal(await recovered(out.id), 0);
  });

  test('F5: the owner profit recognises exactly the recovered amounts (costs = cash − advances paid + advances recovered)', async () => {
    const pr = (await profitParts(h.db, null, null, T)).total;
    const ev = (await advanceRecoveries(h.db, T)).events.reduce((t, x) => t + x.amount, 0);
    assert.equal(pr.advancesRecovered, r2(ev));
    assert.equal(pr.costs, r2(pr.cashCosts - pr.advancesPaid + pr.advancesRecovered));
    assert.ok(pr.advancesRecovered <= pr.advancesPaid + 0.01, 'never more recovered than paid');
  });
});

// ===================================================================================================== F4
describe('F4 exclusive collections under concurrency', () => {
  let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let pid = '';
  before(async () => {
    h = await harness('2026-11-10T10:00:00Z'); c = await cast(h);
    pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج التزامن', ownerName: 'مالك', ownerPhone: '0100' })).body.project.id;
  });
  after(async () => { await h.close(); });
  let k = 0;
  const unit = async (deposit: number) => (await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: `C-${++k}`, clientName: `عميل ${k}`,
    unitPrice: 1_000_000, depositAmount: deposit, paymentMethod: 'cash' })).body.unit.id as string;
  const receipt = (u: string, amount: number, clientRef?: string, kind = 'reservation') =>
    h.call(c.t.hr, 'POST', `/exclusive/units/${u}/receipts`, { kind, amount, ...(clientRef ? { clientRef } : {}) });
  const total = async (u: string) => N((await h.db.query(`SELECT sum(amount_egp) s FROM cash_receipts WHERE ex_unit_id = $1 AND status = 'posted'`, [u])).rows[0].s);
  const uuid = () => crypto.randomUUID();

  test('two identical requests at the same time → one receipt, the other gets it back', async () => {
    const u = await unit(50_000); const ref = uuid();
    const rs = await Promise.all([receipt(u, 20_000, ref), receipt(u, 20_000, ref), receipt(u, 20_000, ref)]);
    assert.deepEqual(rs.map((r) => r.status).sort(), [200, 200, 201]);
    assert.equal(new Set(rs.map((r) => r.body.receipt.id)).size, 1);
    assert.equal(await total(u), 20_000);
  });

  test('the same reference used for another unit / another kind → refused, nothing recorded', async () => {
    const a = await unit(30_000), b = await unit(30_000); const ref = uuid();
    assert.equal((await receipt(a, 10_000, ref)).status, 201);
    const x = await receipt(b, 10_000, ref);
    assert.equal(x.status, 409); assert.equal(x.body.error.details.reason, 'client_ref_reused');
    assert.equal(await total(b), 0);
  });

  test('different references racing for the same remaining balance → never more than the deposit', async () => {
    const u = await unit(30_000);
    const rs = await Promise.all([receipt(u, 20_000, uuid()), receipt(u, 20_000, uuid()), receipt(u, 20_000, uuid())]);
    assert.equal(rs.filter((r) => r.status === 201).length, 1);
    assert.ok(rs.every((r) => [201, 400].includes(r.status)), JSON.stringify(rs.map((r) => r.status)));
    assert.equal(await total(u), 20_000);
  });

  test('two partial collections that fit together both succeed; the exact remainder succeeds; one more pound is refused', async () => {
    const u = await unit(30_000);
    const rs = await Promise.all([receipt(u, 10_000, uuid()), receipt(u, 10_000, uuid())]);
    assert.deepEqual(rs.map((r) => r.status), [201, 201]);
    assert.equal((await receipt(u, 10_000, uuid())).status, 201, 'exactly the remaining balance');
    assert.equal((await receipt(u, 1, uuid())).status, 400, 'over the deposit');
    assert.equal(await total(u), 30_000);
  });

  test('a failed attempt records nothing; its retry with the same reference records once', async () => {
    const u = await unit(10_000); const ref = uuid();
    assert.equal((await receipt(u, 15_000, ref)).status, 400, 'over the deposit — the transaction rolls back');
    assert.equal(await total(u), 0);
    assert.equal((await receipt(u, 10_000, ref)).status, 201);
    assert.equal((await receipt(u, 10_000, ref)).status, 200);
    assert.equal(await total(u), 10_000);
  });

  test('the request path and the direct path at the same time → collected once, no deadlock', async () => {
    for (let i = 0; i < 5; i++) {
      const u = await unit(40_000);
      const pend = (await h.db.query(`SELECT id FROM ex_payments WHERE unit_id = $1 AND status = 'pending'`, [u])).rows[0].id;
      const rs = await Promise.all([h.call(c.t.hr, 'POST', `/exclusive/payments/${pend}/receive`, {}), receipt(u, 40_000, uuid())]);
      assert.ok(rs.every((r) => r.status < 500), JSON.stringify(rs.map((r) => [r.status, r.body?.error?.message])));
      assert.equal(rs.filter((r) => r.status === 200 || r.status === 201).length, 1);
      assert.equal(await total(u), 40_000);
    }
  });
});

// ===================================================================================================== F9 + F6 (085)
describe('085: payout finality and ownership-share history', () => {
  let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
  before(async () => {
    h = await harness('2026-01-10T08:00:00Z'); c = await cast(h);
    await h.db.tx(async (q) => { await q.query(file('085_financial_integrity.sql')); });
  });
  after(async () => { await h.close(); });
  const pay = async (status = 'pending') => (await h.db.query(`INSERT INTO payouts (employee_id, kind, amount_egp, period, note, created_by, status, received_at)
    VALUES ($1,'advance',500,'2026-01-01','سلفة',$2,$3,$4) RETURNING id`, [c.ids.e1, c.ids.hr, status, status === 'received' ? '2026-01-05T10:00:00Z' : null])).rows[0].id as string;
  const upd = (id: string, set: string, vals: unknown[] = []) => h.db.query(`UPDATE payouts SET ${set} WHERE id = $1`, [id, ...vals]);

  test('F9: a received payout — amount, recipient, source, note, received time and status are all fixed; it is never deleted', async () => {
    const id = await pay('received');
    await assert.rejects(upd(id, `amount_egp = 600`), /cannot be changed/);
    await assert.rejects(upd(id, `employee_id = $2`, [c.ids.e2]), /cannot be changed/);
    await assert.rejects(upd(id, `kind = 'salary'`), /cannot be changed/);
    await assert.rejects(upd(id, `note = 'x'`), /cannot be changed/);
    await assert.rejects(upd(id, `received_at = received_at + interval '1 day'`), /final/);
    await assert.rejects(upd(id, `status = 'cancelled', cancelled_at = now()`), /final/);
    await assert.rejects(upd(id, `status = 'pending', received_at = NULL`), /final/);
    await assert.rejects(h.db.query(`DELETE FROM payouts WHERE id = $1`, [id]), /never deleted/);
    const adv = (await h.db.query(`INSERT INTO advance_requests (employee_id, kind, period, amount_egp, status, created_by, decided_by, decided_at)
      VALUES ($1,'advance','2026-01-01',500,'confirmed',$1,$2,now()) RETURNING id`, [c.ids.e1, c.ids.owner])).rows[0].id;
    await assert.rejects(upd(id, `advance_id = $2`, [adv]), /cannot be changed/, 'its source cannot be attached later');
  });

  test('F9: a pending payout only moves forward, each step stamping its own time once', async () => {
    const a = await pay();
    await assert.rejects(upd(a, `received_at = now()`), /only changes with its status/);
    await assert.rejects(upd(a, `status = 'received'`), /check constraint|stamps received_at/);
    await upd(a, `status = 'received', received_at = now()`);
    const b = await pay();
    await assert.rejects(upd(b, `status = 'cancelled', cancelled_at = now(), received_at = now()`), /check constraint|stamps cancelled_at/);
    await upd(b, `status = 'cancelled', cancelled_at = now()`);
    await assert.rejects(upd(b, `cancelled_at = now() + interval '1 day'`), /final/);
    const d = await pay();
    await upd(d, `status = 'disputed', dispute_reason = 'ناقص', disputed_at = now()`);
    await assert.rejects(upd(d, `status = 'pending'`), /cannot go from disputed to pending/);
    await assert.rejects(upd(d, `dispute_reason = 'تاني'`), /only changes with its status/);
    await upd(d, `status = 'received', received_at = now()`);
    const x = await pay();
    await h.db.query(`DELETE FROM payouts WHERE id = $1`, [x]); // a pending, never-confirmed record may go (only the data reset does this)
  });

  test('F9: the app\'s real flows still work on top of 085 — pay, confirm by code, cancel, dispute', async () => {
    const adv = (await h.db.query(`INSERT INTO advance_requests (employee_id, kind, period, amount_egp, status, created_by, decided_by, decided_at)
      VALUES ($1,'advance','2026-01-01',700,'confirmed',$1,$2,now()) RETURNING id`, [c.ids.e2, c.ids.owner])).rows[0].id;
    const p = await h.call(c.t.hr, 'POST', '/payouts', { kind: 'advance', employeeId: c.ids.e2, amount: 700, month: '2026-01', advanceId: adv });
    assert.equal(p.status, 201, JSON.stringify(p.body));
    assert.equal((await confirmPayout(h, c.t.e2, c.t.hr, p.body.payout.id)).status, 200);
    const q = await h.call(c.t.hr, 'POST', '/payouts', { kind: 'advance', employeeId: c.ids.e3, amount: 300, month: '2026-01' });
    assert.equal((await h.call(c.t.hr, 'POST', `/payouts/${q.body.payout.id}/cancel`, {})).status, 200);
    const r = await h.call(c.t.hr, 'POST', '/payouts', { kind: 'advance', employeeId: c.ids.e3, amount: 301, month: '2026-01' });
    assert.equal((await h.call(c.t.e3, 'POST', `/payouts/${r.body.payout.id}/dispute`, { reason: 'استلمت أقل' })).status, 200);
    assert.equal((await confirmPayout(h, c.t.e3, c.t.hr, r.body.payout.id)).status, 200, 'a disputed payment can still be confirmed');
  });

});


// ===================================================================================================== F6 (085), its own database
describe('F6 ownership-share history', () => {
  let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
  before(async () => {
    h = await harness('2026-01-01T08:00:00Z'); c = await cast(h);
    await h.db.tx(async (q) => { await q.query(file('085_financial_integrity.sql')); });
  });
  after(async () => { await h.close(); });
  test('F6: shares month by month — initial, changed mid-month, a new owner, an owner removed; past months never move', async () => {
    const A = c.ids.owner;
    const B = await insertEmployee(h.db, { code: 'OWN-B', role: 'sales_employee' });
    const C = await insertEmployee(h.db, { code: 'OWN-C', role: 'sales_employee' });
    await h.db.query(`DELETE FROM company_owner_shares`);
    const income = (m: string) => h.db.query(`INSERT INTO cash_receipts (kind, amount_egp, cashbox, actual_recipient_id, payer_name, purpose, payment_method, occurred_at, recorded_by)
      VALUES ('commission', 100000, 'office', $1, 'مطور', 'عمولة', 'cash', $2, $1)`, [A, `${m}-05T10:00:00Z`]);
    const put = (at: string, owners: [string, number][]) => { h.now.value = new Date(at); return h.call(c.t.owner, 'PUT', '/cash/owners', { owners: owners.map(([employeeId, pct]) => ({ employeeId, pct })) }); };
    const profit = async (id: string) => (await h.call(c.t.owner, 'GET', '/cash/injections')).body.owners.find((x: any) => x.id === id)?.account?.profit;
    assert.equal((await put('2026-01-02T10:00:00Z', [[A, 60], [B, 40]])).status, 200);
    await income('2026-01');
    assert.equal(await profit(A), 60_000); assert.equal(await profit(B), 40_000);
    await income('2026-02');
    assert.equal((await put('2026-02-15T10:00:00Z', [[A, 50], [B, 50]])).status, 200, 'a change in the middle of February applies to February');
    await income('2026-03');
    assert.equal((await put('2026-03-20T10:00:00Z', [[A, 40], [B, 40], [C, 20]])).status, 200, 'a new owner from March');
    await income('2026-04');
    assert.equal((await put('2026-04-10T10:00:00Z', [[A, 70], [B, 0], [C, 30]])).status, 200, 'B removed from April');
    h.now.value = new Date('2026-04-30T10:00:00Z');
    // A: 60 + 50 + 40 + 70 · B: 40 + 50 + 40 + 0 · C: 20 + 30 (thousands)
    assert.equal(await profit(A), 220_000); assert.equal(await profit(B), 130_000, 'B keeps the profit of the months he held a share');
    assert.equal(await profit(C), 50_000);
    // a historical report of January alone is still January's shares
    const jan = (await h.call(c.t.owner, 'GET', '/cash/injections?from=2026-01-01&to=2026-01-31')).body.owners;
    assert.deepEqual([A, B, C].map((id) => jan.find((x: any) => x.id === id)?.profit ?? 0), [60_000, 40_000, 0]);
  });
});
