import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, notFound } from '../http/errors.ts';
import { isUuid, obj, reqStr } from '../http/validate.ts';
import { audit, authenticate, has, readableIds } from '../auth/context.ts';
import { cairoInstant, local } from '../lib/time.ts';
import { exitMinutes, exitTierFor, type ExitTier } from '../lib/attendance-policy.ts';
import { attendancePolicy } from './presence.ts';
import { notify } from './notify.ts';

/**
 * «خروج بدون إذن» incidents (proposed migration 094) — one row per verified unauthorized exit:
 *  - opened by the tracking ping that first saw the employee outside the office with no approved permission / visit
 *    (a pending request does not make it authorized; the pending request is recorded on the incident);
 *  - closed once — back inside, check-out, or the scheduled shift end — with its minutes (exit → the earlier of the
 *    return and the shift end), the tier that applied and the fixed amount, frozen at that moment;
 *  - deducted by the payroll of its month exactly once (the payroll sums closed incidents; nothing is written to payroll);
 *  - corrected only by an auditable reversal (payroll.approve, never one's own, refused once that month's salary was paid).
 * One open incident per employee (database unique index), one incident per exit instant (unique): replayed pings, a
 * second phone outside, or concurrent requests never open a second one.
 * Before 094 is installed nothing here writes anything: the exit alarm works exactly as before.
 */
let installed: { at: number; ok: boolean } | null = null;
export async function incidentsInstalled(q: Q): Promise<boolean> {
  if (installed && Date.now() - installed.at < 60_000) return installed.ok;
  const r = await one(q, `SELECT to_regclass('public.unauthorized_exit_incidents') IS NOT NULL AS ok`);
  installed = { at: Date.now(), ok: r?.ok === true };
  return installed.ok;
}
export function forgetIncidentsInstalled() { installed = null; }

/** The scheduled end of the employee's shift on that day (Cairo). */
async function shiftEndAt(q: Q, employeeId: string, workDate: string): Promise<Date> {
  const s = await one(q, `SELECT COALESCE(e.work_end, ws.end_time)::text AS end_time FROM employees e
      JOIN work_schedules ws ON ws.id = COALESCE(e.schedule_id, (SELECT id FROM work_schedules WHERE is_default)) WHERE e.id = $1`, [employeeId]);
  return cairoInstant(workDate, String(s.end_time).slice(0, 5));
}

/** Opens the incident of a verified unauthorized exit (inside the ping's transaction). Returns its id, or null. */
export async function openIncident(q: Q, x: { employeeId: string; workDate: string; exitAt: Date; deviceKey: string }): Promise<string | null> {
  if (!(await incidentsInstalled(q))) return null;
  const att = await one(q, `SELECT id FROM attendance WHERE employee_id = $1 AND work_date = $2`, [x.employeeId, x.workDate]);
  if (!att) return null;
  // a request waiting for approval does not authorize the exit — it is recorded on the incident (and is never erased by a
  // later approval); an approved one whose return time passed is recorded as expired
  const req = await one(q, `SELECT id, status FROM outing_requests WHERE employee_id = $1 AND work_date = $2
                             AND (status = 'pending' OR (status = 'approved' AND returned_at IS NULL))
                           ORDER BY (status = 'pending') DESC, requested_at DESC LIMIT 1`, [x.employeeId, x.workDate]);
  const state = !req ? 'none' : req.status === 'pending' ? 'pending' : 'expired';
  const r = await one(q, `
    INSERT INTO unauthorized_exit_incidents (employee_id, work_date, attendance_id, exit_at, device_key, outing_id, permission_state, shift_end_at, period)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8, date_trunc('month', $2::date)::date)
    ON CONFLICT DO NOTHING RETURNING id`,
    [x.employeeId, x.workDate, att.id, x.exitAt, x.deviceKey, req?.id ?? null, state, await shiftEndAt(q, x.employeeId, x.workDate)]);
  if (r) await audit(q, x.employeeId, 'exit_incident.open', 'unauthorized_exit_incident', r.id, undefined, { exitAt: x.exitAt, permission: state });
  return r?.id ?? null;
}

/**
 * Closes the employee's open incident (back inside / check-out / shift end): minutes, tier and amount frozen now.
 * The deduction applies only when the company switched it on AND an enabled tier matches; otherwise the incident is kept
 * with no amount (recorded, never deducted).
 */
export async function closeIncident(q: Q, employeeId: string, at: Date, reason: 'returned' | 'checked_out' | 'shift_end'): Promise<void> {
  if (!(await incidentsInstalled(q))) return;
  const inc = await one(q, `SELECT * FROM unauthorized_exit_incidents WHERE employee_id = $1 AND status = 'open' FOR UPDATE`, [employeeId]);
  if (!inc) return;
  const policy = await attendancePolicy(q);
  const minutes = exitMinutes(new Date(inc.exit_at), at, new Date(inc.shift_end_at));
  const tier: ExitTier | null = exitTierFor(policy.exitTiers as ExitTier[], minutes);
  const amount = policy.exitDeduction && tier ? tier.amount : null;
  await q.query(`UPDATE unauthorized_exit_incidents SET status = 'closed', ended_at = $2, end_reason = $3, minutes = $4,
                   tier = $5::jsonb, amount_egp = $6, deduction_enabled = $7 WHERE id = $1`,
    [inc.id, new Date(Math.min(at.getTime(), new Date(inc.shift_end_at).getTime())), reason, minutes, tier ? JSON.stringify(tier) : null,
      amount, policy.exitDeduction]);
  await audit(q, employeeId, 'exit_incident.close', 'unauthorized_exit_incident', inc.id, undefined, { reason, minutes, tier, amount });
  if (amount) {
    await notify(q, { to: employeeId, type: 'unauthorized_exit_deduction', title: `خصم خروج بدون إذن: ${amount} جنيه`,
      body: `${minutes} دقيقة برة المكتب من غير إذن معتمد — من مرتب ${String(inc.period).slice(0, 7)}.`,
      entity: 'unauthorized_exit_incident', entityId: inc.id, dedupeKey: `exit_incident:${inc.id}:deduction` });
  }
}

