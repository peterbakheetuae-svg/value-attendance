import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { forbidden, invalid, notFound } from '../http/errors.ts';
import { monthParam, isUuid } from '../http/validate.ts';
import { assertCanRead, authenticate, has, readableIds, teamMemberIds, type Actor } from '../auth/context.ts';
import { addMonths, local } from '../lib/time.ts';
import { workbook, XLSX_MIME, type Cell } from '../lib/xlsx.ts';
import { computeMonth, type MonthSummary } from './attendance-calc.ts';
import { ensurePeriod, loadPeriod } from './kpi.ts';
import { overall } from './evaluations.ts';

export interface EmployeeMonthly {
  employee: { id: string; code: string; fullName: string; jobTitle: string; departmentName: string | null; teamName: string | null; salesManagerName: string | null };
  period: string; complete: boolean;
  attendance: MonthSummary;
  requests: { total: number; approved: number; rejected: number; pending: number; cancelled: number; hourlyPermissions: number; absenceRequests: number };
  kpi: { status: string; target: number | null; actual: number | null; achievementPercent: number | null; weightedScore: number | null;
         previousWeightedScore: number | null; change: number | null; items: any[] } | null;
  evaluation: { managerScore: number | null; hrScore: number | null; strengths: string; improvements: string; comments: string; recommendations: string;
                status: 'published' | 'not_evaluated' };
  summary: { attendanceStatus: string; kpiStatus: string; evaluationStatus: string; overallPercent: number | null; components: string[] };
}

function attendanceStatus(a: MonthSummary): string {
  if (!a.workingDays) return 'no_working_days';
  if ((a.attendancePercent ?? 0) >= 95 && a.unapprovedAbsenceDays === 0 && a.lateArrivals <= 2) return 'good';
  if ((a.attendancePercent ?? 0) >= 85) return 'needs_attention';
  return 'poor';
}

