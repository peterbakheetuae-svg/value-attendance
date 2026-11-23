import type { Q } from '../db.ts';

/**
 * F1 — what OLDER payroll sheets settled inside the «salary».
 *
 * Before the salary-only rule (2026-11-22) a payroll-sheet line paid the employee's whole net, commissions and approved
 * work expenses included, as one `salary` payout linked to the line (`payouts.batch_line_id`). Those commissions / work
 * expenses have no payout of their own, so without this they would look unpaid and could be paid a second time.
 *
 * The evidence is the sheet line itself — never a salary amount on its own:
 *   - only lines WITHOUT `snapshot.settles = 'salary_only'` (sheets prepared under the old rule);
 *   - the line's snapshot says what it contained: net, commissions (C), work expenses (W);
 *   - what was paid against THAT line (payouts with its batch_line_id, not cancelled) = P;
 *   - the line's salary part = net − C − W (may be negative: deductions then ate into C / W, which still counts as settled);
 *   - covered = P − (net − C − W), kept between 0 and C + W — commissions first, then work expenses;
 *   - it goes to the items the line actually contained: entitlements / work-expense requests of that employee and month
 *     already approved when the sheet was frozen (submitted), oldest first — whether or not they ALSO got a payout of their
 *     own later (that would be a double payment: it then shows as paid above its amount, and the detection SQL lists it).
 * A salary paid above the salary part through any other path (صرف الراتب, an old free-form payout) settles nothing.
 * Deterministic: the same records always give the same answer; nothing is written.
 */
export interface LegacyCoverage {
  /** covered money the line paid above its salary part (commissions + work expenses), as paid — the salary path does not own it */
  lineCovered: number;
  /** of it, given to specific items (an entitlement / a request without its own payout) */
  commissions: number;
  workExpenses: number;
  /** item id → covered amount (entitlement id, or work-expense request id) */
  items: Map<string, number>;
}

const r2 = (n: number) => Math.round(n * 100) / 100;
const empty = (): LegacyCoverage => ({ lineCovered: 0, commissions: 0, workExpenses: 0, items: new Map() });

export async function legacyCoverage(q: Q, employeeIds: string[], period: string): Promise<Map<string, LegacyCoverage>> {
  const out = new Map<string, LegacyCoverage>();
  for (const id of employeeIds) out.set(id, empty());
  if (!employeeIds.length) return out;
  const lines = (await q.query(`
    SELECT l.id, l.employee_id,
           COALESCE((l.snapshot->>'net')::numeric, 0) AS net,
           COALESCE((l.snapshot->>'commissions')::numeric, 0) AS c,
           COALESCE((l.snapshot->>'workExpenses')::numeric, 0) AS w,
           COALESCE(b.submitted_at, b.decided_at, b.prepared_at) AS frozen_at,
           COALESCE((SELECT sum(p.amount_egp) FROM payouts p WHERE p.batch_line_id = l.id AND p.status <> 'cancelled'), 0) AS paid
      FROM payroll_batch_lines l JOIN payroll_batches b ON b.id = l.batch_id
     WHERE l.employee_id = ANY($1::uuid[]) AND b.period = $2 AND b.status <> 'cancelled'
       AND COALESCE(l.snapshot->>'settles', '') <> 'salary_only'
       AND (COALESCE((l.snapshot->>'commissions')::numeric, 0) > 0 OR COALESCE((l.snapshot->>'workExpenses')::numeric, 0) > 0)`,
    [employeeIds, period])).rows;
  if (!lines.length) return out;
  const emps = [...new Set(lines.map((l) => l.employee_id as string))];
  const ents = (await q.query(`
    SELECT ce.id, ce.employee_id, ce.amount_egp, ce.included_at FROM commission_entitlements ce
     WHERE ce.employee_id = ANY($1::uuid[]) AND ce.period = $2 AND ce.status = 'active'
     ORDER BY ce.included_at, ce.id`, [emps, period])).rows;
  const reqs = (await q.query(`
    SELECT ar.id, ar.employee_id, ar.amount_egp, COALESCE(ar.decided_at, ar.created_at) AS at FROM advance_requests ar
     WHERE ar.employee_id = ANY($1::uuid[]) AND ar.period = $2 AND ar.kind = 'work_expense' AND ar.status = 'confirmed'
     ORDER BY COALESCE(ar.decided_at, ar.created_at), ar.id`, [emps, period])).rows;
  // lines of one employee and month in the order they were frozen (normally one per month)
  lines.sort((x, y) => new Date(x.frozen_at).getTime() - new Date(y.frozen_at).getTime() || String(x.id).localeCompare(String(y.id)));
  for (const l of lines) {
    const cov = out.get(l.employee_id)!;
    const net = Number(l.net), C = Number(l.c), W = Number(l.w), P = Number(l.paid);
    const total = r2(Math.min(C + W, Math.max(0, P - (net - C - W))));
    if (total <= 0.009) continue;
    cov.lineCovered = r2(cov.lineCovered + total);
    let forC = r2(Math.min(total, C)), forW = r2(Math.min(total - forC, W));
    const frozen = new Date(l.frozen_at).getTime();
    for (const e of ents) {
      if (forC <= 0.009) break;
      if (e.employee_id !== l.employee_id || new Date(e.included_at).getTime() > frozen) continue;
      const open = r2(Number(e.amount_egp) - (cov.items.get(e.id) ?? 0));
      if (open <= 0.009) continue;
      const take = r2(Math.min(open, forC));
      cov.items.set(e.id, r2((cov.items.get(e.id) ?? 0) + take)); cov.commissions = r2(cov.commissions + take); forC = r2(forC - take);
    }
    for (const x of reqs) {
      if (forW <= 0.009) break;
      if (x.employee_id !== l.employee_id || new Date(x.at).getTime() > frozen) continue;
      const open = r2(Number(x.amount_egp) - (cov.items.get(x.id) ?? 0));
      if (open <= 0.009) continue;
      const take = r2(Math.min(open, forW));
      cov.items.set(x.id, r2((cov.items.get(x.id) ?? 0) + take)); cov.workExpenses = r2(cov.workExpenses + take); forW = r2(forW - take);
    }
  }
  return out;
}

/** the covered amount of one item (entitlement / work-expense request) of an employee's month */
export async function legacyCoveredItem(q: Q, employeeId: string, period: string, itemId: string): Promise<number> {
  return (await legacyCoverage(q, [employeeId], period)).get(employeeId)!.items.get(itemId) ?? 0;
}
