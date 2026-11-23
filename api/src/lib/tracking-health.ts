/**
 * Tracking health (2026-11-24, G2 / T2): pure rules, no database — the sweep and the live board use them.
 */

/** a GPS fix with a reported accuracy worse than this proves nothing about inside / outside the office */
export const WEAK_GPS_M = 200;

/** weak = an accuracy was reported and it is worse than WEAK_GPS_M (200 m itself still counts as a usable fix) */
export const isWeakFix = (acc: number | null | undefined): boolean => typeof acc === 'number' && Number.isFinite(acc) && acc > WEAK_GPS_M;

/**
 * What the board shows for a device. A weak last fix is never taken as «still inside»: unknown (null) — unless the
 * device is already known to be outside (a weak fix after an exit proves no return either, so «outside» stays).
 */
export function boardInside(inside: boolean | null, lastAccuracyM: number | null): boolean | null {
  if (inside === false) return false;
  return isWeakFix(lastAccuracyM) ? null : inside;
}

const minutesSince = (from: Date, now: Date) => Math.floor((now.getTime() - from.getTime()) / 60_000);

/** checked in and not one location since: the watchers are told once [staleMin] minutes have passed since the check-in */
export function neverPingedDue(checkInAt: Date, now: Date, staleMin: number): boolean {
  return staleMin > 0 && minutesSince(checkInAt, now) >= staleMin;
}

/** minimum weak fixes in a row before a warning (one poor sample never warns) */
export const WEAK_STREAK_MIN = 3;

/**
 * Locations keep arriving but none is usable: at least WEAK_STREAK_MIN weak fixes since the last usable one (or since the
 * check-in when there was none) and that usable one is [staleMin] minutes old or more.
 */
export function weakStreakDue(p: { lastGoodAt: Date | null; checkInAt: Date; now: Date; staleMin: number; weakSince: number }): boolean {
  if (p.staleMin <= 0 || p.weakSince < WEAK_STREAK_MIN) return false;
  const from = p.lastGoodAt && p.lastGoodAt > p.checkInAt ? p.lastGoodAt : p.checkInAt;
  return minutesSince(from, p.now) >= p.staleMin;
}

/**
 * Why no location arrives, as far as the server can tell from what it already keeps:
 *  - no_tracking_phone: no signed-in Android phone with the app (push token) on the account — nothing can track him
 *  - no_location: an Android phone of his talked to the server recently but sent no location → GPS / location permission off
 *  - phone_offline: his Android phone(s) did not talk to the server recently → off, no internet, or the app was stopped
 */
export type SilentCause = 'no_tracking_phone' | 'no_location' | 'phone_offline';

export function silentCause(p: { androidPhones: number; androidSeenRecently: boolean }): SilentCause {
  if (p.androidPhones <= 0) return 'no_tracking_phone';
  return p.androidSeenRecently ? 'no_location' : 'phone_offline';
}

export const SILENT_CAUSE_AR: Record<SilentCause, string> = {
  no_tracking_phone: 'مفيش موبايل أندرويد عليه التطبيق متسجل دخول على حسابه',
  no_location: 'الموبايل متصل بالسيستم بس مش بيبعت موقع — غالبًا الـ GPS أو صلاحية الموقع مقفولة',
  phone_offline: 'الموبايل مش متصل — مقفول أو من غير نت أو التطبيق اتقفل',
};
