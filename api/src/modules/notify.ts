import type { Q } from '../db.ts';
import { effectiveSql } from '../auth/permission-admin.ts';
import { pushTo, type PushResult } from '../lib/fcm.ts';

/** Insert a notification exactly once per (recipient, dedupeKey). Returns what the push did (null: a duplicate). */
export async function notify(q: Q, n: {
  to: string; type: string; title: string; body?: string; entity?: string; entityId?: string; dedupeKey: string;
}): Promise<PushResult | null> {
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
     WHERE e.id = $1 AND g.status = 'active' AND g.id <> e.id`, [employeeId]);
  return r.rows[0]?.id ?? null;
}

/** Who hears about approved requests: the general manager, or every active owner when none is set. */
export async function gmRecipients(q: Q, employeeId: string): Promise<string[]> {
  const gm = await generalManagerOf(q, employeeId);
  if (gm) return [gm];
  const r = await q.query<{ id: string }>(`SELECT id FROM employees WHERE role_key = 'owner' AND status = 'active' AND id <> $1`, [employeeId]);
  return r.rows.map((x) => x.id);
}