export async function employeeMonthly(q: Q, employeeId: string, period: string, today: string, opts: { kpi: boolean; evaluation: boolean }): Promise<EmployeeMonthly> {
  const e = await one(q, `
    SELECT e.id, e.code, e.full_name, e.job_title, d.name_ar AS department_name, t.name AS team_name, m.full_name AS manager_name
      FROM employees e LEFT JOIN departments d ON d.id = e.department_id LEFT JOIN teams t ON t.id = e.team_id
      LEFT JOIN employees m ON m.id = e.sales_manager_id WHERE e.id = $1`, [employeeId]);
  if (!e) throw notFound();
  const { summary: att } = await computeMonth(q, employeeId, period, today);
  const end = addMonths(period, 1);
  const rq = await one(q, `
    SELECT count(*)::int AS total,
           count(*) FILTER (WHERE status = 'approved')::int AS approved,
           count(*) FILTER (WHERE status = 'rejected')::int AS rejected,
           count(*) FILTER (WHERE status IN ('pending_manager','pending_hr'))::int AS pending,
           count(*) FILTER (WHERE status = 'cancelled')::int AS cancelled,
           count(*) FILTER (WHERE type IN ('hourly_permission','short_leave','emergency_permission'))::int AS hourly,
           count(*) FILTER (WHERE type = 'full_day_absence')::int AS absence
      FROM requests WHERE employee_id = $1
       AND COALESCE(day, start_date, correction_date) >= $2 AND COALESCE(day, start_date, correction_date) < $3`, [employeeId, period, end]);

  let kpi: EmployeeMonthly['kpi'] = null;
  if (opts.kpi) {
    if (period <= today.slice(0, 7) + '-01') await ensurePeriod(q, employeeId, period);
    const cur = await loadPeriod(q, employeeId, period);
    const prev = await loadPeriod(q, employeeId, addMonths(period, -1));
    const evaluated = cur.items.filter((i) => i.actual !== null);
    // target/actual are only summed when every item shares one unit — otherwise they are not comparable
    const units = new Set(cur.items.map((i) => i.measurementType));
    const sameUnit = units.size === 1 && evaluated.length === cur.items.length && cur.items.length > 0;
    kpi = {
      status: cur.status,
      target: sameUnit ? cur.items.reduce((s, i) => s + i.target, 0) : null,
      actual: sameUnit ? evaluated.reduce((s, i) => s + (i.actual as number), 0) : null,
      achievementPercent: cur.weightedScore !== null && cur.evaluatedWeight ? Math.round((cur.weightedScore / cur.evaluatedWeight) * 1000) / 10 : null,
      weightedScore: cur.weightedScore,
      previousWeightedScore: prev.weightedScore,
      change: cur.weightedScore !== null && prev.weightedScore !== null ? Math.round((cur.weightedScore - prev.weightedScore) * 100) / 100 : null,
      items: cur.items,
    };
  }

  let evaluation: EmployeeMonthly['evaluation'] = { managerScore: null, hrScore: null, strengths: '', improvements: '', comments: '', recommendations: '', status: 'not_evaluated' };
  if (opts.evaluation) {
    const evs = (await q.query(`SELECT * FROM evaluations WHERE employee_id = $1 AND period = $2 AND status = 'published'`, [employeeId, period])).rows;
    const mgr = evs.find((x) => x.evaluator_kind === 'manager');
    const hr = evs.find((x) => x.evaluator_kind === 'hr') ?? evs.find((x) => x.evaluator_kind === 'owner');
    if (evs.length) {
      evaluation = {
        managerScore: mgr ? overall(mgr) : null, hrScore: hr ? overall(hr) : null,
        strengths: evs.map((x) => x.strengths).filter(Boolean).join('\n'),
        improvements: evs.map((x) => x.improvements).filter(Boolean).join('\n'),
        comments: evs.map((x) => x.feedback).filter(Boolean).join('\n'),
        recommendations: mgr?.improvement_plan || hr?.improvement_plan || '',
        status: 'published',
      };
    }
  }

  const components: string[] = []; const parts: number[] = [];
  if (att.attendancePercent !== null) { components.push('attendance'); parts.push(att.attendancePercent); }
  if (kpi?.achievementPercent !== null && kpi?.achievementPercent !== undefined && kpi.status !== 'not_evaluated') { components.push('kpi'); parts.push(Math.min(kpi.achievementPercent, 100)); }
  const evalScore = evaluation.managerScore ?? evaluation.hrScore;
  if (evalScore !== null) { components.push('evaluation'); parts.push(evalScore); }

  return {
    employee: { id: e.id, code: e.code, fullName: e.full_name, jobTitle: e.job_title, departmentName: e.department_name, teamName: e.team_name, salesManagerName: e.manager_name },
    period, complete: att.complete, attendance: att,
    requests: { total: rq.total, approved: rq.approved, rejected: rq.rejected, pending: rq.pending, cancelled: rq.cancelled, hourlyPermissions: rq.hourly, absenceRequests: rq.absence },
    kpi, evaluation,
    summary: {
      attendanceStatus: attendanceStatus(att),
      kpiStatus: kpi ? (kpi.status === 'completed' && (kpi.achievementPercent ?? 0) < 100 ? 'below_target' : kpi.status) : 'hidden',
      evaluationStatus: evaluation.status,
      overallPercent: parts.length ? Math.round((parts.reduce((s, v) => s + v, 0) / parts.length) * 10) / 10 : null,
      components,
    },
  };
}

type Mode = 'full' | 'payroll';

/** Who may see which employees, and in which mode. */
async function reportScope(q: Q, a: Actor): Promise<{ ids: string[] | null; mode: Mode }> {
  if (has(a, 'report.read_all')) return { ids: null, mode: 'full' };
  if (has(a, 'report.read_team')) return { ids: await teamMemberIds(q, a.id), mode: 'full' };
  if (has(a, 'report.payroll')) return { ids: null, mode: 'payroll' };
  return { ids: [a.id], mode: 'full' };
}

async function filteredEmployees(q: Q, a: Actor, query: URLSearchParams, ids: string[] | null) {
  const vals: unknown[] = []; const where = [`e.status = 'active'`];
  if (ids) { vals.push(ids); where.push(`e.id = ANY($${vals.length}::uuid[])`); }
  for (const [k, col] of [['employeeId', 'e.id'], ['departmentId', 'e.department_id'], ['teamId', 'e.team_id'], ['salesManagerId', 'e.sales_manager_id']] as const) {
    const v = query.get(k);
    if (v) { if (!isUuid(v)) throw invalid(`${k} must be an id`); vals.push(v); where.push(`${col} = $${vals.length}`); }
  }
  const rows = await q.query(`SELECT e.id FROM employees e WHERE ${where.join(' AND ')} ORDER BY e.full_name`, vals);
  return rows.rows.map((x) => x.id as string);
}

