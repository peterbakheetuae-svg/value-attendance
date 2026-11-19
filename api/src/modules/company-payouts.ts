import { createHash, randomInt } from 'node:crypto';
import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { isUuid, monthParam, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, type Actor } from '../auth/context.ts';
import { authenticatePartner } from '../auth/partner.ts';
import { local } from '../lib/time.ts';
import { canOffice, hrDesk } from './cash.ts';
import { PAYOUT_OTP_TTL_MIN } from './payouts.ts';

/**
 * The marketing companies' money with the same disbursement code as the employees' (db/proposed/084).
 *
 * A payment to a company is an expense of a cashbox, as today; it now waits for the company's 4-digit code
 * («awaiting_otp» — not in cash_ledger, so not out of the cashbox): the company's app asks for the code (only the company
 * can — POST /partner/payments/:id/code) and shows it; the company tells it to whoever paid, who enters it
 * (POST /cash/expenses/:id/verify). A fixed («راتب ثابت») company is paid its monthly fee from the salaries page; a
 * commission company what it earned on contracted units, from the commissions page, on its payment day.
 * Until 084 runs, nothing changes (the company endpoints answer 409 «module_not_installed»).
 */
const r2 = (x: number) => Math.round(x * 100) / 100;
const N = (v: unknown) => Number(v ?? 0);
const act = (id: string) => `expense:${id}`;
const hashOf = (company: string, id: string, code: string) => createHash('sha256').update(`company:${company}:${act(id)}:${code}`).digest('hex');

let installedOk = false;
export async function companyOtpInstalled(q: Q) {
  if (installedOk) return true;
  const r = await one(q, `SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'marketing_companies' AND column_name = 'payment_day'`);
  return (installedOk = !!r);
}
/** for the throwaway test databases (one per test file) */
export function forgetCompanyOtp() { installedOk = false; }

/** a company can be paid through the code only when it signs in to the app (it must see the code) */
export async function companyForPayment(q: Q, id: string) {
  const c = await one(q, `SELECT * FROM marketing_companies WHERE id = $1 FOR UPDATE`, [id]);
  if (!c) throw invalid('اختار شركة التسويق', { field: 'marketingCompanyId' });
  if (!c.password_hash || c.login_active === false) {
    throw new AppError('unprocessable', 'شركة التسويق دي ملهاش دخول على التطبيق — فعّل حسابها الأول عشان يوصلها كود الصرف', { reason: 'company_no_app' });
  }
  return c;
}

/** the company is told a payment waits for its code — the code itself is never in a notification */
export async function tellCompany(q: Q, x: { id: string; marketing_company_id: string; amount_egp: unknown }, payerName: string, what: string) {
  await q.query(`INSERT INTO partner_notifications (company_id, key, type, title, body, entity, entity_id, created_at)
                 VALUES ($1, $2, 'payment_otp', $3, $4, 'cash_expense', $5, now()) ON CONFLICT (company_id, key) DO NOTHING`,
    [x.marketing_company_id, `payment:${x.id}`, `${what}: ${r2(N(x.amount_egp))} جنيه — مستني تأكيدك`,
      `افتح التطبيق: هيظهرلك كود من 4 أرقام، قوله لـ ${payerName} وهو يكتبه`, x.id]);
}

/** a fixed company's fee for a month: due, paid (posted), waiting for the code, left */
async function feeOf(q: Q, c: any, period: string) {
  const s = await one(q, `SELECT COALESCE(sum(amount_egp) FILTER (WHERE status = 'posted'), 0) AS paid,
                                 COALESCE(sum(amount_egp) FILTER (WHERE status IN ('awaiting_otp','pending_approval')), 0) AS waiting
                            FROM cash_expenses WHERE marketing_company_id = $1 AND mk_period = $2`, [c.id, period]);
  const due = r2(N(c.monthly_fee));
  return { due, paid: r2(N(s.paid)), waiting: r2(N(s.waiting)), left: r2(due - N(s.paid) - N(s.waiting)) };
}

