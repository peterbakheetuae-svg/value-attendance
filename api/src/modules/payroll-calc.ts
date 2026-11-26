import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { local, timeToMinutes } from '../lib/time.ts';
import { buildMonth, fetchMonthMany, type MonthData } from './attendance-calc.ts';
import { legacyCoverage, type LegacyCoverage } from './legacy-coverage.ts';
import { incidentDeductions } from './exit-incidents.ts';

export interface Tier { afterMinutes: number; amount: number }
export interface PayrollRules {
  auto: boolean; dayDivisor: number; mode: 'per_minute' | 'tiers' | 'hourly';
  lateTiers: Tier[]; earlyTiers: Tier[]; absencePenaltyDays: number;
  lateFixedAfterMinutes: number; lateFixedAmount: number; lateHourAmount: number;
  /** الانصراف بدري is deducted (off → it is only counted and shown) */
  earlyDeduction: boolean;
}

export async function loadRules(q: Q): Promise<PayrollRules> {
  const s = await one(q, `SELECT * FROM company_settings`);
  return { auto: s.payroll_auto_deductions, dayDivisor: s.day_divisor, mode: s.deduction_mode,
    lateTiers: s.late_tiers ?? [], earlyTiers: s.early_tiers ?? [], absencePenaltyDays: Number(s.absence_penalty_days),
    lateFixedAfterMinutes: Number(s.late_fixed_after_minutes ?? 30), lateFixedAmount: Number(s.late_fixed_amount ?? 0),
    lateHourAmount: Number(s.late_hour_amount ?? 0), earlyDeduction: s.early_deduction !== false };
}

const r2 = (n: number) => Math.round(n * 100) / 100;

/**
 * Simple rule: late ≥ 60 min → per hour (proportional); late > N min → fixed amount; else nothing.
 * An amount left empty (0) falls back to the employee's own pay for the late minutes, so a late
 * employee is never left without a deduction just because a box was not filled.
 */
export function hourlyLateAmount(r: Pick<PayrollRules, 'lateFixedAfterMinutes' | 'lateFixedAmount' | 'lateHourAmount'>, minutes: number,
  minuteWage: number | null = null): number {
  if (minutes <= r.lateFixedAfterMinutes) return 0;
  if (minutes >= 60) {
    if (r.lateHourAmount > 0) return r2((minutes / 60) * r.lateHourAmount);
    if (minuteWage !== null) return r2(minutes * minuteWage);
  }
  if (r.lateFixedAmount > 0) return r.lateFixedAmount;
  return minuteWage === null ? 0 : r2(minutes * minuteWage);
}

/** Amount of the highest tier the raw minutes passed (0 when below every tier). */
export function tierAmount(tiers: Tier[], minutes: number): number {
  let amt = 0;
  for (const t of [...tiers].sort((a, b) => a.afterMinutes - b.afterMinutes)) if (minutes > t.afterMinutes) amt = t.amount;
  return amt;
}

/** Everything the payroll of one employee and month reads (fetched one employee at a time, or for many at once). */
export interface PayrollData {
  sal: { base_salary: unknown } | null;
  exempt: boolean;
  sch: { start_time: string; end_time: string } | null;
  month: MonthData;
  att: { work_date: string; check_in_at: Date; check_out_at: Date | null; schedule_start: string; schedule_end: string;
    late_grace_minutes: number; early_grace_minutes: number }[];
  adj: { deductions: unknown; bonuses: unknown };
  adv: { advances: unknown; expenses: unknown };
  paid: { salary: unknown; commission: unknown; work_expense: unknown };
  com: { s: unknown };
  /** F1: what an older (full-net) payroll-sheet line of this month settled inside the salary */
  legacy?: LegacyCoverage;
  /** «خروج بدون إذن»: the month's closed incidents with a frozen amount (proposed 094) */
  exits?: { count: number; amount: number };
}

const SCH_SQL = (where: string) => `SELECT e.id AS employee_id, ws.*, COALESCE(e.work_start, ws.start_time) AS start_time, COALESCE(e.work_end, ws.end_time) AS end_time FROM employees e
      JOIN work_schedules ws ON ws.id = COALESCE(e.schedule_id, (SELECT id FROM work_schedules WHERE is_default)) WHERE ${where}`;

