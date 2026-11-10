import { ok, type Module } from '../ctx.ts';
import { one } from '../db.ts';
import { forbidden } from '../http/errors.ts';
import { local } from '../lib/time.ts';
import { authenticate } from '../auth/context.ts';
import { cashSummary, canOffice } from './cash.ts';
import { computePayroll, loadRules } from './payroll-calc.ts';

/**
 * The home page of المالك / المدير العام — one call with every card (laid out like the Ignara overview:
 * greeting → actions → 4 KPIs → money chart → approvals line → top sales → latest requests → cashboxes →
 * month's payroll → coming up → needs attention → last activity). Office figures: المالك / المدير العام only.
 */
const r2 = (n: number) => Math.round(n * 100) / 100;
const n = (v: unknown) => Number(v ?? 0);
const ds = (v: unknown) => (v instanceof Date ? v.toISOString() : String(v ?? '')).slice(0, 10);
const LATE = `((at.check_in_at AT TIME ZONE 'Africa/Cairo')::time > at.schedule_start + make_interval(mins => at.late_grace_minutes))`;
const IN_RANGE = (col: string, from: string, to: string) =>
  `${col} >= (${from}::date AT TIME ZONE 'Africa/Cairo') AND ${col} < ((${to}::date + 1) AT TIME ZONE 'Africa/Cairo')`;

