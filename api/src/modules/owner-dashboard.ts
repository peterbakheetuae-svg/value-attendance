import { ok, type Module } from '../ctx.ts';
import { one, type Db } from '../db.ts';
import { forbidden } from '../http/errors.ts';
import { local } from '../lib/time.ts';
import { adminOfficerSql, authenticate, can, notSettled, type Actor } from '../auth/context.ts';
import { cashSummary, canOffice } from './cash.ts';
import { computePayrollMany, loadRules } from './payroll-calc.ts';
import { exclusiveTotals } from './exclusive.ts';
import { LATE as LEAD_LATE, OPEN_SQL } from './leads.ts';

/**
 * The home of المالك / المدير العام — the Ignara overview layout, filled by one of two views:
 *   view=finance   — الخزنة (نقدي / بنك), أمانات الملاك, عمولتي, الوحدات, المصروفات وصافي المكتب, تغطية المصاريف, الطلبات المالية
 *   view=employees — الحضور / الانصراف / التأخير / الغياب, عدد الموظفين, أفضل الموظفين, الـ KPIs, الإجازات والأذونات والزيارات
 *   view=sales     — لوحة السيلز: الليدز الجديدة، المتابعات المتأخرة، الأكشنز، الحجوزات والتعاقدات قدام التارجت، المراحل،
 *                    أنشط السيلز، أحدث الليدز، الميتنجات الجاية، والليدز اللي مستنية سيلز
 * All return the same card shapes (kpis · chart · pipeline · ranked · latest · wallet · ring · coming · attention · last),
 * so the app draws one page. Every card carries a `route` key the app maps to its page.
 */
const r2 = (n: number) => Math.round(n * 100) / 100;
const n = (v: unknown) => Number(v ?? 0);
const ds = (v: unknown) => (v instanceof Date ? v.toISOString() : String(v ?? '')).slice(0, 10);
const LATE = `((at.check_in_at AT TIME ZONE 'Africa/Cairo')::time > at.schedule_start + make_interval(mins => at.late_grace_minutes))`;
const IN_RANGE = (col: string, from: string, to: string) =>
  `${col} >= (${from}::date AT TIME ZONE 'Africa/Cairo') AND ${col} < ((${to}::date + 1) AT TIME ZONE 'Africa/Cairo')`;
const addDays = (d: string, k: number) => new Date(Date.parse(d + 'T00:00:00Z') + k * 86400000).toISOString().slice(0, 10);

type Card = Record<string, unknown>;

/** Daily values → one point per day (14 / 30) or per week (91 days → 13 points, the week's sum or average). */
function bucket(days: { day: string; v: number }[], range: number, avg = false) {
  if (range <= 31) return days.map((x) => ({ day: x.day, value: r2(x.v) }));
  const out = [];
  for (let i = 0; i < days.length; i += 7) {
    const part = days.slice(i, i + 7);
    const s = part.reduce((a, x) => a + x.v, 0);
    out.push({ day: part[0].day, value: r2(avg ? s / part.length : s) });
  }
  return out;
}

async function payrollMonth(db: Db, month: string, t: string) {
  const rules = await loadRules(db);
  const emps = await db.query(`SELECT e.id FROM employees e JOIN employee_salaries s ON s.employee_id = e.id WHERE e.status = 'active'`);
  // every employee in a fixed number of queries (it used to run all of them at once and hold the whole connection pool)
  const pays = [...(await computePayrollMany(db, emps.rows.map((e) => e.id as string), month, t, rules)).values()];
  // F7: the month's parts (salary, commissions, work expenses) and what settled each — the one rule of payroll-calc
  let due = 0, paid = 0;
  for (const p of pays as any[]) {
    if (p?.net == null || !p.components) continue;
    for (const c of [p.components.salary, p.components.commissions, p.components.workExpenses]) { due += n(c.due); paid += n(c.paid); }
  }
  return { due: r2(due), paid: r2(paid) };
}

/**
 * The finance view's money of others, each on its own permission (both cash.office before 066, so unchanged until then):
 * the exclusive projects' commission / owners' trust → exclusive.view_finance; the office's income and net → finance.company_income.
 */
function redactFinance(body: any, a: Actor) {
  const ex = can(a, 'exclusive.view_finance', 'cash.office'), income = can(a, 'finance.company_income', 'cash.office');
  if (!ex) {
    body.kpis = (body.kpis ?? []).filter((k: any) => !['percent', 'owner'].includes(k.icon));
    body.summary = (body.summary ?? []).filter((x: string) => !x.includes('للملاك') && !x.includes('عمولة'));
    if (body.ranked) body.ranked = { ...body.ranked, rows: [], empty: 'مش متاح' };
    if (body.attention) body.attention = { ...body.attention, rows: body.attention.rows.filter((r: any) => !['percent', 'home'].includes(r.icon)) };
    if (body.ring) body.ring = { ...body.ring, extra: [] };
  }
  if (!income) {
    body.kpis = (body.kpis ?? []).filter((k: any) => k.icon !== 'profit');
    body.ring = null;
  }
  return body;
}

/**
 * Posted receipts per Cairo day for [from, to], by kind (R5). One grouped pass over a sargable Cairo-local range instead
 * of four correlated scans per day; proven row-for-row identical (dates, order, totals, numeric type) over 261 ranges
 * incl. Cairo midnight and DST-change days, reversed receipts and every kind — docs/remediation/evidence/cash_series_equivalence.sql.
 */
export const DAILY_RECEIPTS_SQL = `
      WITH days AS (SELECT d::date AS day FROM generate_series($1::date, $2::date, interval '1 day') d),
           x AS (SELECT (occurred_at AT TIME ZONE 'Africa/Cairo')::date AS day,
                        sum(amount_egp) FILTER (WHERE kind = 'reservation') AS k_res,
                        sum(amount_egp) FILTER (WHERE kind = 'down_payment') AS k_down,
                        sum(amount_egp) FILTER (WHERE kind = 'installment') AS k_inst,
                        sum(amount_egp) AS k_all
                   FROM cash_receipts
                  WHERE status = 'posted'
                    AND occurred_at >= ($1::date::timestamp AT TIME ZONE 'Africa/Cairo')
                    AND occurred_at <  (($2::date + 1)::timestamp AT TIME ZONE 'Africa/Cairo')
                  GROUP BY 1)
      SELECT days.day, COALESCE(x.k_res, 0) AS k_res, COALESCE(x.k_down, 0) AS k_down, COALESCE(x.k_inst, 0) AS k_inst, COALESCE(x.k_all, 0) AS k_all
        FROM days LEFT JOIN x USING (day) ORDER BY 1`;

