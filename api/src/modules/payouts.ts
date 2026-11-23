import { createHash, randomInt } from 'node:crypto';
import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { local } from '../lib/time.ts';
import { isUuid, monthParam, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, type Actor, notSettled } from '../auth/context.ts';
import { notify } from './notify.ts';
import { computePayroll, computePayrollMany, loadRules } from './payroll-calc.ts';
import { legacyCoveredItem } from './legacy-coverage.ts';
import { companySalaryRows } from './company-payouts.ts';

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
  const open = p.status === 'pending' || p.status === 'disputed';
  return { ...p, kindAr: PAYOUT_AR[p.kind] ?? p.kind,
    // «تم الاستلام» is gone: the recipient shows the 4-digit code, the payer enters it (POST /payouts/:id/verify)
    canReceive: false,
    awaitingMyCode: open && p.employee_id === a.id,
    canVerify: open && p.created_by === a.id,
    canDispute: p.status === 'pending' && p.employee_id === a.id,
    canCancel: open && p.created_by === a.id };
}

// ------------------------------------------------------------------ the disbursement code (OTP)
/**
 * Every payment to an employee (salary, advance, commission, work expense, cash handed to HR) is confirmed by a 4-digit
 * code: the RECIPIENT's app asks for it (POST /payouts/:id/code — only he can) and shows it; he tells it to the person
 * paying, who enters it (POST /payouts/:id/verify). Only a hash is stored (action_otps, action «payout:<id>»): nobody —
 * the payer included — can read a code back. A new code ends the previous one; 5 wrong tries end a code; 15 wrong tries
 * on one payment within an hour stop it for an hour; at most 5 codes per payment in 15 minutes. Codes live
 * PAYOUT_OTP_TTL_MIN minutes (default 10, 2–30).
 */
export const PAYOUT_OTP_TTL_MIN = Math.min(30, Math.max(2, Number(process.env.PAYOUT_OTP_TTL_MIN ?? 10) || 10));
const otpAction = (id: string) => `payout:${id}`;
const otpHash = (recipient: string, id: string, code: string) => createHash('sha256').update(`${recipient}:${otpAction(id)}:${code}`).digest('hex');
const OPEN = ['pending', 'disputed'];

/** the recipient is told a payment waits for his code — the code itself never travels in a notification */
export async function tellRecipient(q: Q, x: { id: string; employee_id: string; kind: string; amount_egp: unknown }, payerName: string) {
  await notify(q, { to: x.employee_id, type: 'payout_otp', title: `${PAYOUT_AR[x.kind] ?? 'صرف'}: ${Math.round(Number(x.amount_egp) * 100) / 100} جنيه — مستني تأكيدك`,
    body: `افتح التطبيق: هيظهرلك كود من 4 أرقام، قوله لـ ${payerName} وهو يكتبه`, entity: 'payout', entityId: x.id, dedupeKey: `payout:${x.id}:otp` });
}

/**
 * F1: how much of an approved item (commission entitlement / work-expense request) is still to pay: its amount minus what
 * an OLDER payroll-sheet line of its month already paid for it inside the salary (legacy-coverage.ts — from that line's
 * own records, never from a salary amount). Fully covered → refused; partly covered → only the rest may be paid.
 */