/** a commission company: earned on its contracted units − paid − waiting */
async function commissionOf(q: Q, c: any) {
  const s = await one(q, `SELECT
      COALESCE((SELECT sum(u.unit_price * u.mk_pct / 100) FROM ex_units u WHERE u.mk_company_id = $1 AND u.status = 'contracted'), 0) AS earned,
      COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE marketing_company_id = $1 AND status = 'posted'), 0) AS paid,
      COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE marketing_company_id = $1 AND status IN ('awaiting_otp','pending_approval')), 0) AS waiting`, [c.id]);
  return { earned: r2(N(s.earned)), paid: r2(N(s.paid)), waiting: r2(N(s.waiting)), left: r2(N(s.earned) - N(s.paid) - N(s.waiting)) };
}

/** the next payment day of a commission company from a day (YYYY-MM-DD): this month's if not passed, else next month's */
export function nextPaymentDate(today: string, day: number | null): string | null {
  if (!day) return null;
  const [y, m, d] = today.split('-').map(Number);
  const pad = (n: number) => String(n).padStart(2, '0');
  if (d <= day) return `${y}-${pad(m)}-${pad(day)}`;
  const ny = m === 12 ? y + 1 : y, nm = m === 12 ? 1 : m + 1;
  return `${ny}-${pad(nm)}-${pad(day)}`;
}

const canBox = (a: Actor, box: string) => (box === 'office' ? canOffice(a) : hrDesk(a));
const OPEN = ['awaiting_otp'];

/** the companies' rows of the salaries page (fixed fee) and the commissions page (commission), for this person */
export async function companySalaryRows(q: Q, a: Actor, period: string) {
  // only for whoever works a cashbox (the companies' money is not an employee's business)
  if (!(canOffice(a) || hrDesk(a)) || !(await companyOtpInstalled(q))) return null;
  const cs = await q.query(`SELECT * FROM marketing_companies WHERE kind = 'fixed' AND status = 'active' ORDER BY name`);
  const out = [];
  for (const c of cs.rows) {
    const f = await feeOf(q, c, period);
    const w = await one(q, `SELECT id FROM cash_expenses WHERE marketing_company_id = $1 AND mk_period = $2 AND status = 'awaiting_otp' AND recorded_by = $3
                             ORDER BY created_at DESC LIMIT 1`, [c.id, period, a.id]);
    out.push({ companyId: c.id, name: c.name, kind: 'fixed', month: period.slice(0, 7), ...f, hasApp: !!c.password_hash && c.login_active !== false,
      status: f.left > 0.009 ? (f.paid + f.waiting > 0 ? 'partly_paid' : 'unpaid') : f.waiting > 0 ? 'awaiting_receipt' : f.paid > 0 ? 'received' : 'nothing_due',
      canPay: f.left > 0.009 && (canOffice(a) || hrDesk(a)), verifyExpenseId: w?.id ?? null });
  }
  return out;
}
export async function companyCommissionRows(q: Q, a: Actor, today: string) {
  if (!(canOffice(a) || hrDesk(a)) || !(await companyOtpInstalled(q))) return null;
  const cs = await q.query(`SELECT * FROM marketing_companies WHERE kind = 'commission' AND status = 'active' ORDER BY name`);
  const out = [];
  for (const c of cs.rows) {
    const f = await commissionOf(q, c);
    const next = nextPaymentDate(today, c.payment_day == null ? null : Number(c.payment_day));
    const w = await one(q, `SELECT id FROM cash_expenses WHERE marketing_company_id = $1 AND status = 'awaiting_otp' AND recorded_by = $2
                             ORDER BY created_at DESC LIMIT 1`, [c.id, a.id]);
    if (f.left <= 0.009 && f.waiting <= 0.009 && !w) continue;
    // payable on its payment day (no day set = any time)
    const payableNow = !c.payment_day || Number(today.slice(8, 10)) >= Number(c.payment_day);
    out.push({ companyId: c.id, name: c.name, kind: 'commission', ...f, paymentDay: c.payment_day ?? null, nextPaymentDate: next, payableNow,
      hasApp: !!c.password_hash && c.login_active !== false,
      canPay: f.left > 0.009 && payableNow && (canOffice(a) || hrDesk(a)), verifyExpenseId: w?.id ?? null });
  }
  return out;
}

