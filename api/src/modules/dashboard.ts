import { ok, type Module } from '../ctx.ts';
import { sweep } from './tracking.ts';
import { one } from '../db.ts';
import { forbidden } from '../http/errors.ts';
import { authenticate, has, readableIds, teamMemberIds } from '../auth/context.ts';
import { local } from '../lib/time.ts';
import { computeMonth } from './attendance-calc.ts';
import { ensurePeriod, loadPeriod } from './kpi.ts';
import { overall } from './evaluations.ts';

/** One endpoint, role-shaped by permissions. Every number comes from stored data. */
export const dashboardModule: Module = (r, { db, clock }) => {
  /**
   * Admin home: company (or own team) totals for today and this month, shaped like the
   * employee home boxes. Late = checked in after schedule start + grace (Cairo time).
   */
  r.get('/dashboard/overview', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'attendance.read_all') && !has(a, 'attendance.read_team')) throw forbidden();
    await sweep(db, clock()).catch(() => { /* never break the page */ });
    const l = local(clock());
    const period = l.date.slice(0, 7) + '-01';
    const ids = await readableIds(db, a, 'attendance');
    const scope = ids ? ids.filter((x) => x !== a.id) : null;
    const lateExpr = `((at.check_in_at AT TIME ZONE 'Africa/Cairo')::time > at.schedule_start + make_interval(mins => at.late_grace_minutes))`;
    const lateMin = `GREATEST(0, EXTRACT(EPOCH FROM ((at.check_in_at AT TIME ZONE 'Africa/Cairo')::time - at.schedule_start)) / 60)`;
    const t = await one(db, `
      SELECT count(*) FILTER (WHERE e.status = 'active' AND NOT e.attendance_exempt)::int AS active,
             count(at.id)::int AS present,
             count(at.id) FILTER (WHERE ${lateExpr})::int AS late,
             count(at.id) FILTER (WHERE at.check_out_at IS NOT NULL)::int AS checked_out,
             count(*) FILTER (WHERE e.status = 'active' AND NOT e.attendance_exempt AND at.id IS NULL AND ab.id IS NOT NULL)::int AS on_leave,
             COALESCE(sum(EXTRACT(EPOCH FROM (COALESCE(at.check_out_at, now()) - at.check_in_at)) / 60)
               FILTER (WHERE at.id IS NOT NULL), 0)::int AS work_minutes
        FROM employees e
        LEFT JOIN attendance at ON at.employee_id = e.id AND at.work_date = $1
        LEFT JOIN LATERAL (SELECT r.id FROM requests r WHERE r.employee_id = e.id AND r.type = 'full_day_absence'
                  AND r.status = 'approved' AND $1 BETWEEN r.start_date AND r.end_date LIMIT 1) ab ON true
       WHERE e.status = 'active' AND NOT e.attendance_exempt AND ($2::uuid[] IS NULL OR e.id = ANY($2::uuid[]))`, [l.date, scope]);
    const out = await one(db, `SELECT count(*)::int AS n FROM outing_requests o
        WHERE o.work_date = $1 AND o.status = 'approved' AND o.returned_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM outing_requests c WHERE c.parent_id = o.id AND c.status = 'approved')
          AND ($2::uuid[] IS NULL OR o.employee_id = ANY($2::uuid[]))`, [l.date, scope]);
    const pendingOut = await one(db, `SELECT count(*)::int AS n FROM outing_requests WHERE work_date = $1 AND status = 'pending'
          AND ($2::uuid[] IS NULL OR employee_id = ANY($2::uuid[]))`, [l.date, scope]);
    const holiday = await one(db, `SELECT name FROM holidays WHERE day = $1`, [l.date]);
    const m = await one(db, `
      SELECT count(at.id)::int AS attendance_days,
             count(at.id) FILTER (WHERE ${lateExpr})::int AS late_days,
             COALESCE(sum(${lateMin}) FILTER (WHERE ${lateExpr}), 0)::int AS late_minutes
        FROM attendance at JOIN employees e ON e.id = at.employee_id
       WHERE at.work_date >= $1 AND at.work_date <= $2 AND NOT e.attendance_exempt
         AND ($3::uuid[] IS NULL OR at.employee_id = ANY($3::uuid[]))`, [period, l.date, scope]);
    const lv = await one(db, `
      SELECT COALESCE(sum(days_count) FILTER (WHERE absence_type <> 'sick'), 0)::int AS leave_days,
             COALESCE(sum(days_count) FILTER (WHERE absence_type = 'sick'), 0)::int AS sick_days,
             COALESCE(sum(days_count) FILTER (WHERE absence_type = 'unpaid'), 0)::int AS unpaid_days
        FROM requests WHERE type = 'full_day_absence' AND status = 'approved'
         AND start_date >= $1 AND start_date < ($1::date + interval '1 month')
         AND ($2::uuid[] IS NULL OR employee_id = ANY($2::uuid[]))`, [period, scope]);
    const pend = await one(db, `SELECT count(*)::int AS n FROM requests WHERE status IN ('pending_manager','pending_hr')
         AND ($1::uuid[] IS NULL OR employee_id = ANY($1::uuid[]))`, [scope]);
    const absentToday = holiday ? 0 : Math.max(0, t.active - t.present - t.on_leave);
    return ok({
      date: l.date, scope: ids ? 'team' : 'company', holiday: holiday?.name ?? null,
      today: { employees: t.active, present: t.present, late: t.late, absent: absentToday, onLeave: t.on_leave,
        checkedOut: t.checked_out, outNow: out.n, pendingOutings: pendingOut.n, workMinutes: t.work_minutes },
      month: { attendanceDays: m.attendance_days, lateDays: m.late_days, lateMinutes: m.late_minutes,
        leaveDays: lv.leave_days, sickDays: lv.sick_days, unpaidDays: lv.unpaid_days },
      pendingRequests: pend.n,
    });
  });

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

  /**
   * Monthly performance ring (حلقة الأداء): starts at 100% on the 1st and only goes down —
   * unexcused absence −5 per day, late arrival −2 per day, early leave −1 per day, approved penalty (خصم) −5 each.
   * A published evaluation for the month is averaged in. Accounts without attendance lose nothing for attendance.
   */
  r.get('/me/score', async (req) => {
    const a = await authenticate(db, req);
    const l = local(clock());
    const period = l.date.slice(0, 7) + '-01';
    const emp = await one(db, `SELECT attendance_exempt FROM employees WHERE id = $1`, [a.id]);
    const parts = { absence: 0, late: 0, early: 0, penalties: 0 };
    if (!emp.attendance_exempt) {
      const { summary } = await computeMonth(db, a.id, period, l.date);
      parts.absence = summary.unapprovedAbsenceDays * 5;
      parts.late = summary.lateArrivals * 2;
      parts.early = summary.earlyDepartures;
    }
    const pen = await one(db, `SELECT count(*)::int AS n FROM salary_adjustments
                                WHERE employee_id = $1 AND period = $2 AND kind = 'deduction' AND status = 'approved'`, [a.id, period]);
    parts.penalties = pen.n * 5;
    let score = Math.max(0, 100 - parts.absence - parts.late - parts.early - parts.penalties);
    const evs = await db.query(`SELECT * FROM evaluations WHERE employee_id = $1 AND period = $2 AND status = 'published'`, [a.id, period]);
    const evPcts = evs.rows.map(overall).filter((v): v is number => v !== null);
    const evaluation = evPcts.length ? Math.round(evPcts.reduce((x, y) => x + y, 0) / evPcts.length) : null;
    if (evaluation !== null) score = Math.round((score + evaluation) / 2);
    return ok({ period, score: Math.min(100, Math.max(0, Math.round(score))), deductions: parts, evaluation });
  });
};