async function payrollRows(q: Q, a: Actor, ids: string[], period: string, today: string) {
  const canSalary = has(a, 'employee.salary_read');
  const out = [];
  for (const id of ids) {
    const e = await one(q, `SELECT e.id, e.code, e.full_name, e.job_title, s.base_salary FROM employees e
                             LEFT JOIN employee_salaries s ON s.employee_id = e.id WHERE e.id = $1`, [id]);
    const { summary } = await computeMonth(q, id, period, today);
    const adj = await one(q, `SELECT COALESCE(sum(amount_egp) FILTER (WHERE kind = 'deduction'),0) AS deductions,
                                     COALESCE(sum(amount_egp) FILTER (WHERE kind = 'bonus'),0) AS bonuses
                                FROM salary_adjustments WHERE employee_id = $1 AND period = $2 AND status = 'approved'`, [id, period]);
    out.push({
      employee: { id: e.id, code: e.code, fullName: e.full_name, jobTitle: e.job_title },
      attendance: {
        workingDays: summary.workingDays, attendedDays: summary.attendedDays, approvedAbsenceDays: summary.approvedAbsenceDays,
        unpaidAbsenceDays: summary.unpaidAbsenceDays, unapprovedAbsenceDays: summary.unapprovedAbsenceDays,
        lateMinutes: summary.lateMinutes, earlyMinutes: summary.earlyMinutes, overtimeMinutes: summary.overtimeMinutes,
        hourlyPermissionMinutes: summary.hourlyPermissionMinutes, complete: summary.complete,
      },
      // money is EGP only, and kept apart from any non-financial totals
      money: { currency: 'EGP', baseSalary: canSalary ? e.base_salary ?? null : undefined,
        approvedDeductions: adj.deductions, approvedBonuses: adj.bonuses },
    });
  }
  return out;
}

const AR_STATUS: Record<string, string> = {
  good: 'جيد', needs_attention: 'يحتاج متابعة', poor: 'ضعيف', no_working_days: 'لا توجد أيام عمل',
  completed: 'مكتمل', in_progress: 'قيد التنفيذ', not_evaluated: 'لم يُقيَّم', below_target: 'أقل من المستهدف',
  no_kpis: 'لا توجد مؤشرات', hidden: '—', published: 'منشور',
};