export const companyPayoutsModule: Module = (r, { db, clock }) => {
  const need = async (q: Q) => {
    if (!(await companyOtpInstalled(q))) throw new AppError('conflict', 'صرف شركات التسويق بالكود محتاج تشغيل migration 084 بعد موافقة المالك', { reason: 'module_not_installed' });
  };

  /** صرف لشركة تسويق: its monthly fee (fixed) or what it earned (commission) — waits for the company's code */
  r.post('/marketing-companies/:id/pay', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const box = oneOf(b, 'cashbox', ['office', 'hr'] as const, true) ?? (canOffice(a) ? 'office' : 'hr');
    if (!canBox(a, box)) throw forbidden('محتاج صلاحية الصرف من الخزنة دي');
    const method = oneOf(b, 'paymentMethod', ['cash', 'bank'] as const, true) ?? 'cash';
    const note = (str(b, 'note', { optional: true, max: 500 }) ?? '').trim();
    const out = await db.tx(async (q) => {
      await need(q);
      const c = await companyForPayment(q, req.params.id);
      if (c.status !== 'active') throw conflict('الشركة دي مش نشطة');
      let amount: number, period: string | null = null, what: string;
      if (c.kind === 'fixed') {
        period = monthParam(typeof b.month === 'string' && b.month ? b.month : local(clock()).date.slice(0, 7));
        const f = await feeOf(q, c, period);
        if (f.left <= 0.009) throw new AppError('conflict', 'راتب الشهر ده اتصرف (أو مستني الكود)', { reason: 'already_paid' });
        amount = num(b, 'amount', { optional: true, min: 0.01, max: 100_000_000 }) ?? f.left;
        if (amount > f.left + 0.001) throw new AppError('unprocessable', `الباقي من راتب الشهر ${f.left} جنيه بس`, { reason: 'over_pay', remaining: f.left });
        what = `راتب ${period.slice(0, 7)}`;
      } else {
        const f = await commissionOf(q, c);
        if (f.left <= 0.009) throw new AppError('conflict', 'مفيش عمولة مستحقة للشركة دي دلوقتي', { reason: 'already_paid' });
        const today = local(clock()).date;
        if (c.payment_day && Number(today.slice(8, 10)) < Number(c.payment_day)) {
          throw new AppError('unprocessable', `ميعاد صرف عمولة الشركة يوم ${c.payment_day} من الشهر`, { reason: 'not_payment_day', nextPaymentDate: nextPaymentDate(today, Number(c.payment_day)) });
        }
        amount = num(b, 'amount', { optional: true, min: 0.01, max: 100_000_000 }) ?? f.left;
        if (amount > f.left + 0.001) throw new AppError('unprocessable', `المستحق ${f.left} جنيه بس`, { reason: 'over_pay', remaining: f.left });
        what = 'عمولة';
      }
      amount = r2(amount);
      const s = await one(q, `SELECT expense_approval_threshold FROM company_settings LIMIT 1`);
      const needsApproval = box === 'hr' && !canOffice(a) && amount > Number(s?.expense_approval_threshold ?? 1000);
      const x = await one(q, `
        INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, notes, occurred_at, recorded_by, status, payment_method, marketing_company_id, mk_period)
        VALUES ($1,$2,'شركة تسويق',$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING id, ref_no, marketing_company_id, amount_egp`,
        [box, amount, `${what} — ${c.name}`, c.name, note, clock(), a.id, needsApproval ? 'pending_approval' : 'awaiting_otp', method, c.id, period]);
      await audit(q, a.id, 'cash.company_payment', 'cash_expense', x.id, undefined,
        { company: c.id, kind: c.kind, amount, period, cashbox: box, status: needsApproval ? 'pending_approval' : 'awaiting_otp' });
      if (!needsApproval) await tellCompany(q, x, a.fullName, what);
      return { id: x.id, refNo: Number(x.ref_no), amount, status: needsApproval ? 'pending_approval' : 'awaiting_otp' };
    });
    return ok({ payment: out }, 201);
  });

  /** the company's own payments waiting for its code */
  r.get('/partner/payments', async (req) => {
    const p = await authenticatePartner(db, req);
    if (!(await companyOtpInstalled(db))) return ok({ payments: [] });
    const rows = await db.query(`SELECT x.id, x.ref_no, x.amount_egp, x.reason, x.mk_period, x.created_at, e.full_name AS payer
                                   FROM cash_expenses x JOIN employees e ON e.id = x.recorded_by
                                  WHERE x.marketing_company_id = $1 AND x.status = 'awaiting_otp' ORDER BY x.created_at`, [p.companyId]);
    return ok({ payments: rows.rows.map((x) => ({ id: x.id, refNo: Number(x.ref_no), amount: N(x.amount_egp), what: x.reason, payerName: x.payer,
      month: x.mk_period ? String(x.mk_period instanceof Date ? x.mk_period.toISOString() : x.mk_period).slice(0, 7) : null, createdAt: x.created_at })) });
  });

  /** the company's code for one of its payments (a new one each time; the previous one ends) — only the company gets it */
  r.post('/partner/payments/:id/code', async (req) => {
    const p = await authenticatePartner(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const out = await db.tx(async (q) => {
      await need(q);
      const x = await one(q, `SELECT x.*, e.full_name AS payer FROM cash_expenses x JOIN employees e ON e.id = x.recorded_by WHERE x.id = $1 FOR UPDATE OF x`, [req.params.id]);
      if (!x || x.marketing_company_id !== p.companyId) throw notFound();
      if (!OPEN.includes(x.status)) throw conflict('الصرف ده اتأكد أو اتلغى');
      const recent = await one(q, `SELECT count(*)::int AS n FROM action_otps WHERE company_id = $1 AND action = $2 AND created_at > now() - interval '15 minutes'`,
        [p.companyId, act(x.id)]);
      if (recent.n >= 5) throw new AppError('rate_limited', 'طلبت أكواد كتير للصرف ده — استنى ربع ساعة', { reason: 'otp_rate_limited' });
      const code = String(randomInt(0, 10_000)).padStart(4, '0');
      await q.query(`UPDATE action_otps SET expires_at = now() WHERE company_id = $1 AND action = $2 AND used_at IS NULL AND expires_at > now()`, [p.companyId, act(x.id)]);
      const o = await one(q, `INSERT INTO action_otps (company_id, action, code_hash, expires_at) VALUES ($1, $2, $3, now() + make_interval(mins => $4)) RETURNING expires_at`,
        [p.companyId, act(x.id), hashOf(p.companyId, x.id, code), PAYOUT_OTP_TTL_MIN]);
      await audit(q, null, 'cash.company_payment.code_issued', 'cash_expense', x.id, undefined, { company: p.companyId, expiresAt: o.expires_at });
      return { code, expiresAt: o.expires_at, amount: N(x.amount_egp), what: x.reason, payerName: x.payer };
    });
    return ok(out);
  });

  /** whoever paid enters the company's code: only then the payment is posted (and leaves the cashbox) */
  r.post('/cash/expenses/:id/verify', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const code = obj(req.body).code;
    const bad = (reason = 'otp_invalid') => new AppError('validation_failed',
      reason === 'otp_locked' ? 'اتكتب كود غلط كتير — استنى ساعة' : 'الكود غلط أو خلص وقته — اطلب من الشركة الكود اللي ظاهر عندها دلوقتي', { reason, field: 'code' });
    if (typeof code !== 'string' || !/^\d{4}$/.test(code)) throw bad();
    const res = await db.tx(async (q) => {
      await need(q);
      const x = await one(q, `SELECT * FROM cash_expenses WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x || x.recorded_by !== a.id || !x.marketing_company_id) throw notFound();
      if (!canBox(a, x.cashbox)) throw forbidden();
      if (!OPEN.includes(x.status)) throw new AppError('conflict', 'الصرف ده اتأكد أو اتلغى', { reason: 'not_open' });
      const tries = await one(q, `SELECT COALESCE(sum(attempts), 0)::int AS n FROM action_otps WHERE company_id = $1 AND action = $2 AND created_at > now() - interval '1 hour'`,
        [x.marketing_company_id, act(x.id)]);
      if (tries.n >= 15) return { fail: 'otp_locked' as const };
      const o = await one(q, `SELECT * FROM action_otps WHERE company_id = $1 AND action = $2 AND used_at IS NULL AND expires_at > now()
                               ORDER BY created_at DESC LIMIT 1 FOR UPDATE`, [x.marketing_company_id, act(x.id)]);
      if (!o || o.attempts >= 5) return { fail: 'otp_invalid' as const };
      if (o.code_hash !== hashOf(x.marketing_company_id, x.id, code)) return { fail: 'otp_invalid' as const, wrong: o.id as string };
      await q.query(`UPDATE action_otps SET used_at = now() WHERE id = $1`, [o.id]);
      // posted now: the cashbox pays it today (cash_ledger dates an expense by approved_at)
      await q.query(`UPDATE cash_expenses SET status = 'posted', approved_by = COALESCE(approved_by, $2), approved_at = $3 WHERE id = $1`, [x.id, a.id, clock()]);
      await audit(q, a.id, 'cash.company_payment.verified', 'cash_expense', x.id, { status: x.status }, { status: 'posted', by: 'otp', company: x.marketing_company_id });
      await q.query(`INSERT INTO partner_notifications (company_id, key, type, title, body, entity, entity_id, created_at)
                     VALUES ($1, $2, 'payment_received', $3, '', 'cash_expense', $4, now()) ON CONFLICT (company_id, key) DO NOTHING`,
        [x.marketing_company_id, `payment:${x.id}:received`, `اتأكد استلامكم ${r2(N(x.amount_egp))} جنيه`, x.id]);
      return { ok: true as const };
    });
    if ('fail' in res) {
      if (res.wrong) {
        await db.query(`UPDATE action_otps SET attempts = attempts + 1 WHERE id = $1`, [res.wrong]);
        await audit(db, a.id, 'cash.company_payment.code_wrong', 'cash_expense', req.params.id);
      }
      throw bad(res.fail);
    }
    return ok({ ok: true, status: 'posted' });
  });

  /** the payer takes back a company payment still waiting for its code (nothing left the cashbox) */
  r.post('/cash/expenses/:id/cancel-payment', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const reason = str(obj(req.body), 'reason', { min: 3, max: 500 })!.trim();
    await db.tx(async (q) => {
      await need(q);
      const x = await one(q, `SELECT * FROM cash_expenses WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x || x.recorded_by !== a.id || !x.marketing_company_id) throw notFound();
      if (!OPEN.includes(x.status)) throw conflict('الصرف ده مش مستني الكود');
      await q.query(`UPDATE cash_expenses SET status = 'rejected', reject_reason = $2 WHERE id = $1`, [x.id, reason]);
      await q.query(`UPDATE action_otps SET expires_at = now() WHERE company_id = $1 AND action = $2 AND used_at IS NULL AND expires_at > now()`,
        [x.marketing_company_id, act(x.id)]);
      await audit(q, a.id, 'cash.company_payment.cancel', 'cash_expense', x.id, { status: x.status }, { status: 'rejected', reason });
    });
    return ok({ ok: true });
  });

  /** a commission company's payment day (the managers of the companies) */
  r.patch('/marketing-companies/:id/payment-day', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const day = b.paymentDay === null ? null : num(b, 'paymentDay', { min: 1, max: 28, int: true })!;
    await db.tx(async (q) => {
      await need(q);
      const c = await one(q, `SELECT id, payment_day FROM marketing_companies WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!c) throw notFound();
      await q.query(`UPDATE marketing_companies SET payment_day = $2 WHERE id = $1`, [c.id, day]);
      await audit(q, a.id, 'marketing_company.payment_day', 'marketing_company', c.id, { paymentDay: c.payment_day }, { paymentDay: day });
    });
    return ok({ paymentDay: day });
  });
};