async function financeView(db: Db, a: any, t: string, range: number, from: string) {
  const month = t.slice(0, 8) + '01';
  const monthEnd = new Date(Date.UTC(Number(t.slice(0, 4)), Number(t.slice(5, 7)), 0)).toISOString().slice(0, 10);
  const [cash, ex, money, daily, bal0, flows, pay, latest, coming, overdue] = await Promise.all([
    cashSummary(db, a),
    exclusiveTotals(db),
    one(db, `SELECT
        COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE status = 'posted' AND payment_method <> 'cash'), 0)
          - COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE status = 'posted' AND payment_method = 'bank'), 0)
          - COALESCE((SELECT sum(CASE direction WHEN 'bank_to_cash' THEN amount_egp ELSE -amount_egp END) FROM cash_bank_moves), 0) AS bank_in,
        COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE status = 'posted' AND ex_kind IS NULL AND ${IN_RANGE('COALESCE(approved_at, occurred_at)', '$1', '$2')}), 0) AS expenses,
        COALESCE((SELECT sum(company_amount) FROM commission_requests WHERE status = 'approved' AND period = $1 AND ex_unit_id IS NULL), 0) AS marketing,
        COALESCE((SELECT sum(amount_egp) FROM ex_commission_transfers WHERE ${IN_RANGE('created_at', '$1', '$2')}), 0) AS ex_moved_month`, [month, t]),
    db.query(DAILY_RECEIPTS_SQL, [from, t]),
    one(db, `SELECT COALESCE(sum(amount), 0) AS b FROM cash_ledger WHERE at < ($1::date AT TIME ZONE 'Africa/Cairo')`, [from]),
    db.query(`SELECT (at AT TIME ZONE 'Africa/Cairo')::date AS day, sum(amount) AS s FROM cash_ledger
               WHERE at >= ($1::date AT TIME ZONE 'Africa/Cairo') GROUP BY 1`, [from]),
    payrollMonth(db, month, t),
    db.query(`
      (SELECT 'advance' AS kind, ar.id::text AS id, e.full_name AS title, CASE ar.kind WHEN 'advance' THEN 'سلفة' ELSE 'مصاريف عمل' END AS sub,
              ar.amount_egp AS amount, ar.created_at AS at, 'مستني موافقتك' AS status, 'warn' AS tone
         FROM advance_requests ar JOIN employees e ON e.id = ar.employee_id WHERE ar.status = 'pending')
      UNION ALL
      (SELECT 'transfer', t.id::text, CASE t.direction WHEN 'hr_to_office' THEN 'توريد لخزنة المكتب' ELSE 'تحويل لخزنة المحاسب' END, t.reason,
              COALESCE(t.amount_executed, t.amount_requested), t.requested_at,
              CASE t.status WHEN 'requested' THEN 'مطلوب' WHEN 'approved' THEN 'متوافق' ELSE 'اتسلّم؟' END, 'info'
         FROM cash_transfers t WHERE t.status IN ('requested','approved','executed'))
      UNION ALL
      (SELECT 'owner_payout', x.id::text, 'صرف لمالك العقار — ' || x.beneficiary, x.reason, x.amount_egp, x.created_at, 'مستني موافقة', 'warn'
         FROM cash_expenses x WHERE x.status = 'pending_approval' AND x.ex_kind = 'owner_payout')
      UNION ALL
      (SELECT 'expense', x.id::text, x.beneficiary, x.category, x.amount_egp, x.created_at, 'مستني موافقة', 'warn'
         FROM cash_expenses x WHERE x.status = 'pending_approval' AND x.ex_kind IS NULL)
      UNION ALL
      (SELECT 'contract', u.id::text, 'تعاقد — ' || p.name || ' — وحدة ' || u.unit_no, u.client_name, u.unit_price, u.contract_requested_at, 'مستني موافقتك', 'warn'
         FROM ex_units u JOIN commission_projects p ON p.id = u.project_id WHERE u.status = 'contract_pending')
      UNION ALL
      (SELECT 'cancel', u.id::text, 'إلغاء حجز — ' || p.name || ' — وحدة ' || u.unit_no, u.cancel_reason, u.deposit_amount, u.created_at, 'مستني موافقتك', 'bad'
         FROM ex_units u JOIN commission_projects p ON p.id = u.project_id WHERE u.status = 'cancel_pending')
      ORDER BY at DESC LIMIT 6`),
    db.query(`
      SELECT * FROM (
        SELECT i.due_date AS day, 'قسط ' || u.client_name AS title, p.name || ' — وحدة ' || u.unit_no AS sub,
               i.amount_egp - COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0) AS amount, 'ex' AS src
          FROM ex_installments i JOIN ex_units u ON u.id = i.unit_id JOIN commission_projects p ON p.id = u.project_id
         WHERE u.status = 'contracted' AND i.due_date BETWEEN $1 AND ($1::date + 14)
        UNION ALL
        SELECT i.due_date, 'قسط ' || s.buyer_name, 'وحدة ' || s.unit_no,
               i.amount_egp - COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.installment_id = i.id AND r.status = 'posted'), 0), 'mk'
          FROM sale_installments i JOIN unit_sales s ON s.id = i.sale_id
         WHERE s.status = 'active' AND i.due_date BETWEEN $1 AND ($1::date + 14)
      ) x WHERE amount > 0 ORDER BY day LIMIT 5`, [t]),
    one(db, `
      SELECT count(*)::int AS n, COALESCE(sum(left_amt), 0) AS s FROM (
        SELECT i.amount_egp - COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0) AS left_amt
          FROM ex_installments i JOIN ex_units u ON u.id = i.unit_id WHERE u.status = 'contracted' AND i.due_date < $1
        UNION ALL
        SELECT i.amount_egp - COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.installment_id = i.id AND r.status = 'posted'), 0)
          FROM sale_installments i JOIN unit_sales s ON s.id = i.sale_id WHERE s.status = 'active' AND i.due_date < $1
      ) x WHERE left_amt > 0`, [t]),
  ]);
  const c: any = cash;
  const office = r2(n(c.office?.bookBalance)), accountant = r2(n(c.hr?.bookBalance));
  const total = r2(office + accountant);
  const bank = r2(Math.min(Math.max(n(money.bank_in), 0), Math.max(total, 0)));
  const sumEx = (f: (p: any) => number) => r2(ex.reduce((s, p) => s + f(p), 0));
  const mine = {
    transferred: sumEx((p) => p.commission.transferred), pending: sumEx((p) => p.commission.pending),
    upcoming: sumEx((p) => p.commission.upcoming), potential: sumEx((p) => p.commission.potential),
  };
  const ownersDue = sumEx((p) => p.owner.due), ownersPaid = sumEx((p) => p.owner.paid);
  const income = r2(n(money.marketing) + n(money.ex_moved_month));
  const costs = r2(pay.due + n(money.expenses));
  const net = r2(income - costs);
  const daysLeft = Math.max(1, (Date.parse(monthEnd) - Date.parse(t)) / 86400000 + 1);
  // the cashbox balance day by day (for the wallet's line)
  let running = n(bal0.b);
  const spark: number[] = [];
  for (let d = from; d <= t; d = addDays(d, 1)) {
    running += n(flows.rows.find((x) => ds(x.day) === d)?.s);
    spark.push(r2(running));
  }
  const series = (key: string) => bucket(daily.rows.map((x) => ({ day: ds(x.day), v: n(x[key]) })), range);
  const all = series('k_all');
  const avg = all.length ? r2(all.reduce((s, x) => s + x.value, 0) / all.length) : 0;
  const best = all.reduce((b, x) => (x.value > (b?.value ?? -1) ? x : b), null as any);
  const units = {
    reserved: ex.reduce((s, p) => s + p.units.reserved, 0), contracted: ex.reduce((s, p) => s + p.units.contracted, 0),
    completed: ex.reduce((s, p) => s + p.units.completed, 0), cancelled: ex.reduce((s, p) => s + p.units.cancelled, 0),
  };
  const next = coming.rows[0];
  const maxDue = Math.max(1, ...ex.map((p) => p.owner.inTrust));
  return {
    summary: [
      `في الخزن ${fmt(total)}`,
      ownersDue > 0 ? `منهم ${fmt(ownersDue)} للملاك` : '',
      mine.pending > 0 ? `${fmt(mine.pending)} عمولة مستنية التحويل` : '',
      n(overdue.n) > 0 ? `${overdue.n} قسط متأخر` : '',
    ].filter(Boolean),
    kpis: [
      { label: 'الخزنة', value: total, format: 'money', highlight: true, progress: total > 0 ? r2((total - bank) / total) : 0,
        foot: `نقدي ${short(total - bank)} · بنك ${short(bank)}`, route: 'cash', icon: 'wallet' },
      { label: 'عمولتي', value: mine.transferred, format: 'money', foot: `في الأمانة ${short(mine.pending)} · جاية ${short(mine.upcoming)}`,
        delta: null, route: 'office_commissions', icon: 'percent' },
      { label: 'المستحق للملاك', value: ownersDue, format: 'money', foot: `اتصرف لهم ${short(ownersPaid)}`, route: 'owners', icon: 'owner' },
      { label: 'صافي المكتب', value: net, format: 'money', tone: net >= 0 ? 'good' : 'bad',
        foot: `دخل ${short(income)} − مصاريف ${short(costs)}`, route: 'finance', icon: 'profit' },
    ],
    chart: {
      title: 'التحصيل', sub: 'كل اللي دخل الخزن — العمود الملوّن يوم فوق المتوسط', unit: 'money',
      chips: [{ key: 'k_all', label: 'الكل' }, { key: 'k_res', label: 'عربون' }, { key: 'k_down', label: 'مقدم' }, { key: 'k_inst', label: 'أقساط' }],
      series: { k_all: all, k_res: series('k_res'), k_down: series('k_down'), k_inst: series('k_inst') },
      target: avg, targetLabel: 'المتوسط',
      stats: [
        { label: 'اتحصّل', value: r2(all.reduce((s, x) => s + x.value, 0)), format: 'money' },
        { label: 'فوق المتوسط', value: all.filter((x) => x.value > avg).length, format: 'count', of: all.length },
        { label: 'المتوسط', value: avg, format: 'money', dashed: true },
        { label: 'أعلى يوم', value: best?.value ?? 0, format: 'money', day: best?.day ?? null },
      ],
      route: 'cash',
    },
    pipeline: {
      title: 'الوحدات', sub: 'المشاريع الحصري — كل الوحدات حسب حالتها', route: 'units',
      rows: [
        { label: 'محجوز', value: units.reserved, tone: 'accent' }, { label: 'متعاقد', value: units.contracted, tone: 'warn' },
        { label: 'مكتمل', value: units.completed, tone: 'info' }, { label: 'ملغي', value: units.cancelled, tone: 'muted' },
      ],
      footer: next ? { icon: 'calendar', strong: ds(next.day), text: `أقرب قسط · ${next.title}` } : { icon: 'calendar', strong: '', text: 'مفيش أقساط قريبة' },
      button: 'المشاريع',
    },
    ranked: {
      title: 'أمانات الملاك', sub: 'لكل مشروع: اللي في الأمانة والمستحق للمالك', route: 'projects_box',
      rows: ex.filter((p) => p.units.total > 0 || p.owner.inTrust > 0).sort((x, y) => y.owner.inTrust - x.owner.inTrust).slice(0, 5).map((p) => ({
        title: p.name, sub: `${p.ownerName} · ${p.units.contracted + p.units.completed} مباع`, value: p.owner.due, format: 'money',
        progress: r2(p.owner.inTrust / maxDue), id: p.id,
        detail: { collected: p.collected, transferred: p.commission.transferred, paid: p.owner.paid, inTrust: p.owner.inTrust, due: p.owner.due },
      })),
      empty: 'لسه مفيش مشاريع حصري',
    },
    latest: {
      title: 'الطلبات المالية', sub: 'سلف، توريد، صرف للملاك، تعاقدات', route: 'finance_requests',
      rows: latest.rows.map((x) => ({ kind: x.kind, id: x.id, title: x.title, sub: x.sub ?? '', at: x.at, amount: x.amount == null ? null : r2(n(x.amount)),
        status: x.status, tone: x.tone })),
      empty: 'مفيش طلبات مستنياك',
    },
    wallet: {
      title: 'الخزنة', label: 'الرصيد دلوقتي', value: total, format: 'money', spark,
      rows: [{ label: 'خزنة المكتب', value: office, format: 'money' }, { label: 'خزنة المحاسب', value: accountant, format: 'money' }],
      button: { label: 'طلب توريد', route: 'cash' },
      warn: n(overdue.n) > 0 ? { label: `${overdue.n} قسط متأخر`, route: 'installments' } : null,
      route: 'cash',
    },
    ring: {
      title: 'تغطية المصاريف', sub: `الرواتب ${short(pay.due)} + المصاريف ${short(n(money.expenses))}`,
      pct: costs > 0 ? Math.min(1, income / costs) : income > 0 ? 1 : 0, center: costs > 0 ? (income / costs > 9.99 ? '+999٪' : `${Math.round((income / costs) * 100)}٪`) : (income > 0 ? '100٪' : '0٪'),
      centerSub: `${short(income)} من ${short(costs)}`,
      stats: [
        { label: net >= 0 ? 'الربح' : 'العجز', value: Math.abs(net), format: 'money', tone: net >= 0 ? 'good' : 'bad' },
        { label: 'المطلوب يتغطى', value: Math.max(costs - income, 0), format: 'money' },
        { label: 'في اليوم', value: r2(Math.max(costs - income, 0) / daysLeft), format: 'money' },
      ],
      extra: [
        { label: 'عمولة جاية من أقساط', value: mine.upcoming, format: 'money' },
        { label: 'عمولة محتملة من حجوزات', value: mine.potential, format: 'money' },
      ],
      route: 'finance',
    },
    coming: {
      title: 'الجاي', sub: 'أقساط الأسبوعين الجايين', route: 'installments',
      rows: coming.rows.map((x) => ({ day: ds(x.day), title: x.title, sub: x.sub, amount: r2(n(x.amount)), tone: x.src === 'ex' ? 'accent' : 'info' })),
      empty: 'مفيش أقساط قريبة',
    },
    attention: {
      title: 'محتاج انتباه', sub: 'حاجات مستنية قرار', route: 'finance_requests',
      rows: [
        n(overdue.n) > 0 ? { icon: 'alert', title: `${overdue.n} قسط متأخر`, sub: `${fmt(n(overdue.s))} لسه متحصلتش`, button: 'الأقساط', route: 'installments' } : null,
        mine.pending > 0 ? { icon: 'percent', title: 'عمولة مستنية التحويل', sub: `${fmt(mine.pending)} لسه جوه أمانات الملاك`, button: 'حوّل', route: 'office_commissions' } : null,
        units.reserved > 0 ? { icon: 'home', title: `${units.reserved} وحدة محجوزة`, sub: `عمولة محتملة ${fmt(mine.potential)}`, button: 'الوحدات', route: 'units' } : null,
        pay.due - pay.paid > 0 ? { icon: 'payroll', title: 'مرتبات لسه متصرفتش', sub: `${fmt(r2(pay.due - pay.paid))} من ${fmt(pay.due)}`, button: 'المرتبات', route: 'finance_requests' } : null,
      ].filter(Boolean),
      empty: 'كله تمام',
    },
  };
}

