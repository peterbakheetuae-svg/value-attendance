/**
 * Notification categories for «إعدادات الإشعارات» (2026-11-26) — built from the notification types the API already sends.
 * A preference can only SUPPRESS a category for its owner; it never adds a recipient (who receives what is decided by the
 * sending code, from permissions and team records). Types outside every category are always delivered.
 */
export const CATEGORIES = ['unauthorized_exit', 'outings', 'requests', 'lateness_absence', 'attendance', 'finance', 'announcements'] as const;
export type Category = typeof CATEGORIES[number];

export const CATEGORY_AR: Record<Category, string> = {
  unauthorized_exit: 'تنبيهات الخروج بدون إذن',
  outings: 'طلبات المعاينة وإذن الساعات',
  requests: 'طلبات الإجازة والأذونات',
  lateness_absence: 'التأخير والغياب',
  attendance: 'الحضور والانصراف',
  finance: 'الإشعارات المالية',
  announcements: 'الإعلانات الإدارية',
};

/**
 * Always delivered, whatever a preference says: security alerts, the employee's own «you are outside without
 * permission», the payment code, and the phone calls that start the in-shift follow-up.
 */
export const MANDATORY_TYPES = new Set(['security_alert', 'unauthorized_exit_self', 'payout_otp', 'tracking_phone_off', 'checkin_other_phone']);

const EXACT: Record<string, Category> = {
  unauthorized_exit: 'unauthorized_exit',
  not_checked_in: 'lateness_absence', checkin_reminder: 'lateness_absence', not_checked_out: 'lateness_absence',
  checkout_reminder: 'lateness_absence', absence_threshold_reached: 'lateness_absence',
  back_in_office: 'attendance', tracking_stopped: 'attendance', tracking_weak_gps: 'attendance',
  offline_attendance: 'attendance', attendance_corrected: 'attendance',
  payroll_batch: 'finance', cash: 'finance',
  message: 'announcements',
};
const PREFIX: [string, Category][] = [
  ['outing_', 'outings'], ['request_', 'requests'],
  ['payout_', 'finance'], ['advance_', 'finance'], ['cash_', 'finance'], ['finance_', 'finance'], ['commission_', 'finance'],
  ['exclusive_payment', 'finance'], ['exclusive_refund', 'finance'], ['brokerage_', 'finance'], ['unauthorized_exit_deduction', 'finance'],
];

/** The category of a notification type (null = not a category: always delivered). */
export function categoryOf(type: string): Category | null {
  if (MANDATORY_TYPES.has(type)) return null;
  if (EXACT[type]) return EXACT[type];
  for (const [p, c] of PREFIX) if (type.startsWith(p)) return c;
  return null;
}

/** Categories that HR and the owners must keep (their approvals and the exit alarm never go silent). */
export const MANDATORY_FOR_HR_OWNER: ReadonlySet<Category> = new Set(['unauthorized_exit', 'outings', 'requests']);