/** Sweep: open incidents whose scheduled shift ended are closed at the shift end. */
export async function closeEndedShifts(q: Q, now: Date): Promise<void> {
  if (!(await incidentsInstalled(q))) return;
  const due = await q.query(`SELECT employee_id, shift_end_at FROM unauthorized_exit_incidents WHERE status = 'open' AND shift_end_at <= $1`, [now]);
  for (const d of due.rows) await closeIncident(q, d.employee_id, new Date(d.shift_end_at), 'shift_end');
}

/** The month's deductions from closed incidents, per employee (schema-tolerant: empty before 094). */
export async function incidentDeductions(q: Q, ids: string[], period: string): Promise<Map<string, { count: number; amount: number }>> {
  const out = new Map<string, { count: number; amount: number }>();
  if (!ids.length || !(await incidentsInstalled(q))) return out;
  const r = await q.query(`SELECT employee_id, count(*)::int AS n, COALESCE(sum(amount_egp), 0) AS s FROM unauthorized_exit_incidents
                            WHERE employee_id = ANY($1::uuid[]) AND period = $2 AND status = 'closed' AND amount_egp IS NOT NULL
                            GROUP BY employee_id`, [ids, period]);
  for (const x of r.rows) out.set(x.employee_id, { count: x.n, amount: Number(x.s) });
  return out;
}

export const exitIncidentsModule: Module = (r, { db, clock }) => {
  /** The incidents of a month (his own, or those of the people whose attendance he may read). */
  r.get('/attendance/exit-incidents', async (req) => {
    const a = await authenticate(db, req);
    if (!(await incidentsInstalled(db))) return ok({ installed: false, incidents: [] });
    const month = req.query.get('month') ?? local(clock()).date.slice(0, 7);
    if (!/^\d{4}-\d{2}$/.test(month)) throw new AppError('validation_failed', 'month must be YYYY-MM', { field: 'month' });
    const ids = req.query.get('scope') === 'mine' ? [a.id] : await readableIds(db, a, 'attendance');
    const rows = await db.query(`
      SELECT i.id, i.employee_id, e.full_name AS employee_name, i.work_date, i.exit_at, i.ended_at, i.end_reason, i.minutes,
             i.permission_state, i.tier, i.amount_egp, i.status, i.reversed_at, i.reverse_reason
        FROM unauthorized_exit_incidents i JOIN employees e ON e.id = i.employee_id
       WHERE i.period = $1::date AND ($2::uuid[] IS NULL OR i.employee_id = ANY($2::uuid[]))
       ORDER BY i.exit_at DESC`, [`${month}-01`, ids]);
    return ok({ installed: true, incidents: rows.rows });
  });

  /** Reversal: the only correction of an incident — auditable, never one's own, not after that month's salary was paid. */
  r.post('/attendance/exit-incidents/:id/reverse', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'payroll.approve')) throw forbidden('Only a payroll approver reverses an incident');
    if (!isUuid(req.params.id)) throw notFound();
    const reason = reqStr(obj(req.body), 'reason', { min: 3, max: 500 });
    if (!(await incidentsInstalled(db))) throw notFound();
    const row = await db.tx(async (q) => {
      const inc = await one(q, `SELECT * FROM unauthorized_exit_incidents WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!inc) throw notFound();
      if (inc.employee_id === a.id) throw forbidden('You cannot reverse your own incident');
      if (inc.status !== 'closed') throw conflict(inc.status === 'open' ? 'The incident is still open' : 'Already reversed');
      const paid = await one(q, `SELECT 1 FROM payouts WHERE employee_id = $1 AND period = $2 AND kind = 'salary' AND status = 'received'`,
        [inc.employee_id, inc.period]);
      if (paid && inc.amount_egp) {
        throw new AppError('unprocessable', 'That month\'s salary was already paid — use an approved bonus adjustment instead', { reason: 'month_paid' });
      }
      const x = await one(q, `UPDATE unauthorized_exit_incidents SET status = 'reversed', reversed_by = $2, reversed_at = now(), reverse_reason = $3
                               WHERE id = $1 RETURNING *`, [inc.id, a.id, reason]);
      await audit(q, a.id, 'exit_incident.reverse', 'unauthorized_exit_incident', inc.id, { status: 'closed', amount: inc.amount_egp }, { status: 'reversed', reason });
      await notify(q, { to: inc.employee_id, type: 'unauthorized_exit_deduction_reversed', title: 'اتلغى خصم خروج بدون إذن',
        body: reason, entity: 'unauthorized_exit_incident', entityId: inc.id, dedupeKey: `exit_incident:${inc.id}:reversed` });
      return x;
    });
    return ok({ incident: row });
  });
};
