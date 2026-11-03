import { ok, type Module } from '../ctx.ts';
import { one } from '../db.ts';
import { conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { monthParam, num, obj, oneOf, reqStr, str, uuid, isUuid } from '../http/validate.ts';
import { audit, authenticate, requirePerm } from '../auth/context.ts';
import { holdersOf, notify } from './notify.ts';

/** Salary adjustments (EGP). Four-eyes: the creator, the subject and the approver are three different people. */
export const financeModule: Module = (r, { db }) => {
  r.get('/finance/adjustments', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'finance.read');
    const vals: unknown[] = []; const where: string[] = [];
    const m = req.query.get('month'); if (m) { vals.push(monthParam(m)); where.push(`s.period = $${vals.length}`); }
    const st = req.query.get('status'); if (st) { vals.push(st); where.push(`s.status = $${vals.length}`); }
    const rows = await db.query(`
      SELECT s.*, e.full_name AS employee_name, e.code AS employee_code, c.full_name AS created_by_name, d.full_name AS decided_by_name
        FROM salary_adjustments s JOIN employees e ON e.id = s.employee_id JOIN employees c ON c.id = s.created_by
        LEFT JOIN employees d ON d.id = s.decided_by ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
       ORDER BY s.created_at DESC LIMIT 300`, vals);
    return ok({ currency: 'EGP', adjustments: rows.rows.map((x) => ({ ...x, canDecide: x.status === 'pending' && x.created_by !== a.id && x.employee_id !== a.id && a.perms.has('finance.approve') })) });
  });

  r.post('/finance/adjustments', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'finance.manage');
    const b = obj(req.body);
    const employeeId = uuid(b, 'employeeId')!;
    if (employeeId === a.id) throw forbidden('You cannot create an adjustment for yourself');
    if (!(await one(db, `SELECT 1 FROM employees WHERE id = $1`, [employeeId]))) throw notFound('Employee not found');
    const row = await db.tx(async (q) => {
      const s = await one(q, `INSERT INTO salary_adjustments (employee_id, period, kind, amount_egp, reason, created_by)
        VALUES ($1,$2,$3,$4,$5,$6) RETURNING *`, [employeeId, monthParam(typeof b.month === 'string' ? b.month : null),
        oneOf(b, 'kind', ['deduction', 'bonus'] as const), num(b, 'amountEgp', { min: 0.01, max: 10_000_000 }),
        reqStr(b, 'reason', { min: 3, max: 500 }), a.id]);
      await audit(q, a.id, 'finance.adjustment_create', 'salary_adjustment', s.id, undefined, s);
      for (const to of await holdersOf(q, 'finance.approve', [a.id, employeeId])) {
        await notify(q, { to, type: 'finance_awaiting', title: 'تسوية مالية بانتظار الاعتماد', entity: 'salary_adjustment', entityId: s.id, dedupeKey: `fin:${s.id}:awaiting` });
      }
      return s;
    });
    return ok({ adjustment: row }, 201);
  });

  r.post('/finance/adjustments/:id/decision', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'finance.approve');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const decision = oneOf(b, 'decision', ['approve', 'reject'] as const)!;
    const comment = str(b, 'comment', { optional: true, max: 500 });
    if (decision === 'reject' && !comment) throw invalid('A rejection reason is required', { field: 'comment' });
    await db.tx(async (q) => {
      const s = await one(q, `SELECT * FROM salary_adjustments WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!s) throw notFound();
      if (s.created_by === a.id) throw forbidden('You cannot approve an adjustment you created');
      if (s.employee_id === a.id) throw forbidden('You cannot approve an adjustment about yourself');
      if (s.status !== 'pending') throw conflict('Already decided');
      const status = decision === 'approve' ? 'approved' : 'rejected';
      await q.query(`UPDATE salary_adjustments SET status = $2, decided_by = $3, decided_at = now() WHERE id = $1`, [s.id, status, a.id]);
      await audit(q, a.id, `finance.adjustment_${status}`, 'salary_adjustment', s.id, { status: s.status }, { status, comment });
    });
    return ok({ ok: true });
  });
};
