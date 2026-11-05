import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { obj, oneOf, reqStr, str, isUuid } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';
import { cairoInstant, local, actionTime } from '../lib/time.ts';
import { gmRecipients, holdersOf, notify } from './notify.ts';

const KIND_AR: Record<string, string> = { permission: 'إذن ساعات', visit: 'زيارة' };

async function resolveManager(q: Q, employeeId: string): Promise<string | null> {
  const r = await one(q, `
    SELECT COALESCE(
      (SELECT m.id FROM employees m WHERE m.id = e.sales_manager_id AND m.status = 'active'),
      (SELECT m.id FROM teams t JOIN employees m ON m.id = t.manager_id WHERE t.id = e.team_id AND t.active AND m.status = 'active')) AS mid
      FROM employees e WHERE e.id = $1`, [employeeId]);
  return r?.mid && r.mid !== employeeId ? r.mid : null;
}

/** Approvers: the employee's sales manager (snapshot) + every HR approver. */
async function approversOf(q: Q, employeeId: string, managerId: string | null) {
  const hr = await holdersOf(q, 'request.approve_hr', [employeeId]);
  // the owner is told only after approval (separate notification)
  const owners = new Set((await q.query<{ id: string }>(`SELECT id FROM employees WHERE role_key = 'owner'`)).rows.map((x) => x.id));
  return [...new Set([...(managerId ? [managerId] : []), ...hr])].filter((id) => !owners.has(id));
}

export function canDecide(a: Actor, r: any) {
  if (r.employee_id === a.id || r.status !== 'pending') return false;
  return has(a, 'request.approve_hr') || (has(a, 'request.approve_manager') && r.manager_id === a.id);
}

const COLS = `o.*, e.full_name AS employee_name, e.code AS employee_code, d.full_name AS decided_by_name, m.full_name AS manager_name`;
const FROM = `FROM outing_requests o JOIN employees e ON e.id = o.employee_id
  LEFT JOIN employees d ON d.id = o.decided_by LEFT JOIN employees m ON m.id = o.manager_id`;

/** The approved, not-yet-returned outing of an employee right now (latest in its extension chain). */
export async function activeOuting(q: Q, employeeId: string, date: string) {
  return one(q, `SELECT * FROM outing_requests WHERE employee_id = $1 AND work_date = $2
                  AND status = 'approved' AND returned_at IS NULL ORDER BY requested_at DESC LIMIT 1`, [employeeId, date]);
}

/** Close the whole chain when the employee is back (button or back inside the office geofence). */
export async function markReturned(q: Q, outing: any, at: Date, actorId: string | null, how: string) {
  let id: string | null = outing.id;
  const chain: string[] = [];
  while (id) {
    chain.push(id);
    const p = await one(q, `SELECT parent_id FROM outing_requests WHERE id = $1`, [id]);
    id = p?.parent_id ?? null;
  }
  await q.query(`UPDATE outing_requests SET returned_at = $2 WHERE id = ANY($1::uuid[]) AND returned_at IS NULL`, [chain, at]);
  await audit(q, actorId, 'outing.returned', 'outing_request', outing.id, undefined, { at, how });
}

function shape(r: any, a: Actor, now: Date) {
  return {
    ...r,
    isExtension: !!r.parent_id,
    overdue: r.status === 'approved' && !r.returned_at && new Date(r.expected_return_at) < now,
    canDecide: canDecide(a, r),
    canCancel: r.employee_id === a.id && r.status === 'pending',
  };
}

