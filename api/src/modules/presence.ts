import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { local, timeToMinutes } from '../lib/time.ts';
import { absenceThresholdMinutes, type AbsencePolicy } from '../lib/attendance-policy.ts';

/**
 * The company's attendance policy columns, read schema-tolerantly (before migration 094 they do not exist: the policy is
 * off and every caller behaves exactly as before).
 */
export async function attendancePolicy(q: Q): Promise<{ absence: AbsencePolicy; exitTiers: any[]; exitDeduction: boolean }> {
  const s = (await one(q, `SELECT to_jsonb(s) AS j FROM company_settings s LIMIT 1`))?.j ?? {};
  const mode = s.absence_threshold_mode === 'fixed_hours' || s.absence_threshold_mode === 'half_shift' ? s.absence_threshold_mode : null;
  return {
    absence: { mode, hours: s.absence_threshold_hours === null || s.absence_threshold_hours === undefined ? null : Number(s.absence_threshold_hours) },
    exitTiers: Array.isArray(s.unauthorized_exit_tiers) ? s.unauthorized_exit_tiers : [],
    exitDeduction: s.unauthorized_exit_deduction === true,
  };
}

/**
 * Which of these people are away from work right now (2026-11-26, «Sales manager leave and absence»):
 *  - an approved full-day absence / leave covering today, or
 *  - a recorded absence: today is a working day for him, the company's absence threshold has passed and he has not
 *    checked in (only when the company configured the threshold — otherwise «not checked in» alone never makes anyone away).
 * Computed from the server's records on every call: when the person is back (checks in / the leave ends) he is no longer away.
 */
export async function awaySet(q: Q, ids: string[], now: Date): Promise<Set<string>> {
  const out = new Set<string>();
  if (!ids.length) return out;
  const l = local(now);
  const policy = (await attendancePolicy(q)).absence;
  const rows = await q.query(`
    SELECT e.id, COALESCE(e.work_start, ws.start_time)::text AS start_time, COALESCE(e.work_end, ws.end_time)::text AS end_time,
           ws.weekend_days, e.attendance_exempt,
           EXISTS (SELECT 1 FROM requests r WHERE r.employee_id = e.id AND r.status = 'approved' AND r.type = 'full_day_absence'
                     AND r.start_date <= $2 AND r.end_date >= $2) AS on_leave,
           EXISTS (SELECT 1 FROM attendance a WHERE a.employee_id = e.id AND a.work_date = $2) AS checked_in,
           EXISTS (SELECT 1 FROM holidays h WHERE h.day = $2) AS holiday
      FROM employees e
      JOIN work_schedules ws ON ws.id = COALESCE(e.schedule_id, (SELECT id FROM work_schedules WHERE is_default))
     WHERE e.id = ANY($1::uuid[])`, [ids, l.date]);
  for (const r of rows.rows) {
    if (r.on_leave) { out.add(r.id); continue; }
    if (r.attendance_exempt || r.checked_in || r.holiday || (r.weekend_days as number[]).includes(l.isoDow)) continue;
    const t = absenceThresholdMinutes(policy, r.start_time.slice(0, 5), r.end_time.slice(0, 5));
    if (t !== null && l.minutes >= timeToMinutes(r.start_time.slice(0, 5)) + t) out.add(r.id);
  }
  return out;
}

/** The ones of these people who are NOT away now (order kept). */
export async function available(q: Q, ids: string[], now: Date): Promise<string[]> {
  const away = await awaySet(q, ids, now);
  return ids.filter((id) => !away.has(id));
}