/**
 * The payroll reads for many employees in a fixed number of queries (instead of ~15 per employee). The rows are the
 * same as the one-employee reads, grouped by employee; the calculation (buildPayroll) is one and the same function.
 */
export async function fetchPayrollMany(q: Q, ids: string[], period: string): Promise<Map<string, PayrollData>> {
  const P = [ids, period];
  const [months, sal, emp, sch, adj, adv, paid, com, legacy, exits] = await Promise.all([
    fetchMonthMany(q, ids, period),
    q.query(`SELECT employee_id, base_salary FROM employee_salaries WHERE employee_id = ANY($1::uuid[])`, [ids]),
    q.query(`SELECT id, attendance_exempt FROM employees WHERE id = ANY($1::uuid[])`, [ids]),
    q.query(SCH_SQL('e.id = ANY($1::uuid[])'), [ids]),
    q.query(`SELECT employee_id, COALESCE(sum(amount_egp) FILTER (WHERE kind = 'deduction'),0) AS deductions,
                    COALESCE(sum(amount_egp) FILTER (WHERE kind = 'bonus'),0) AS bonuses
               FROM salary_adjustments WHERE employee_id = ANY($1::uuid[]) AND period = $2 AND status = 'approved' GROUP BY employee_id`, P),
    q.query(`SELECT x.id AS employee_id,
        COALESCE((SELECT sum(ar.amount_egp) FROM advance_requests ar
                   WHERE ar.employee_id = x.id AND ar.period = $2 AND ar.status = 'confirmed' AND ar.kind = 'advance'
                     AND NOT EXISTS (SELECT 1 FROM advance_deductions d WHERE d.advance_id = ar.id AND d.status = 'active')), 0)
      + COALESCE((SELECT sum(d.amount_egp) FROM advance_deductions d
                   WHERE d.employee_id = x.id AND d.period = $2 AND d.status = 'active'), 0) AS advances,
        COALESCE((SELECT sum(amount_egp) FROM advance_requests
                   WHERE employee_id = x.id AND period = $2 AND status = 'confirmed' AND kind = 'work_expense'), 0) AS expenses
        FROM unnest($1::uuid[]) AS x(id)`, P),
    q.query(`SELECT employee_id, COALESCE(sum(amount_egp) FILTER (WHERE kind = 'salary'), 0) AS salary,
                    COALESCE(sum(amount_egp) FILTER (WHERE kind = 'commission'), 0) AS commission,
                    COALESCE(sum(amount_egp) FILTER (WHERE kind = 'work_expense'), 0) AS work_expense
               FROM payouts WHERE employee_id = ANY($1::uuid[]) AND period = $2 AND status <> 'cancelled' GROUP BY employee_id`, P),
    q.query(`SELECT employee_id, COALESCE(sum(amount_egp), 0) AS s FROM commission_entitlements
              WHERE employee_id = ANY($1::uuid[]) AND period = $2 AND status = 'active' GROUP BY employee_id`, P),
    legacyCoverage(q, ids, period),
    incidentDeductions(q, ids, period),
  ]);
  const by = (rows: any[], k = 'employee_id') => new Map(rows.map((r) => [r[k] as string, r]));
  const salBy = by(sal.rows), empBy = by(emp.rows, 'id'), schBy = by(sch.rows), adjBy = by(adj.rows), advBy = by(adv.rows),
    paidBy = by(paid.rows), comBy = by(com.rows);
  const out = new Map<string, PayrollData>();
  for (const id of ids) {
    const month = months.get(id)!;
    out.set(id, {
      sal: salBy.get(id) ?? null, exempt: empBy.get(id)?.attendance_exempt === true, sch: schBy.get(id) ?? null, month,
      att: month.att, adj: adjBy.get(id) ?? { deductions: 0, bonuses: 0 }, adv: advBy.get(id) ?? { advances: 0, expenses: 0 },
      paid: paidBy.get(id) ?? { salary: 0, commission: 0, work_expense: 0 }, com: comBy.get(id) ?? { s: 0 },
      legacy: legacy.get(id), exits: exits.get(id),
    });
  }
  return out;
}

/**
 * Month payroll for one employee, computed only from stored data — nothing is written.
 * Per day: approved hourly permissions are used up first against late, then early minutes.
 */