export const outingsModule: Module = (r, { db, clock }) => {
  /** Submit a permission / visit, or an extension (parentId) of the current approved one. */
  r.post('/outings', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const kind = oneOf(b, 'kind', ['permission', 'visit'] as const)!;
    const reason = reqStr(b, 'reason', { min: 3, max: 1000 });
    const ret = reqStr(b, 'expectedReturn', { max: 40 });
    const now = clock(); const l = local(now);
    // "HH:MM" today (Cairo) or a full ISO timestamp
    const expected = /^\d{2}:\d{2}$/.test(ret) ? cairoInstant(l.date, ret) : new Date(ret);
    if (Number.isNaN(expected.getTime())) throw invalid('Expected return time is invalid', { field: 'expectedReturn' });
    if (expected <= now) throw invalid('The return time must be later than now', { field: 'expectedReturn' });
    if (local(expected).date !== l.date) throw invalid('The return time must be today', { field: 'expectedReturn' });
    // hourly permission: its own start (HH:MM today); a visit (and an extension) starts now
    let startsAt: Date | null = null;
    if (kind === 'permission' && typeof b.startAt === 'string' && b.startAt) {
      if (!/^\d{2}:\d{2}$/.test(b.startAt)) throw invalid('Start time must be HH:MM', { field: 'startAt' });
      startsAt = cairoInstant(l.date, b.startAt);
      if (startsAt >= expected) throw invalid('The permission must end after it starts', { field: 'startAt' });
    }
    const parentId = typeof b.parentId === 'string' && b.parentId ? b.parentId : null;
    if (parentId && !isUuid(parentId)) throw notFound();

    const row = await db.tx(async (q) => {
      await q.query(`SELECT 1 FROM employees WHERE id = $1 FOR UPDATE`, [a.id]);
      const att = await one(q, `SELECT id, check_out_at FROM attendance WHERE employee_id = $1 AND work_date = $2`, [a.id, l.date]);
      // a permission can be requested before checking in (e.g. coming late with permission)
      if (att?.check_out_at) throw conflict('Your work day has ended');
      const pending = await one(q, `SELECT id FROM outing_requests WHERE employee_id = $1 AND work_date = $2 AND status = 'pending'`, [a.id, l.date]);
      if (pending) throw conflict('You already have a request waiting for approval');
      const active = await activeOuting(q, a.id, l.date);
      if (parentId) {
        if (!active || active.id !== parentId) throw conflict('Only the current approved permission/visit can be extended');
        if (expected <= new Date(active.expected_return_at)) throw invalid('The new return time must be after the current one', { field: 'expectedReturn' });
      } else if (active) {
        throw conflict('You are already out on an approved permission/visit — request an extension instead');
      }
      const managerId = await resolveManager(q, a.id);
      const x = await one(q, `INSERT INTO outing_requests (employee_id, kind, parent_id, work_date, requested_at, expected_return_at, reason, manager_id, starts_at)
                               VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *`,
        [a.id, parentId ? active.kind : kind, parentId, l.date, now, expected, reason, managerId, parentId ? null : startsAt]);
      await audit(q, a.id, parentId ? 'outing.extension_submit' : 'outing.submit', 'outing_request', x.id, undefined,
        { kind: x.kind, expectedReturn: expected, parentId });
      const label = parentId ? `تمديد ${KIND_AR[x.kind]}` : KIND_AR[x.kind];
      const fmt = (d: Date) => { const m = local(d).minutes; return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`; };
      const back = startsAt ? `${fmt(startsAt)} → ${fmt(expected)}` : fmt(expected);
      for (const to of await approversOf(q, a.id, managerId)) {
        await notify(q, { to, type: parentId ? 'outing_extension_awaiting' : 'outing_awaiting', title: `طلب ${label} من ${a.fullName}`,
          body: `${startsAt ? 'من' : 'الرجوع'} ${back} — ${reason}`, entity: 'outing_request', entityId: x.id, dedupeKey: `outing:${x.id}:awaiting` });
      }
      return x;
    });
    return ok({ outing: shape(row, a, now) }, 201);
  });

  r.get('/outings', async (req) => {
    const a = await authenticate(db, req);
    const now = clock();
    const vals: unknown[] = []; const where: string[] = [];
    const mine = req.query.get('scope') === 'mine';
    if (mine || (!has(a, 'request.approve_hr') && !has(a, 'request.read_all') && !has(a, 'request.approve_manager'))) {
      vals.push(a.id); where.push(`o.employee_id = $${vals.length}`);
    } else if (!has(a, 'request.approve_hr') && !has(a, 'request.read_all')) {
      vals.push(a.id); where.push(`(o.manager_id = $${vals.length} OR o.employee_id = $${vals.length})`);
    }
    const st = req.query.get('status');
    if (st === 'awaiting') { where.push(`o.status = 'pending'`); vals.push(a.id); where.push(`o.employee_id <> $${vals.length}`); }
    else if (st === 'out') { where.push(`o.status = 'approved' AND o.returned_at IS NULL`); }
    else if (st) { vals.push(st); where.push(`o.status = $${vals.length}`); }
    const date = req.query.get('date');
    if (date) { if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw invalid('date must be YYYY-MM-DD'); vals.push(date); where.push(`o.work_date = $${vals.length}`); }
    const rows = await db.query(`SELECT ${COLS} ${FROM} ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
                                 ORDER BY o.requested_at DESC LIMIT 300`, vals);
    return ok({ outings: rows.rows.map((x) => shape(x, a, now)) });
  });

  /** The employee's state today: pending request, current approved outing, overdue flag. */
  r.get('/outings/today', async (req) => {
    const a = await authenticate(db, req);
    const now = clock(); const l = local(now);
    const rows = await db.query(`SELECT ${COLS} ${FROM} WHERE o.employee_id = $1 AND o.work_date = $2 ORDER BY o.requested_at`, [a.id, l.date]);
    const list = rows.rows.map((x) => shape(x, a, now));
    const pending = list.find((x) => x.status === 'pending') ?? null;
    const active = [...list].reverse().find((x) => x.status === 'approved' && !x.returned_at) ?? null;
    return ok({ date: l.date, pending, active, history: list });
  });

  r.post('/outings/:id/decision', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const decision = oneOf(b, 'decision', ['approve', 'reject'] as const)!;
    const note = str(b, 'comment', { optional: true, max: 500 }) ?? null;
    const now = clock();
    const out = await db.tx(async (q) => {
      const x = await one(q, `SELECT o.*, e.full_name AS employee_name FROM outing_requests o JOIN employees e ON e.id = o.employee_id
                               WHERE o.id = $1 FOR UPDATE OF o`, [req.params.id]);
      if (!x) throw notFound();
      if (x.employee_id === a.id) throw forbidden('You cannot decide on your own request');
      if (x.status !== 'pending') throw conflict('This request has already been decided');
      if (!canDecide(a, x)) throw forbidden('Only the employee\'s sales manager or HR can decide');
      const status = decision === 'approve' ? 'approved' : 'rejected';
      await q.query(`UPDATE outing_requests SET status = $2, decided_by = $3, decided_at = $4, decision_note = $5 WHERE id = $1`,
        [x.id, status, a.id, now, note]);
      if (status === 'approved' && x.parent_id) {
        await q.query(`UPDATE outing_requests SET status = 'superseded' WHERE id = $1 AND status = 'approved'`, [x.parent_id]);
      }
      await audit(q, a.id, `outing.${status}`, 'outing_request', x.id, { status: 'pending' }, { status, note });
      const label = x.parent_id ? `تمديد ${KIND_AR[x.kind]}` : KIND_AR[x.kind];
      await notify(q, { to: x.employee_id, type: status === 'approved' ? 'outing_approved' : 'outing_rejected',
        title: status === 'approved' ? `تمت الموافقة على طلب ${label}` : `تم رفض طلب ${label}`,
        body: note ?? '', entity: 'outing_request', entityId: x.id, dedupeKey: `outing:${x.id}:${status}` });
      if (status === 'approved') {
        // the general manager (or the owner when none is set) hears only about approved requests
        for (const gm of (await gmRecipients(q, x.employee_id)).filter((id) => id !== a.id)) {
          await notify(q, { to: gm, type: x.parent_id ? 'outing_extension_approved_owner' : `outing_${x.kind}_approved_owner`,
            title: x.parent_id ? `تمت الموافقة على تمديد ${KIND_AR[x.kind]} — ${x.employee_name}` : `تمت الموافقة على ${KIND_AR[x.kind]} — ${x.employee_name}`,
            body: `وافق: ${a.fullName}`, entity: 'outing_request', entityId: x.id, dedupeKey: `outing:${x.id}:owner` });
        }
      }
      return status;
    });
    return ok({ status: out });
  });

  r.post('/outings/:id/cancel', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM outing_requests WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x || x.employee_id !== a.id) throw notFound();
      if (x.status !== 'pending') throw conflict('Only a pending request can be cancelled');
      await q.query(`UPDATE outing_requests SET status = 'cancelled', decided_at = now() WHERE id = $1`, [x.id]);
      await audit(q, a.id, 'outing.cancel', 'outing_request', x.id);
    });
    return ok({ ok: true });
  });

  /** "I'm back" — closes the current permission/visit. */
  r.post('/outings/return', async (req) => {
    const a = await authenticate(db, req);
    const { at: now } = actionTime(obj(req.body ?? {}), clock()); const l = local(now);
    await db.tx(async (q) => {
      const x = await activeOuting(q, a.id, l.date);
      if (!x) throw new AppError('conflict', 'You are not out on a permission or visit');
      await markReturned(q, x, now, a.id, 'button');
    });
    return ok({ ok: true, returnedAt: now });
  });
};
