import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { isoDow, local, timeToMinutes } from '../lib/time.ts';
import { absenceThresholdMinutes, thresholdReached, type AbsencePolicy } from '../lib/attendance-policy.ts';

/**
 * The company's attendance policy columns, read schema-tolerantly (before migration 094 they do not exist: the policy is
 * off and every caller behaves exactly as before).
 */
export async function attendancePolicy(q: Q): Promise<{ absence: AbsencePolicy; exitTiers: any[]; exitDeduction: boolean; autoDeductions: boolean }> {
  const s = (await one(q, `SELECT to_jsonb(s) AS j FROM company_settings s LIMIT 1`))?.j ?? {};
  const mode = s.absence_threshold_mode === 'fixed_hours' || s.absence_threshold_mode === 'half_shift' ? s.absence_threshold_mode : null;
  return {
    absence: { mode, hours: s.absence_threshold_hours === null || s.absence_threshold_hours === undefined ? null : Number(s.absence_threshold_hours) },
    exitTiers: Array.isArray(s.unauthorized_exit_tiers) ? s.unauthorized_exit_tiers : [],
    exitDeduction: s.unauthorized_exit_deduction === true,
    autoDeductions: s.payroll_auto_deductions !== false,
  };
}

export interface DayShift {
  employeeId: string; date: string; start: string; end: string; weekendDays: number[]; workingDay: boolean;
  holiday: boolean; onLeave: boolean; exempt: boolean;
  /** the day's attendance row, when he checked in; its schedule snapshot is the shift of that day */
  attendance: { id: string; checkInAt: Date; checkOutAt: Date | null } | null;
  /** true when start / end come from that attendance row's snapshot (else from the current schedule) */
  fromSnapshot: boolean;
}

/**
 * Each person's shift on `date`: the schedule SNAPSHOT saved on that day's attendance row when he checked in (so a later
 * schedule change never rewrites that day), otherwise his current schedule; plus holiday, weekend and approved
 * full-day leave. Read-only.
 */
export async function dayShifts(q: Q, ids: string[], date: string): Promise<Map<string, DayShift>> {
  const out = new Map<string, DayShift>();
  if (!ids.length) return out;
  const rows = await q.query(`
    SELECT e.id, e.attendance_exempt,
           COALESCE(a.schedule_start, COALESCE(e.work_start, ws.start_time))::text AS start_time,
           COALESCE(a.schedule_end, COALESCE(e.work_end, ws.end_time))::text AS end_time,
           (a.id IS NOT NULL) AS snapshot, a.id AS att_id, a.check_in_at, a.check_out_at, ws.weekend_days,
           EXISTS (SELECT 1 FROM holidays h WHERE h.day = $2) AS holiday,
           EXISTS (SELECT 1 FROM requests r WHERE r.employee_id = e.id AND r.status = 'approved' AND r.type = 'full_day_absence'
                     AND r.start_date <= $2 AND r.end_date >= $2) AS on_leave
      FROM employees e
      JOIN work_schedules ws ON ws.id = COALESCE(e.schedule_id, (SELECT id FROM work_schedules WHERE is_default))
      LEFT JOIN attendance a ON a.employee_id = e.id AND a.work_date = $2
     WHERE e.id = ANY($1::uuid[])`, [ids, date]);
  const dow = isoDow(date);
  for (const r of rows.rows) {
    const weekendDays: number[] = r.weekend_days ?? [];
    out.set(r.id, {
      employeeId: r.id, date, start: String(r.start_time).slice(0, 5), end: String(r.end_time).slice(0, 5), weekendDays,
      workingDay: !weekendDays.includes(dow) && !r.holiday, holiday: r.holiday, onLeave: r.on_leave, exempt: r.attendance_exempt,
      attendance: r.att_id ? { id: r.att_id, checkInAt: new Date(r.check_in_at), checkOutAt: r.check_out_at ? new Date(r.check_out_at) : null } : null,
      fromSnapshot: r.snapshot,
    });
  }
  return out;
}

/**
 * The absence threshold for one person today: when (if the company configured it) he may register an absence for today.
 * Purely an eligibility answer — nothing is registered, approved or changed by it.
 */
export async function absenceWindow(q: Q, employeeId: string, now: Date) {
  const l = local(now);
  const [policy, shifts] = await Promise.all([attendancePolicy(q), dayShifts(q, [employeeId], l.date)]);
  const d = shifts.get(employeeId);
  const threshold = d ? absenceThresholdMinutes(policy.absence, d.start, d.end) : null;
  if (!d || threshold === null) return { configured: false as const, thresholdMinutes: null, reachedAtMinutes: null, reached: false, workingDay: d?.workingDay ?? false };
  const since = l.minutes - timeToMinutes(d.start);
  return { configured: true as const, thresholdMinutes: threshold, reachedAtMinutes: timeToMinutes(d.start) + threshold,
    reached: d.workingDay && thresholdReached(since, threshold), workingDay: d.workingDay };
}

/**
 * Which of these people count as AWAY right now — for notification routing only (2026-11-26, «Sales manager leave and
 * absence»); it changes no attendance, leave or request record:
 *  - an approved full-day absence / leave covering today, or
 *  - unresponsive: today is a working day for him, the company's absence threshold has passed, and he has not checked in.
 *    Only when the company configured the threshold; otherwise «not checked in» alone never makes anyone away.
 * Computed from the server's records on every call: once he checks in (or the leave ends) he is no longer away.
 */
export async function awaySet(q: Q, ids: string[], now: Date): Promise<Set<string>> {
  const out = new Set<string>();
  if (!ids.length) return out;
  const l = local(now);
  const [policy, shifts] = await Promise.all([attendancePolicy(q), dayShifts(q, ids, l.date)]);
  for (const d of shifts.values()) {
    if (d.onLeave) { out.add(d.employeeId); continue; }
    if (d.exempt || d.attendance || !d.workingDay) continue;
    const t = absenceThresholdMinutes(policy.absence, d.start, d.end);
    if (thresholdReached(l.minutes - timeToMinutes(d.start), t)) out.add(d.employeeId);
  }
  return out;
}

/** The ones of these people who are NOT away now (order kept). */
export async function available(q: Q, ids: string[], now: Date): Promise<string[]> {
  const away = await awaySet(q, ids, now);
  return ids.filter((id) => !away.has(id));
}