async function itemLeftToPay(q: Q, employeeId: string, period: string, itemId: string, itemAmount: number) {
  const covered = await legacyCoveredItem(q, employeeId, period, itemId);
  const left = Math.round((itemAmount - covered) * 100) / 100;
  if (left <= 0.009) {
    throw new AppError('conflict', 'المبلغ ده اتصرف قبل كده ضمن كشف مرتبات الشهر (كشف قديم) — مش هيتصرف تاني',
      { reason: 'settled_in_payroll', coveredBySalary: covered });
  }
  return { left, covered };
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
       WHERE rp.perm_key = 'finance.disburse' AND e.status = 'active' AND ${notSettled('e')} AND e.id <> $1 ORDER BY e.full_name`, [a.id]);
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
      // one payout at a time per employee: two taps / two people can not both pass the checks below
      const emp = await one(q, `SELECT id, full_name, status FROM employees WHERE id = $1 FOR UPDATE`, [employeeId]);
      if (!emp || emp.status !== 'active') throw notFound('Employee not found');
      // the same payment twice (a double tap, two people at once): the same employee, kind, amount and month within two
      // minutes, not cancelled → refused (a real second payment is simply made after that)
      const twin = await one(q, `SELECT id FROM payouts WHERE employee_id = $1 AND kind = $2 AND amount_egp = $3 AND period = $4
                                   AND advance_id IS NOT DISTINCT FROM $5 AND commission_entitlement_id IS NOT DISTINCT FROM $6
                                   AND status <> 'cancelled' AND created_at > now() - interval '2 minutes'`,
        [employeeId, kind, amount, period, advanceId, entitlementId]);
      if (twin) throw new AppError('conflict', 'This exact payment was just made — check the list before paying again', { reason: 'duplicate_payout' });
      if (kind === 'fund') {
        if (!has(a, 'finance.fund')) throw forbidden('Only the manager or the owner hands cash to HR');
        const ok = await one(q, `SELECT 1 FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
                                  WHERE e.id = $1 AND rp.perm_key = 'finance.disburse'`, [employeeId]);
        if (!ok) throw invalid('Cash can only be handed to someone who pays employees (HR)', { field: 'employeeId' });
      } else {
        if (!has(a, 'finance.disburse')) throw forbidden('Only HR pays employees');
        // F2: a salary goes through صرف الراتب or the payroll sheet (they know what is due); a commission only against its
        // approved entitlement — never a free amount
        if (kind === 'salary') {
          throw new AppError('unprocessable', 'المرتب بيتصرف من «صرف الراتب» أو كشف المرتبات بس', { reason: 'salary_path_required' });
        }
        if (kind === 'commission' && !entitlementId) {
          throw new AppError('unprocessable', 'العمولة بتتصرف على عمولة معتمدة بس', { reason: 'entitlement_required', field: 'entitlementId' });
        }

        // the HR cashbox may go below zero (approved policy): the deficit shows to the manager as money to transfer
        if (advanceId) {
          // paying an approved financial request (سلفة / مصاريف عمل): the amount is the approved one
          const adv = await one(q, `SELECT * FROM advance_requests WHERE id = $1 FOR UPDATE`, [advanceId]);
          if (!adv || adv.employee_id !== employeeId || adv.status !== 'confirmed') throw invalid('The advance is not approved', { field: 'advanceId' });
          if (adv.kind !== kind) throw invalid('The payment kind does not match the request', { field: 'kind' });
          if (adv.paid_outside) throw conflict('This advance was already handed over outside the cashbox');
          if (await one(q, `SELECT 1 FROM payouts WHERE advance_id = $1 AND status <> 'cancelled'`, [advanceId])) throw conflict('This advance was already paid');
          // a work expense an older payroll sheet already paid (in full / in part) inside the salary: only what is left
          const due = kind === 'work_expense'
            ? (await itemLeftToPay(q, employeeId, String(adv.period).slice(0, 10), adv.id, Number(adv.amount_egp))).left : Number(adv.amount_egp);
          if (Math.round(due * 100) !== Math.round(amount * 100)) throw invalid(`The amount to pay is ${due}`, { field: 'amount', due });
        }
        if (entitlementId) {
          // paying an approved deal commission: amount and month come from the entitlement, never from the app
          const ce = await one(q, `SELECT * FROM commission_entitlements WHERE id = $1 FOR UPDATE`, [entitlementId]);
          if (!ce || ce.employee_id !== employeeId || ce.status !== 'active') throw invalid('The commission is not approved', { field: 'entitlementId' });
          if (String(ce.period).slice(0, 10) !== period) throw invalid('The commission belongs to another payroll month', { field: 'month' });
          if (await one(q, `SELECT 1 FROM payouts WHERE commission_entitlement_id = $1 AND status <> 'cancelled'`, [entitlementId])) {
            throw conflict('This commission was already paid');
          }
          // the entitlement's amount — less what an older payroll sheet already paid for it inside the salary
          const { left } = await itemLeftToPay(q, employeeId, period, ce.id, Number(ce.amount_egp));
          if (Math.round(left * 100) !== Math.round(amount * 100)) throw invalid(`The commission amount is ${left}`, { field: 'amount', due: left });
        }
      }
      const p = await one(q, `INSERT INTO payouts (employee_id, kind, amount_egp, period, note, advance_id, created_by, commission_entitlement_id)
                              VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`, [employeeId, kind, amount, period, note, advanceId, a.id, entitlementId]);
      await audit(q, a.id, 'payout.create', 'payout', p.id, undefined, { kind, amount, employeeId, period });
      await tellRecipient(q, p, a.fullName);
      return p;
    });
    return ok({ payout: shape(row, a) }, 201);
  });

  // ------------------------------------------------------------------ salaries (one month at a time)
  /**
   * The month's salary of every active employee who has one: what is due in cash — the payroll's net without the
   * commissions and the work expenses (those are paid on their own: صرف العمولة / صرف الطلب) — and what was paid.
   */
  async function salaryRow(q: Q, e: { id: string; full_name: string; code?: string }, period: string, rules: any, t: string, pre?: any, prePays?: any[]) {
    const p: any = pre ?? await computePayroll(q, e.id, period, t, rules);
    if (p?.net == null) return null;
    // the salary part — the one rule shared with the payroll sheet (payroll-calc settlementComponents)
    const due = Number(p.salaryDue);
    const pays = prePays ? { rows: prePays } : await q.query(`SELECT id, amount_egp, status, created_at, received_at, created_by FROM payouts
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
      payments: pays.rows.map((x) => ({ id: x.id, amount: Number(x.amount_egp), status: x.status, createdAt: x.created_at, receivedAt: x.received_at,
        createdBy: x.created_by })) };
  }

  r.get('/payouts/salaries', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'finance.disburse') && !has(a, 'finance.read')) throw forbidden();
    const period = monthParam(req.query.get('month') ?? local(clock()).date.slice(0, 7));
    const rules = await loadRules(db);
    const t = local(clock()).date;
    const emps = await db.query(`SELECT e.id, e.full_name, e.code FROM employees e JOIN employee_salaries s ON s.employee_id = e.id
                                  WHERE e.status = 'active' ORDER BY e.full_name`);
    // every employee's payroll in a fixed number of queries; then a few rows at a time (the connection pool is small)
    const pays = await computePayrollMany(db, emps.rows.map((e) => e.id as string), period, t, rules);
    const salPays = new Map<string, any[]>();
    for (const x of (await db.query(`SELECT employee_id, id, amount_egp, status, created_at, received_at, created_by FROM payouts
                                       WHERE employee_id = ANY($1::uuid[]) AND period = $2 AND kind = 'salary' AND status <> 'cancelled'
                                       ORDER BY created_at`, [emps.rows.map((e) => e.id), period])).rows) {
      const l = salPays.get(x.employee_id) ?? []; l.push(x); salPays.set(x.employee_id, l);
    }
    const out: any[] = new Array(emps.rows.length);
    let next = 0;
    await Promise.all([0, 1, 2].map(async () => {
      while (next < emps.rows.length) {
        const i = next++;
        const e = emps.rows[i];
        const x = await salaryRow(db, e, period, rules, t, pays.get(e.id), salPays.get(e.id) ?? []);
        out[i] = x ? { ...x, canPay: x.remaining > 0.009 && paysSalaries(a) && e.id !== a.id,
          // the payment waiting for the code this person must enter (he paid it)
          verifyPayoutId: x.payments.find((p) => OPEN.includes(p.status) && p.createdBy === a.id)?.id ?? null } : null;
      }
    }));
    const rows: any[] = out.filter(Boolean);
    const sum = (k: 'due' | 'paid' | 'received' | 'awaiting' | 'remaining') =>
      Math.round(rows.reduce((s, x) => s + Math.max(0, x[k]), 0) * 100) / 100;
    // the fixed («راتب ثابت») marketing companies' monthly fee, paid the same way (with the company's code) — once 084 runs
    const companies = await companySalaryRows(db, a, period);
    return ok({ currency: 'EGP', month: period.slice(0, 7), salaries: rows, canPay: paysSalaries(a), companies,
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
      await tellRecipient(q, p, a.fullName);
      return p;
    });
    return ok({ payout: shape(row, a) }, 201);
  });

  /** «تم الاستلام» by the employee is replaced by the code the payer enters (any payment, the ones waiting from before too). */
  r.post('/payouts/:id/receive', async (req) => {
    await authenticate(db, req);
    throw new AppError('conflict', 'تأكيد الاستلام بقى بالكود: افتح التطبيق، هيظهرلك كود من 4 أرقام، قوله للي بيصرفلك', { reason: 'otp_required' });
  });

  /** the recipient's code for one of his payments (a new one each time; the previous one ends) */
  r.post('/payouts/:id/code', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const out = await db.tx(async (q) => {
      const x = await one(q, `SELECT p.*, c.full_name AS payer FROM payouts p JOIN employees c ON c.id = p.created_by WHERE p.id = $1 FOR UPDATE OF p`, [req.params.id]);
      if (!x || x.employee_id !== a.id) throw notFound(); // only the recipient — the payer never sees it
      if (!OPEN.includes(x.status)) throw conflict('الصرف ده اتأكد أو اتلغى');
      const act = otpAction(x.id);
      const recent = await one(q, `SELECT count(*)::int AS n FROM action_otps WHERE employee_id = $1 AND action = $2 AND created_at > now() - interval '15 minutes'`, [a.id, act]);
      if (recent.n >= 5) throw new AppError('rate_limited', 'طلبت أكواد كتير للصرف ده — استنى ربع ساعة', { reason: 'otp_rate_limited' });
      const code = String(randomInt(0, 10_000)).padStart(4, '0');
      await q.query(`UPDATE action_otps SET expires_at = now() WHERE employee_id = $1 AND action = $2 AND used_at IS NULL AND expires_at > now()`, [a.id, act]);
      const o = await one(q, `INSERT INTO action_otps (employee_id, action, code_hash, expires_at) VALUES ($1, $2, $3, now() + make_interval(mins => $4))
                              RETURNING expires_at`, [a.id, act, otpHash(a.id, x.id, code), PAYOUT_OTP_TTL_MIN]);
      await audit(q, a.id, 'payout.code_issued', 'payout', x.id, undefined, { expiresAt: o.expires_at }); // never the code
      return { code, expiresAt: o.expires_at, amount: Number(x.amount_egp), kind: x.kind, kindAr: PAYOUT_AR[x.kind] ?? x.kind, payerName: x.payer,
        period: String(x.period).slice(0, 7) };
    });
    return ok(out);
  });

  /** the payer enters the code the recipient told him: only then the payment counts as received (and leaves the cashbox) */
  r.post('/payouts/:id/verify', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const code = obj(req.body).code;
    const bad = (reason = 'otp_invalid') => new AppError('validation_failed',
      reason === 'otp_locked' ? 'اتكتب كود غلط كتير — استنى ساعة أو اطلب من الموظف كود جديد بعدها' : 'الكود غلط أو خلص وقته — اطلب من الموظف الكود اللي ظاهر عنده دلوقتي',
      { reason, field: 'code' });
    if (typeof code !== 'string' || !/^\d{4}$/.test(code)) throw bad();
    const now = clock();
    const res = await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM payouts WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x || x.created_by !== a.id) throw notFound(); // the payer of this very payment
      if (!has(a, x.kind === 'fund' ? 'finance.fund' : 'finance.disburse')) throw forbidden();
      if (!OPEN.includes(x.status)) throw new AppError('conflict', 'الصرف ده اتأكد أو اتلغى', { reason: 'not_open' });
      const act = otpAction(x.id);
      const tries = await one(q, `SELECT COALESCE(sum(attempts), 0)::int AS n FROM action_otps WHERE employee_id = $1 AND action = $2 AND created_at > now() - interval '1 hour'`,
        [x.employee_id, act]);
      if (tries.n >= 15) return { fail: 'otp_locked' as const };
      const o = await one(q, `SELECT * FROM action_otps WHERE employee_id = $1 AND action = $2 AND used_at IS NULL AND expires_at > now()
                               ORDER BY created_at DESC LIMIT 1 FOR UPDATE`, [x.employee_id, act]);
      if (!o || o.attempts >= 5) return { fail: 'otp_invalid' as const };
      if (o.code_hash !== otpHash(x.employee_id, x.id, code)) return { fail: 'otp_invalid' as const, wrong: o.id as string };
      await q.query(`UPDATE action_otps SET used_at = now() WHERE id = $1`, [o.id]);
      const y = await one(q, `UPDATE payouts SET status = 'received', received_at = $2 WHERE id = $1 RETURNING *`, [x.id, now]);
      await audit(q, a.id, 'payout.verified', 'payout', x.id, { status: x.status }, { status: 'received', by: 'otp', recipient: x.employee_id });
      await notify(q, { to: x.employee_id, type: 'payout_received', title: `اتأكد استلامك ${PAYOUT_AR[x.kind] ?? ''} (${Math.round(Number(x.amount_egp) * 100) / 100} جنيه)`,
        body: `بالكود اللي اديته لـ ${a.fullName}`, entity: 'payout', entityId: x.id, dedupeKey: `payout:${x.id}:received` });
      return { payout: y };
    });
    if ('fail' in res) {
      // a wrong try is counted on its own (outside the refused step, so it is never rolled back)
      if (res.wrong) {
        await db.query(`UPDATE action_otps SET attempts = attempts + 1 WHERE id = $1`, [res.wrong]);
        await audit(db, a.id, 'payout.code_wrong', 'payout', req.params.id);
      }
      throw bad(res.fail);
    }
    return ok({ payout: shape(res.payout, a) });
  });

  r.post('/payouts/:id/cancel', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM payouts WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x || x.created_by !== a.id) throw notFound();
      // only while he still may pay (a revoked cashier can no longer move money back)
      if (!has(a, 'finance.disburse') && !has(a, 'finance.fund')) throw forbidden();
      // a disputed payment may be cancelled by whoever paid it (the money is back in the HR cashbox)
      if (x.status !== 'pending' && x.status !== 'disputed') throw conflict('Only a payout that was not received yet can be cancelled');
      await q.query(`UPDATE payouts SET status = 'cancelled', cancelled_at = now() WHERE id = $1`, [x.id]);
      await q.query(`UPDATE action_otps SET expires_at = now() WHERE employee_id = $1 AND action = $2 AND used_at IS NULL AND expires_at > now()`,
        [x.employee_id, otpAction(x.id)]);
      await audit(q, a.id, 'payout.cancel', 'payout', x.id);
    });
    return ok({ ok: true });
  });
};
