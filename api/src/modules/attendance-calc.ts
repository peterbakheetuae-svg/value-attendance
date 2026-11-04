import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { daysInMonth, isoDow, local, timeToMinutes } from '../lib/time.ts';

export interface AttendanceRow {
  id: string; work_date: string; check_in_at: Date; check_out_at: Date | null;
  schedule_start: string; schedule_end: string; late_grace_minutes: number; early_grace_minutes: number;
  overtime_enabled: boolean; overtime_min_minutes: number; corrected: boolean; source: string;
  original_check_in_at: Date; original_check_out_at: Date | null; geofence_status: string;
}

export interface DayMetrics {
  lateMinutes: number; earlyMinutes: number; workedMinutes: number; overtimeMinutes: number;
  isLate: boolean; isEarly: boolean; missingCheckout: boolean;
}

/** Late/early are counted from the schedule start/end once they exceed the grace period. */
export function metrics(a: AttendanceRow, today: string): DayMetrics {
  const start = timeToMinutes(a.schedule_start), end = timeToMinutes(a.schedule_end);
  const inMin = local(new Date(a.check_in_at)).minutes;
  const lateRaw = Math.max(0, inMin - start);
  const late = lateRaw > a.late_grace_minutes ? lateRaw : 0;
  let early = 0, worked = 0, overtime = 0;
  const missing = !a.check_out_at && a.work_date < today;
  if (a.check_out_at) {
    const outLocal = local(new Date(a.check_out_at));
    // a check-out after local midnight counts as end-of-day + overflow
    const outMin = outLocal.date > a.work_date ? 24 * 60 + outLocal.minutes : outLocal.minutes;
    const earlyRaw = Math.max(0, end - outMin);
    early = earlyRaw > a.early_grace_minutes ? earlyRaw : 0;
    worked = Math.max(0, Math.round((new Date(a.check_out_at).getTime() - new Date(a.check_in_at).getTime()) / 60000));
    const extra = outMin - end;
    overtime = a.overtime_enabled && extra >= a.overtime_min_minutes ? extra : 0;
  }
  return { lateMinutes: late, earlyMinutes: early, workedMinutes: worked, overtimeMinutes: overtime,
    isLate: late > 0, isEarly: early > 0, missingCheckout: missing };
}

export type DayStatus =
  | 'present' | 'absent' | 'weekend' | 'holiday' | 'approved_absence' | 'unpaid_absence'
  | 'mission' | 'before_joining' | 'future' | 'inactive';

export interface DayEntry {
  date: string; status: DayStatus; holidayName?: string; absenceType?: string;
  attendance?: { id: string; checkIn: Date; checkOut: Date | null; corrected: boolean; hasSelfie: boolean } & DayMetrics;
  hourlyPermissionMinutes: number;
}

export interface MonthSummary {
  period: string; complete: boolean; throughDate: string | null;
  workingDays: number; attendedDays: number; absenceDays: number; approvedAbsenceDays: number;
  unapprovedAbsenceDays: number; unpaidAbsenceDays: number; missionDays: number;
  lateArrivals: number; lateMinutes: number; earlyDepartures: number; earlyMinutes: number;
  missingCheckouts: number; workedMinutes: number; overtimeMinutes: number;
  hourlyPermissions: number; hourlyPermissionMinutes: number; attendancePercent: number | null;
}

/**
 * Builds the day-by-day calendar for one employee and month from stored data only.
 * Working days are counted up to `today` (inclusive) so a running month is labelled incomplete.
 */
