import { ok, type Module } from '../ctx.ts';
import { one } from '../db.ts';
import { conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { monthParam, num, obj, oneOf, reqStr, str, uuid, isUuid } from '../http/validate.ts';
import { audit, authenticate, requirePerm } from '../auth/context.ts';
import { holdersOf, notify } from './notify.ts';

/** Salary adjustments (EGP). Four-eyes: the creator, the subject and the approver are three different people. */
const KIND_AR: Record<string, string> = { deduction: 'جزاء', bonus: 'علاوة', raise: 'زيادة راتب' };

export const financeModule: Module = (r, { db }) => {
  r.get('/finance/adjustments/:id/attachment', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const x = await one(db, `SELECT employee_id, attachment FROM salary_adjustments WHERE id = $1`, [req.params.id]);
    if (!x || !x.attachment) throw notFound();
    if (x.employee_id !== a.id && !a.perms.has('finance.read')) throw notFound();
    return { binary: x.attachment, contentType: 'image/jpeg' };
  });

  r.get('/finance/adjustments', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'finance.read');
    const vals: unknown[] = []; const where: string[] = [];
    const k = req.query.get('kind'); if (k) { vals.push(k); where.push(`s.kind = $${vals.length}`); }
    const m = req.query.get('month'); if (m) { vals.push(monthParam(m)); where.push(`s.period = $${vals.length}`); }
    const st = req.query.get('status'); if (st) { vals.push(st); where.push(`s.status = $${vals.length}`); }
    const rows = await db.query(`
      SELECT s.id, s.employee_id, s.period, s.kind, s.amount_egp, s.reason, s.status, s.created_by, s.decided_by, s.decided_at,
             s.created_at, (s.attachment IS NOT NULL) AS has_attachment, e.full_name AS employee_name, e.code AS employee_code, c.full_name AS created_by_name, d.full_name AS decided_by_name
        FROM salary_adjustments s JOIN employees e ON e.id = s.employee_id JOIN employees c ON c.id = s.created_by
        LEFT JOIN employees d ON d.id = s.decided_by ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
       ORDER BY s.created_at DESC LIMIT 300`, vals);
    return ok({ currency: 'EGP', canCreate: a.perms.has('finance.manage'), adjustments: rows.rows.map((x) => ({ ...x, kindAr: KIND_AR[x.kind] ?? x.kind, canDecide: x.status === 'pending' && x.created_by !== a.id && x.employee_id !== a.id && a.perms.has('finance.approve') })) });
  });

  r.post('/finance/adjustments', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'finance.manage');
    const b = obj(req.body);
    const employeeId = uuid(b, 'employeeId')!;
    if (employeeId === a.id) throw forbidden('You cannot create an adjustment for yourself');
    if (!(await one(db, `SELECT 1 FROM employees WHERE id = $1`, [employeeId]))) throw notFound('Employee not found');
    let attachment: Buffer | null = null;
    if (typeof b.attachment === 'string' && b.attachment.length) {
      attachment = Buffer.from(b.attachment.replace(/^data:[^;]+;base64,/, ''), 'base64');
      if (attachment.length > 600_000) throw invalid('Attachment is too large', { field: 'attachment' });
    }
    const kind = oneOf(b, 'kind', ['deduction', 'bonus', 'raise'] as const)!;
    const row = await db.tx(async (q) => {
      const s = await one(q, `INSERT INTO salary_adjustments (employee_id, period, kind, amount_egp, reason, created_by, attachment)
        VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id, employee_id, period, kind, amount_egp, reason, status, created_by, created_at`,
        [employeeId, monthParam(typeof b.month === 'string' ? b.month : null),
        kind, num(b, 'amountEgp', { min: 0.01, max: 10_000_000 }),
        reqStr(b, 'reason', { min: 3, max: 500 }), a.id, attachment]);
      await audit(q, a.id, 'finance.adjustment_create', 'salary_adjustment', s.id, undefined, s);
      const emp = await one(q, `SELECT full_name FROM employees WHERE id = $1`, [employeeId]);
      for (const to of await holdersOf(q, 'finance.approve', [a.id, employeeId])) {
        await notify(q, { to, type: 'finance_awaiting', title: `${KIND_AR[kind]} بانتظار موافقتك`,
          body: `${emp.full_name} — ${s.amount_egp} جنيه`, entity: 'salary_adjustment', entityId: s.id, dedupeKey: `fin:${s.id}:awaiting` });
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
      if (status === 'approved' && s.kind === 'raise') {
        // زيادة راتب: added to the employee's "الزيادة" and to his monthly salary (starting salary + raises)
        const amt = Number(s.amount_egp);
        await q.query(`UPDATE employees SET legacy_fields = jsonb_set(COALESCE(legacy_fields, '{}'::jsonb), '{increase}',
                         to_jsonb((COALESCE(NULLIF(legacy_fields->>'increase', '')::numeric, 0) + $2)::text)) WHERE id = $1`, [s.employee_id, amt]);
        const cur = await one(q, `SELECT base_salary FROM employee_salaries WHERE employee_id = $1 FOR UPDATE`, [s.employee_id]);
        if (cur) await q.query(`UPDATE employee_salaries SET base_salary = base_salary + $2, updated_by = $3, updated_at = now() WHERE employee_id = $1`, [s.employee_id, amt, a.id]);
        else await q.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, $2, $3)`, [s.employee_id, amt, a.id]);
        await audit(q, a.id, 'employee.salary_raise', 'employee', s.employee_id, { baseSalary: cur ? Number(cur.base_salary) : null },
          { raise: amt, adjustmentId: s.id });
      }
      await notify(q, { to: s.employee_id, type: `finance_${status}`, title: `${KIND_AR[s.kind] ?? 'تسوية'}: ${s.amount_egp} جنيه — ${status === 'approved' ? 'اتعتمدت' : 'اترفضت'}`,
        entity: 'salary_adjustment', entityId: s.id, dedupeKey: `fin:${s.id}:${status}` });
      await audit(q, a.id, `finance.adjustment_${status}`, 'salary_adjustment', s.id, { status: s.status }, { status, comment });
    });
    return ok({ ok: true });
  });
};