export const ownerDashboardModule: Module = (r, { db, clock }) => {
  r.get('/dashboard/owner', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden();
    const t = local(clock()).date;
    const range = [14, 30, 91].includes(Number(req.query.get('range'))) ? Number(req.query.get('range')) : 14;
    const month = t.slice(0, 8) + '01';
    const prevMonth = new Date(Date.UTC(Number(t.slice(0, 4)), Number(t.slice(5, 7)) - 2, 1)).toISOString().slice(0, 10);
    const prevSameDay = (() => { // same day-of-month last month (for a fair "vs last month")
      const d = new Date(Date.UTC(Number(t.slice(0, 4)), Number(t.slice(5, 7)) - 2, Number(t.slice(8, 10))));
      return d.toISOString().slice(0, 10);
    })();
    const from = new Date(Date.parse(t + 'T00:00:00Z') - (range - 1) * 86400000).toISOString().slice(0, 10);

    const [me, today, people, money, series, pipe, top, latest, inst, upcoming, holidays, advances, last, cash] = await Promise.all([
      one(db, `SELECT full_name FROM employees WHERE id = $1`, [a.id]),
      one(db, `
        SELECT count(*)::int AS active, count(at.id)::int AS present, count(at.id) FILTER (WHERE ${LATE})::int AS late,
               count(*) FILTER (WHERE at.id IS NULL AND ab.id IS NOT NULL)::int AS on_leave
          FROM employees e
          LEFT JOIN attendance at ON at.employee_id = e.id AND at.work_date = $1
          LEFT JOIN LATERAL (SELECT r.id FROM requests r WHERE r.employee_id = e.id AND r.type = 'full_day_absence'
                    AND r.status = 'approved' AND $1 BETWEEN r.start_date AND r.end_date LIMIT 1) ab ON true
         WHERE e.status = 'active' AND NOT e.attendance_exempt`, [t]),
      db.query(`
        SELECT e.id, e.full_name, at.id AS att, (at.id IS NOT NULL AND ${LATE}) AS late,
               EXISTS (SELECT 1 FROM requests r WHERE r.employee_id = e.id AND r.type = 'full_day_absence' AND r.status = 'approved'
                        AND $1 BETWEEN r.start_date AND r.end_date) AS on_leave
          FROM employees e LEFT JOIN attendance at ON at.employee_id = e.id AND at.work_date = $1
         WHERE e.status = 'active' AND NOT e.attendance_exempt ORDER BY e.full_name`, [t]),
      one(db, `SELECT
          COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE status = 'posted' AND ${IN_RANGE('occurred_at', '$1', '$2')}), 0) AS coll,
          COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE status = 'posted' AND ${IN_RANGE('occurred_at', '$3', '$4')}), 0) AS coll_prev,
          COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE status = 'posted' AND ${IN_RANGE('occurred_at', '$1', '$2')}), 0) AS expenses,
          COALESCE((SELECT sum(amount_egp) FROM payouts WHERE status = 'received' AND kind = 'salary' AND period = $1), 0) AS salaries_paid,
          COALESCE((SELECT sum(company_amount) FROM commission_requests WHERE status = 'approved' AND period = $1), 0) AS company_commission,
          COALESCE((SELECT sum(amount_egp) FROM commission_entitlements WHERE status = 'active' AND period = $1), 0) AS staff_commission`,
        [month, t, prevMonth, prevSameDay]),
      db.query(`
        WITH days AS (SELECT generate_series($1::date, $2::date, interval '1 day')::date AS d)
        SELECT d.d AS day,
               COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE status = 'posted'
                          AND (occurred_at AT TIME ZONE 'Africa/Cairo')::date = d.d), 0) AS money_in,
               COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE status = 'posted'
                          AND (occurred_at AT TIME ZONE 'Africa/Cairo')::date = d.d), 0)
             + COALESCE((SELECT sum(amount_egp) FROM payouts WHERE status = 'received' AND kind <> 'fund'
                          AND (received_at AT TIME ZONE 'Africa/Cairo')::date = d.d), 0) AS money_out
          FROM days d ORDER BY d.d`, [from, t]),
      one(db, `SELECT
          (SELECT count(*) FROM requests WHERE status IN ('pending_manager','pending_hr'))
          + (SELECT count(*) FROM advance_requests WHERE status = 'pending')
          + (SELECT count(*) FROM cash_expenses WHERE status = 'pending_approval')
          + (SELECT count(*) FROM unit_sales WHERE status = 'pending')
          + (SELECT count(*) FROM commission_requests WHERE status = 'pending')
          + (SELECT count(*) FROM salary_adjustments WHERE status = 'pending') AS awaiting,
          (SELECT count(*) FROM advance_requests ar WHERE ar.status = 'confirmed' AND NOT ar.paid_outside
             AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.advance_id = ar.id AND p.status <> 'cancelled')) AS to_pay,
          (SELECT count(*) FROM payouts WHERE status = 'pending') AS awaiting_receipt,
          (SELECT count(*) FROM payouts WHERE status = 'received' AND kind <> 'fund' AND ${IN_RANGE('received_at', '$1', '$2')}) AS paid,
          (SELECT count(*) FROM cash_transfers WHERE status IN ('requested','approved','executed')) AS transfers_open`, [month, t]),
      db.query(`
        SELECT e.full_name AS name, count(*)::int AS units, COALESCE(sum(cr.unit_value), 0) AS value, COALESCE(sum(cr.sales_amount), 0) AS commission
          FROM commission_requests cr JOIN employees e ON e.id = cr.employee_id
         WHERE cr.status = 'approved' AND cr.period = $1
         GROUP BY e.full_name ORDER BY value DESC LIMIT 5`, [month]),
      db.query(`
        (SELECT 'request' AS kind, r.id::text, e.full_name AS who, r.type AS what, NULL::numeric AS amount, r.created_at AS at, r.status
           FROM requests r JOIN employees e ON e.id = r.employee_id WHERE r.status IN ('pending_manager','pending_hr'))
        UNION ALL
        (SELECT 'advance', ar.id::text, e.full_name, ar.kind, ar.amount_egp, ar.created_at, ar.status
           FROM advance_requests ar JOIN employees e ON e.id = ar.employee_id WHERE ar.status = 'pending')
        UNION ALL
        (SELECT 'expense', x.id::text, x.beneficiary, x.category, x.amount_egp, x.created_at, x.status
           FROM cash_expenses x WHERE x.status = 'pending_approval')
        UNION ALL
        (SELECT 'sale', s.id::text, s.buyer_name, s.unit_no, s.total_price, s.created_at, s.status
           FROM unit_sales s WHERE s.status = 'pending')
        UNION ALL
        (SELECT 'commission', c.id::text, e.full_name, c.unit_no, c.sales_amount, c.created_at, c.status
           FROM commission_requests c JOIN employees e ON e.id = c.employee_id WHERE c.status = 'pending')
        ORDER BY at DESC LIMIT 6`),
      one(db, `
        WITH lines AS (
          SELECT i.due_date, i.amount_egp,
                 COALESCE((SELECT sum(x.amount_egp) FROM cash_receipts x WHERE x.installment_id = i.id AND x.status = 'posted'), 0) AS paid
            FROM sale_installments i JOIN unit_sales s ON s.id = i.sale_id WHERE s.status = 'active')
        SELECT COALESCE(sum(amount_egp - paid) FILTER (WHERE due_date < $1 AND paid < amount_egp), 0) AS overdue,
               count(*) FILTER (WHERE due_date < $1 AND paid < amount_egp)::int AS overdue_n,
               count(*) FILTER (WHERE due_date = $1 AND paid < amount_egp)::int AS today_n
          FROM lines`, [t]),
      db.query(`
        SELECT i.due_date, i.amount_egp - COALESCE((SELECT sum(x.amount_egp) FROM cash_receipts x WHERE x.installment_id = i.id AND x.status = 'posted'), 0) AS left,
               s.buyer_name, s.unit_no, s.id AS sale_id
          FROM sale_installments i JOIN unit_sales s ON s.id = i.sale_id
         WHERE s.status = 'active' AND i.due_date BETWEEN $1 AND ($1::date + 7)
           AND i.amount_egp > COALESCE((SELECT sum(x.amount_egp) FROM cash_receipts x WHERE x.installment_id = i.id AND x.status = 'posted'), 0)
         ORDER BY i.due_date LIMIT 6`, [t]),
      db.query(`SELECT day, name FROM holidays WHERE day BETWEEN $1 AND ($1::date + 14) ORDER BY day`, [t]),
      one(db, `SELECT count(*)::int AS n, COALESCE(sum(GREATEST(ar.amount_egp - COALESCE(d.done, 0), 0)), 0) AS left
          FROM advance_requests ar
          LEFT JOIN LATERAL (SELECT sum(x.amount_egp) AS done FROM advance_deductions x WHERE x.advance_id = ar.id AND x.status = 'active') d ON true
         WHERE ar.kind = 'advance' AND ar.status = 'confirmed' AND ar.amount_egp > COALESCE(d.done, 0)`),
      one(db, `SELECT l.action, l.entity, l.at, e.full_name AS actor FROM audit_log l LEFT JOIN employees e ON e.id = l.actor_id
                ORDER BY l.id DESC LIMIT 1`),
      cashSummary(db, a),
    ]);

    // the month's payroll: what everyone is due, and what was handed over
    const rules = await loadRules(db);
    const emps = await db.query(`SELECT e.id FROM employees e JOIN employee_salaries s ON s.employee_id = e.id WHERE e.status = 'active'`);
    let due = 0, paid = 0;
    const pays = await Promise.all(emps.rows.map((e) => computePayroll(db, e.id, month, t, rules).catch(() => null)));
    for (const p of pays as any[]) { if (p?.net == null) continue; due += n(p.net); paid += n(p.salaryPaid); }

    const c: any = cash;
    const office = r2(n(c.office?.bookBalance)), accountant = r2(n(c.hr?.bookBalance));
    const income = n(money.company_commission);
    const salaries = n(money.salaries_paid), expenses = n(money.expenses);
    const absent = people.rows.filter((p) => !p.att && !p.on_leave);
    return ok({
      date: t, name: me?.full_name ?? '', range,
      summary: { present: today.present, employees: today.active, awaiting: Number(pipe.awaiting), installmentsToday: inst.today_n },
      kpis: {
        collections: { month: r2(n(money.coll)), prev: r2(n(money.coll_prev)) },
        net: { income: r2(income), salaries: r2(salaries), expenses: r2(expenses), staffCommission: r2(n(money.staff_commission)),
          net: r2(income - salaries - expenses) },
        cash: { office, accountant, total: r2(office + accountant) },
        attendance: { present: today.present, employees: today.active, late: today.late, onLeave: today.on_leave,
          pct: today.active ? Math.round((today.present / today.active) * 100) : 0 },
      },
      series: series.rows.map((x) => ({ day: ds(x.day), in: r2(n(x.money_in)), out: r2(n(x.money_out)) })),
      pipeline: { awaiting: Number(pipe.awaiting), toPay: Number(pipe.to_pay), awaitingReceipt: Number(pipe.awaiting_receipt), paid: Number(pipe.paid) },
      topSales: top.rows.map((x) => ({ name: x.name, units: x.units, value: r2(n(x.value)), commission: r2(n(x.commission)) })),
      latest: latest.rows.map((x) => ({ kind: x.kind, id: x.id, who: x.who, what: x.what, amount: x.amount == null ? null : r2(n(x.amount)), at: x.at, status: x.status })),
      wallet: { office, accountant, overdueInstallments: { count: inst.overdue_n, amount: r2(n(inst.overdue)) },
        transfersOpen: Number(pipe.transfers_open) },
      payroll: { due: r2(due), paid: r2(paid), remaining: r2(Math.max(due - paid, 0)) },
      upcoming: [
        ...upcoming.rows.map((x) => ({ kind: 'installment', day: ds(x.due_date), title: `قسط ${x.buyer_name} — وحدة ${x.unit_no}`, amount: r2(n(x.left)), id: x.sale_id })),
        ...holidays.rows.map((x) => ({ kind: 'holiday', day: ds(x.day), title: x.name, amount: null, id: null })),
      ].sort((x, y) => x.day.localeCompare(y.day)),
      attention: {
        absent: absent.map((p) => p.full_name), late: people.rows.filter((p) => p.late).map((p) => p.full_name),
        openAdvances: { count: advances.n, amount: r2(n(advances.left)) },
      },
      lastActivity: last ? { action: last.action, entity: last.entity, at: last.at, actor: last.actor } : null,
    });
  });
};
