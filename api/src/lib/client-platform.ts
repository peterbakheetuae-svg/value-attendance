import type { IncomingMessage } from 'node:http';

/**
 * G1 (2026-11-24) — which clients may record attendance (check-in / check-out / «I'm back») and feed location.
 *
 * A browser is recognised by the `Origin` header: every browser adds it to a POST (cross-origin always, same-origin too)
 * and page script can neither remove nor change it. The phone app (Android, dart:io) and the Windows app never send it.
 * Nothing the client says about itself (a platform field, a custom header, a device name) is read: it can be forged.
 * Limit (documented, same as fake GPS): a script outside a browser can omit Origin — the location rules still apply to it.
 *
 * ATTENDANCE_BROWSER_PUNCH (API host env):
 *  - approved_device (default, also when unset): a browser may punch only from a session whose device the administration
 *    approved («ربط الحساب بالجهاز» on for the employee and this browser's device approved) — e.g. an iPhone Home Screen
 *    app that is the employee's linked device. Any other browser is refused.
 *  - deny: no browser ever punches.
 *  - allow: the previous behaviour (any browser).
 *  - anything else: treated as deny (a typo never opens it).
 */
export type BrowserPunchPolicy = 'approved_device' | 'deny' | 'allow';

export function browserPunchPolicy(env: Record<string, string | undefined> = process.env): BrowserPunchPolicy {
  const v = (env.ATTENDANCE_BROWSER_PUNCH ?? '').trim().toLowerCase();
  if (v === '' || v === 'approved_device') return 'approved_device';
  if (v === 'allow') return 'allow';
  return 'deny';
}

/** the request was sent by a browser (it carries an Origin header — "null" included) */
export function isBrowserRequest(headers: IncomingMessage['headers']): boolean {
  const o: unknown = headers.origin;
  if (Array.isArray(o)) return o.length > 0;
  return typeof o === 'string' && o.trim().length > 0;
}
