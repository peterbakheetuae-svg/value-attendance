import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { conflict, forbidden, notFound } from '../http/errors.ts';
import { isUuid } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';
import { generalManagerOf, holdersOf, notify } from './notify.ts';

/**
 * ربط الحساب بأكتر من جهاز: the phones linked to an account. The first one is linked at sign-in by itself;
 * every other phone asks, and the employee's general manager, the administrative officer (devices.approve)
 * or the owner approves or refuses it. Only approved phones can sign in.
 */

/** Who is asked to approve a new phone: holders of devices.approve + the employee's general manager. */
export async function deviceApprovers(q: Q, employeeId: string): Promise<string[]> {
  const gm = await generalManagerOf(q, employeeId);
  return [...new Set([...(await holdersOf(q, 'devices.approve', [employeeId])), ...(gm ? [gm] : [])])];
}

async function canApprove(q: Q, a: Actor, employeeId: string): Promise<boolean> {
  if (a.id === employeeId) return false; // nobody approves his own phone
  if (has(a, 'devices.approve')) return true;
  return (await generalManagerOf(q, employeeId)) === a.id;
}

const shape = (d: any) => ({
  id: d.id, label: d.label ?? 'جهاز', status: d.status, requestedAt: d.requested_at, decidedAt: d.decided_at,
  decidedBy: d.decided_by_name ?? null, lastLoginAt: d.last_login_at,
});

export const devicesModule: Module = (r, { db }) => {
  /** The phones of one employee (himself, HR, and whoever may approve them). */
  r.get('/employees/:id/devices', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const approver = await canApprove(db, a, req.params.id);
    if (a.id !== req.params.id && !approver && !has(a, 'employee.manage')) throw notFound();
    const rows = await db.query(`
      SELECT d.*, x.full_name AS decided_by_name FROM employee_devices d LEFT JOIN employees x ON x.id = d.decided_by
       WHERE d.employee_id = $1
       ORDER BY (d.status = 'pending') DESC, (d.status = 'approved') DESC, d.requested_at`, [req.params.id]);
    return ok({ devices: rows.rows.map(shape), canApprove: approver });
  });

  /** Phones waiting for my approval (every employee I may approve for). */
  r.get('/devices/pending', async (req) => {
    const a = await authenticate(db, req);
    const rows = await db.query(`
      SELECT d.*, e.full_name, e.code FROM employee_devices d JOIN employees e ON e.id = d.employee_id
       WHERE d.status = 'pending' AND e.status = 'active' AND e.id <> $1
         AND ($2::boolean OR e.general_manager_id = $1)
       ORDER BY d.requested_at`, [a.id, has(a, 'devices.approve')]);
    return ok({ devices: rows.rows.map((d) => ({ ...shape(d), employeeId: d.employee_id, fullName: d.full_name, code: d.code })) });
  });

  async function decide(req: any, to: 'approved' | 'rejected') {
    const a = await authenticate(db, req);
    const { id, did } = req.params;
    if (!isUuid(id) || !isUuid(did)) throw notFound();
    if (!await canApprove(db, a, id)) throw forbidden('Only the general manager or the administrative officer can approve a phone');
    const d = await db.tx(async (q) => {
      const d = await one(q, `SELECT * FROM employee_devices WHERE id = $1 AND employee_id = $2 FOR UPDATE`, [did, id]);
      if (!d) throw notFound();
      if (d.status === to) throw conflict(to === 'approved' ? 'Already approved' : 'Already refused');
      await q.query(`UPDATE employee_devices SET status = $2, decided_at = now(), decided_by = $3 WHERE id = $1`, [did, to, a.id]);
      if (to === 'rejected') {
        // a refused phone is signed out at once
        await q.query(`UPDATE sessions SET revoked_at = now() WHERE employee_id = $1 AND device_id = $2 AND revoked_at IS NULL`, [id, d.device_id]);
      }
      await audit(q, a.id, to === 'approved' ? 'employee.device_approved' : 'employee.device_rejected', 'employee', id, undefined, { label: d.label });
      await notify(q, { to: id, type: to === 'approved' ? 'device_approved' : 'device_rejected',
        title: to === 'approved' ? 'اتوافق على جهازك الجديد ✅' : 'اترفض طلب الجهاز الجديد',
        body: to === 'approved' ? `تقدر تدخل دلوقتي من: ${d.label ?? 'الجهاز'}` : `${d.label ?? 'الجهاز'} — كلّم الإدارة`,
        entity: 'employee', entityId: id, dedupeKey: `device:${did}:${to}:${Date.now()}` });
      return d;
    });
    return ok({ device: { id: d.id, status: to } });
  }
  r.post('/employees/:id/devices/:did/approve', (req) => decide(req, 'approved'));
  r.post('/employees/:id/devices/:did/reject', (req) => decide(req, 'rejected'));

  /** Unlink one phone: it is signed out and can no longer sign in (it would have to ask again). */
  r.post('/employees/:id/devices/:did/remove', async (req) => {
    const a = await authenticate(db, req);
    const { id, did } = req.params;
    if (!isUuid(id) || !isUuid(did)) throw notFound();
    if (!await canApprove(db, a, id) && !has(a, 'employee.manage')) throw forbidden();
    await db.tx(async (q) => {
      const d = await one(q, `DELETE FROM employee_devices WHERE id = $1 AND employee_id = $2 RETURNING *`, [did, id]);
      if (!d) throw notFound();
      const s = await q.query(`UPDATE sessions SET revoked_at = now() WHERE employee_id = $1 AND device_id = $2 AND revoked_at IS NULL RETURNING id`, [id, d.device_id]);
      if (s.rows.length) {
        const ids = s.rows.map((x) => x.id);
        await q.query(`DELETE FROM push_tokens WHERE session_id = ANY($1::uuid[])`, [ids]);
        await q.query(`DELETE FROM web_push_subscriptions WHERE session_id = ANY($1::uuid[])`, [ids]);
      }
      await audit(q, a.id, 'employee.device_removed', 'employee', id, { label: d.label }, undefined);
    });
    return ok({ ok: true });
  });
};