export async function computePayroll(q: Q, employeeId: string, period: string, today: string, rules: PayrollRules) {
  const data = (await fetchPayrollMany(q, [employeeId], period)).get(employeeId)!;
  return buildPayroll(data, period, today, rules);
}

/** The payroll of many employees for one month: the same calculation, a fixed number of queries. */
export async function computePayrollMany(q: Q, ids: string[], period: string, today: string, rules: PayrollRules) {
  const out = new Map<string, ReturnType<typeof buildPayroll>>();
  if (!ids.length) return out;
  const data = await fetchPayrollMany(q, ids, period);
  for (const id of ids) out.set(id, buildPayroll(data.get(id)!, period, today, rules));
  return out;
}

/** The payroll calculation itself — pure, from the data fetched above. */
export function buildPayroll(data: PayrollData, period: string, today: string, rules: PayrollRules) {
  const { sal, exempt, sch, adj, adv, paid, com } = data;
  const { days, summary } = buildMonth(data.month, period, today);
  const attBy = new Map(data.att.map((a) => [a.work_date, a]));
  const advances = Number(adv.advances), workExpenses = Number(adv.expenses);
  const salaryPaid = Number(paid.salary), commissionPaid = Number(paid.commission), workExpensePaid = Number(paid.work_expense);
  // deal commissions approved by the general manager for this payroll month (salesperson / sales manager share)
  const commissions = Number(com.s);
  const base = sal ? Number(sal.base_salary) : null;
  const dayWage = base === null ? null : base / rules.dayDivisor;
  const shiftMin = sch ? Math.max(1, timeToMinutes(sch.end_time) - timeToMinutes(sch.start_time)) : 480;
  const minuteWage = dayWage === null ? null : dayWage / shiftMin;

  let lateMin = 0, earlyMin = 0, lateDays = 0, earlyDays = 0, lateAmt = 0, earlyAmt = 0;
  for (const d of days) {
    const a = attBy.get(d.date);
    // a day the absence threshold turned into an absence is paid / deducted as an absence only (never also as late)
    if (!a || !d.attendance || d.lateAsAbsence) continue;
    const start = timeToMinutes(a.schedule_start), end = timeToMinutes(a.schedule_end);
    const lateRaw = Math.max(0, local(new Date(a.check_in_at)).minutes - start);
    let earlyRaw = 0;
    if (a.check_out_at) {
      const o = local(new Date(a.check_out_at));
      const outMin = o.date > a.work_date ? 24 * 60 + o.minutes : o.minutes;
      earlyRaw = Math.max(0, end - outMin);
    }
    let permit = d.hourlyPermissionMinutes;
    const useLate = Math.min(permit, lateRaw); permit -= useLate;
    const useEarly = Math.min(permit, earlyRaw);
    const late = lateRaw - useLate, early = earlyRaw - useEarly;
    if (rules.mode === 'per_minute') {
      const l = Math.max(0, late - a.late_grace_minutes), e = Math.max(0, early - a.early_grace_minutes);
      if (l) { lateDays++; lateMin += l; }
      if (e) { earlyDays++; earlyMin += e; }
    } else if (rules.mode === 'hourly') {
      const la = hourlyLateAmount(rules, late, minuteWage);
      if (la) { lateDays++; lateMin += late; lateAmt += la; }
      const ea = hourlyLateAmount(rules, early, minuteWage);
      if (ea) { earlyDays++; earlyMin += early; earlyAmt += ea; }
    } else {
      const la = tierAmount(rules.lateTiers, late), ea = tierAmount(rules.earlyTiers, early);
      if (la) { lateDays++; lateMin += late; lateAmt += la; }
      if (ea) { earlyDays++; earlyMin += early; earlyAmt += ea; }
    }
  }
  if (rules.mode === 'per_minute' && minuteWage !== null) { lateAmt = lateMin * minuteWage; earlyAmt = earlyMin * minuteWage; }
  // «خصم الانصراف بدري» off: the early leave is still counted and shown, nothing is deducted for it
  if (!rules.earlyDeduction) earlyAmt = 0;

  const absentDays = summary.unapprovedAbsenceDays, unpaidDays = summary.unpaidAbsenceDays;
  // salary for the days: every elapsed day of the month is paid (work days, weekends, holidays, paid leave)
  // except unexcused absence and unpaid leave; a full month never pays more than the monthly salary
  const elapsed = days.filter((d) => !['future', 'before_joining', 'inactive'].includes(d.status)).length;
  const paidDays = Math.max(0, elapsed - absentDays - unpaidDays);
  // the whole month is paid in full only when he was employed all of it (no days before joining / inactive)
  const fullMonth = !days.some((d) => d.status === 'before_joining' || d.status === 'inactive');
  // days actually worked or on paid leave: none at all → nothing is earned for the month (weekends are not paid alone)
  const earnedDays = summary.attendedDays + summary.approvedAbsenceDays - summary.unpaidAbsenceDays;
  const nothingEarned = !exempt && earnedDays <= 0;
  let attendanceSalary: number | null = null;
  if (base !== null && dayWage !== null) {
    if (exempt) attendanceSalary = summary.complete && fullMonth ? base : Math.min(base, elapsed * dayWage);
    else if (nothingEarned) attendanceSalary = 0;
    else attendanceSalary = summary.complete && fullMonth && absentDays + unpaidDays === 0 ? base : Math.min(base, paidDays * dayWage);
  }
  // the absent day itself is already unpaid above; the penalty adds only the extra days (e.g. 2 = one more day)
  const absenceAmt = dayWage === null ? 0 : absentDays * Math.max(0, rules.absencePenaltyDays - 1) * dayWage;
  const unpaidAmt = 0;
  // no automatic deductions for someone who does not use check-in, or who earned nothing this month
  const auto = rules.auto && base !== null && !exempt && !nothingEarned;
  // «خروج بدون إذن»: each closed incident's fixed amount, frozen when it closed — summed here, written nowhere else, so
  // the month's payroll (and a payroll sheet's snapshot of it) carries each incident exactly once
  const exitAmt = Number(data.exits?.amount ?? 0);
  const autoTotal = auto ? lateAmt + earlyAmt + absenceAmt + unpaidAmt + exitAmt : 0;
  const adminDed = Number(adj.deductions), bonuses = Number(adj.bonuses);
  const net = attendanceSalary === null ? null : r2(attendanceSalary - autoTotal - adminDed + bonuses + commissions - advances + workExpenses);
  return {
    paidDays, elapsedDays: elapsed,
    attendanceSalary: attendanceSalary === null ? null : r2(attendanceSalary),
    hourWage: dayWage === null ? null : r2(dayWage / (shiftMin / 60)),
    complete: summary.complete, baseSalary: base, dayWage: dayWage === null ? null : r2(dayWage),
    minuteWage: minuteWage === null ? null : Math.round(minuteWage * 10000) / 10000,
    rules: { auto: rules.auto, mode: rules.mode, dayDivisor: rules.dayDivisor, absencePenaltyDays: rules.absencePenaltyDays,
      lateFixedAfterMinutes: rules.lateFixedAfterMinutes, lateFixedAmount: rules.lateFixedAmount, lateHourAmount: rules.lateHourAmount,
      earlyDeduction: rules.earlyDeduction },
    late: { days: lateDays, minutes: lateMin, amount: auto ? r2(lateAmt) : 0 },
    early: { days: earlyDays, minutes: earlyMin, amount: auto ? r2(earlyAmt) : 0 },
    absence: { days: absentDays, amount: auto ? r2(absenceAmt) : 0 },
    unauthorizedExit: { incidents: data.exits?.count ?? 0, amount: auto ? r2(exitAmt) : 0 },
    unpaid: { days: unpaidDays, amount: auto ? r2(unpaidAmt) : 0 },
    adminDeductions: adminDed, bonuses, commissions: r2(commissions), advances, workExpenses,
    totalDeductions: r2(autoTotal + adminDed),
    // due = salary for the days + bonuses/commissions + work expenses − deductions − advances
    net,
    // cash actually handed over for this month (صرف القبض) and what is still owed
    salaryPaid: r2(salaryPaid), commissionPaid: r2(commissionPaid),
    // commission payouts (صرف عمولة) settle the commissions part, salary payouts the rest
    // work expenses paid on their own (صرف الطلب) settle that part too
    workExpensePaid: r2(workExpensePaid),
    remaining: attendanceSalary === null ? null
      : r2(attendanceSalary - autoTotal - adminDed + bonuses + commissions - advances + workExpenses - salaryPaid - commissionPaid - workExpensePaid),
    // each part of the month settles on its own path (F1): the salary part through صرف الراتب / the payroll sheet,
    // commissions through صرف العمولة (linked to the entitlement), work expenses through صرف الطلب (linked to the request)
    ...settlementComponents(net, commissions, workExpenses, salaryPaid, commissionPaid, workExpensePaid, data.legacy),
  };
}

