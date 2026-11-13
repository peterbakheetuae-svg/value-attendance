import { ok, type Module } from '../ctx.ts';
import { one } from '../db.ts';
import { forbidden, notFound } from '../http/errors.ts';
import { local } from '../lib/time.ts';
import { isUuid, monthParam } from '../http/validate.ts';
import { authenticate, has } from '../auth/context.ts';
import { cashSummary, canHrView, canOffice } from './cash.ts';
import { computePayroll, loadRules } from './payroll-calc.ts';

/**
 * Financial system, phase 5 — dashboards, the employee account report, and monthly employee indicators.
 * Each figure is returned only to the people allowed to see it (office figures never reach HR).
 * Indicators inform the manager; they never trigger a deduction or a disciplinary step by themselves.
 */

const r2 = (n: number) => Math.round(n * 100) / 100;
const n = (v: unknown) => Number(v ?? 0);
/** a date / timestamp as YYYY-MM-DD (pg gives dates as text, timestamps as Date) */
const ds = (v: unknown) => (v instanceof Date ? v.toISOString() : String(v ?? '')).slice(0, 10);

function prevMonth(period: string) {
  const [y, m] = period.split('-').map(Number);
  const d = new Date(Date.UTC(y, m - 2, 1));
  return d.toISOString().slice(0, 10);
}

/** the clients' money (حجز / مقدم / قسط / تسوية / تحصيل آخر) — not a ضخ, not a developer's commission */
const CLIENT_KINDS = ['reservation', 'down_payment', 'installment', 'settlement', 'other'];

/** every installment still owed: the old sales (unit_sales) + the projects' contracted units (ex_installments) */
const INSTALLMENT_LINES = `
  SELECT i.seq, i.due_date, i.amount_egp, s.buyer_name, s.buyer_phone, s.unit_no, p.name AS project,
         COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.installment_id = i.id AND r.status = 'posted'), 0) AS paid
    FROM sale_installments i JOIN unit_sales s ON s.id = i.sale_id JOIN commission_projects p ON p.id = s.project_id WHERE s.status = 'active'
  UNION ALL
  SELECT i.seq, i.due_date, i.amount_egp, u.client_name, u.client_phone, u.unit_no, p.name,
         COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0)
    FROM ex_installments i JOIN ex_units u ON u.id = i.unit_id JOIN commission_projects p ON p.id = u.project_id WHERE u.status = 'contracted'`;

/** what is still to come on each sold unit: the old sales' open installments + a contracted unit's price − what it paid */
const UNITS_LEFT = `
  SELECT s.buyer_name, s.buyer_phone, s.unit_no, p.name AS project,
         sum(GREATEST(i.amount_egp - COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.installment_id = i.id AND r.status = 'posted'), 0), 0)) AS left_amount
    FROM sale_installments i JOIN unit_sales s ON s.id = i.sale_id JOIN commission_projects p ON p.id = s.project_id WHERE s.status = 'active'
   GROUP BY s.id, s.buyer_name, s.buyer_phone, s.unit_no, p.name
  UNION ALL
  SELECT u.client_name, u.client_phone, u.unit_no, p.name,
         GREATEST(u.unit_price - COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted'
                                            AND r.kind IN ('reservation','down_payment','installment')), 0), 0)
    FROM ex_units u JOIN commission_projects p ON p.id = u.project_id WHERE u.status = 'contracted'`;

const IN_MONTH = (col: string, p = '$1') =>
  `${col} >= (${p}::date AT TIME ZONE 'Africa/Cairo') AND ${col} < ((${p}::date + interval '1 month') AT TIME ZONE 'Africa/Cairo')`;