export const reportsModule: Module = (r, { db, clock }) => {
  const today = () => local(clock()).date;

  r.get('/reports/monthly/employee/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const period = monthParam(req.query.get('month'));
    const { ids, mode } = await reportScope(db, a);
    if (req.params.id !== a.id) {
      if (mode === 'payroll') throw forbidden('Use the payroll summary');
      if (ids && !ids.includes(req.params.id)) throw notFound('Employee not found');
    }
    return ok({ report: await employeeMonthly(db, req.params.id, period, today(), { kpi: true, evaluation: true }) });
  });

  r.get('/reports/monthly', async (req) => {
    const a = await authenticate(db, req);
    const period = monthParam(req.query.get('month'));
    const { ids, mode } = await reportScope(db, a);
    if (mode === 'payroll') throw forbidden('Use the payroll summary');
    const list = await filteredEmployees(db, a, req.query, ids);
    const reports = [];
    for (const id of list) reports.push(await employeeMonthly(db, id, period, today(), { kpi: true, evaluation: true }));
    const complete = reports.length ? reports[0].complete : addMonths(period, 1) <= today();
    return ok({ period, complete, count: reports.length, reports });
  });

  r.get('/reports/payroll', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'report.payroll') && !has(a, 'report.read_all')) throw forbidden();
    const period = monthParam(req.query.get('month'));
    const list = await filteredEmployees(db, a, req.query, null);
    const rows = await payrollRows(db, a, list, period, today());
    return ok({ period, complete: addMonths(period, 1) <= today(), currency: 'EGP', rows });
  });

  r.get('/reports/monthly.xlsx', async (req) => {
    const a = await authenticate(db, req);
    const period = monthParam(req.query.get('month'));
    const { ids, mode } = await reportScope(db, a);
    if (mode === 'payroll') throw forbidden('Use the payroll export');
    const list = await filteredEmployees(db, a, req.query, ids);
    const rows: Cell[][] = [];
    for (const id of list) {
      const m = await employeeMonthly(db, id, period, today(), { kpi: true, evaluation: true });
      const at = m.attendance;
      rows.push([m.employee.code, m.employee.fullName, m.employee.jobTitle, m.employee.teamName, at.workingDays, at.attendedDays,
        at.absenceDays, at.approvedAbsenceDays, at.unapprovedAbsenceDays, at.lateArrivals, at.earlyDepartures,
        Math.round(at.workedMinutes / 6) / 10, Math.round(at.overtimeMinutes / 6) / 10, at.hourlyPermissions, at.attendancePercent,
        m.requests.total, m.requests.approved, m.requests.rejected, m.requests.pending,
        m.kpi?.weightedScore ?? null, m.kpi?.achievementPercent ?? null, m.kpi?.change ?? null,
        m.evaluation.managerScore, m.evaluation.hrScore,
        AR_STATUS[m.summary.attendanceStatus], AR_STATUS[m.summary.kpiStatus], AR_STATUS[m.summary.evaluationStatus] ?? m.summary.evaluationStatus,
        m.summary.overallPercent]);
    }
    const complete = addMonths(period, 1) <= today();
    const header = ['الكود', 'الاسم', 'الوظيفة', 'الفريق', 'أيام العمل', 'أيام الحضور', 'أيام الغياب', 'غياب معتمد', 'غياب غير معتمد',
      'مرات التأخير', 'انصراف مبكر', 'ساعات العمل', 'ساعات إضافية', 'أذونات الساعات', 'نسبة الحضور %',
      'إجمالي الطلبات', 'طلبات معتمدة', 'طلبات مرفوضة', 'طلبات معلقة',
      'درجة KPI الموزونة', 'نسبة تحقيق KPI %', 'التغير عن الشهر السابق', 'تقييم المدير %', 'تقييم الموارد البشرية %',
      'حالة الحضور', 'حالة KPI', 'حالة التقييم', 'الأداء العام %'];
    const info = [[`الفترة`, period.slice(0, 7)], ['حالة الفترة', complete ? 'مكتملة' : 'غير مكتملة — الشهر لم ينتهِ بعد'], ['تاريخ الإصدار', today()]];
    const buf = workbook([
      { name: 'التقرير الشهري', header, rows, rtl: true },
      { name: 'معلومات', header: ['البند', 'القيمة'], rows: info, rtl: true },
    ]);
    return { binary: buf, contentType: XLSX_MIME, fileName: `monthly-report-${period.slice(0, 7)}.xlsx` };
  });

  r.get('/reports/payroll.xlsx', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'report.payroll') && !has(a, 'report.read_all')) throw forbidden();
    const period = monthParam(req.query.get('month'));
    const list = await filteredEmployees(db, a, req.query, null);
    const data = await payrollRows(db, a, list, period, today());
    const canSalary = has(a, 'employee.salary_read');
    const header = ['الكود', 'الاسم', 'أيام العمل', 'أيام الحضور', 'غياب معتمد', 'منها بدون مرتب', 'غياب غير معتمد',
      'دقائق التأخير', 'دقائق الانصراف المبكر', 'دقائق إضافية', 'دقائق الأذونات',
      ...(canSalary ? ['المرتب الأساسي (EGP)'] : []), 'خصومات معتمدة (EGP)', 'مكافآت معتمدة (EGP)'];
    const rows = data.map((d) => [d.employee.code, d.employee.fullName, d.attendance.workingDays, d.attendance.attendedDays,
      d.attendance.approvedAbsenceDays, d.attendance.unpaidAbsenceDays, d.attendance.unapprovedAbsenceDays,
      d.attendance.lateMinutes, d.attendance.earlyMinutes, d.attendance.overtimeMinutes, d.attendance.hourlyPermissionMinutes,
      ...(canSalary ? [d.money.baseSalary ?? null] : []), d.money.approvedDeductions, d.money.approvedBonuses] as Cell[]);
    const buf = workbook([{ name: 'ملخص الرواتب', header, rows, rtl: true }]);
    return { binary: buf, contentType: XLSX_MIME, fileName: `payroll-${period.slice(0, 7)}.xlsx` };
  });
};

export { readableIds, assertCanRead };
