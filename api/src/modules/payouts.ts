import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { local } from '../lib/time.ts';
import { isUuid, monthParam, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';
import { notify } from './notify.ts';

const KINDS = ['salary', 'advance', 'commission', 'work_expense'] as const;
export const PAYOUT_AR: Record<string, string> = {
  salary: 'القبض', advance: 'السلفة', commission: 'العمولة', work_expense: 'مصاريف العمل', fund: 'صرف أموال',
};

/** Cash in hand: money received from the manager / owner minus everything paid out (not cancelled). */
export async function cashBalance(q: Q, employeeId: string): Promise<number> {
  const r = await one(q, `
    SELECT COALESCE((SELECT sum(amount_egp) FROM payouts WHERE employee_id = $1 AND kind = 'fund' AND status = 'received'), 0)
         - COALESCE((SELECT sum(amount_egp) FROM payouts WHERE created_by = $1 AND kind <> 'fund' AND status <> 'cancelled'), 0) AS b`,
    [employeeId]);
  return Number(r.b);
}

const COLS = `p.*, e.full_name AS employee_name, e.code AS employee_code, c.full_name AS created_by_name`;
const FROM = `FROM payouts p JOIN employees e ON e.id = p.employee_id JOIN employees c ON c.id = p.created_by`;

function shape(p: any, a: Actor) {
  return { ...p, kindAr: PAYOUT_AR[p.kind] ?? p.kind,
    canReceive: p.status === 'pending' && p.employee_id === a.id,
    canCancel: p.status === 'pending' && p.created_by === a.id };
}

/**
 * صرف مالية: HR pays salary / advances / commissions / work expenses out of the cash the manager or owner
 * handed over; every payout is confirmed by the person who got it ("تم الاستلام").
 */
export const payoutsModule: Module = (r, { db, clock }) => {
  r.get('/payouts', async (req) => {
    const a = await authenticate(db, req);
    const all = req.query.get('scope') !== 'mine' && (has(a, 'finance.disburse') || has(a, 'finance.fund'));
    const vals: unknown[] = []; const where: string[] = [];
    if (!all) { vals.push(a.id); where.push(`p.employee_id = $${vals.length}`); }
    const st = req.query.get('status');
    if (st) { vals.push(st); where.push(`p.status = $${vals.length}`); }
    const m = req.query.get('month');
    if (m) { vals.push(monthParam(m)); where.push(`p.period = $${vals.length}`); }
    const rows = await db.query(`SELECT ${COLS} ${FROM} ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
                                 ORDER BY p.created_at DESC LIMIT 500`, vals);
    const balance = has(a, 'finance.disburse') ? await cashBalance(db, a.id) : null;
    return ok({ currency: 'EGP', balance, payouts: rows.rows.map((p) => shape(p, a)),
      canDisburse: has(a, 'finance.disburse'), canFund: has(a, 'finance.fund') });
  });

  /** People who can receive cash for paying employees (HR). */
  r.get('/payouts/cashiers', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'finance.fund')) throw forbidden();
    const rows = await db.query(`
      SELECT e.id, e.full_name, e.code FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
       WHERE rp.perm_key = 'finance.disburse' AND e.status = 'active' AND e.id <> $1 ORDER BY e.full_name`, [a.id]);
    return ok({ cashiers: rows.rows });
  });

  r.post('/payouts', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const kind = oneOf(b, 'kind', [...KINDS, 'fund'] as const)!;
    const amount = num(b, 'amount', { min: 0.01, max: 10_000_000 })!;
    const employeeId = typeof b.employeeId === 'string' ? b.employeeId : '';
    if (!isUuid(employeeId)) throw invalid('Choose the employee', { field: 'employeeId' });
    if (employeeId === a.id) throw forbidden('You cannot pay yourself');
    const period = monthParam(typeof b.month === 'string' && b.month ? b.month : local(clock()).date.slice(0, 7));
    const note = str(b, 'note', { optional: true, max: 1000 }) ?? '';
    const advanceId = typeof b.advanceId === 'string' && b.advanceId ? b.advanceId : null;
    if (advanceId && !isUuid(advanceId)) throw invalid('advanceId is invalid', { field: 'advanceId' });

    const row = await db.tx(async (q) => {
      const emp = await one(q, `SELECT id, full_name, status FROM employees WHERE id = $1`, [employeeId]);
      if (!emp || emp.status !== 'active') throw notFound('Employee not found');
      if (kind === 'fund') {
        if (!has(a, 'finance.fund')) throw forbidden('Only the manager or the owner hands cash to HR');
        const ok = await one(q, `SELECT 1 FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
                                  WHERE e.id = $1 AND rp.perm_key = 'finance.disburse'`, [employeeId]);
        if (!ok) throw invalid('Cash can only be handed to someone who pays employees (HR)', { field: 'employeeId' });
      } else {
        if (!has(a, 'finance.disburse')) throw forbidden('Only HR pays employees');
        // one payer at a time: the cash box never goes below zero
        await q.query(`SELECT 1 FROM employees WHERE id = $1 FOR UPDATE`, [a.id]);
        const bal = await cashBalance(q, a.id);
        if (amount > bal) throw new AppError('unprocessable', 'Not enough cash in hand — ask the manager / owner for cash first', { reason: 'no_cash', balance: bal });
        if (advanceId) {
          const adv = await one(q, `SELECT * FROM advance_requests WHERE id = $1`, [advanceId]);
          if (!adv || adv.employee_id !== employeeId || adv.status !== 'confirmed') throw invalid('The advance is not approved', { field: 'advanceId' });
          if (await one(q, `SELECT 1 FROM payouts WHERE advance_id = $1 AND status <> 'cancelled'`, [advanceId])) throw conflict('This advance was already paid');
        }
      }
      const p = await one(q, `INSERT INTO payouts (employee_id, kind, amount_egp, period, note, advance_id, created_by)
                              VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING *`, [employeeId, kind, amount, period, note, advanceId, a.id]);
      await audit(q, a.id, 'payout.create', 'payout', p.id, undefined, { kind, amount, employeeId, period });
      await notify(q, { to: employeeId, type: 'payout_pending', title: `${PAYOUT_AR[kind]}: ${amount} جنيه — أكّد الاستلام`,
        body: `من ${a.fullName}${note ? ' — ' + note : ''}`, entity: 'payout', entityId: p.id, dedupeKey: `payout:${p.id}:pending` });
      return p;
    });
    return ok({ payout: shape(row, a) }, 201);
  });

  r.post('/payouts/:id/receive', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const now = clock();
    const p = await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM payouts WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x || x.employee_id !== a.id) throw notFound();
      if (x.status !== 'pending') throw conflict('Already confirmed or cancelled');
      const y = await one(q, `UPDATE payouts SET status = 'received', received_at = $2 WHERE id = $1 RETURNING *`, [x.id, now]);
      await audit(q, a.id, 'payout.received', 'payout', x.id);
      await notify(q, { to: x.created_by, type: 'payout_received', title: `${a.fullName} استلم ${PAYOUT_AR[x.kind]} (${x.amount_egp} جنيه)`,
        entity: 'payout', entityId: x.id, dedupeKey: `payout:${x.id}:received` });
      return y;
    });
    return ok({ payout: shape(p, a) });
  });

  r.post('/payouts/:id/cancel', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM payouts WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x || x.created_by !== a.id) throw notFound();
      if (x.status !== 'pending') throw conflict('Only a payout that was not received yet can be cancelled');
      await q.query(`UPDATE payouts SET status = 'cancelled', cancelled_at = now() WHERE id = $1`, [x.id]);
      await audit(q, a.id, 'payout.cancel', 'payout', x.id);
    });
    return ok({ ok: true });
  });
};
