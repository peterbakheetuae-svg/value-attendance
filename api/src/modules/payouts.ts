import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { local } from '../lib/time.ts';
import { isUuid, monthParam, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';
import { notify } from './notify.ts';
import { computePayroll, loadRules } from './payroll-calc.ts';

const KINDS = ['salary', 'advance', 'commission', 'work_expense'] as const;
export const PAYOUT_AR: Record<string, string> = {
  salary: 'القبض', advance: 'السلفة', commission: 'العمولة', work_expense: 'مصاريف العمل', fund: 'صرف أموال',
};

/**
 * The HR cashbox book balance (cash_ledger: collections, expenses, transfers, cash handed over by the manager and
 * every payout). It may be negative — that is money the office owes the HR cashbox (approved policy).
 */
export async function cashBalance(q: Q, _employeeId?: string): Promise<number> {
  const r = await one(q, `SELECT COALESCE(sum(amount), 0) AS b FROM cash_ledger WHERE cashbox = 'hr'`);
  return Math.round(Number(r.b) * 100) / 100;
}

/** صرف الراتب is HR's desk only: المدير and the owner (office cashbox) see who was paid and who was not, nothing more. */
const paysSalaries = (a: Actor) => has(a, 'finance.disburse') && !has(a, 'cash.office');

const COLS = `p.*, e.full_name AS employee_name, e.code AS employee_code, c.full_name AS created_by_name`;
const FROM = `FROM payouts p JOIN employees e ON e.id = p.employee_id JOIN employees c ON c.id = p.created_by`;

function shape(p: any, a: Actor) {
  return { ...p, kindAr: PAYOUT_AR[p.kind] ?? p.kind,
    canReceive: (p.status === 'pending' || p.status === 'disputed') && p.employee_id === a.id,
    canDispute: p.status === 'pending' && p.employee_id === a.id,
    canCancel: (p.status === 'pending' || p.status === 'disputed') && p.created_by === a.id };
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
    const entitlementId = typeof b.entitlementId === 'string' && b.entitlementId ? b.entitlementId : null;
    if (entitlementId && (!isUuid(entitlementId) || kind !== 'commission')) throw invalid('entitlementId is invalid', { field: 'entitlementId' });

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
        // the HR cashbox may go below zero (approved policy): the deficit shows to the manager as money to transfer
        if (advanceId) {
          // paying an approved financial request (سلفة / مصاريف عمل): the amount is the approved one
          const adv = await one(q, `SELECT * FROM advance_requests WHERE id = $1 FOR UPDATE`, [advanceId]);
          if (!adv || adv.employee_id !== employeeId || adv.status !== 'confirmed') throw invalid('The advance is not approved', { field: 'advanceId' });
          if (adv.kind !== kind) throw invalid('The payment kind does not match the request', { field: 'kind' });
          if (adv.paid_outside) throw conflict('This advance was already handed over outside the cashbox');
          if (Math.round(Number(adv.amount_egp) * 100) !== Math.round(amount * 100)) throw invalid(`The approved amount is ${Number(adv.amount_egp)}`, { field: 'amount' });
          if (await one(q, `SELECT 1 FROM payouts WHERE advance_id = $1 AND status <> 'cancelled'`, [advanceId])) throw conflict('This advance was already paid');
        }
        if (entitlementId) {
          // paying an approved deal commission: amount and month come from the entitlement, never from the app
          const ce = await one(q, `SELECT * FROM commission_entitlements WHERE id = $1 FOR UPDATE`, [entitlementId]);
          if (!ce || ce.employee_id !== employeeId || ce.status !== 'active') throw invalid('The commission is not approved', { field: 'entitlementId' });
          if (Number(ce.amount_egp) !== amount) throw invalid(`The commission amount is ${Number(ce.amount_egp)}`, { field: 'amount' });
          if (String(ce.period).slice(0, 10) !== period) throw invalid('The commission belongs to another payroll month', { field: 'month' });
          if (await one(q, `SELECT 1 FROM payouts WHERE commission_entitlement_id = $1 AND status <> 'cancelled'`, [entitlementId])) {
            throw conflict('This commission was already paid');
          }
        }
      }
      const p = await one(q, `INSERT INTO payouts (employee_id, kind, amount_egp, period, note, advance_id, created_by, commission_entitlement_id)
                              VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`, [employeeId, kind, amount, period, note, advanceId, a.id, entitlementId]);
      await audit(q, a.id, 'payout.create', 'payout', p.id, undefined, { kind, amount, employeeId, period });
      await notify(q, { to: employeeId, type: 'payout_pending', title: `${PAYOUT_AR[kind]}: ${amount} جنيه — أكّد الاستلام`,
        body: `من ${a.fullName}${note ? ' — ' + note : ''}`, entity: 'payout', entityId: p.id, dedupeKey: `payout:${p.id}:pending` });
      return p;
    });
    return ok({ payout: shape(row, a) }, 201);
  });

  // ------------------------------------------------------------------ salaries (one month at a time)
  /**
   * The month's salary of every active employee who has one: what is due in cash — the payroll's net without the
   * commissions and the work expenses (those are paid on their own: صرف العمولة / صرف الطلب) — and what was paid.
   */
  async function salaryRow(q: Q, e: { id: string; full_name: string; code?: string }, period: string, rules: any, t: string) {
    const p: any = await computePayroll(q, e.id, period, t, rules);
    if (p?.net == null) return null;
    const due = Math.round((Number(p.net) - Number(p.commissions) - Number(p.workExpenses)) * 100) / 100;
    const pays = await q.query(`SELECT id, amount_egp, status, created_at, received_at FROM payouts
                                 WHERE employee_id = $1 AND period = $2 AND kind = 'salary' AND status <> 'cancelled'
                                 ORDER BY created_at`, [e.id, period]);
    const paid = Math.round(pays.rows.reduce((s, x) => s + Number(x.amount_egp), 0) * 100) / 100;
    const received = Math.round(pays.rows.filter((x) => x.status === 'received').reduce((s, x) => s + Number(x.amount_egp), 0) * 100) / 100;
    const remaining = Math.round((due - paid) * 100) / 100;
    const awaiting = Math.round((paid - received) * 100) / 100; // handed over, not confirmed by him yet (قيد المراجعة)
    const waiting = pays.rows.some((x) => x.status === 'pending' || x.status === 'disputed');
    return { employeeId: e.id, employeeName: e.full_name, employeeCode: e.code ?? null, month: period.slice(0, 7), due, paid, received, awaiting, remaining,
      complete: !!p.complete,
      status: remaining > 0.009 ? (paid > 0 ? 'partly_paid' : 'unpaid') : waiting ? 'awaiting_receipt' : paid > 0 ? 'received' : 'nothing_due',
      payments: pays.rows.map((x) => ({ id: x.id, amount: Number(x.amount_egp), status: x.status, createdAt: x.created_at, receivedAt: x.received_at })) };
  }

  r.get('/payouts/salaries', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'finance.disburse') && !has(a, 'finance.read')) throw forbidden();
    const period = monthParam(req.query.get('month') ?? local(clock()).date.slice(0, 7));
    const rules = await loadRules(db);
    const t = local(clock()).date;
    const emps = await db.query(`SELECT e.id, e.full_name, e.code FROM employees e JOIN employee_salaries s ON s.employee_id = e.id
                                  WHERE e.status = 'active' ORDER BY e.full_name`);
    // a few employees at a time (the connection pool is small) instead of one after another
    const out: any[] = new Array(emps.rows.length);
    let next = 0;
    await Promise.all([0, 1, 2].map(async () => {
      while (next < emps.rows.length) {
        const i = next++;
        const e = emps.rows[i];
        const x = await salaryRow(db, e, period, rules, t);
        out[i] = x ? { ...x, canPay: x.remaining > 0.009 && paysSalaries(a) && e.id !== a.id } : null;
      }
    }));
    const rows: any[] = out.filter(Boolean);
    const sum = (k: 'due' | 'paid' | 'received' | 'awaiting' | 'remaining') =>
      Math.round(rows.reduce((s, x) => s + Math.max(0, x[k]), 0) * 100) / 100;
    return ok({ currency: 'EGP', month: period.slice(0, 7), salaries: rows, canPay: paysSalaries(a),
      totals: { due: sum('due'), paid: sum('paid'), received: sum('received'), awaiting: sum('awaiting'), remaining: sum('remaining') } });
  });

  /** صرف الراتب: hands the employee what is left of the month's salary; it leaves the HR cashbox once he confirms. */
  r.post('/payouts/salary', async (req) => {
    const a = await authenticate(db, req);
    if (!paysSalaries(a)) throw forbidden('Only HR pays salaries — the manager and the owner only follow who was paid');
    const b = obj(req.body);
    const employeeId = typeof b.employeeId === 'string' ? b.employeeId : '';
    if (!isUuid(employeeId)) throw invalid('Choose the employee', { field: 'employeeId' });
    if (employeeId === a.id) throw forbidden('You cannot pay yourself');
    const period = monthParam(typeof b.month === 'string' && b.month ? b.month : local(clock()).date.slice(0, 7));
    const rules = await loadRules(db);
    const row = await db.tx(async (q) => {
      const emp = await one(q, `SELECT id, full_name, code, status FROM employees WHERE id = $1 FOR UPDATE`, [employeeId]);
      if (!emp || emp.status !== 'active') throw notFound('Employee not found');
      const x = await salaryRow(q, emp, period, rules, local(clock()).date);
      if (!x) throw invalid('This employee has no salary set', { field: 'employeeId' });
      if (x.remaining <= 0.009) throw new AppError('conflict', 'This salary was already paid', { reason: 'already_paid' });
      const p = await one(q, `INSERT INTO payouts (employee_id, kind, amount_egp, period, note, created_by)
                              VALUES ($1,'salary',$2,$3,$4,$5) RETURNING *`,
        [employeeId, x.remaining, period, `مرتب ${period.slice(0, 7)}`, a.id]);
      await audit(q, a.id, 'payout.salary', 'payout', p.id, undefined, { employeeId, period, amount: x.remaining, due: x.due });
      await notify(q, { to: employeeId, type: 'payout_pending', title: `مرتب ${period.slice(0, 7)}: ${x.remaining} جنيه — أكّد الاستلام`,
        body: `من ${a.fullName}`, entity: 'payout', entityId: p.id, dedupeKey: `payout:${p.id}:pending` });
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
      // a disputed payment can still be confirmed once the problem is settled
      if (x.status !== 'pending' && x.status !== 'disputed') throw conflict('Already confirmed or cancelled');
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
      // a disputed payment may be cancelled by whoever paid it (the money is back in the HR cashbox)
      if (x.status !== 'pending' && x.status !== 'disputed') throw conflict('Only a payout that was not received yet can be cancelled');
      await q.query(`UPDATE payouts SET status = 'cancelled', cancelled_at = now() WHERE id = $1`, [x.id]);
      await audit(q, a.id, 'payout.cancel', 'payout', x.id);
    });
    return ok({ ok: true });
  });
};
