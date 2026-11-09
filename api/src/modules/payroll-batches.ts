import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { local } from '../lib/time.ts';
import { isUuid, monthParam, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';
import { notify } from './notify.ts';
import { computePayroll, loadRules } from './payroll-calc.ts';

/**
 * Financial system, phase 3 — monthly payroll batches and advance repayment.
 *
 * Batch: HR prepares (draft, each employee's full calculation frozen as a snapshot) → HR reviews and submits →
 * المدير / owner approves or returns it (never the one who prepared it) → HR pays each line from the HR cashbox
 * (a صرف مالية salary payout linked to the line) → the employee confirms receipt or reports a problem.
 * Not confirming is never treated as having received the money.
 *
 * Advances: the amount deducted each month is set by hand (approved policy), at most two stages, never more than
 * what is left of the advance, never twice in the same month, and not in a month whose salary was already paid.
 */

const r2 = (n: number) => Math.round(n * 100) / 100;
const canPrepare = (a: Actor) => has(a, 'payroll.prepare');
const canApprove = (a: Actor) => has(a, 'payroll.approve');
const MAX_STAGES = 2;

async function salaryPaidOut(q: Q, employeeId: string, period: string) {
  return !!(await one(q, `SELECT 1 FROM payouts WHERE employee_id = $1 AND period = $2 AND kind = 'salary' AND status = 'received'`, [employeeId, period]));
}

async function advanceState(q: Q, advanceId: string) {
  const a = await one(q, `SELECT ar.*, e.full_name AS employee_name FROM advance_requests ar JOIN employees e ON e.id = ar.employee_id WHERE ar.id = $1`, [advanceId]);
  if (!a) return null;
  const d = await q.query(`SELECT d.*, c.full_name AS created_by_name FROM advance_deductions d JOIN employees c ON c.id = d.created_by
                            WHERE d.advance_id = $1 ORDER BY d.period, d.created_at`, [advanceId]);
  const active = d.rows.filter((x) => x.status === 'active');
  const planned = active.reduce((s, x) => s + Number(x.amount_egp), 0);
  return {
    advance: a,
    deductions: d.rows,
    // without hand-set deductions the old rule applies: the whole advance in its own month
    planned: active.length ? r2(planned) : Number(a.amount_egp),
    remaining: active.length ? r2(Number(a.amount_egp) - planned) : 0,
    mode: active.length ? 'manual' : 'default',
  };
}

function shapeAdvance(s: NonNullable<Awaited<ReturnType<typeof advanceState>>>) {
  return {
    id: s.advance.id, employeeId: s.advance.employee_id, employeeName: s.advance.employee_name, amount: Number(s.advance.amount_egp),
    month: String(s.advance.period).slice(0, 7), status: s.advance.status, mode: s.mode, planned: s.planned, remaining: s.remaining,
    deductions: s.deductions.map((d) => ({ id: d.id, month: String(d.period).slice(0, 7), amount: Number(d.amount_egp), note: d.note,
      status: d.status, createdByName: d.created_by_name, createdAt: d.created_at })),
  };
}

export const payrollBatchesModule: Module = (r, { db, clock }) => {
  const today = () => local(clock()).date;

  // ------------------------------------------------------------------ advances: hand-set deductions
  r.get('/advances/open', async (req) => {
    const a = await authenticate(db, req);
    if (!canPrepare(a) && !canApprove(a)) throw forbidden();
    const rows = await db.query(`SELECT id FROM advance_requests WHERE kind = 'advance' AND status = 'confirmed' ORDER BY period DESC, created_at DESC LIMIT 300`);
    const out = [];
    for (const x of rows.rows) {
      const s = await advanceState(db, x.id);
      if (s) out.push(shapeAdvance(s));
    }
    return ok({ currency: 'EGP', advances: out });
  });

  r.get('/advances/mine', async (req) => {
    const a = await authenticate(db, req);
    const rows = await db.query(`SELECT id FROM advance_requests WHERE kind = 'advance' AND status = 'confirmed' AND employee_id = $1 ORDER BY period DESC`, [a.id]);
    const out = [];
    for (const x of rows.rows) {
      const s = await advanceState(db, x.id);
      if (s) out.push(shapeAdvance(s));
    }
    return ok({ currency: 'EGP', advances: out });
  });

  r.post('/advances/:id/deductions', async (req) => {
    const a = await authenticate(db, req);
    if (!canPrepare(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const period = monthParam(typeof b.month === 'string' ? b.month : null);
    const amount = num(b, 'amount', { min: 0.01, max: 10_000_000 })!;
    const note = str(b, 'note', { optional: true, max: 300 }) ?? '';
    await db.tx(async (q) => {
      const adv = await one(q, `SELECT * FROM advance_requests WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!adv || adv.kind !== 'advance') throw notFound();
      if (adv.status !== 'confirmed') throw conflict('Only an approved advance is deducted');
      if (adv.employee_id === a.id) throw forbidden('You cannot set your own advance deductions');
      if (period < String(adv.period).slice(0, 10)) throw invalid('Deductions start from the advance month', { field: 'month' });
      if (await salaryPaidOut(q, adv.employee_id, period)) {
        throw new AppError('unprocessable', 'That month was already paid — pick a later month', { reason: 'month_closed', field: 'month' });
      }
      const act = await q.query(`SELECT period, amount_egp FROM advance_deductions WHERE advance_id = $1 AND status = 'active'`, [adv.id]);
      if (act.rows.some((x) => String(x.period).slice(0, 10) === period)) {
        throw new AppError('conflict', 'This advance already has a deduction in that month', { reason: 'already_deducted' });
      }
      if (act.rows.length >= MAX_STAGES) throw new AppError('unprocessable', 'An advance is repaid in two stages at most', { reason: 'max_stages' });
      const left = Math.round(Number(adv.amount_egp) * 100) - act.rows.reduce((s, x) => s + Math.round(Number(x.amount_egp) * 100), 0);
      if (Math.round(amount * 100) > left) {
        throw new AppError('unprocessable', `Only ${left / 100} is left of this advance`, { reason: 'over_deduct', remaining: left / 100 });
      }
      const d = await one(q, `INSERT INTO advance_deductions (advance_id, employee_id, period, amount_egp, note, created_by) VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
        [adv.id, adv.employee_id, period, amount, note, a.id]);
      await audit(q, a.id, 'advance.deduction', 'advance_request', adv.id, undefined, { deductionId: d.id, month: period.slice(0, 7), amount });
      await notify(q, { to: adv.employee_id, type: 'advance_deduction', title: `خصم سلفة: ${r2(amount)} جنيه`,
        body: `من مرتب ${period.slice(0, 7)}`, entity: 'advance_request', entityId: adv.id, dedupeKey: `advance:${adv.id}:${period}` });
    });
    const s = await advanceState(db, req.params.id);
    return ok({ advance: shapeAdvance(s!) }, 201);
  });

  r.post('/advances/deductions/:id/cancel', async (req) => {
    const a = await authenticate(db, req);
    if (!canPrepare(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    let advanceId = '';
    await db.tx(async (q) => {
      const d = await one(q, `SELECT * FROM advance_deductions WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!d) throw notFound();
      if (d.status !== 'active') throw conflict('Already cancelled');
      if (await salaryPaidOut(q, d.employee_id, String(d.period).slice(0, 10))) {
        throw new AppError('unprocessable', 'That month was already paid — it cannot change', { reason: 'month_closed' });
      }
      await q.query(`UPDATE advance_deductions SET status = 'cancelled', cancelled_by = $2, cancelled_at = now() WHERE id = $1`, [d.id, a.id]);
      await audit(q, a.id, 'advance.deduction.cancel', 'advance_request', d.advance_id, { deductionId: d.id, amount: Number(d.amount_egp) }, { status: 'cancelled' });
      advanceId = d.advance_id;
    });
    const s = await advanceState(db, advanceId);
    return ok({ advance: shapeAdvance(s!) });
  });

  // ------------------------------------------------------------------ payroll batches
  async function batchView(q: Q, id: string, a: Actor) {
    const b = await one(q, `SELECT b.*, p.full_name AS prepared_by_name, d.full_name AS decided_by_name FROM payroll_batches b
                             JOIN employees p ON p.id = b.prepared_by LEFT JOIN employees d ON d.id = b.decided_by WHERE b.id = $1`, [id]);
    if (!b) throw notFound();
    const lines = await q.query(`
      SELECT l.*, e.full_name AS employee_name, e.code AS employee_code,
             (SELECT json_agg(json_build_object('id', po.id, 'amount', po.amount_egp, 'status', po.status, 'createdAt', po.created_at,
                     'receivedAt', po.received_at, 'disputeReason', po.dispute_reason) ORDER BY po.created_at)
                FROM payouts po WHERE po.batch_line_id = l.id AND po.status <> 'cancelled') AS payments
        FROM payroll_batch_lines l JOIN employees e ON e.id = l.employee_id WHERE l.batch_id = $1 ORDER BY e.full_name`, [id]);
    const shaped = lines.rows.map((l) => {
      const pays = (l.payments ?? []) as any[];
      const paid = pays.reduce((s, p) => s + Number(p.amount), 0);
      const net = Number(l.net_egp);
      const status = !pays.length ? (b.status === 'approved' ? 'approved' : b.status)
        : pays.some((p) => p.status === 'disputed') ? 'disputed'
          : paid + 0.005 < net ? 'partly_paid'
            : pays.every((p) => p.status === 'received') ? 'confirmed' : 'awaiting_confirmation';
      return { id: l.id, employeeId: l.employee_id, employeeName: l.employee_name, employeeCode: l.employee_code, net,
        paid: r2(paid), remaining: r2(Math.max(0, net - paid)), status, snapshot: l.snapshot,
        payments: pays.map((p) => ({ ...p, amount: Number(p.amount) })) };
    });
    const total = shaped.reduce((s, l) => s + l.net, 0);
    return {
      currency: 'EGP',
      batch: { id: b.id, refNo: Number(b.ref_no), month: String(b.period).slice(0, 7), status: b.status,
        preparedByName: b.prepared_by_name, preparedAt: b.prepared_at, submittedAt: b.submitted_at, decidedByName: b.decided_by_name,
        decidedAt: b.decided_at, returnReason: b.return_reason, total: r2(total),
        paid: r2(shaped.reduce((s, l) => s + l.paid, 0)), employees: shaped.length },
      lines: shaped,
      can: {
        refresh: canPrepare(a) && ['draft', 'returned'].includes(b.status),
        submit: canPrepare(a) && ['draft', 'returned'].includes(b.status),
        decide: canApprove(a) && b.status === 'pending_approval' && b.prepared_by !== a.id,
        pay: canPrepare(a) && has(a, 'finance.disburse') && b.status === 'approved',
        cancel: canPrepare(a) && ['draft', 'returned'].includes(b.status),
      },
    };
  }

  /** (Re)build every line from the payroll calculation — only while the batch is a draft / returned. */
  async function fillLines(q: Q, batchId: string, period: string) {
    await q.query(`DELETE FROM payroll_batch_lines WHERE batch_id = $1`, [batchId]);
    const rules = await loadRules(q);
    const emps = await q.query(`
      SELECT e.id FROM employees e WHERE e.status = 'active' AND e.role_key <> 'owner'
         AND EXISTS (SELECT 1 FROM employee_salaries s WHERE s.employee_id = e.id) ORDER BY e.full_name`);
    for (const e of emps.rows) {
      const p = await computePayroll(q, e.id, period, today(), rules);
      if (p.net === null) continue;
      await q.query(`INSERT INTO payroll_batch_lines (batch_id, employee_id, snapshot, net_egp) VALUES ($1,$2,$3,$4)`,
        [batchId, e.id, JSON.stringify(p), Math.max(0, Number(p.net))]);
    }
  }

  r.get('/payroll-batches', async (req) => {
    const a = await authenticate(db, req);
    if (!canPrepare(a) && !canApprove(a)) throw forbidden();
    const rows = await db.query(`
      SELECT b.*, p.full_name AS prepared_by_name, (SELECT count(*) FROM payroll_batch_lines l WHERE l.batch_id = b.id) AS n,
             (SELECT COALESCE(sum(net_egp),0) FROM payroll_batch_lines l WHERE l.batch_id = b.id) AS total
        FROM payroll_batches b JOIN employees p ON p.id = b.prepared_by ORDER BY b.period DESC, b.prepared_at DESC LIMIT 60`);
    return ok({ currency: 'EGP', batches: rows.rows.map((b) => ({ id: b.id, refNo: Number(b.ref_no), month: String(b.period).slice(0, 7),
      status: b.status, preparedByName: b.prepared_by_name, employees: Number(b.n), total: r2(Number(b.total)) })),
      can: { prepare: canPrepare(a), approve: canApprove(a) } });
  });

  r.post('/payroll-batches', async (req) => {
    const a = await authenticate(db, req);
    if (!canPrepare(a)) throw forbidden();
    const period = monthParam(typeof obj(req.body).month === 'string' ? obj(req.body).month as string : null);
    const id = await db.tx(async (q) => {
      if (await one(q, `SELECT 1 FROM payroll_batches WHERE period = $1 AND status <> 'cancelled'`, [period])) {
        throw new AppError('conflict', 'This month already has a payroll batch', { reason: 'batch_exists' });
      }
      const b = await one(q, `INSERT INTO payroll_batches (period, prepared_by) VALUES ($1,$2) RETURNING id`, [period, a.id]);
      await fillLines(q, b.id, period);
      await audit(q, a.id, 'payroll.batch.create', 'payroll_batch', b.id, undefined, { month: period.slice(0, 7) });
      return b.id;
    });
    return ok(await batchView(db, id, a), 201);
  });

  r.get('/payroll-batches/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!canPrepare(a) && !canApprove(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    return ok(await batchView(db, req.params.id, a));
  });

  async function step(id: string, a: Actor, fn: (q: Q, b: any) => Promise<void>) {
    if (!isUuid(id)) throw notFound();
    await db.tx(async (q) => {
      const b = await one(q, `SELECT * FROM payroll_batches WHERE id = $1 FOR UPDATE`, [id]);
      if (!b) throw notFound();
      await fn(q, b);
    });
    return ok(await batchView(db, id, a));
  }

  r.post('/payroll-batches/:id/refresh', async (req) => {
    const a = await authenticate(db, req);
    if (!canPrepare(a)) throw forbidden();
    return step(req.params.id, a, async (q, b) => {
      if (!['draft', 'returned'].includes(b.status)) throw conflict('Only a draft can be recalculated');
      await fillLines(q, b.id, String(b.period).slice(0, 10));
      await audit(q, a.id, 'payroll.batch.refresh', 'payroll_batch', b.id);
    });
  });

  r.post('/payroll-batches/:id/submit', async (req) => {
    const a = await authenticate(db, req);
    if (!canPrepare(a)) throw forbidden();
    return step(req.params.id, a, async (q, b) => {
      if (!['draft', 'returned'].includes(b.status)) throw conflict('Already submitted');
      await q.query(`UPDATE payroll_batches SET status = 'pending_approval', submitted_at = now(), return_reason = NULL WHERE id = $1`, [b.id]);
      await audit(q, a.id, 'payroll.batch.submit', 'payroll_batch', b.id, { status: b.status }, { status: 'pending_approval' });
      const ap = await q.query(`SELECT DISTINCT e.id FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
                                 WHERE rp.perm_key = 'payroll.approve' AND e.status = 'active' AND e.id <> $1`, [a.id]);
      for (const x of ap.rows) {
        await notify(q, { to: x.id, type: 'payroll_batch', title: `مرتبات ${String(b.period).slice(0, 7)} مستنية موافقتك`,
          body: `دفعة #${b.ref_no}`, entity: 'payroll_batch', entityId: b.id, dedupeKey: `payroll:${b.id}:submit:${Date.now()}` });
      }
    });
  });

  r.post('/payroll-batches/:id/decision', async (req) => {
    const a = await authenticate(db, req);
    if (!canApprove(a)) throw forbidden();
    const body = obj(req.body);
    const decision = oneOf(body, 'decision', ['approve', 'return'] as const)!;
    const reason = decision === 'return' ? str(body, 'reason', { min: 3, max: 500 })! : null;
    return step(req.params.id, a, async (q, b) => {
      if (b.status !== 'pending_approval') throw conflict('This batch is not waiting for approval');
      if (b.prepared_by === a.id) throw forbidden('You cannot approve a batch you prepared');
      await q.query(`UPDATE payroll_batches SET status = $2, decided_by = $3, decided_at = now(), return_reason = $4 WHERE id = $1`,
        [b.id, decision === 'approve' ? 'approved' : 'returned', a.id, reason]);
      await audit(q, a.id, `payroll.batch.${decision}`, 'payroll_batch', b.id, { status: b.status }, { status: decision === 'approve' ? 'approved' : 'returned', reason });
      await notify(q, { to: b.prepared_by, type: 'payroll_batch', title: decision === 'approve' ? `اتوافق على مرتبات ${String(b.period).slice(0, 7)}` : `اترجعت مرتبات ${String(b.period).slice(0, 7)}`,
        body: reason ?? 'تقدر تصرف دلوقتي', entity: 'payroll_batch', entityId: b.id, dedupeKey: `payroll:${b.id}:${decision}:${Date.now()}` });
    });
  });

  r.post('/payroll-batches/:id/cancel', async (req) => {
    const a = await authenticate(db, req);
    if (!canPrepare(a)) throw forbidden();
    return step(req.params.id, a, async (q, b) => {
      if (!['draft', 'returned'].includes(b.status)) throw conflict('Only a draft can be cancelled');
      await q.query(`UPDATE payroll_batches SET status = 'cancelled' WHERE id = $1`, [b.id]);
      await audit(q, a.id, 'payroll.batch.cancel', 'payroll_batch', b.id, { status: b.status }, { status: 'cancelled' });
    });
  });

  /** Pay one approved line (all or part of what is left) — a صرف مالية salary payout from the HR cashbox. */
  r.post('/payroll-batches/:id/lines/:lineId/pay', async (req) => {
    const a = await authenticate(db, req);
    if (!canPrepare(a) || !has(a, 'finance.disburse')) throw forbidden();
    if (!isUuid(req.params.lineId)) throw notFound();
    const body = obj(req.body);
    return step(req.params.id, a, async (q, b) => {
      if (b.status !== 'approved') throw conflict('The batch must be approved first');
      const l = await one(q, `SELECT * FROM payroll_batch_lines WHERE id = $1 AND batch_id = $2 FOR UPDATE`, [req.params.lineId, b.id]);
      if (!l) throw notFound();
      if (l.employee_id === a.id) throw forbidden('You cannot pay your own salary');
      const paid = await one(q, `SELECT COALESCE(sum(amount_egp),0) AS s FROM payouts WHERE batch_line_id = $1 AND status <> 'cancelled'`, [l.id]);
      const left = Math.round(Number(l.net_egp) * 100) - Math.round(Number(paid.s) * 100);
      if (left <= 0) throw new AppError('conflict', 'This salary was already paid', { reason: 'already_paid' });
      const amount = num(body, 'amount', { optional: true, min: 0.01, max: 10_000_000 }) ?? left / 100;
      if (Math.round(amount * 100) > left) throw new AppError('unprocessable', `Only ${left / 100} is left`, { reason: 'over_pay', remaining: left / 100 });
      const method = oneOf(body, 'method', ['cash', 'bank_transfer', 'wallet', 'cheque'] as const, true) ?? 'cash';
      const p = await one(q, `INSERT INTO payouts (employee_id, kind, amount_egp, period, note, created_by, batch_line_id)
                              VALUES ($1,'salary',$2,$3,$4,$5,$6) RETURNING id`,
        [l.employee_id, amount, String(b.period).slice(0, 10), `مرتب ${String(b.period).slice(0, 7)} — ${method}`, a.id, l.id]);
      await audit(q, a.id, 'payroll.pay', 'payroll_batch', b.id, undefined, { lineId: l.id, payoutId: p.id, amount, method });
      await notify(q, { to: l.employee_id, type: 'payout', title: `اتصرفلك مرتب ${String(b.period).slice(0, 7)}: ${r2(amount)} جنيه`,
        body: 'افتح التطبيق وأكّد الاستلام أو بلّغ عن مشكلة', entity: 'payout', entityId: p.id, dedupeKey: `payout:${p.id}` });
    });
  });

  /** The employee's own salary records (approved batches only). */
  r.get('/payroll-batches/mine/lines', async (req) => {
    const a = await authenticate(db, req);
    const rows = await db.query(`
      SELECT l.id, l.snapshot, l.net_egp, b.period, b.status,
             (SELECT json_agg(json_build_object('id', po.id, 'amount', po.amount_egp, 'status', po.status, 'createdAt', po.created_at, 'receivedAt', po.received_at))
                FROM payouts po WHERE po.batch_line_id = l.id AND po.status <> 'cancelled') AS payments
        FROM payroll_batch_lines l JOIN payroll_batches b ON b.id = l.batch_id
       WHERE l.employee_id = $1 AND b.status = 'approved' ORDER BY b.period DESC LIMIT 36`, [a.id]);
    return ok({ currency: 'EGP', lines: rows.rows.map((x) => ({ id: x.id, month: String(x.period).slice(0, 7), net: Number(x.net_egp),
      snapshot: x.snapshot, payments: (x.payments ?? []).map((p: any) => ({ ...p, amount: Number(p.amount) })) })) });
  });

  /** The employee reports a problem with a payment instead of confirming it. */
  r.post('/payouts/:id/dispute', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const reason = str(obj(req.body), 'reason', { min: 3, max: 500 })!;
    await db.tx(async (q) => {
      const p = await one(q, `SELECT * FROM payouts WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!p || p.employee_id !== a.id) throw notFound();
      if (p.status !== 'pending') throw conflict('Only a payment waiting for your confirmation can be disputed');
      await q.query(`UPDATE payouts SET status = 'disputed', dispute_reason = $2, disputed_at = now() WHERE id = $1`, [p.id, reason]);
      await audit(q, a.id, 'payout.dispute', 'payout', p.id, { status: 'pending' }, { status: 'disputed', reason });
      await notify(q, { to: p.created_by, type: 'payout_dispute', title: `بلاغ عن صرف ${r2(Number(p.amount_egp))} جنيه`,
        body: reason, entity: 'payout', entityId: p.id, dedupeKey: `payout:${p.id}:dispute` });
    });
    return ok({ ok: true });
  });
};
