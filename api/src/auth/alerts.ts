import type { Q } from '../db.ts';
import { notify } from '../modules/notify.ts';

/**
 * Suspicious-activity alerts: the owners get a notification (and a phone push) once per [key] — an account locked after
 * too many wrong passwords, a network that hit the sign-in limit. Never throws: an alert must not break the request.
 */
export async function securityAlert(q: Q, key: string, title: string, body: string): Promise<void> {
  try {
    const r = await q.query<{ id: string }>(`SELECT id FROM employees WHERE role_key = 'owner' AND status = 'active'`);
    for (const o of r.rows) await notify(q, { to: o.id, type: 'security_alert', title, body, dedupeKey: `sec:${key}` });
  } catch { /* best effort */ }
}