/**
 * The month's three parts and what settled each. The salary part = net − commissions − work expenses (the rule صرف الراتب
 * always used). Commissions / work expenses are settled by their own linked payouts, and — for months of an OLDER
 * payroll sheet that paid the whole net — by what that very sheet line paid above its salary part, given to the items the
 * line contained (legacy-coverage.ts). A salary simply paid above the salary part settles nothing else (it shows as paid).
 * `salaryShortfall`: deductions / advances larger than the salary part (they are not taken from commissions).
 */
export function settlementComponents(net: number | null, commissions: number, workExpenses: number,
  salaryPaid: number, commissionPaid: number, workExpensePaid: number, legacy?: Pick<LegacyCoverage, 'lineCovered' | 'commissions' | 'workExpenses'>) {
  if (net === null) return { salaryDue: null, salaryShortfall: 0, components: null };
  const salaryDue = r2(net - commissions - workExpenses);
  const part = (due: number, paidDirect: number, covered: number) => {
    const paid = r2(paidDirect + covered);
    return { due: r2(due), paid, paidDirect: r2(paidDirect), coveredBySalary: r2(covered), remaining: r2(Math.max(0, due - paid)),
      status: due <= 0.009 ? 'nothing_due' : paid + 0.009 >= due ? 'paid' : paid > 0.009 ? 'partly_paid' : 'unpaid' };
  };
  // the old sheet's line money above its salary part belongs to the commissions / work expenses, not to the salary part
  const salaryOnly = r2(Math.max(0, salaryPaid - (legacy?.lineCovered ?? 0)));
  const salaryPart = { due: r2(Math.max(0, salaryDue)), paid: r2(Math.min(salaryOnly, Math.max(0, salaryDue))),
    remaining: r2(Math.max(0, Math.max(0, salaryDue) - salaryOnly)) };
  const salary = { ...salaryPart, status: salaryPart.due <= 0.009 ? 'nothing_due' : salaryPart.remaining <= 0.009 ? 'paid' : salaryPart.paid > 0.009 ? 'partly_paid' : 'unpaid' };
  return { salaryDue, salaryShortfall: r2(Math.max(0, -salaryDue)),
    components: { salary, commissions: part(commissions, commissionPaid, legacy?.commissions ?? 0),
      workExpenses: part(workExpenses, workExpensePaid, legacy?.workExpenses ?? 0) } };
}

/**
 * المتأخرات: what is still owed from the months BEFORE `period` (never the month itself). Counted only from the
 * first month salaries were paid through the system (earlier months were settled outside it), at most 12 months back.
 */
export async function arrearsBefore(q: Q, employeeId: string, period: string, today: string, rules: PayrollRules): Promise<number> {
  const start = await one(q, `SELECT GREATEST(
      (SELECT min(period) FROM payouts WHERE kind = 'salary' AND status <> 'cancelled'),
      (SELECT date_trunc('month', joining_date)::date FROM employees WHERE id = $1),
      ($2::date - interval '12 months')::date) AS m`, [employeeId, period]);
  if (!start?.m) return 0;
  let m = String(start.m instanceof Date ? start.m.toISOString() : start.m).slice(0, 10);
  let owed = 0;
  while (m < period) {
    const p: any = await computePayroll(q, employeeId, m, today, rules);
    if (p?.remaining != null && p.remaining > 0) owed += p.remaining;
    const [y, mo] = m.split('-').map(Number);
    m = `${mo === 12 ? y + 1 : y}-${String(mo === 12 ? 1 : mo + 1).padStart(2, '0')}-01`;
  }
  return r2(owed);
}