/**
 * «الموظفين دلوقتي»: every active employee with a green/red dot (a session seen in the last 10 minutes — the same rule as
 * «المستخدمون المتصلون» in لوحة السيلز) and where they are: during their work hours داخل المكتب (checked in, not out, no
 * outing running) / خارج المكتب بإذن ساعات / بإذن زيارة (an approved outing not back yet) / انصرف / لسه مسجلش / إجازة;
 * outside their work hours only متصل / مش متصل.
 */
async function employeesPresence(db: Db, t: string, now: Date) {
  const rows = (await db.query(`
    SELECT e.id, e.full_name, e.job_title, e.attendance_exempt,
           EXISTS (SELECT 1 FROM sessions s WHERE s.employee_id = e.id AND s.revoked_at IS NULL
                    AND s.last_seen_at > $2::timestamptz - interval '10 minutes') AS online,
           at.check_in_at, at.check_out_at,
           EXISTS (SELECT 1 FROM requests r WHERE r.employee_id = e.id AND r.type = 'full_day_absence' AND r.status = 'approved'
                    AND $1 BETWEEN r.start_date AND r.end_date) AS on_leave,
           (SELECT o.kind FROM outing_requests o WHERE o.employee_id = e.id AND o.work_date = $1 AND o.status = 'approved'
                AND o.parent_id IS NULL AND o.returned_at IS NULL AND COALESCE(o.starts_at, o.decided_at, o.requested_at) <= $2
              ORDER BY o.requested_at DESC LIMIT 1) AS outing,
           (ws.id IS NOT NULL
              AND NOT (EXTRACT(isodow FROM ($2::timestamptz AT TIME ZONE 'Africa/Cairo'))::int = ANY(ws.weekend_days))
              AND ($2::timestamptz AT TIME ZONE 'Africa/Cairo')::time
                  BETWEEN COALESCE(e.work_start, ws.start_time) AND COALESCE(e.work_end, ws.end_time)) AS in_hours
      FROM employees e
      LEFT JOIN work_schedules ws ON ws.id = COALESCE(e.schedule_id, (SELECT id FROM work_schedules WHERE is_default LIMIT 1))
      LEFT JOIN attendance at ON at.employee_id = e.id AND at.work_date = $1
     WHERE e.status = 'active' AND ${notSettled('e')}
     ORDER BY e.full_name`, [t, now])).rows;
  const where = (x: any): { status: string; tone: string } => {
    if (!x.in_hours) return x.online ? { status: 'متصل', tone: 'good' } : { status: 'مش متصل', tone: 'muted' };
    if (x.on_leave) return { status: 'في إجازة', tone: 'info' };
    if (x.outing) return { status: x.outing === 'visit' ? 'خارج المكتب بإذن معاينة' : 'خارج المكتب بإذن ساعات', tone: 'warn' };
    if (x.check_in_at && !x.check_out_at) return { status: 'داخل المكتب', tone: 'good' };
    if (x.check_out_at) return { status: 'انصرف', tone: 'muted' };
    // no check-in for him (no attendance: the owner, a manager …): only whether he is online
    if (x.attendance_exempt) return x.online ? { status: 'متصل', tone: 'good' } : { status: 'مش متصل', tone: 'muted' };
    return { status: 'لسه مسجلش حضور', tone: 'bad' };
  };
  const list = rows.map((x) => ({ id: x.id, name: x.full_name, job: x.job_title ?? '', online: !!x.online, inHours: !!x.in_hours, ...where(x) }));
  list.sort((a, b) => Number(b.online) - Number(a.online));
  return {
    title: 'الموظفين دلوقتي', sub: `${list.filter((x) => x.online).length} متصل من ${list.length}`, route: 'attendance_today',
    rows: list, empty: 'مفيش موظفين',
  };
}