export const financeDashboardModule: Module = (r, { db, clock }) => {
  const today = () => local(clock()).date;

  /** Every active employee with a salary: what the month's payroll says he is due, and what was paid of it. */
  async function salaries(period: string) {
    const rules = await loadRules(db);
    const emps = await db.query(`SELECT e.id, e.full_name FROM employees e JOIN employee_salaries s ON s.employee_id = e.id
                                  WHERE e.status = 'active' ORDER BY e.full_name`);
    const rows = [];
    for (const e of emps.rows) {
      const p: any = await computePayroll(db, e.id, period, today(), rules);
      if (p?.net == null) continue;
      rows.push({ id: e.id, name: e.full_name, net: r2(n(p.net)), paid: r2(n(p.salaryPaid)), remaining: r2(n(p.net) - n(p.salaryPaid)) });
    }
    return rows;
  }

  r.get('/finance/dashboard', async (req) => {
    const a = await authenticate(db, req);
    const hr = canHrView(a), office = canOffice(a);
    if (!hr && !office) throw forbidden();
    const period = monthParam(req.query.get('month') ?? today().slice(0, 7));
    const t = today();
    const cash = await cashSummary(db, a);
    const m = await one(db, `SELECT
        COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE status = 'posted' AND cashbox = ANY($2::text[]) AND kind = ANY($3::text[])
                   AND occurred_at >= ($1::date AT TIME ZONE 'Africa/Cairo') AND occurred_at < (($1::date + interval '1 month') AT TIME ZONE 'Africa/Cairo')), 0) AS collections,
        COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE status = 'posted' AND cashbox = ANY($2::text[]) AND kind IN ('reservation','down_payment')
                   AND occurred_at >= ($1::date AT TIME ZONE 'Africa/Cairo') AND occurred_at < (($1::date + interval '1 month') AT TIME ZONE 'Africa/Cairo')), 0) AS down_payments,
        COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE status = 'posted' AND cashbox = ANY($2::text[]) AND kind = 'installment'
                   AND occurred_at >= ($1::date AT TIME ZONE 'Africa/Cairo') AND occurred_at < (($1::date + interval '1 month') AT TIME ZONE 'Africa/Cairo')), 0) AS installments,
        COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE status = 'posted' AND cashbox = 'hr' AND ex_kind IS NULL AND sale_id IS NULL
                   AND ${IN_MONTH('COALESCE(approved_at, occurred_at)')}), 0) AS hr_expenses,
        COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE status = 'posted' AND cashbox = 'office' AND ex_kind IS NULL AND sale_id IS NULL AND owner_draw_id IS NULL
                   AND ${IN_MONTH('COALESCE(approved_at, occurred_at)')}), 0) AS office_expenses,
        COALESCE((SELECT sum(amount_egp) FROM payouts WHERE kind = 'salary' AND status = 'received' AND period = $1), 0) AS salaries_paid,
        COALESCE((SELECT sum(amount_egp) FROM commission_entitlements WHERE status = 'active' AND period = $1), 0) AS commissions,
        COALESCE((SELECT sum(ce.amount_egp) FROM commission_entitlements ce WHERE ce.status = 'active'
                   AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.commission_entitlement_id = ce.id AND p.status <> 'cancelled')), 0) AS commissions_unpaid,
        (SELECT count(*) FROM payroll_batches WHERE status IN ('draft','returned','pending_approval')) AS batches_open,
        (SELECT count(*) FROM cash_transfers WHERE status IN ('requested','approved','executed')) AS transfers_open`,
      [period, office ? ['hr', 'office'] : ['hr'], CLIENT_KINDS]);
    // outstanding advances: what is still to come off salaries from this month on
    const adv = await one(db, `SELECT COALESCE(sum(GREATEST(ar.amount_egp - COALESCE(d.done, 0), 0)), 0) AS outstanding
        FROM advance_requests ar
        LEFT JOIN LATERAL (SELECT sum(x.amount_egp) AS done FROM advance_deductions x
                            WHERE x.advance_id = ar.id AND x.status = 'active' AND x.period < $1) d ON true
       WHERE ar.kind = 'advance' AND ar.status = 'confirmed'
         AND (EXISTS (SELECT 1 FROM advance_deductions y WHERE y.advance_id = ar.id AND y.status = 'active') OR ar.period >= $1)`, [period]);
    const inst = await one(db, `
      WITH lines AS (${INSTALLMENT_LINES})
      SELECT COALESCE(sum(amount_egp - paid) FILTER (WHERE due_date < $1 AND paid < amount_egp), 0) AS overdue,
             count(*) FILTER (WHERE due_date < $1 AND paid < amount_egp) AS overdue_n,
             COALESCE(sum(amount_egp - paid) FILTER (WHERE due_date >= $1 AND due_date <= ($1::date + 7) AND paid < amount_egp), 0) AS week,
             count(*) FILTER (WHERE due_date >= $1 AND due_date <= ($1::date + 7) AND paid < amount_egp) AS week_n
        FROM lines`, [t]);
    const left = await one(db, `SELECT COALESCE(sum(left_amount), 0) AS s FROM (${UNITS_LEFT}) x`, []);
    const sal = await salaries(period);
    const out: Record<string, unknown> = {
      currency: 'EGP', month: period.slice(0, 7), cash,
      hr: {
        salariesDue: r2(sal.reduce((x, y) => x + y.net, 0)), salariesPaid: r2(n(m.salaries_paid)),
        salariesRemaining: r2(sal.reduce((x, y) => x + Math.max(y.remaining, 0), 0)),
        collections: r2(n(m.collections)), expenses: r2(n(m.hr_expenses)),
        requiredFromOffice: (cash as any).hr ? r2(n((cash as any).hr.deficit)) : 0,
        payrollBatchesOpen: Number(m.batches_open), outstandingAdvances: r2(n(adv.outstanding)),
        commissionsAwaitingPayment: r2(n(m.commissions_unpaid)),
        installmentsDueThisWeek: { amount: r2(n(inst.week)), count: Number(inst.week_n) },
        overdueInstallments: { amount: r2(n(inst.overdue)), count: Number(inst.overdue_n) },
      },
    };
    if (office) {
      out.management = {
        transfersOpen: Number(m.transfers_open), hrExpenses: r2(n(m.hr_expenses)), officeExpenses: r2(n(m.office_expenses)),
        salariesPaid: r2(n(m.salaries_paid)), outstandingAdvances: r2(n(adv.outstanding)), commissions: r2(n(m.commissions)),
        downPayments: r2(n(m.down_payments)), installmentsCollected: r2(n(m.installments)),
        overdueInstallments: r2(n(inst.overdue)), unitsRemaining: r2(n(left.s)),
      };
    }
    return ok(out);
  });

  /**
   * What is behind one box of the cashbox page (tap a box → its list). Same visibility as the dashboard:
   * office lists only for المدير / المالك.
   */
  r.get('/finance/dashboard/details', async (req) => {
    const a = await authenticate(db, req);
    const hr = canHrView(a), office = canOffice(a);
    if (!hr && !office) throw forbidden();
    const period = monthParam(req.query.get('month') ?? today().slice(0, 7));
    const key = req.query.get('key') ?? '';
    const boxes = office ? ['hr', 'office'] : ['hr'];
    type Row = { title: string; sub: string; amount: number; tag?: string };
    let title = ''; let rows: Row[] = [];
    const q = async (sql: string, vals: unknown[]) => (await db.query(sql, vals)).rows;
    const officeOnly = ['office_expenses', 'transfers_open', 'units_remaining'];
    if (officeOnly.includes(key) && !office) throw forbidden();
    switch (key) {
      case 'collections': case 'down_payments': case 'installments_collected': {
        title = key === 'collections' ? 'تحصيلات الشهر' : key === 'down_payments' ? 'الحجز والمقدمات' : 'الأقساط المحصّلة';
        const kinds = key === 'collections' ? CLIENT_KINDS : key === 'down_payments' ? ['reservation', 'down_payment'] : ['installment'];
        rows = (await q(`SELECT ref_no, payer_name, purpose, amount_egp, cashbox, occurred_at FROM cash_receipts
                          WHERE status = 'posted' AND cashbox = ANY($2::text[]) AND ${IN_MONTH('occurred_at')}
                            AND ($3::text[] IS NULL OR kind = ANY($3::text[])) ORDER BY occurred_at DESC`, [period, boxes, kinds]))
          .map((x) => ({ title: x.payer_name, sub: `#${x.ref_no} — ${x.purpose} — ${ds(x.occurred_at).slice(0, 10)}`,
            amount: n(x.amount_egp), tag: x.cashbox === 'hr' ? 'خزنة المحاسب' : 'خزنة المكتب' }));
        break;
      }
      case 'hr_expenses': case 'office_expenses': {
        title = key === 'hr_expenses' ? 'مصروفات خزنة المحاسب' : 'مصروفات المكتب';
        rows = (await q(`SELECT ref_no, category, reason, beneficiary, amount_egp, occurred_at FROM cash_expenses
                          WHERE status = 'posted' AND cashbox = $2 AND ex_kind IS NULL AND sale_id IS NULL AND owner_draw_id IS NULL
                            AND ${IN_MONTH('COALESCE(approved_at, occurred_at)')} ORDER BY occurred_at DESC`,
          [period, key === 'hr_expenses' ? 'hr' : 'office']))
          .map((x) => ({ title: `${x.category} — ${x.beneficiary}`, sub: `#${x.ref_no} — ${x.reason}`, amount: n(x.amount_egp) }));
        break;
      }
      case 'salaries': {
        title = 'مرتبات الشهر';
        rows = (await salaries(period)).map((x) => ({ title: x.name, sub: `الصافي ${x.net} — اتصرف ${x.paid}`, amount: x.remaining,
          tag: x.remaining <= 0 ? 'اتصرف' : x.paid > 0 ? 'جزء' : 'مستحق' }));
        break;
      }
      case 'salaries_paid': {
        title = 'مرتبات اتصرفت';
        rows = (await q(`SELECT e.full_name, p.amount_egp, p.status, p.created_at FROM payouts p JOIN employees e ON e.id = p.employee_id
                          WHERE p.kind = 'salary' AND p.status = 'received' AND p.period = $1 ORDER BY p.created_at DESC`, [period]))
          .map((x) => ({ title: x.full_name, sub: ds(x.created_at).slice(0, 10), amount: n(x.amount_egp),
            tag: x.status === 'received' ? 'استلم' : x.status === 'disputed' ? 'بلاغ مشكلة' : 'مستني تأكيد' }));
        break;
      }
      case 'advances': {
        title = 'سلف لسه هتتخصم';
        rows = (await q(`SELECT e.full_name, ar.period, GREATEST(ar.amount_egp - COALESCE(d.done, 0), 0) AS left_amount, ar.amount_egp
            FROM advance_requests ar JOIN employees e ON e.id = ar.employee_id
            LEFT JOIN LATERAL (SELECT sum(x.amount_egp) AS done FROM advance_deductions x
                                WHERE x.advance_id = ar.id AND x.status = 'active' AND x.period < $1) d ON true
           WHERE ar.kind = 'advance' AND ar.status = 'confirmed'
             AND (EXISTS (SELECT 1 FROM advance_deductions y WHERE y.advance_id = ar.id AND y.status = 'active') OR ar.period >= $1)
           ORDER BY e.full_name`, [period]))
          .filter((x) => n(x.left_amount) > 0)
          .map((x) => ({ title: x.full_name, sub: `سلفة ${ds(x.period).slice(0, 7)} — أصلها ${n(x.amount_egp)}`, amount: n(x.left_amount) }));
        break;
      }
      case 'commissions_unpaid': case 'commissions': {
        title = key === 'commissions' ? 'عمولات الشهر' : 'عمولات مستنية الصرف';
        rows = (await q(`SELECT e.full_name, ce.amount_egp, ce.period, p.name AS project, cr.unit_no FROM commission_entitlements ce
            JOIN employees e ON e.id = ce.employee_id JOIN commission_requests cr ON cr.id = ce.request_id JOIN commission_projects p ON p.id = cr.project_id
           WHERE ce.status = 'active' AND ${key === 'commissions' ? 'ce.period = $1' : `NOT EXISTS (SELECT 1 FROM payouts py WHERE py.commission_entitlement_id = ce.id AND py.status <> 'cancelled') AND $1::date IS NOT NULL`}
           ORDER BY ce.period DESC, e.full_name`, [period]))
          .map((x) => ({ title: x.full_name, sub: `${x.project} — وحدة ${x.unit_no} — ${ds(x.period).slice(0, 7)}`, amount: n(x.amount_egp) }));
        break;
      }
      case 'installments_week': case 'installments_overdue': {
        title = key === 'installments_week' ? 'أقساط مستحقة خلال أسبوع' : 'أقساط متأخرة';
        const t = today();
        const cond = key === 'installments_week' ? `due_date >= $1 AND due_date <= ($1::date + 7)` : `due_date < $1`;
        rows = (await q(`SELECT * FROM (${INSTALLMENT_LINES}) l WHERE paid < amount_egp AND ${cond} ORDER BY due_date`, [t]))
          .map((x) => ({ title: `${x.buyer_name} — ${x.project} ${x.unit_no}`,
            sub: `${Number(x.seq) === 0 ? 'المقدم' : `قسط ${x.seq}`} — ${ds(x.due_date).slice(0, 10)}${x.buyer_phone ? ` — ${x.buyer_phone}` : ''}`,
            amount: r2(n(x.amount_egp) - n(x.paid)) }));
        break;
      }
      case 'units_remaining': {
        title = 'الباقي على الوحدات';
        rows = (await q(`SELECT * FROM (${UNITS_LEFT}) x WHERE left_amount > 0 ORDER BY left_amount DESC`, []))
          .map((x) => ({ title: `${x.buyer_name} — ${x.project} ${x.unit_no}`, sub: x.buyer_phone ?? '', amount: n(x.left_amount) }));
        break;
      }
      case 'transfers_open': {
        title = 'تحويلات مفتوحة';
        rows = (await q(`SELECT t.ref_no, t.direction, t.amount_requested, t.status, t.reason FROM cash_transfers t
                          WHERE t.status IN ('requested','approved','executed') ORDER BY t.requested_at DESC`, []))
          .map((x) => ({ title: x.direction === 'office_to_hr' ? 'تحويل لخزنة المحاسب' : 'توريد للمكتب', sub: `#${x.ref_no} — ${x.reason}`,
            amount: n(x.amount_requested), tag: x.status === 'requested' ? 'مطلوب' : x.status === 'approved' ? 'اتوافق عليه' : 'اتسلّم — مستني تأكيد' }));
        break;
      }
      case 'batches_open': {
        title = 'دفعات مرتبات مفتوحة';
        rows = (await q(`SELECT b.ref_no, b.period, b.status, COALESCE(sum(l.net_egp), 0) AS total FROM payroll_batches b
                          LEFT JOIN payroll_batch_lines l ON l.batch_id = b.id
                          WHERE b.status IN ('draft','returned','pending_approval') GROUP BY b.id ORDER BY b.period DESC`, []))
          .map((x) => ({ title: `مرتبات ${ds(x.period).slice(0, 7)}`, sub: `#${x.ref_no}`, amount: n(x.total),
            tag: x.status === 'pending_approval' ? 'مستنية الاعتماد' : x.status === 'returned' ? 'راجعة للتعديل' : 'مسودة' }));
        break;
      }
      default: throw notFound();
    }
    return ok({ key, title, month: period.slice(0, 7), rows, total: r2(rows.reduce((x, y) => x + y.amount, 0)) });
  });

  /** One employee's money: payroll per month, payments (with confirmation), advances and commissions. */
  r.get('/finance/employee-account/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const self = req.params.id === a.id;
    if (!self && !(has(a, 'employee.salary_read') && (canHrView(a) || canOffice(a)))) throw forbidden();
    const emp = await one(db, `SELECT id, full_name, code FROM employees WHERE id = $1`, [req.params.id]);
    if (!emp) throw notFound();
    const pays = await db.query(`SELECT id, kind, amount_egp, period, status, created_at, received_at, dispute_reason, note
                                   FROM payouts WHERE employee_id = $1 AND kind <> 'fund' ORDER BY created_at DESC LIMIT 200`, [emp.id]);
    const advs = await db.query(`SELECT ar.id, ar.amount_egp, ar.period, ar.status,
          (SELECT json_agg(json_build_object('month', to_char(d.period,'YYYY-MM'), 'amount', d.amount_egp, 'status', d.status) ORDER BY d.period)
             FROM advance_deductions d WHERE d.advance_id = ar.id) AS deductions
        FROM advance_requests ar WHERE ar.employee_id = $1 AND ar.kind = 'advance' ORDER BY ar.period DESC LIMIT 50`, [emp.id]);
    const coms = await db.query(`SELECT ce.amount_egp, ce.period, ce.role, ce.status, p.name AS project, cr.unit_no
        FROM commission_entitlements ce JOIN commission_requests cr ON cr.id = ce.request_id JOIN commission_projects p ON p.id = cr.project_id
       WHERE ce.employee_id = $1 ORDER BY ce.period DESC LIMIT 100`, [emp.id]);
    return ok({
      currency: 'EGP', employee: { id: emp.id, name: emp.full_name, code: emp.code },
      payments: pays.rows.map((p) => ({ id: p.id, kind: p.kind, amount: n(p.amount_egp), month: String(p.period).slice(0, 7), status: p.status,
        at: p.created_at, receivedAt: p.received_at, disputeReason: p.dispute_reason, note: p.note })),
      advances: advs.rows.map((x) => ({ id: x.id, amount: n(x.amount_egp), month: String(x.period).slice(0, 7), status: x.status,
        deductions: (x.deductions ?? []).map((d: any) => ({ ...d, amount: n(d.amount) })) })),
      commissions: coms.rows.map((x) => ({ amount: n(x.amount_egp), month: String(x.period).slice(0, 7), role: x.role, status: x.status,
        project: x.project, unitNo: x.unit_no })),
    });
  });

  /**
   * Monthly indicators per employee vs the previous month: punctuality, late count / minutes, absence, unpaid leave,
   * permissions & visits, manager evaluation, deals and commissions. Alerts and suggestions are advice only.
   */
  r.get('/insights/employees', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a) && !has(a, 'report.read_all')) throw forbidden();
    const period = monthParam(req.query.get('month') ?? today().slice(0, 7));
    const prev = prevMonth(period);
    const rules = await loadRules(db);
    const emps = await db.query(`SELECT id, full_name, code FROM employees WHERE status = 'active' AND role_key <> 'owner' AND NOT attendance_exempt ORDER BY full_name`);
    const out = [];
    for (const e of emps.rows) {
      const stat = async (p: string) => {
        const pay = await computePayroll(db, e.id, p, today(), rules);
        const att = await one(db, `SELECT count(*) AS n FROM attendance WHERE employee_id = $1 AND work_date >= $2 AND work_date < ($2::date + interval '1 month')`, [e.id, p]);
        const outs = await one(db, `SELECT count(*) FILTER (WHERE kind = 'permission') AS perms, count(*) FILTER (WHERE kind = 'visit') AS visits
                                      FROM outing_requests WHERE employee_id = $1 AND status = 'approved' AND parent_id IS NULL
                                       AND requested_at >= ($2::date AT TIME ZONE 'Africa/Cairo') AND requested_at < (($2::date + interval '1 month') AT TIME ZONE 'Africa/Cairo')`, [e.id, p]);
        const deals = await one(db, `SELECT count(*) AS n, COALESCE(sum(sales_amount),0) AS c FROM commission_requests WHERE employee_id = $1 AND status = 'approved' AND period = $2`, [e.id, p]);
        const ev = await one(db, `SELECT avg((SELECT avg(v) FROM unnest(ARRAY[discipline, attendance, communication, follow_up, teamwork,
                                        sales_performance, initiative, professional_behavior]) v)) AS s
                                    FROM evaluations WHERE employee_id = $1 AND period = $2 AND status = 'published'`, [e.id, p]);
        const days = Number(att.n);
        const lateDays = Number((pay as any).late?.days ?? 0);
        return {
          attendanceDays: days, lateCount: lateDays, lateMinutes: Number((pay as any).late?.minutes ?? 0),
          earlyCount: Number((pay as any).early?.days ?? 0), absenceDays: Number((pay as any).absence?.days ?? 0),
          unpaidLeaveDays: Number((pay as any).unpaid?.days ?? 0), permissions: Number(outs.perms ?? 0), visits: Number(outs.visits ?? 0),
          punctuality: days ? Math.round(((days - lateDays) / days) * 100) : null,
          deals: Number(deals.n), commissions: r2(n(deals.c)), evaluation: ev?.s == null ? null : r2(Number(ev.s)),
        };
      };
      const cur = await stat(period), old = await stat(prev);
      const alerts: string[] = [], tips: string[] = [];
      if (cur.lateCount >= 3) alerts.push(`اتأخر ${cur.lateCount} مرات الشهر ده`);
      if (cur.lateCount > old.lateCount && old.lateCount > 0) alerts.push('التأخير زاد عن الشهر اللي فات');
      if (cur.absenceDays >= 2) alerts.push(`غياب بدون إذن ${cur.absenceDays} يوم`);
      if (old.punctuality != null && cur.punctuality != null && cur.punctuality + 10 < old.punctuality) alerts.push('نسبة الالتزام نزلت');
      if (old.deals > 0 && cur.deals < old.deals) alerts.push('صفقات أقل من الشهر اللي فات');
      if (cur.lateCount >= 3) tips.push('كلمه عن مواعيد الحضور وشوف لو فيه ظرف يحتاج تعديل ميعاده');
      if (cur.absenceDays >= 2) tips.push('اتأكد من سبب الغياب قبل أي إجراء');
      if (old.deals > 0 && cur.deals < old.deals) tips.push('راجع معاه الصفقات المفتوحة واحتياجه من دعم');
      if (!alerts.length && cur.punctuality != null && cur.punctuality >= 95) tips.push('التزام ممتاز — يستاهل كلمة شكر');
      out.push({ id: e.id, name: e.full_name, code: e.code, current: cur, previous: old, alerts, suggestions: tips });
    }
    return ok({ month: period.slice(0, 7), previousMonth: prev.slice(0, 7), employees: out,
      note: 'المؤشرات للمتابعة فقط — مفيش خصم أو إجراء تلقائي بناءً عليها' });
  });
};
