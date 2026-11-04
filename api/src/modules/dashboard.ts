import { ok, type Module } from '../ctx.ts';
import { sweep } from './tracking.ts';
import { one } from '../db.ts';
import { authenticate, has, readableIds, teamMemberIds } from '../auth/context.ts';
import { local } from '../lib/time.ts';
import { computeMonth } from './attendance-calc.ts';
import { ensurePeriod, loadPeriod } from './kpi.ts';
import { overall } from './evaluations.ts';

/** One endpoint, role-shaped by permissions. Every number comes from stored data. */
export const dashboardModule: Module = (r, { db, clock }) => {
  r.get('/dashboard', async (req) => {
    const a = await authenticate(db, req);
    await sweep(db, clock()).catch(() => { /* reminders must never break the page */ });
    const l = local(clock());
    const period = l.date.slice(0, 7) + '-01';
    const out: Record<string, unknown> = { date: l.date, period, role: a.role };

    // -------- personal block (everyone)
    const today = await one(db, `SELECT check_in_at, check_out_at FROM attendance WHERE employee_id = $1 AND work_date = $2`, [a.id, l.date]);
    const month = await computeMonth(db, a.id, period, l.date);
    const myPending = await one(db, `SELECT count(*)::int AS n FROM requests WHERE employee_id = $1 AND status IN ('pending_manager','pending_hr')`, [a.id]);
    await ensurePeriod(db, a.id, period);
    const myKpi = await loadPeriod(db, a.id, period);
    const lastEval = await one(db, `SELECT * FROM evaluations WHERE employee_id = $1 AND status = 'published' ORDER BY period DESC, published_at DESC LIMIT 1`, [a.id]);
    out.me = {
      today: today ? { checkIn: today.check_in_at, checkOut: today.check_out_at } : null,
      month: month.summary, pendingRequests: myPending.n,
      kpi: { status: myKpi.status, weightedScore: myKpi.weightedScore, items: myKpi.items.length },
      latestEvaluation: lastEval ? { period: lastEval.period, overallPercent: overall(lastEval), kind: lastEval.evaluator_kind } : null,
    };

    // -------- approvals waiting for me
    if (has(a, 'request.approve_manager') || has(a, 'request.approve_hr')) {
      const n = await one(db, `SELECT count(*)::int AS n FROM requests r WHERE r.employee_id <> $1 AND (
          (r.status = 'pending_manager' AND r.manager_id = $1 AND $2) OR (r.status = 'pending_hr' AND $3))`,
        [a.id, has(a, 'request.approve_manager'), has(a, 'request.approve_hr')]);
      out.awaitingMyApproval = n.n;
    }

    // -------- organisation / team block
    if (has(a, 'attendance.read_all') || has(a, 'attendance.read_team')) {
      const ids = await readableIds(db, a, 'attendance');
      const scopeIds = ids ? ids.filter((x) => x !== a.id) : null;
      const counts = await one(db, `
        SELECT count(*) FILTER (WHERE e.status = 'active')::int AS active,
               count(*)::int AS total,
               count(at.id) FILTER (WHERE e.status = 'active')::int AS checked_in,
               count(at.id) FILTER (WHERE at.check_out_at IS NOT NULL)::int AS checked_out,
               count(*) FILTER (WHERE e.status = 'active' AND at.id IS NULL AND ab.id IS NOT NULL)::int AS on_leave
          FROM employees e
          LEFT JOIN attendance at ON at.employee_id = e.id AND at.work_date = $1
          LEFT JOIN LATERAL (SELECT r.id FROM requests r WHERE r.employee_id = e.id AND r.type = 'full_day_absence'
                    AND r.status = 'approved' AND $1 BETWEEN r.start_date AND r.end_date LIMIT 1) ab ON true
         WHERE ($2::uuid[] IS NULL OR e.id = ANY($2::uuid[]))`, [l.date, scopeIds]);
      const holiday = await one(db, `SELECT name FROM holidays WHERE day = $1`, [l.date]);
      out.team = {
        scope: ids ? 'team' : 'company',
        totalEmployees: counts.total, activeEmployees: counts.active,
        today: { checkedIn: counts.checked_in, checkedOut: counts.checked_out, onApprovedLeave: counts.on_leave,
          notCheckedIn: Math.max(0, counts.active - counts.checked_in - counts.on_leave), holiday: holiday?.name ?? null },
      };
      const pending = await one(db, `SELECT count(*)::int AS n FROM requests WHERE status IN ('pending_manager','pending_hr')
                                       AND ($1::uuid[] IS NULL OR employee_id = ANY($1::uuid[]))`, [scopeIds]);
      (out.team as any).pendingRequests = pending.n;
      const issues = await db.query(`
        SELECT e.id, e.full_name, count(*)::int AS missing_checkouts
          FROM attendance at JOIN employees e ON e.id = at.employee_id
         WHERE at.work_date >= $1 AND at.work_date < $2 AND at.check_out_at IS NULL AND e.status = 'active'
           AND ($3::uuid[] IS NULL OR e.id = ANY($3::uuid[]))
         GROUP BY e.id ORDER BY 3 DESC LIMIT 10`, [period, l.date, scopeIds]);
      (out.team as any).attentionNeeded = issues.rows;
      const absMonth = await one(db, `SELECT count(*)::int AS requests, COALESCE(sum(days_count),0)::int AS days FROM requests
          WHERE type = 'full_day_absence' AND status = 'approved' AND start_date >= $1 AND start_date < ($1::date + interval '1 month')
            AND ($2::uuid[] IS NULL OR employee_id = ANY($2::uuid[]))`, [period, scopeIds]);
      (out.team as any).monthAbsence = absMonth;
    }

    if (has(a, 'kpi.read_all') || has(a, 'kpi.read_team')) {
      const ids = has(a, 'kpi.read_all') ? null : await teamMemberIds(db, a.id);
      const emps = await db.query(`SELECT id, full_name FROM employees WHERE status = 'active' AND role_key IN ('sales_employee','sales_manager')
                                     AND id <> $2 AND ($1::uuid[] IS NULL OR id = ANY($1::uuid[]))`, [ids, a.id]);
      let notEvaluated = 0, inProgress = 0, completed = 0, below = 0, noKpis = 0; const scores: number[] = [];
      const top: { id: string; name: string; score: number }[] = [];
      for (const e of emps.rows) {
        await ensurePeriod(db, e.id, period);
        const s = await loadPeriod(db, e.id, period);
        if (s.status === 'no_kpis') noKpis++;
        else if (s.status === 'not_evaluated') notEvaluated++;
        else if (s.status === 'in_progress') inProgress++;
        else { completed++; if (s.belowTarget) below++; }
        if (s.weightedScore !== null) { scores.push(s.weightedScore); top.push({ id: e.id, name: e.full_name, score: s.weightedScore }); }
      }
      out.kpiOverview = { employees: emps.rows.length, noKpis, notEvaluated, inProgress, completed, belowTarget: below,
        averageWeightedScore: scores.length ? Math.round((scores.reduce((s, v) => s + v, 0) / scores.length) * 10) / 10 : null,
        top: top.sort((x, y) => y.score - x.score).slice(0, 5) };
    }

    if (has(a, 'evaluation.read_all') || has(a, 'evaluation.write_team')) {
      const ids = has(a, 'evaluation.read_all') ? null : await teamMemberIds(db, a.id);
      const ev = await one(db, `
        SELECT count(DISTINCT e.id)::int AS employees,
               count(DISTINCT v.employee_id) FILTER (WHERE v.status = 'published')::int AS evaluated,
               count(DISTINCT v.employee_id) FILTER (WHERE v.status = 'draft')::int AS drafts
          FROM employees e LEFT JOIN evaluations v ON v.employee_id = e.id AND v.period = $1
         WHERE e.status = 'active' AND e.role_key IN ('sales_employee','sales_manager') AND e.id <> $3
           AND ($2::uuid[] IS NULL OR e.id = ANY($2::uuid[]))`, [period, ids, a.id]);
      out.evaluationProgress = ev;
    }

    if (has(a, 'report.payroll') || has(a, 'finance.read')) {
      const fin = await one(db, `
        SELECT COALESCE(sum(amount_egp) FILTER (WHERE kind = 'deduction' AND status = 'approved'),0) AS approved_deductions,
               COALESCE(sum(amount_egp) FILTER (WHERE kind = 'bonus' AND status = 'approved'),0) AS approved_bonuses,
               count(*) FILTER (WHERE status = 'pending')::int AS pending_adjustments
          FROM salary_adjustments WHERE period = $1`, [period]);
      const abs = await one(db, `SELECT count(*)::int AS approved_absence_requests,
               COALESCE(sum(days_count) FILTER (WHERE absence_type = 'unpaid'),0)::int AS unpaid_days
          FROM requests WHERE type = 'full_day_absence' AND status = 'approved' AND start_date >= $1 AND start_date < ($1::date + interval '1 month')`, [period]);
      out.finance = { currency: 'EGP', ...fin, ...abs };
    }

    const unread = await one(db, `SELECT count(*)::int AS n FROM notifications WHERE recipient_id = $1 AND read_at IS NULL`, [a.id]);
    out.unreadNotifications = unread.n;
    return ok(out);
  });
};