async function employeesView(db: Db, t: string, range: number, from: string, now: Date) {
  const month = t.slice(0, 8) + '01';
  const [today, people, daily, ranked, pending, outs, outDaily, kpi, leaves, holidays, births, forgot] = await Promise.all([
    one(db, `
      SELECT count(*)::int AS active, count(at.id)::int AS present, count(at.id) FILTER (WHERE ${LATE})::int AS late,
             count(at.id) FILTER (WHERE at.check_out_at IS NOT NULL)::int AS out_done,
             count(*) FILTER (WHERE at.id IS NULL AND ab.id IS NOT NULL)::int AS on_leave
        FROM employees e
        LEFT JOIN attendance at ON at.employee_id = e.id AND at.work_date = $1
        LEFT JOIN LATERAL (SELECT r.id FROM requests r WHERE r.employee_id = e.id AND r.type = 'full_day_absence'
                  AND r.status = 'approved' AND $1 BETWEEN r.start_date AND r.end_date LIMIT 1) ab ON true
       WHERE e.status = 'active' AND NOT e.attendance_exempt AND ${notSettled('e')}`, [t]),
    db.query(`
      SELECT e.full_name, at.id AS att, (at.id IS NOT NULL AND ${LATE}) AS late,
             EXISTS (SELECT 1 FROM requests r WHERE r.employee_id = e.id AND r.type = 'full_day_absence' AND r.status = 'approved'
                      AND $1 BETWEEN r.start_date AND r.end_date) AS on_leave
        FROM employees e LEFT JOIN attendance at ON at.employee_id = e.id AND at.work_date = $1
       WHERE e.status = 'active' AND NOT e.attendance_exempt AND ${notSettled('e')} ORDER BY e.full_name`, [t]),
    db.query(`
      SELECT d::date AS day,
             (SELECT count(*) FROM attendance at JOIN employees e ON e.id = at.employee_id WHERE at.work_date = d::date AND NOT e.attendance_exempt) AS present,
             (SELECT count(*) FROM attendance at JOIN employees e ON e.id = at.employee_id WHERE at.work_date = d::date AND NOT e.attendance_exempt AND ${LATE}) AS late
        FROM generate_series($1::date, $2::date, interval '1 day') d ORDER BY 1`, [from, t]),
    db.query(`
      SELECT e.id, e.full_name, e.job_title, count(at.id)::int AS days, count(at.id) FILTER (WHERE ${LATE})::int AS late_days
        FROM employees e LEFT JOIN attendance at ON at.employee_id = e.id AND at.work_date >= $1 AND at.work_date <= $2
       WHERE e.status = 'active' AND NOT e.attendance_exempt AND ${notSettled('e')} GROUP BY e.id ORDER BY count(at.id) DESC`, [month, t]),
    db.query(`
      (SELECT 'request' AS kind, r.id::text AS id, e.full_name AS title,
              CASE r.type WHEN 'full_day_absence' THEN 'إجازة ' || r.days_count || ' يوم' WHEN 'hourly_permission' THEN 'إذن ساعات' ELSE r.type END AS sub,
              r.created_at AS at, CASE r.status WHEN 'pending_manager' THEN 'مستني المدير' ELSE 'مستني HR' END AS status
         FROM requests r JOIN employees e ON e.id = r.employee_id WHERE r.status IN ('pending_manager','pending_hr'))
      UNION ALL
      (SELECT 'outing', o.id::text, e.full_name, CASE o.kind WHEN 'visit' THEN 'معاينة' ELSE 'إذن خروج' END, o.requested_at, 'مستني الموافقة'
         FROM outing_requests o JOIN employees e ON e.id = o.employee_id WHERE o.status = 'pending')
      ORDER BY at DESC LIMIT 6`),
    one(db, `SELECT
        count(*) FILTER (WHERE o.work_date = $1 AND o.status = 'approved' AND o.parent_id IS NULL)::int AS today,
        count(*) FILTER (WHERE o.work_date = $1 AND o.status = 'approved' AND o.returned_at IS NULL
                          AND NOT EXISTS (SELECT 1 FROM outing_requests c WHERE c.parent_id = o.id AND c.status = 'approved'))::int AS out_now,
        count(*) FILTER (WHERE o.work_date = $1 AND o.status = 'approved' AND o.returned_at IS NULL AND o.expected_return_at < now())::int AS late_back,
        count(*) FILTER (WHERE o.kind = 'permission' AND o.status = 'approved' AND o.parent_id IS NULL AND o.work_date >= $2)::int AS perms_month,
        count(*) FILTER (WHERE o.kind = 'visit' AND o.status = 'approved' AND o.parent_id IS NULL AND o.work_date >= $2)::int AS visits_month
        FROM outing_requests o`, [t, month]),
    db.query(`SELECT d::date AS day, (SELECT count(*) FROM outing_requests o WHERE o.work_date = d::date AND o.status = 'approved' AND o.parent_id IS NULL) AS n
                FROM generate_series($1::date, $2::date, interval '1 day') d ORDER BY 1`, [from, t]),
    db.query(`
      SELECT e.full_name, sum(k.weight_snapshot * LEAST(k.actual / NULLIF(k.target_snapshot, 0), 1.2)) / NULLIF(sum(k.weight_snapshot), 0) AS score
        FROM kpi_results k JOIN employees e ON e.id = k.employee_id
       WHERE k.period = $1 AND k.actual IS NOT NULL GROUP BY e.full_name`, [month]),
    db.query(`SELECT r.start_date AS day, e.full_name AS title, r.days_count FROM requests r JOIN employees e ON e.id = r.employee_id
               WHERE r.type = 'full_day_absence' AND r.status = 'approved' AND r.start_date BETWEEN $1 AND ($1::date + 14) ORDER BY r.start_date LIMIT 5`, [t]),
    db.query(`SELECT day, name FROM holidays WHERE day BETWEEN $1 AND ($1::date + 14) ORDER BY day`, [t]),
    db.query(`SELECT full_name, legacy_fields->>'birthDate' AS b FROM employees WHERE status = 'active' AND legacy_fields ? 'birthDate'`),
    db.query(`SELECT e.full_name FROM attendance at JOIN employees e ON e.id = at.employee_id
               WHERE at.work_date = ($1::date - 1) AND at.check_out_at IS NULL ORDER BY e.full_name`, [t]),
  ]);
  const absent = people.rows.filter((p) => !p.att && !p.on_leave).map((p) => p.full_name);
  const late = people.rows.filter((p) => p.late).map((p) => p.full_name);
  const pct = today.active ? today.present / today.active : 0;
  const presentSeries = bucket(daily.rows.map((x) => ({ day: ds(x.day), v: n(x.present) })), range, true);
  const lateSeries = bucket(daily.rows.map((x) => ({ day: ds(x.day), v: n(x.late) })), range, true);
  const workDays = presentSeries.filter((x) => x.value > 0);
  const avg = workDays.length ? r2(workDays.reduce((s, x) => s + x.value, 0) / workDays.length) : 0;
  const best = presentSeries.reduce((b, x) => (x.value > (b?.value ?? -1) ? x : b), null as any);
  const monthLate = ranked.rows.reduce((s, x) => s + n(x.late_days), 0);
  const top = ranked.rows.filter((x) => n(x.days) > 0)
    .map((x) => ({ ...x, punct: n(x.days) ? (n(x.days) - n(x.late_days)) / n(x.days) : 0 }))
    .sort((x, y) => y.punct - x.punct || n(y.days) - n(x.days)).slice(0, 5);
  const scores = kpi.rows.map((x) => ({ name: x.full_name, s: n(x.score) * 100 })).sort((x, y) => y.s - x.s);
  const kpiAvg = scores.length ? scores.reduce((s, x) => s + x.s, 0) / scores.length : 0;
  // birthdays in the next 14 days (stored as YYYY-MM-DD or DD/MM/YYYY)
  const bd: { day: string; title: string }[] = [];
  for (const x of births.rows) {
    const m = String(x.b ?? '').match(/^(\d{4})-(\d{1,2})-(\d{1,2})|^(\d{1,2})[/-](\d{1,2})[/-](\d{4})/);
    if (!m) continue;
    const mm = Number(m[2] ?? m[5]), dd = Number(m[3] ?? m[4]);
    for (const y of [Number(t.slice(0, 4)), Number(t.slice(0, 4)) + 1]) {
      const d = `${y}-${String(mm).padStart(2, '0')}-${String(dd).padStart(2, '0')}`;
      if (d >= t && d <= addDays(t, 14)) bd.push({ day: d, title: `عيد ميلاد ${x.full_name}` });
    }
  }
  const presence = await employeesPresence(db, t, now);
  const coming = [
    ...leaves.rows.map((x) => ({ day: ds(x.day), title: `إجازة ${x.title}`, sub: `${x.days_count} يوم`, tone: 'info' })),
    ...holidays.rows.map((x) => ({ day: ds(x.day), title: x.name, sub: 'إجازة رسمية', tone: 'good' })),
    ...bd.map((x) => ({ ...x, sub: '🎂', tone: 'accent' })),
  ].sort((x, y) => x.day.localeCompare(y.day)).slice(0, 5);
  return {
    presence,
    summary: [
      `حاضر النهارده ${today.present} من ${today.active}`,
      today.late ? `${today.late} متأخر` : '',
      absent.length ? `${absent.length} غايب` : '',
      pending.rows.length ? `${pending.rows.length} طلب مستني` : '',
    ].filter(Boolean),
    kpis: [
      { label: 'الحضور النهارده', value: Math.round(pct * 100), format: 'pct', highlight: true, progress: r2(pct),
        foot: `${today.present} من ${today.active} · انصرف ${today.out_done}`, route: 'attendance_today', icon: 'checkin' },
      { label: 'عدد الموظفين', value: today.active, format: 'count', foot: `${today.on_leave} في إجازة النهارده`, route: 'employees', icon: 'people' },
      { label: 'التأخير', value: today.late, format: 'count', foot: `${monthLate} يوم تأخير الشهر ده`, route: 'attendance_report', icon: 'late', tone: today.late ? 'warn' : null },
      { label: 'الغياب', value: absent.length, format: 'count', foot: absent.slice(0, 2).join('، ') || 'محدش غايب', route: 'attendance_today', icon: 'absent', tone: absent.length ? 'bad' : null },
    ],
    chart: {
      title: 'الحضور اليومي', sub: 'عدد الحاضرين كل يوم — العمود الملوّن يوم الكل حضر فيه', unit: 'count',
      chips: [{ key: 'present', label: 'الحضور' }, { key: 'late', label: 'التأخير' }],
      series: { present: presentSeries, late: lateSeries },
      target: today.active, targetLabel: 'الكل',
      stats: [
        { label: 'متوسط الحضور', value: avg, format: 'count' },
        { label: 'أيام كاملة', value: presentSeries.filter((x) => x.value >= today.active && today.active > 0).length, format: 'count', of: workDays.length },
        { label: 'الموظفين', value: today.active, format: 'count', dashed: true },
        { label: 'أعلى يوم', value: best?.value ?? 0, format: 'count', day: best?.day ?? null },
      ],
      route: 'attendance_report',
    },
    pipeline: {
      title: 'النهارده', sub: 'كل الموظفين حسب حالتهم دلوقتي', route: 'attendance_today',
      rows: [
        { label: 'حاضر', value: today.present - today.out_done, tone: 'accent' }, { label: 'انصرف', value: today.out_done, tone: 'info' },
        { label: 'خارج دلوقتي', value: outs.out_now, tone: 'warn' }, { label: 'غايب', value: absent.length, tone: 'bad' },
        { label: 'إجازة', value: today.on_leave, tone: 'muted' },
      ],
      footer: { icon: 'clock', strong: `${outs.today}`, text: 'خروج ومعاينة النهارده' },
      button: 'الحضور',
    },
    ranked: {
      title: 'أفضل الموظفين', sub: 'الشهر ده — الالتزام بالمواعيد', route: 'attendance_report',
      rows: top.map((x) => ({ title: x.full_name, sub: `${x.days} يوم حضور · ${x.late_days} تأخير`, value: Math.round(x.punct * 100), format: 'pct', progress: r2(x.punct) })),
      empty: 'لسه مفيش حضور الشهر ده',
    },
    latest: {
      title: 'الإجازات والأذونات', sub: 'طلبات مستنية الرد', route: 'leave_requests',
      rows: pending.rows.map((x) => ({ kind: x.kind, id: x.id, title: x.title, sub: x.sub, at: x.at, amount: null, status: x.status, tone: 'warn' })),
      empty: 'مفيش طلبات مستنية',
    },
    wallet: {
      title: 'الخروج والمعاينات', label: 'خرجوا النهارده', value: outs.today, format: 'count',
      spark: outDaily.rows.map((x) => n(x.n)),
      rows: [{ label: 'أذونات الشهر', value: outs.perms_month, format: 'count' }, { label: 'معاينات الشهر', value: outs.visits_month, format: 'count' }],
      button: { label: 'الطلبات', route: 'requests' },
      warn: outs.late_back > 0 ? { label: `${outs.late_back} اتأخر في الرجوع`, route: 'attendance_today' } : null,
      route: 'requests',
    },
    ring: {
      title: 'مؤشرات الأداء KPIs', sub: `${scores.length} موظف اتقيّم الشهر ده`, pct: Math.min(1, kpiAvg / 100), center: `${Math.round(kpiAvg)}٪`,
      centerSub: 'متوسط الإنجاز',
      stats: [
        { label: 'الأعلى', value: scores[0] ? Math.round(scores[0].s) : 0, format: 'pct', tone: 'good', name: scores[0]?.name ?? '' },
        { label: 'الأقل', value: scores.length ? Math.round(scores[scores.length - 1].s) : 0, format: 'pct', name: scores[scores.length - 1]?.name ?? '' },
        { label: 'اتقيّموا', value: scores.length, format: 'count', of: today.active },
      ],
      route: 'kpi',
    },
    coming: { title: 'الجاي', sub: 'إجازات، أعياد ميلاد، إجازات رسمية', route: 'leave_requests', rows: coming, empty: 'مفيش حاجة الأسبوعين الجايين' },
    attention: {
      title: 'محتاج انتباه', sub: 'النهارده', route: 'attendance_today',
      rows: [
        absent.length ? { icon: 'absent', title: `غياب: ${absent.length}`, sub: absent.join('، '), button: 'الحضور', route: 'attendance_today' } : null,
        late.length ? { icon: 'late', title: `تأخير: ${late.length}`, sub: late.join('، '), button: 'التقرير', route: 'attendance_report' } : null,
        forgot.rows.length ? { icon: 'clock', title: `نسيوا الانصراف امبارح: ${forgot.rows.length}`, sub: forgot.rows.map((x) => x.full_name).join('، '), button: 'تعديل', route: 'attendance_report' } : null,
        outs.late_back ? { icon: 'alert', title: `${outs.late_back} اتأخر في الرجوع`, sub: 'من إذن خروج أو معاينة', button: 'متابعة', route: 'attendance_today' } : null,
      ].filter(Boolean),
      empty: 'كله تمام النهارده',
    },
  };
}

