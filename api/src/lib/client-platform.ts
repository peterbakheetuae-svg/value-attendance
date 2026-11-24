import type { IncomingMessage } from 'node:http';

/**
 * G1 — who may record attendance (check-in / check-out / «I'm back») and feed location. Revised 2026-11-24 (second
 * review): the decision rests on the server's own device-approval records, never on a request header.
 *
 * What is trusted, and what is not:
 *  - DEVICE AUTHORIZATION (enforced): «ربط الحساب بالجهاز» (employees.device_lock) + the administration's approval of a
 *    device id (employee_devices.status = 'approved'), checked against the device id the SESSION was created with
 *    (sessions.device_id, written by the server at sign-in after the approval check). Checked again on every attendance
 *    step, so a device refused after sign-in, a session without a device, or a device approved for someone else never
 *    punches — whatever headers the request carries.
 *  - CLIENT IDENTITY (NOT available): nothing proves the request comes from the genuine VALUNIVO app. A device id is a
 *    random value the app keeps; whoever copies it (and the password) can present it. Only platform attestation
 *    (Play Integrity) could prove the app — not in place. This module does not claim otherwise.
 *  - HEADERS (never trusted): Origin / User-Agent / custom headers are client-controlled. An Origin header is used only to
 *    REFUSE more (a browser of an employee whose account is not device-linked); its absence never grants anything that
 *    the device rule would not grant anyway.
 *
 * ATTENDANCE_DEVICE_POLICY (API host env):
 *  - approved_device (default, also when unset):
 *      device-linked employee → only from an approved device of his (any client: Android app, iPhone web app, …)
 *      not device-linked     → the administration turned the link off for him: no device can be checked; the phone
 *                              app keeps working, a browser is refused (the owner's choice: «approved device only»)
 *  - strict: every attendance step needs a device-linked account and an approved device (employees whose link is off
 *    are refused until the administration turns it on — use after checking the list in the report)
 *  - anything else: strict (a typo never opens it)
 */
export type DevicePolicy = 'approved_device' | 'strict';

export function devicePolicy(env: Record<string, string | undefined> = process.env): DevicePolicy {
  const v = (env.ATTENDANCE_DEVICE_POLICY ?? '').trim().toLowerCase();
  if (v === '' || v === 'approved_device') return 'approved_device';
  return 'strict';
}

/** a browser announced itself (Origin header, "null" included) — used only to refuse more, never to allow */
export function isBrowserRequest(headers: IncomingMessage['headers']): boolean {
  const o: unknown = headers.origin;
  if (Array.isArray(o)) return o.length > 0;
  return typeof o === 'string' && o.trim().length > 0;
}

/** what the server knows about the session (from its own tables) */
export interface SessionDevice {
  /** the employee's «ربط الحساب بالجهاز» */
  deviceLock: boolean;
  /** the device id the session was created with (null: unknown device) */
  deviceId: string | null;
  /** that device id is approved for THIS employee */
  approved: boolean;
}

export type PunchRefusal = 'device_not_approved' | 'device_link_off_browser' | 'device_link_required';

/** the attendance decision: null = allowed, otherwise why not. Headers can only add a refusal. */
export function punchRefusal(s: SessionDevice | null, browser: boolean, policy: DevicePolicy): PunchRefusal | null {
  if (!s) return 'device_not_approved';
  if (s.deviceLock) return s.deviceId && s.approved ? null : 'device_not_approved';
  if (policy === 'strict') return 'device_link_required';
  return browser ? 'device_link_off_browser' : null;
}

export const PUNCH_REFUSAL_AR: Record<PunchRefusal, string> = {
  device_not_approved: 'الجهاز ده مش معتمد لحسابك — سجّل من جهازك المعتمد أو اطلب موافقة الإدارة',
  device_link_off_browser: 'تسجيل الحضور من المتصفح محتاج «ربط الحساب بالجهاز» — سجّل من تطبيق الموبايل أو كلّم الإدارة',
  device_link_required: 'تسجيل الحضور محتاج «ربط الحساب بالجهاز» — كلّم الإدارة',
};
