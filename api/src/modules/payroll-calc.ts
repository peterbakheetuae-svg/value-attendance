import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { local, timeToMinutes } from '../lib/time.ts';
import { computeMonth } from './attendance-calc.ts';

export interface Tier { afterMinutes: number; amount: number }
export interface PayrollRules {
  auto: boolean; dayDivisor: number; mode: 'per_minute' | 'tiers' | 'hourly';
  lateTiers: Tier[]; earlyTiers: Tier[]; absencePenaltyDays: number;
  lateFixedAfterMinutes: number; lateFixedAmount: number; lateHourAmount: number;
}

export async function loadRules(q: Q): Promise<PayrollRules> {
  const s = await one(q, `SELECT * FROM company_settings`);
  return { auto: s.payroll_auto_deductions, dayDivisor: s.day_divisor, mode: s.deduction_mode,
    lateTiers: s.late_tiers ?? [], earlyTiers: s.early_tiers ?? [], absencePenaltyDays: Number(s.absence_penalty_days),
    lateFixedAfterMinutes: Number(s.late_fixed_after_minutes ?? 30), lateFixedAmount: Number(s.late_fixed_amount ?? 0),
    lateHourAmount: Number(s.late_hour_amount ?? 0) };
}

const r2 = (n: number) => Math.round(n * 100) / 100;

/** Simple rule: late ≥ 60 min → per hour (proportional); late > N min → fixed amount; else nothing. */
export function hourlyLateAmount(r: Pick<PayrollRules, 'lateFixedAfterMinutes' | 'lateFixedAmount' | 'lateHourAmount'>, minutes: number): number {
  if (minutes >= 60 && r.lateHourAmount > 0) return r2((minutes / 60) * r.lateHourAmount);
  if (minutes > r.lateFixedAfterMinutes) return r.lateFixedAmount;
  return 0;
}

/** Amount of the highest tier the raw minutes passed (0 when below every tier). */
export function tierAmount(tiers: Tier[], minutes: number): number {
  let amt = 0;
  for (const t of [...tiers].sort((a, b) => a.afterMinutes - b.afterMinutes)) if (minutes > t.afterMinutes) amt = t.amount;
  return amt;
}

/**
 * Month payroll for one employee, computed only from stored data — nothing is written.
 * Per day: approved hourly permissions are used up first against late, then early minutes.
 */
export async function computePayroll(q: Q, employeeId: string, period: string, today: string, rules: PayrollRules) {
  const sal = await one(q, `SELECT base_salary FROM employee_salaries WHERE employee_id = $1`, [employeeId]);
  const sch = await one(q, `SELECT ws.* FROM employees e
      JOIN work_schedules ws ON ws.id = COALESCE(e.schedule_id, (SELECT id FROM work_schedules WHERE is_default)) WHERE e.id = $1`, [employeeId]);
  const { days, summary } = await computeMonth(q, employeeId, period, today);
  const att = await q.query(`SELECT work_date, check_in_at, check_out_at, schedule_start, schedule_end, late_grace_minutes, early_grace_minutes
                               FROM attendance WHERE employee_id = $1 AND work_date >= $2 AND work_date < ($2::date + interval '1 month')`, [employeeId, period]);
  const attBy = new Map(att.rows.map((a) => [a.work_date, a]));
  const adj = await one(q, `SELECT COALESCE(sum(amount_egp) FILTER (WHERE kind = 'deduction'),0) AS deductions,
                                   COALESCE(sum(amount_egp) FILTER (WHERE kind = 'bonus'),0) AS bonuses
                              FROM salary_adjustments WHERE employee_id = $1 AND period = $2 AND status = 'approved'`, [employeeId, period]);

  const adv = await one(q, `SELECT COALESCE(sum(amount_egp) FILTER (WHERE kind = 'advance'),0) AS advances,
                                   COALESCE(sum(amount_egp) FILTER (WHERE kind = 'work_expense'),0) AS expenses
                              FROM advance_requests WHERE employee_id = $1 AND period = $2 AND status = 'confirmed'`, [employeeId, period]);
  const advances = Number(adv.advances), workExpenses = Number(adv.expenses);
  const base = sal ? Number(sal.base_salary) : null;
  const dayWage = base === null ? null : base / rules.dayDivisor;
  const shiftMin = sch ? Math.max(1, timeToMinutes(sch.end_time) - timeToMinutes(sch.start_time)) : 480;
  const minuteWage = dayWage === null ? null : dayWage / shiftMin;

  let lateMin = 0, earlyMin = 0, lateDays = 0, earlyDays = 0, lateAmt = 0, earlyAmt = 0;
  for (const d of days) {
    const a = attBy.get(d.date);
    if (!a || !d.attendance) continue;
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
      const la = hourlyLateAmount(rules, late);
      if (la) { lateDays++; lateMin += late; lateAmt += la; }
    } else {
      const la = tierAmount(rules.lateTiers, late), ea = tierAmount(rules.earlyTiers, early);
      if (la) { lateDays++; lateMin += late; lateAmt += la; }
      if (ea) { earlyDays++; earlyMin += early; earlyAmt += ea; }
    }
  }
  if (rules.mode === 'per_minute' && minuteWage !== null) { lateAmt = lateMin * minuteWage; earlyAmt = earlyMin * minuteWage; }

  const absentDays = summary.unapprovedAbsenceDays, unpaidDays = summary.unpaidAbsenceDays;
  const absenceAmt = dayWage === null ? 0 : absentDays * rules.absencePenaltyDays * dayWage;
  const unpaidAmt = dayWage === null ? 0 : unpaidDays * dayWage;
  const auto = rules.auto && base !== null;
  const autoTotal = auto ? lateAmt + earlyAmt + absenceAmt + unpaidAmt : 0;
  const adminDed = Number(adj.deductions), bonuses = Number(adj.bonuses);
  return {
    complete: summary.complete, baseSalary: base, dayWage: dayWage === null ? null : r2(dayWage),
    minuteWage: minuteWage === null ? null : Math.round(minuteWage * 10000) / 10000,
    rules: { auto: rules.auto, mode: rules.mode, dayDivisor: rules.dayDivisor, absencePenaltyDays: rules.absencePenaltyDays,
      lateFixedAfterMinutes: rules.lateFixedAfterMinutes, lateFixedAmount: rules.lateFixedAmount, lateHourAmount: rules.lateHourAmount },
    late: { days: lateDays, minutes: lateMin, amount: auto ? r2(lateAmt) : 0 },
    early: { days: earlyDays, minutes: earlyMin, amount: auto ? r2(earlyAmt) : 0 },
    absence: { days: absentDays, amount: auto ? r2(absenceAmt) : 0 },
    unpaid: { days: unpaidDays, amount: auto ? r2(unpaidAmt) : 0 },
    adminDeductions: adminDed, bonuses, advances, workExpenses,
    totalDeductions: r2(autoTotal + adminDed),
    net: base === null ? null : r2(base - autoTotal - adminDed + bonuses - advances + workExpenses),
  };
}
