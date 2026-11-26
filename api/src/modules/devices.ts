import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { createHash } from 'node:crypto';
import { AppError, conflict, forbidden, notFound } from '../http/errors.ts';
import { isUuid } from '../http/validate.ts';
import { audit, authenticate, can, has, type Actor } from '../auth/context.ts';
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

// ------------------------------------------------------------------ a marketing company's new device (097)
/**
 * Who approves a marketing company's new device: the devices.approve holders (the administrative officer, the owner) and
 * the company's own general manager / direct manager (its file's «المدير العام» / «المدير المباشر»), when active.
 */
export async function partnerDeviceApprovers(q: Q, companyId: string): Promise<string[]> {
  const c = await one(q, `SELECT general_manager_id, manager_id FROM marketing_companies WHERE id = $1`, [companyId]);
  const own = c ? (await q.query<{ id: string }>(`SELECT id FROM employees WHERE id = ANY($1::uuid[]) AND status = 'active'`,
    [[c.general_manager_id, c.manager_id].filter(Boolean)])).rows.map((x) => x.id) : [];
  return [...new Set([...(await holdersOf(q, 'devices.approve')), ...own])];
}

async function canApprovePartner(q: Q, a: Actor, companyId: string): Promise<boolean> {
  if (a.partner) return false; // a company never approves (its own or another's) device
  if (has(a, 'devices.approve')) return true;
  const c = await one(q, `SELECT general_manager_id, manager_id FROM marketing_companies WHERE id = $1`, [companyId]);
  return !!c && (c.general_manager_id === a.id || c.manager_id === a.id);
}

/** a stable, non-secret handle of a device id (the id itself is never sent to the office's screens) */
export const deviceRef = (deviceId: string) => createHash('sha256').update('partner-device:' + deviceId).digest('hex').slice(0, 24);

/**
 * Sign-in from a device that is not the company's linked one (password already right). Refused for good if the approvers
 * refused it; otherwise the request is kept on the company row FIRST (so a failed notification never loses it), the
 * approvers are told once per device, and the sign-in waits («device_pending»). A newer device replaces an older pending one.
 */
export async function partnerNewDevice(q: Q, companyId: string, deviceId: string, label: string | null): Promise<never> {
  const c = await one(q, `SELECT name, pending_device_id, rejected_device_ids FROM marketing_companies WHERE id = $1`, [companyId]);
  if ((c?.rejected_device_ids ?? []).includes(deviceId)) {
    throw new AppError('forbidden', 'The request to use this device was refused. Ask the administration', { reason: 'device_rejected' });
  }
  if (c?.pending_device_id !== deviceId) {
    const up = await one(q, `UPDATE marketing_companies SET pending_device_id = $2, pending_device_label = $3, pending_device_at = now()
                              WHERE id = $1 AND pending_device_id IS DISTINCT FROM $2 RETURNING id`, [companyId, deviceId, label]);
    if (up) {
      await audit(q, null, 'partner.device_requested', 'marketing_company', companyId, undefined, { label });
      const ref = deviceRef(deviceId);
      for (const to of await partnerDeviceApprovers(q, companyId)) {
        try {
          await notify(q, { to, type: 'partner_device_request', title: `شركة ${c?.name ?? ''} عايزة تدخل من جهاز جديد 📱`,
            body: `${label ?? 'جهاز'} — محتاج موافقتك (الموافقة تخليه جهاز الشركة بدل القديم)`, entity: 'marketing_company',
            entityId: companyId, dedupeKey: `partner_device:${companyId}:${ref}:${to}` });
        } catch { /* the request is saved and listed in «الأجهزة المنتظرة» even if one notice fails */ }
      }
    }
  }
  throw new AppError('forbidden', 'This device is waiting for the administration to approve it', { reason: 'device_pending' });
}