export async function computeMonth(q: Q, employeeId: string, period: string, today: string): Promise<{ days: DayEntry[]; summary: MonthSummary }> {
  const emp = await one(q, `
    SELECT e.joining_date, e.status, COALESCE(ws.weekend_days, dws.weekend_days) AS weekend_days
      FROM employees e
      LEFT JOIN work_schedules ws ON ws.id = e.schedule_id
      LEFT JOIN work_schedules dws ON dws.is_default
     WHERE e.id = $1`, [employeeId]);
  const days = daysInMonth(period);
  const first = days[0], last = days[days.length - 1];
  const [att, hol, abs, hourly] = await Promise.all([
    q.query<AttendanceRow & { has_selfie: boolean }>(`SELECT a.*, EXISTS (SELECT 1 FROM attendance_selfies s WHERE s.attendance_id = a.id) AS has_selfie
                                FROM attendance a WHERE a.employee_id = $1 AND a.work_date BETWEEN $2 AND $3`, [employeeId, first, last]),
    q.query(`SELECT day, name FROM holidays WHERE day BETWEEN $1 AND $2`, [first, last]),
    q.query(`SELECT start_date, end_date, absence_type FROM requests
              WHERE employee_id = $1 AND type = 'full_day_absence' AND status = 'approved'
                AND start_date <= $3 AND end_date >= $2`, [employeeId, first, last]),
    q.query(`SELECT day, duration_minutes FROM requests
              WHERE employee_id = $1 AND type IN ('hourly_permission','short_leave','emergency_permission')
                AND status = 'approved' AND day BETWEEN $2 AND $3`, [employeeId, first, last]),
  ]);
  const attBy = new Map(att.rows.map((a) => [a.work_date, a]));
  const holBy = new Map(hol.rows.map((h) => [h.day, h.name]));
  const hourlyBy = new Map<string, number>();
  for (const h of hourly.rows) hourlyBy.set(h.day, (hourlyBy.get(h.day) ?? 0) + h.duration_minutes);
  const weekend: number[] = emp?.weekend_days ?? [5];

  const s: MonthSummary = {
    period, complete: last < today, throughDate: null, workingDays: 0, attendedDays: 0, absenceDays: 0,
    approvedAbsenceDays: 0, unapprovedAbsenceDays: 0, unpaidAbsenceDays: 0, missionDays: 0,
    lateArrivals: 0, lateMinutes: 0, earlyDepartures: 0, earlyMinutes: 0, missingCheckouts: 0,
    workedMinutes: 0, overtimeMinutes: 0, hourlyPermissions: 0, hourlyPermissionMinutes: 0, attendancePercent: null,
  };

  const out: DayEntry[] = [];
  for (const d of days) {
    const a = attBy.get(d);
    const entry: DayEntry = { date: d, status: 'absent', hourlyPermissionMinutes: hourlyBy.get(d) ?? 0 };
    if (entry.hourlyPermissionMinutes) { s.hourlyPermissions++; s.hourlyPermissionMinutes += entry.hourlyPermissionMinutes; }
    const absence = abs.rows.find((x) => x.start_date <= d && x.end_date >= d);
    if (a) {
      const m = metrics(a, today);
      entry.status = 'present';
      entry.attendance = { id: a.id, checkIn: a.check_in_at, checkOut: a.check_out_at, corrected: a.corrected, hasSelfie: (a as any).has_selfie === true, ...m };
    }
    if (d > today) entry.status = a ? entry.status : 'future';
    else if (emp && d < emp.joining_date) entry.status = 'before_joining';
    else if (holBy.has(d) && !a) { entry.status = 'holiday'; entry.holidayName = holBy.get(d); }
    else if (weekend.includes(isoDow(d)) && !a) entry.status = 'weekend';
    else if (!a && absence) {
      entry.absenceType = absence.absence_type;
      entry.status = absence.absence_type === 'mission' ? 'mission' : absence.absence_type === 'unpaid' ? 'unpaid_absence' : 'approved_absence';
    }

    const isWorkingDay = d <= today && !(emp && d < emp.joining_date) && !holBy.has(d) && !weekend.includes(isoDow(d));
    if (isWorkingDay) {
      s.workingDays++; s.throughDate = d;
      if (entry.status === 'present' || entry.status === 'mission') s.attendedDays++;
      if (entry.status === 'mission') s.missionDays++;
      if (entry.status === 'absent') { s.absenceDays++; s.unapprovedAbsenceDays++; }
      if (entry.status === 'approved_absence') { s.absenceDays++; s.approvedAbsenceDays++; }
      if (entry.status === 'unpaid_absence') { s.absenceDays++; s.approvedAbsenceDays++; s.unpaidAbsenceDays++; }
    }
    if (entry.attendance) {
      const m = entry.attendance;
      if (m.isLate) { s.lateArrivals++; s.lateMinutes += m.lateMinutes; }
      if (m.isEarly) { s.earlyDepartures++; s.earlyMinutes += m.earlyMinutes; }
      if (m.missingCheckout) s.missingCheckouts++;
      s.workedMinutes += m.workedMinutes; s.overtimeMinutes += m.overtimeMinutes;
    }
    out.push(entry);
  }
  s.attendancePercent = s.workingDays ? Math.round((s.attendedDays / s.workingDays) * 1000) / 10 : null;
  return { days: out, summary: s };
}