// ------------------------------------------------------------------ view=sales (the same numbers as لوحة السيلز:
// reservations = units created this month, contracts = by contract date, actions = lead actions — like its targets)
const CAIRO_DAY = (col: string) => `(${col} AT TIME ZONE 'Africa/Cairo')::date`;
const STAGE_TONE: Record<string, string> = { new: 'info', action: 'warn', reserve: 'good', won: 'good', lost: 'muted' };

async function salesView(db: Db, t: string, range: number, from: string, now: Date) {
  const month = t.slice(0, 8) + '01';
  const [k, daily, stages, ranked, latest, meetings, tasksSoon, lateBy, online] = await Promise.all([
    one(db, `SELECT
        (SELECT count(*) FROM leads l WHERE ${IN_RANGE('l.created_at', '$1', '$1')})::int AS new_today,
        (SELECT count(*) FROM leads l WHERE ${IN_RANGE('l.created_at', '$2', '$1')})::int AS new_month,
        (SELECT count(*) FROM leads l WHERE ${OPEN_SQL})::int AS open,
        (SELECT count(*) FROM leads l WHERE ${OPEN_SQL} AND l.assigned_to IS NULL)::int AS unassigned,
        (SELECT count(*) FROM leads l WHERE ${OPEN_SQL} AND l.assigned_to IS NULL AND l.wait_since IS NOT NULL)::int AS waiting,
        (SELECT count(*) FROM leads l WHERE ${OPEN_SQL} AND l.next_at IS NOT NULL AND ${LEAD_LATE('$3::timestamptz')})::int AS late,
        (SELECT count(*) FROM lead_actions x WHERE x.parent_id IS NULL AND NOT x.auto AND ${IN_RANGE('x.created_at', '$1', '$1')})::int AS actions_today,
        (SELECT count(*) FROM lead_actions x WHERE x.answered AND NOT x.auto AND ${IN_RANGE('x.created_at', '$1', '$1')})::int AS answered_today,
        (SELECT count(*) FROM lead_actions x WHERE x.answered = false AND NOT x.auto AND ${IN_RANGE('x.created_at', '$1', '$1')})::int AS no_answer_today,
        (SELECT count(*) FROM ex_units u WHERE u.status <> 'cancelled' AND ${IN_RANGE('u.created_at', '$2', '$1')})::int AS res_month,
        (SELECT count(*) FROM ex_units u WHERE ${IN_RANGE('u.contracted_at', '$2', '$1')})::int AS deals_month,
        (SELECT COALESCE(sum(u.unit_price), 0) FROM ex_units u WHERE ${IN_RANGE('u.contracted_at', '$2', '$1')}) AS deals_value_month,
        (SELECT COALESCE(sum(reservations), 0) FROM lead_targets WHERE month = $2::date)::int AS t_res,
        (SELECT COALESCE(sum(deals), 0) FROM lead_targets WHERE month = $2::date)::int AS t_deals,
        (SELECT count(*) FROM tasks x WHERE x.status IN ('open','doing') AND x.due_at < $3)::int AS tasks_late,
        (SELECT count(*) FROM deals d WHERE d.stage = 'open')::int AS deals_open,
        (SELECT round(avg(extract(epoch FROM (fx.at - l.assigned_at)) / 60)) FROM leads l
           CROSS JOIN LATERAL (SELECT min(x.created_at) AS at FROM lead_actions x WHERE x.lead_id = l.id AND NOT x.auto AND x.created_at >= l.assigned_at) fx
          WHERE l.assigned_at >= $3::timestamptz - interval '7 days' AND fx.at IS NOT NULL)::int AS response_min,
        (SELECT count(DISTINCT e.id) FROM employees e
           JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key) AND rp.perm_key = 'leads.own'
          WHERE e.status = 'active' AND COALESCE(e.legacy_fields->>'status', '') <> 'تم التصفيه')::int AS sales_people`, [t, month, now]),
    db.query(`
      SELECT d::date AS day,
             (SELECT count(*) FROM leads l WHERE ${CAIRO_DAY('l.created_at')} = d::date)::int AS new,
             (SELECT count(*) FROM lead_actions x WHERE x.parent_id IS NULL AND NOT x.auto AND ${CAIRO_DAY('x.created_at')} = d::date)::int AS actions,
             (SELECT count(*) FROM ex_units u WHERE u.status <> 'cancelled' AND ${CAIRO_DAY('u.created_at')} = d::date)::int AS res,
             (SELECT COALESCE(sum(u.unit_price), 0) FROM ex_units u WHERE ${CAIRO_DAY('u.contracted_at')} = d::date) AS value
        FROM generate_series($1::date, $2::date, interval '1 day') d ORDER BY 1`, [from, t]),
    db.query(`SELECT s.key, s.name_ar, s.kind, count(l.id)::int AS n FROM lead_stages s LEFT JOIN leads l ON l.stage = s.key
               WHERE s.active AND s.kind IN ('new','action') GROUP BY s.key ORDER BY s.sort`),
    db.query(`
      SELECT e.full_name, count(x.id)::int AS actions, count(x.id) FILTER (WHERE x.stage IN ('meeting','after_meeting'))::int AS meetings,
             (SELECT count(*) FROM ex_units u WHERE u.sales_id = e.id AND u.status <> 'cancelled' AND ${IN_RANGE('u.created_at', '$1', '$2')})::int AS res
        FROM lead_actions x JOIN employees e ON e.id = x.by_id
       WHERE x.parent_id IS NULL AND NOT x.auto AND ${IN_RANGE('x.created_at', '$1', '$2')}
       GROUP BY e.id ORDER BY actions DESC LIMIT 5`, [month, t]),
    db.query(`
      SELECT l.id, l.full_name, l.created_at, s.name_ar AS stage_name, s.kind, l.assigned_to, e.full_name AS sales, ch.name AS channel, p.name AS project
        FROM leads l LEFT JOIN lead_stages s ON s.key = l.stage LEFT JOIN employees e ON e.id = l.assigned_to
        LEFT JOIN lead_channels ch ON ch.id = l.channel_id LEFT JOIN commission_projects p ON p.id = l.project_id
       ORDER BY l.created_at DESC LIMIT 6`),
    db.query(`
      SELECT l.next_at, l.full_name, e.full_name AS sales FROM leads l LEFT JOIN employees e ON e.id = l.assigned_to
       WHERE l.stage IN ('meeting','reschedule') AND l.next_at >= $1 AND l.next_at < $1::timestamptz + interval '14 days'
       ORDER BY l.next_at LIMIT 5`, [now]),
    db.query(`
      SELECT x.due_at, x.title, e.full_name AS who FROM tasks x JOIN employees e ON e.id = x.assigned_to
       WHERE x.status IN ('open','doing') AND x.due_at >= $1 AND x.due_at < $1::timestamptz + interval '14 days'
       ORDER BY x.due_at LIMIT 5`, [now]),
    db.query(`
      SELECT e.full_name, count(*)::int AS n FROM leads l JOIN employees e ON e.id = l.assigned_to
       WHERE ${OPEN_SQL} AND l.next_at IS NOT NULL AND ${LEAD_LATE('$1::timestamptz')} GROUP BY e.id ORDER BY n DESC LIMIT 4`, [now]),
    one(db, `SELECT count(DISTINCT e.id)::int AS n FROM sessions s JOIN employees e ON e.id = s.employee_id
               JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key) AND rp.perm_key = 'leads.own'
              WHERE s.revoked_at IS NULL AND s.last_seen_at > $1::timestamptz - interval '10 minutes' AND e.status = 'active'`, [now]),
  ]);
  const won = k.res_month + k.deals_month;
  const target = k.t_res + k.t_deals;
  const pct = target ? Math.min(1, won / target) : 0;
  const newSeries = bucket(daily.rows.map((x) => ({ day: ds(x.day), v: n(x.new) })), range);
  const actSeries = bucket(daily.rows.map((x) => ({ day: ds(x.day), v: n(x.actions) })), range);
  const resSeries = bucket(daily.rows.map((x) => ({ day: ds(x.day), v: n(x.res) })), range);
  const totalNew = daily.rows.reduce((s2, x) => s2 + n(x.new), 0);
  const days = daily.rows.length || 1;
  const avgNew = r2(totalNew / days);
  const best = newSeries.reduce((b, x) => (x.value > (b?.value ?? -1) ? x : b), null as any);
  const maxActions = Math.max(1, ...ranked.rows.map((x) => n(x.actions)));
  const open = stages.rows.filter((x) => n(x.n) > 0);
  const coming = [
    ...meetings.rows.map((x) => ({ day: local(new Date(x.next_at)).date, title: `ميتنج ${x.full_name}`, sub: x.sales ?? 'مش متوزع', tone: 'accent' })),
    ...tasksSoon.rows.map((x) => ({ day: local(new Date(x.due_at)).date, title: x.title, sub: `مهمة · ${x.who}`, tone: 'info' })),
  ].sort((x, y) => x.day.localeCompare(y.day)).slice(0, 5);
  const onlineN = n(online?.n);
  return {
    summary: [
      `${k.new_today} ليد جديد النهارده`,
      k.late ? `${k.late} متابعة متأخرة` : '',
      k.unassigned ? `${k.unassigned} مش متوزع` : '',
      `${onlineN} من السيلز متصل`,
    ].filter(Boolean),
    kpis: [
      { label: 'حجوزات وتعاقدات الشهر', value: won, format: 'count', highlight: true, progress: target ? r2(pct) : null,
        foot: `${k.res_month} حجز · ${k.deals_month} تعاقد${target ? ` · التارجت ${target}` : ''}`, route: 'sales', icon: 'handshake' },
      { label: 'ليدز جديدة النهارده', value: k.new_today, format: 'count', foot: `${k.new_month} الشهر ده`, route: 'leads_fresh', icon: 'lead' },
      { label: 'متابعات متأخرة', value: k.late, format: 'count', foot: k.unassigned ? `${k.unassigned} مش متوزع` : 'كله متوزع',
        route: 'leads_delay', icon: 'late', tone: k.late ? 'warn' : null },
      { label: 'أكشنز النهارده', value: k.actions_today, format: 'count', foot: `${k.answered_today} رد · ${k.no_answer_today} مردّش`, route: 'leads', icon: 'phone' },
    ],
    chart: {
      title: 'الليدز اليومية', sub: 'الليدز الجديدة كل يوم — الخط المتقطع هو المتوسط', unit: 'count',
      chips: [{ key: 'new', label: 'ليدز جديدة' }, { key: 'actions', label: 'الأكشنز' }, { key: 'res', label: 'الحجوزات' }],
      series: { new: newSeries, actions: actSeries, res: resSeries },
      target: Math.round(avgNew), targetLabel: 'المتوسط',
      stats: [
        { label: 'ليدز الفترة', value: totalNew, format: 'count' },
        { label: 'المتوسط في اليوم', value: avgNew, format: 'count', dashed: true },
        { label: 'أكشنز الفترة', value: daily.rows.reduce((s2, x) => s2 + n(x.actions), 0), format: 'count' },
        { label: 'أعلى يوم', value: best?.value ?? 0, format: 'count', day: best?.day ?? null },
      ],
      route: 'leads_all',
    },
    pipeline: {
      title: 'الليدز المفتوحة', sub: `${k.open} ليد حسب المرحلة`, route: 'leads_list',
      rows: open.slice(0, 6).map((x, i) => ({ label: x.name_ar, value: n(x.n), tone: i === 0 ? 'accent' : (STAGE_TONE[x.kind] ?? 'info') })),
      footer: { icon: 'people', strong: `${k.unassigned}`, text: 'ليد مش متوزع على سيلز' },
      button: 'لوحة السيلز',
    },
    ranked: {
      title: 'أنشط السيلز', sub: 'الشهر ده — عدد الأكشنز', route: 'leads',
      rows: ranked.rows.map((x) => ({ title: x.full_name, sub: `${x.meetings} ميتنج · ${x.res} حجز`, value: x.actions, format: 'count',
        progress: r2(n(x.actions) / maxActions) })),
      empty: 'لسه مفيش أكشنز الشهر ده',
    },
    latest: {
      title: 'أحدث الليدز', sub: 'آخر اللي نزل', route: 'leads_list',
      rows: latest.rows.map((x) => ({ kind: 'lead', id: x.id, title: x.full_name, at: x.created_at, amount: null,
        sub: [x.channel ?? 'من غير قناة', x.project, x.sales ?? 'مش متوزع'].filter(Boolean).join(' · '),
        status: x.assigned_to ? (x.stage_name ?? '') : 'مش متوزع', tone: x.assigned_to ? (STAGE_TONE[x.kind] ?? 'info') : 'bad' })),
      empty: 'لسه مفيش ليدز',
    },
    wallet: {
      title: 'المبيعات', label: 'قيمة التعاقدات الشهر ده', value: n(k.deals_value_month), format: 'money',
      spark: daily.rows.map((x) => n(x.value)),
      rows: [{ label: 'حجوزات الشهر', value: k.res_month, format: 'count' }, { label: 'صفقات مفتوحة', value: k.deals_open, format: 'count' }],
      button: { label: 'لوحة السيلز', route: 'leads' },
      warn: k.waiting > 0 ? { label: `${k.waiting} ليد مستني سيلز متصل`, route: 'leads_unassigned' } : null,
      route: 'sales',
    },
    ring: {
      title: 'التارجت', sub: target ? 'الحجوزات والتعاقدات قدام تارجت الشهر' : 'لسه مفيش تارجت متحدد للشهر ده', pct,
      center: target ? `${Math.round(pct * 100)}٪` : '—', centerSub: 'تحقيق التارجت',
      stats: [
        { label: 'الحجوزات', value: k.res_month, format: 'count', of: k.t_res || null, tone: 'good' },
        { label: 'التعاقدات', value: k.deals_month, format: 'count', of: k.t_deals || null },
        { label: 'السيلز المتصلين', value: onlineN, format: 'count', of: k.sales_people },
      ],
      extra: [
        { label: 'متوسط سرعة الرد على الليد (دقيقة) — آخر 7 أيام', value: n(k.response_min), format: 'count' },
        { label: 'ليدز مفتوحة', value: k.open, format: 'count' },
      ],
      route: 'leads_targets',
    },
    coming: { title: 'الجاي', sub: 'ميتنجات ومهام الأسبوعين الجايين', route: 'leads_calendar', rows: coming, empty: 'مفيش ميتنجات ولا مهام جاية' },
    attention: {
      title: 'محتاج انتباه', sub: 'السيلز', route: 'leads',
      rows: [
        k.waiting ? { icon: 'alert', title: `مستنيين سيلز متصل: ${k.waiting}`, sub: 'محدش من السيلز المختارين فاتح — وزّعهم أو هيروحوا لأول واحد يفتح',
          button: 'وزّع', route: 'leads_unassigned' } : null,
        k.unassigned - k.waiting > 0 ? { icon: 'people', title: `مش متوزعين: ${k.unassigned - k.waiting}`, sub: 'ليدز من غير سيلز', button: 'وزّع', route: 'leads_unassigned' } : null,
        k.late ? { icon: 'late', title: `متابعات متأخرة: ${k.late}`, sub: lateBy.rows.map((x) => `${x.full_name} (${x.n})`).join('، '), button: 'متابعة', route: 'leads_delay' } : null,
        k.tasks_late ? { icon: 'calendar', title: `مهام متأخرة: ${k.tasks_late}`, sub: 'عدّى ميعادها ولسه مفتوحة', button: 'المهام', route: 'tasks' } : null,
      ].filter(Boolean),
      empty: 'كله تمام في السيلز',
    },
  };
}