export const devicesModule: Module = (r, { db }) => {
  /** A marketing company's devices: the linked one and a pending request (the same shape as an employee's phones). */
  r.get('/marketing-companies/:id/devices', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const approver = await canApprovePartner(db, a, req.params.id);
    if (!approver && !(has(a, 'leads.config') || has(a, 'cash.office'))) throw notFound();
    const c = await one(db, `SELECT device_id, device_label, pending_device_id, pending_device_label, pending_device_at FROM marketing_companies WHERE id = $1`, [req.params.id]);
    if (!c) throw notFound();
    const devices = [
      ...(c.pending_device_id ? [{ id: deviceRef(c.pending_device_id), label: c.pending_device_label ?? 'جهاز', status: 'pending', requestedAt: c.pending_device_at, decidedAt: null, decidedBy: null, lastLoginAt: null }] : []),
      ...(c.device_id ? [{ id: deviceRef(c.device_id), label: c.device_label ?? 'جهاز', status: 'approved', requestedAt: null, decidedAt: null, decidedBy: null, lastLoginAt: null }] : []),
    ];
    return ok({ devices, canApprove: approver });
  });

  /** Companies' devices waiting for my decision (visible even if the notification never arrived). */
  r.get('/marketing-companies/devices/pending', async (req) => {
    const a = await authenticate(db, req);
    if (a.partner) throw forbidden();
    const rows = (await db.query(`SELECT id, name, pending_device_id, pending_device_label, pending_device_at FROM marketing_companies
                                   WHERE pending_device_id IS NOT NULL AND ($2::boolean OR general_manager_id = $1 OR manager_id = $1)
                                   ORDER BY pending_device_at`, [a.id, has(a, 'devices.approve')])).rows;
    return ok({ devices: rows.map((c) => ({ id: deviceRef(c.pending_device_id), companyId: c.id, companyName: c.name,
      label: c.pending_device_label ?? 'جهاز', status: 'pending', requestedAt: c.pending_device_at })) });
  });

  async function decidePartner(req: any, to: 'approved' | 'rejected') {
    const a = await authenticate(db, req);
    const { id, did } = req.params;
    if (!isUuid(id) || !/^[0-9a-f]{24}$/.test(String(did))) throw notFound();
    if (!await canApprovePartner(db, a, id)) throw forbidden('Only the general manager or the administrative officer can approve a device');
    await db.tx(async (q) => {
      const c = await one(q, `SELECT id, name, device_id, pending_device_id, pending_device_label FROM marketing_companies WHERE id = $1 FOR UPDATE`, [id]);
      if (!c) throw notFound();
      if (!c.pending_device_id || deviceRef(c.pending_device_id) !== did) {
        throw conflict(c.device_id && deviceRef(c.device_id) === did ? 'Already approved' : 'This request is no longer pending');
      }
      if (to === 'approved') {
        // the new device becomes the company's device; the old one is signed out (one linked device, as before)
        await q.query(`UPDATE marketing_companies SET device_id = pending_device_id, device_label = pending_device_label,
                         pending_device_id = NULL, pending_device_label = NULL, pending_device_at = NULL,
                         rejected_device_ids = array_remove(rejected_device_ids, pending_device_id) WHERE id = $1`, [id]);
        await q.query(`UPDATE partner_sessions SET revoked_at = now() WHERE company_id = $1 AND revoked_at IS NULL`, [id]);
      } else {
        await q.query(`UPDATE marketing_companies SET rejected_device_ids = array_append(array_remove(rejected_device_ids, pending_device_id), pending_device_id),
                         pending_device_id = NULL, pending_device_label = NULL, pending_device_at = NULL WHERE id = $1`, [id]);
      }
      await audit(q, a.id, to === 'approved' ? 'marketing_company.device_approved' : 'marketing_company.device_rejected', 'marketing_company', id,
        undefined, { label: c.pending_device_label });
    });
    return ok({ device: { id: did, status: to } });
  }
  r.post('/marketing-companies/:id/devices/:did/approve', (req) => decidePartner(req, 'approved'));
  r.post('/marketing-companies/:id/devices/:did/reject', (req) => decidePartner(req, 'rejected'));

  /** The phones of one employee (himself, HR, and whoever may approve them). */
  r.get('/employees/:id/devices', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const approver = await canApprove(db, a, req.params.id);
    if (a.id !== req.params.id && !approver && !can(a, 'employee.edit', 'employee.manage')) throw notFound();
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
    if (!await canApprove(db, a, id) && !can(a, 'employee.edit', 'employee.manage')) throw forbidden();
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
