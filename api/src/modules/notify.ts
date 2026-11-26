import type { Q } from '../db.ts';
import { effectiveSql } from '../auth/permission-admin.ts';
import { notSettled } from '../auth/context.ts';
import { pushTo, type PushResult } from '../lib/fcm.ts';
import { categoryOf, MANDATORY_FOR_HR_OWNER, type Category } from '../lib/notification-categories.ts';

// notification_preferences (proposed 094): read only once it exists — before, every notification is delivered as today
let prefsTable: { at: number; ok: boolean } | null = null;
async function prefsInstalled(q: Q): Promise<boolean> {
  if (prefsTable && Date.now() - prefsTable.at < 60_000) return prefsTable.ok;
  const r = await q.query<{ ok: boolean }>(`SELECT to_regclass('public.notification_preferences') IS NOT NULL AS ok`);
  prefsTable = { at: Date.now(), ok: r.rows[0]?.ok === true };
  return prefsTable.ok;
}
/** for the throwaway test databases */
export function forgetPrefsTable() { prefsTable = null; }

/**
 * «إعدادات الإشعارات»: true when the recipient turned this category off AND it is not mandatory for him (an owner, or an
 * HR approver for the approvals and the exit alarm). No row = on (nobody is silenced by default).
 */
export async function suppressedFor(q: Q, to: string, category: Category): Promise<boolean> {
  if (!(await prefsInstalled(q))) return false;
  const r = await q.query<{ off: boolean }>(`
    SELECT NOT p.enabled AND NOT (e.role_key = 'owner' OR ($3 AND ${effectiveSql('e', `'request.approve_hr'`)})) AS off
      FROM notification_preferences p JOIN employees e ON e.id = p.employee_id
     WHERE p.employee_id = $1 AND p.category = $2`, [to, category, MANDATORY_FOR_HR_OWNER.has(category)]);
  return r.rows[0]?.off === true;
}

/** Insert a notification exactly once per (recipient, dedupeKey). Returns what the push did (null: a duplicate). */
export async function notify(q: Q, n: {
  to: string; type: string; title: string; body?: string; entity?: string; entityId?: string; dedupeKey: string;
}): Promise<PushResult | null> {
  // the recipient's own preference may silence a category (never a mandatory one); it never adds anyone
  const cat = categoryOf(n.type);
  if (cat && await suppressedFor(q, n.to, cat)) return null;
  const r = await q.query<{ id: string }>(`
    INSERT INTO notifications (recipient_id, type, title, body, entity, entity_id, dedupe_key)
    SELECT $1,$2,$3,$4,$5,$6,$7
     WHERE EXISTS (SELECT 1 FROM employees WHERE id = $1 AND status = 'active')
    ON CONFLICT (recipient_id, dedupe_key) DO NOTHING RETURNING id`,
    [n.to, n.type, n.title, n.body ?? '', n.entity ?? null, n.entityId ?? null, n.dedupeKey]);
  // new notification → phone push (rings even when the app is closed); a duplicate never re-rings
  if (!r.rows[0]) return null;
  return pushTo(q, n.to, { id: r.rows[0].id, type: n.type, title: n.title, body: n.body ?? '', entityId: n.entityId });
}

/** Active holders of a permission (e.g. every HR approver). */
export async function holdersOf(q: Q, perm: string, exclude: string[] = []): Promise<string[]> {
  // the same resolution as sign-in: his job title's grant unless individually denied, or an individual grant
  const r = await q.query<{ id: string }>(`
    SELECT e.id FROM employees e
     WHERE e.status = 'active' AND NOT (e.id = ANY($2::uuid[])) AND ${effectiveSql('e', '$1')}`, [perm, exclude]);
  return r.rows.map((x) => x.id);
}

/** The employee's general manager (active, not themself), or null. */
export async function generalManagerOf(q: Q, employeeId: string): Promise<string | null> {
  const r = await q.query<{ id: string }>(`
    SELECT g.id FROM employees e JOIN employees g ON g.id = e.general_manager_id
     WHERE e.id = $1 AND g.status = 'active' AND ${notSettled('g')} AND g.id <> e.id`, [employeeId]);
  return r.rows[0]?.id ?? null;
}

/** Who hears about approved requests: the general manager, or every active owner when none is set. */
export async function gmRecipients(q: Q, employeeId: string): Promise<string[]> {
  const gm = await generalManagerOf(q, employeeId);
  if (gm) return [gm];
  const r = await q.query<{ id: string }>(`SELECT id FROM employees e WHERE e.role_key = 'owner' AND e.status = 'active' AND ${notSettled('e')} AND e.id <> $1`, [employeeId]);
  return r.rows.map((x) => x.id);
}
