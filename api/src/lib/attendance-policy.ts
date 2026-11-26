/**
 * Attendance policies (2026-11-26 requirements) — pure functions, no database: the API and the payroll call these, the
 * app never decides any of it.
 *
 *  1. Shift-based tracking eligibility: following an employee runs only inside his scheduled shift on a working day,
 *     between check-in and check-out, never on approved leave / approved absence or a holiday.
 *  2. Absence threshold: after how long past the shift start the employee may register an absence for that day — off
 *     (NULL: today's behaviour), a fixed number of hours, or half of that day's own scheduled shift (never a
 *     hard-coded 8-hour shift). It enables an action; it never marks anyone absent.
 *  3. «شرائح خروج بدون إذن»: fixed-EGP tiers by the minutes of an unauthorized exit, separate from the late / early tiers.
 *
 * Shifts are same-day (start < end), as everywhere else in the attendance calculation.
 */
import { invalid } from '../http/errors.ts';
import { timeToMinutes } from './time.ts';

export type AbsenceMode = 'fixed_hours' | 'half_shift';
export interface AbsencePolicy { mode: AbsenceMode | null; hours: number | null }

/** The scheduled shift's length in minutes (at least 1). */
export function shiftMinutes(start: string, end: string): number {
  return Math.max(1, timeToMinutes(end) - timeToMinutes(start));
}

/**
 * Minutes after the scheduled start at which registering an absence for that day becomes possible, or null when the policy
 * is off (or not fully configured — a mode without its value enables nothing).
 */
export function absenceThresholdMinutes(p: AbsencePolicy | null | undefined, shiftStart: string, shiftEnd: string): number | null {
  if (!p?.mode) return null;
  if (p.mode === 'fixed_hours') {
    const h = Number(p.hours);
    return Number.isFinite(h) && h > 0 ? Math.round(h * 60) : null;
  }
  if (p.mode === 'half_shift') return Math.floor(shiftMinutes(shiftStart, shiftEnd) / 2);
  return null;
}

/**
 * Has the threshold been reached, `minutesSinceStart` after the day's scheduled start? Reaching it only makes the
 * employee ELIGIBLE to register an absence for that day (a request HR reviews) — it never registers, approves or
 * records an absence by itself, and never changes the day's attendance.
 */
export function thresholdReached(minutesSinceStart: number, thresholdMinutes: number | null): boolean {
  return thresholdMinutes !== null && minutesSinceStart >= thresholdMinutes;
}

export type TrackingBlock = 'not_working_day' | 'holiday' | 'on_leave' | 'before_shift' | 'shift_ended' | 'not_checked_in' | 'checked_out';

/** Is the employee inside his eligible working period right now? (company / employee switches are checked separately) */
export function shiftEligibility(x: {
  nowMinutes: number; isoDow: number; weekendDays: number[]; holiday: boolean; onLeave: boolean;
  shiftStart: string; shiftEnd: string; checkedIn: boolean; checkedOut: boolean;
}): { eligible: boolean; reason: TrackingBlock | null; endsInMinutes: number | null } {
  const start = timeToMinutes(x.shiftStart), end = timeToMinutes(x.shiftEnd);
  const no = (reason: TrackingBlock) => ({ eligible: false, reason, endsInMinutes: null });
  if (x.holiday) return no('holiday');
  if (x.weekendDays.includes(x.isoDow)) return no('not_working_day');
  if (x.onLeave) return no('on_leave');
  if (x.nowMinutes < start) return no('before_shift');
  if (x.nowMinutes >= end) return no('shift_ended');
  if (!x.checkedIn) return no('not_checked_in');
  if (x.checkedOut) return no('checked_out');
  return { eligible: true, reason: null, endsInMinutes: end - x.nowMinutes };
}

// ------------------------------------------------------------------------------------------------ «شرائح خروج بدون إذن»
/** One tier: from `fromMinutes` (inclusive) up to `toMinutes` (exclusive; null = no upper limit), a fixed EGP amount. */
export interface ExitTier { fromMinutes: number; toMinutes: number | null; amount: number; enabled: boolean }

/**
 * Validates and normalises the tiers sent by the settings screen: whole minutes 1–1440, an upper limit above its lower
 * one, a positive amount, at most 10 tiers, and enabled tiers never overlapping (so exactly one tier — or none — applies
 * to any duration). Order = ascending fromMinutes: the deterministic priority.
 */
export function validateExitTiers(v: unknown): ExitTier[] {
  if (!Array.isArray(v) || v.length > 10) throw invalid('unauthorizedExitTiers must be a list of up to 10 tiers', { field: 'unauthorizedExitTiers' });
  const out = v.map((t: any, i) => {
    const from = Number(t?.fromMinutes), to = t?.toMinutes === null || t?.toMinutes === undefined || t?.toMinutes === '' ? null : Number(t.toMinutes);
    const amount = Number(t?.amount);
    if (!Number.isInteger(from) || from < 1 || from > 1440) throw invalid(`tier ${i + 1}: «from» must be whole minutes 1–1440`, { field: 'unauthorizedExitTiers' });
    if (to !== null && (!Number.isInteger(to) || to <= from || to > 1440)) throw invalid(`tier ${i + 1}: «to» must be after «from» (≤ 1440)`, { field: 'unauthorizedExitTiers' });
    if (!Number.isFinite(amount) || amount <= 0 || amount > 100000) throw invalid(`tier ${i + 1}: a positive amount up to 100000`, { field: 'unauthorizedExitTiers' });
    return { fromMinutes: from, toMinutes: to, amount: Math.round(amount * 100) / 100, enabled: t?.enabled !== false };
  }).sort((a, b) => a.fromMinutes - b.fromMinutes || (a.toMinutes ?? 1e9) - (b.toMinutes ?? 1e9));
  const on = out.filter((t) => t.enabled);
  for (let i = 1; i < on.length; i++) {
    const prev = on[i - 1];
    if (prev.toMinutes === null || on[i].fromMinutes < prev.toMinutes) {
      throw invalid(`the enabled tiers overlap (${prev.fromMinutes}${prev.toMinutes === null ? '+' : `–${prev.toMinutes}`} and ${on[i].fromMinutes}…)`, { field: 'unauthorizedExitTiers', reason: 'tiers_overlap' });
    }
  }
  return out;
}

/** The enabled tier a duration falls in (null = none: nothing is deducted). */
export function exitTierFor(tiers: ExitTier[] | null | undefined, minutes: number): ExitTier | null {
  for (const t of tiers ?? []) {
    if (!t.enabled) continue;
    if (minutes >= t.fromMinutes && (t.toMinutes === null || minutes < t.toMinutes)) return t;
  }
  return null;
}

/**
 * Minutes of an unauthorized exit that count: from the verified exit to the earlier of the verified return / check-out
 * and the scheduled shift end (time after the shift is never counted).
 */
export function exitMinutes(exitAt: Date, endAt: Date, shiftEndAt: Date): number {
  const until = Math.min(endAt.getTime(), shiftEndAt.getTime());
  return Math.max(0, Math.floor((until - exitAt.getTime()) / 60000));
}