function fmt(v: number) { return `${Math.round(v).toLocaleString('en-US')} جنيه`; }
function short(v: number) {
  const a = Math.abs(v);
  const s = a >= 1e6 ? `${(a / 1e6).toFixed(a >= 1e7 ? 0 : 1)}م` : a >= 1e3 ? `${(a / 1e3).toFixed(a >= 1e4 ? 0 : 1)}ك` : `${Math.round(a)}`;
  return v < 0 ? `-${s}` : s;
}

export const ownerDashboardModule: Module = (r, { db, clock }) => {
  /** «الموظفين دلوقتي» at the end of the attendance page: for HR and the admin officer (the owner / GM have it on their dashboard) */
  r.get('/dashboard/presence', async (req) => {
    const a = await authenticate(db, req);
    // the administrative officer by his position (whatever its key — adminOfficerSql), not by a fixed key
    const me = await one(db, `SELECT e.role_key, ${adminOfficerSql('e')} AS admin_officer FROM employees e WHERE e.id = $1`, [a.id]);
    const hrSide = !!me && (me.role_key === 'hr_manager' || me.admin_officer === true);
    if (!hrSide && !canOffice(a)) throw forbidden();
    return ok({ presence: await employeesPresence(db, local(clock()).date, clock()), hr: hrSide });
  });

  r.get('/dashboard/owner', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden();
    const t = local(clock()).date;
    const range = [14, 30, 91].includes(Number(req.query.get('range'))) ? Number(req.query.get('range')) : 14;
    const v = req.query.get('view');
    const view = v === 'employees' || v === 'sales' ? v : 'finance';
    const from = addDays(t, -(range - 1));
    const [me, last] = await Promise.all([
      one(db, `SELECT full_name FROM employees WHERE id = $1`, [a.id]),
      one(db, `SELECT l.action, l.at, e.full_name AS actor FROM audit_log l LEFT JOIN employees e ON e.id = l.actor_id ORDER BY l.id DESC LIMIT 1`),
    ]);
    const body: Card = view === 'finance' ? redactFinance(await financeView(db, a, t, range, from), a)
      : view === 'sales' ? await salesView(db, t, range, from, clock()) : await employeesView(db, t, range, from, clock());
    return ok({ view, date: t, range, name: me?.full_name ?? '', ...body, last: last ? { action: last.action, at: last.at, actor: last.actor } : null });
  });
};
