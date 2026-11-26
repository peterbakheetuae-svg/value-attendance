import type { Q } from '../db.ts';
import { audit } from '../auth/context.ts';
import { notify } from './notify.ts';

/**
 * A request / outing that found NO authorized approver to notify (its manager away and no HR approver): it stays
 * pending — nothing is approved, rejected or re-assigned, and no permission is granted to anyone. The company's active
 * owners (the existing administrative recipients) are told so someone can resolve it; when there is none, the routing
 * failure is recorded in the audit log for administrative resolution.
 */
export async function escalateUnrouted(q: Q, x: {
  actorId: string; entity: 'request' | 'outing'; entityId: string; title: string; body: string;
}): Promise<'escalated' | 'recorded'> {
  const owners = (await q.query<{ id: string }>(`SELECT id FROM employees WHERE role_key = 'owner' AND status = 'active' AND id <> $1`,
    [x.actorId])).rows.map((r) => r.id);
  if (owners.length) {
    for (const to of owners) {
      await notify(q, { to, type: 'routing_escalation', title: x.title, body: x.body, entity: x.entity, entityId: x.entityId,
        dedupeKey: `routing_escalation:${x.entity}:${x.entityId}:${to}` });
    }
    await audit(q, x.actorId, 'routing.escalated', x.entity, x.entityId, undefined, { to: owners, reason: 'no_available_approver' });
    return 'escalated';
  }
  await audit(q, x.actorId, 'routing.unrouted', x.entity, x.entityId, undefined, { reason: 'no_available_approver' });
  return 'recorded';
}
