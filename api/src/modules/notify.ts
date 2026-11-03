import type { Q } from '../db.ts';

/** Insert a notification exactly once per (recipient, dedupeKey). */
export async function notify(q: Q, n: {
  to: string; type: string; title: string; body?: string; entity?: string; entityId?: string; dedupeKey: string;
}) {
  await q.query(`
    INSERT INTO notifications (recipient_id, type, title, body, entity, entity_id, dedupe_key)
    SELECT $1,$2,$3,$4,$5,$6,$7
     WHERE EXISTS (SELECT 1 FROM employees WHERE id = $1 AND status = 'active')
    ON CONFLICT (recipient_id, dedupe_key) DO NOTHING`,
    [n.to, n.type, n.title, n.body ?? '', n.entity ?? null, n.entityId ?? null, n.dedupeKey]);
}

/** Active holders of a permission (e.g. every HR approver). */
export async function holdersOf(q: Q, perm: string, exclude: string[] = []): Promise<string[]> {
  const r = await q.query<{ id: string }>(`
    SELECT e.id FROM employees e JOIN role_permissions rp ON rp.role_key = e.role_key
     WHERE rp.perm_key = $1 AND e.status = 'active' AND NOT (e.id = ANY($2::uuid[]))`, [perm, exclude]);
  return r.rows.map((x) => x.id);
}
