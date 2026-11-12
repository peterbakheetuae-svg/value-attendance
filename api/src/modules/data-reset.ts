import { ok, type Module } from '../ctx.ts';
import { one } from '../db.ts';
import { forbidden, invalid } from '../http/errors.ts';
import { obj } from '../http/validate.ts';
import { audit, authenticate } from '../auth/context.ts';
import { cairoInstant } from '../lib/time.ts';
import { scheduleFor } from './attendance.ts';

/**
 * One-time start-over (the owner only): wipes the activity — attendance, requests, notifications, KPI results and
 * evaluations, every financial record (advances, payouts, adjustments, cashboxes, sales, commissions, payroll
 * batches) and the earlier forms — and keeps the employees exactly as they are, their files, salaries and leave
 * entitlements, the custody (items + assets), the settings and the audit log.
 * Then it brings in attendance from the old app: one row per worked day (check-in / check-out). Days with no row
 * are absences by the normal rules (working day, no leave).
 *
 * `dryRun: true` (the default) only matches the old employees to the current ones and reports; nothing changes.
 */
const WIPE = [
  'attendance_breaks', 'attendance_corrections', 'attendance_selfies', 'attendance', 'tracking_pings', 'tracking_state',
  'request_actions', 'requests', 'outing_requests', 'notifications', 'kpi_results', 'evaluations',
  'salary_adjustments', 'advance_deductions', 'payouts', 'advance_requests', 'payroll_batch_lines', 'payroll_batches',
  'commission_entitlements', 'cash_receipts', 'cash_expenses', 'cash_transfers', 'cash_adjustments',
  'sale_installments', 'unit_sales', 'commission_requests', 'commission_projects', 'ex_payments', 'ex_installments', 'ex_commission_transfers', 'ex_units', 'marketing_companies', 'developers',
];
const CONFIRM = 'امسح البيانات';

const digits = (v: unknown) => String(v ?? '').replace(/\D/g, '').replace(/^(20|0020)/, '').replace(/^(?!0)(1\d{9})$/, '0$1');
const norm = (v: unknown) => String(v ?? '').replace(/[ًٌٍَُِّْـ]/g, '').replace(/[إأآ]/g, 'ا').replace(/ى/g, 'ي').replace(/ة/g, 'ه')
  .replace(/چ/g, 'ج').replace(/\s+/g, ' ').trim().toLowerCase();
const isDay = (v: unknown) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v);
const isTime = (v: unknown) => typeof v === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(v);

export const dataResetModule: Module = (r, { db }) => {
  /** match each old employee to a current one: phone first, then the name */
  async function matchPeople(people: Record<string, unknown>[]) {
    const current = (await db.query(`SELECT id, full_name, phone, status FROM employees`)).rows;
    const byPhone = new Map(current.filter((e) => e.phone).map((e) => [digits(e.phone), e]));
    const byName = new Map(current.map((e) => [norm(e.full_name), e]));
    const match = new Map<string, any>();
    const report = people.map((p) => {
      const e = (p.phone && byPhone.get(digits(p.phone))) || byName.get(norm(p.name));
      if (e) match.set(String(p.key), e);
      return { key: p.key, oldName: p.name, matched: e ? { id: e.id, name: e.full_name, status: e.status } : null };
    });
    return { match, report };
  }

  /**
   * Approved hourly permissions (إذن ساعات) from the old app → approved requests here, so the late arrival they
   * covered is neither counted as late nor deducted. Each one is kept inside the employee's working hours.
   * The owner only; `dryRun: true` (the default) only reports.
   */
  r.post('/admin/import-permissions', async (req) => {
    const a = await authenticate(db, req);
    if (a.role !== 'owner') throw forbidden('Only the owner can import');
    const b = obj(req.body);
    const dryRun = b.dryRun !== false;
    const people = Array.isArray(b.employees) ? b.employees.map((x) => obj(x)) : [];
    const rows = Array.isArray(b.permissions) ? b.permissions.map((x) => obj(x)) : [];
    if (rows.length > 2000) throw invalid('Too many rows');
    const { match, report } = await matchPeople(people);
    const hm = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
    const fmt = (m: number) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
    const plan: { employeeId: string; name: string; day: string; from: string; to: string; minutes: number; reason: string }[] = [];
    const skipped: unknown[] = [];
    for (const x of rows) {
      const e = match.get(String(x.key));
      if (!e || !isDay(x.day) || !isTime(x.from) || !isTime(x.to)) { skipped.push(x); continue; }
      const s0 = await scheduleFor(db, e.id);
      const start = hm(String(s0.start_time)), end = hm(String(s0.end_time));
      const from = Math.max(hm(String(x.from)), start), to = Math.min(hm(String(x.to)), end);
      if (to <= from) { skipped.push(x); continue; }
      plan.push({ employeeId: e.id, name: e.full_name, day: String(x.day), from: fmt(from), to: fmt(to), minutes: to - from,
        reason: (typeof x.reason === 'string' && x.reason.trim().length >= 3 ? x.reason.trim() : 'إذن ساعات — من التطبيق القديم').slice(0, 500) });
    }
    if (dryRun) return ok({ dryRun: true, summary: report, plan, skipped });
    const imported = await db.tx(async (q) => {
      let n = 0;
      for (const p of plan) {
        const dup = await one(q, `SELECT 1 FROM requests WHERE employee_id = $1 AND type = 'hourly_permission' AND day = $2
                                    AND from_time = $3 AND to_time = $4 AND status = 'approved'`, [p.employeeId, p.day, p.from, p.to]);
        if (dup) continue;
        const rq = await one(q, `INSERT INTO requests (employee_id, type, day, from_time, to_time, duration_minutes, reason, route, status, decided_at)
          VALUES ($1,'hourly_permission',$2,$3,$4,$5,$6,'hr_only','approved', now()) RETURNING id`,
          [p.employeeId, p.day, p.from, p.to, p.minutes, p.reason]);
        await q.query(`INSERT INTO request_actions (request_id, actor_id, stage, action, comment) VALUES ($1,$2,'hr','approve','من التطبيق القديم')`, [rq.id, a.id]);
        n++;
      }
      await audit(q, a.id, 'data.import_permissions', 'company', null, undefined, { imported: n });
      return n;
    });
    return ok({ dryRun: false, imported, plan });
  });

  /**
   * An advance already handed over before / outside the system (the owner only): approved, shown in the employee's
   * advances and deducted from that month's salary — never through a cashbox (paid_outside).
   */
  r.post('/admin/opening-advance', async (req) => {
    const a = await authenticate(db, req);
    if (a.role !== 'owner') throw forbidden('Only the owner can add it');
    const b = obj(req.body);
    const employeeId = typeof b.employeeId === 'string' ? b.employeeId : '';
    const amount = Number(b.amount);
    const month = typeof b.month === 'string' && /^\d{4}-\d{2}$/.test(b.month) ? `${b.month}-01` : '';
    if (!/^[0-9a-f-]{36}$/.test(employeeId)) throw invalid('Choose the employee', { field: 'employeeId' });
    if (!(amount > 0 && amount <= 1_000_000)) throw invalid('Enter the amount', { field: 'amount' });
    if (!month) throw invalid('Enter the month (YYYY-MM)', { field: 'month' });
    if (employeeId === a.id) throw forbidden('Nobody approves their own advance');
    const row = await db.tx(async (q) => {
      const emp = await one(q, `SELECT id FROM employees WHERE id = $1 AND status = 'active'`, [employeeId]);
      if (!emp) throw invalid('Choose the employee', { field: 'employeeId' });
      const x = await one(q, `INSERT INTO advance_requests (employee_id, kind, period, amount_egp, note, status, created_by, decided_by, decided_at,
          gm_approved_by, gm_approved_at, paid_outside)
        VALUES ($1,'advance',$2,$3,$4,'confirmed',$5,$5,now(),$5,now(),true) RETURNING *`,
        [employeeId, month, amount, (typeof b.note === 'string' && b.note.trim() ? b.note.trim() : 'سلفة مصروفة قبل كده (خارج الخزنة)').slice(0, 500), a.id]);
      await audit(q, a.id, 'advance.opening', 'advance_request', x.id, undefined, x);
      return x;
    });
    return ok({ advance: { id: row.id, amount: Number(row.amount_egp), period: row.period, paidOutside: true } }, 201);
  });

  r.post('/admin/data-reset', async (req) => {
    const a = await authenticate(db, req);
    if (a.role !== 'owner') throw forbidden('Only the owner can reset the data');
    const b = obj(req.body);
    const dryRun = b.dryRun !== false;
    const people = Array.isArray(b.employees) ? b.employees.map((x) => obj(x)) : [];
    const rows = Array.isArray(b.attendance) ? b.attendance.map((x) => obj(x)) : [];
    if (rows.length > 5000) throw invalid('Too many rows');

    const { match, report } = await matchPeople(people);
    const plan: { employeeId: string; day: string; in: string; out: string | null }[] = [];
    const skipped: unknown[] = [];
    for (const x of rows) {
      const e = match.get(String(x.key));
      if (!e || !isDay(x.day) || !isTime(x.in) || (x.out != null && !isTime(x.out))) { skipped.push(x); continue; }
      const out = x.out && String(x.out) > String(x.in) ? String(x.out) : null;
      plan.push({ employeeId: e.id, day: String(x.day), in: String(x.in), out });
    }
    const days = (id: string) => plan.filter((p) => p.employeeId === id).length;
    const summary = report.map((r0) => ({ ...r0, days: r0.matched ? days(r0.matched.id) : 0 }));
    if (dryRun) return ok({ dryRun: true, summary, rows: plan.length, skipped });

    if (b.confirm !== CONFIRM) throw invalid(`Type "${CONFIRM}" to confirm`, { field: 'confirm' });
    const done = await db.tx(async (q) => {
      const before: Record<string, number> = {};
      for (const t of WIPE) before[t] = Number((await one(q, `SELECT count(*)::int AS n FROM ${t}`)).n);
      await q.query(`TRUNCATE ${WIPE.join(', ')}`);
      await q.query(`SELECT set_config('va.form_delete', '*', true)`);
      const forms = await q.query(`DELETE FROM employee_documents WHERE kind = 'other' AND employee_id IS NOT NULL
        AND (file_name LIKE 'custody-receipt-%' OR file_name LIKE 'laptop-receipt-%' OR file_name LIKE 'client-intro-%')`);
      await q.query(`SELECT set_config('va.form_delete', '', true)`);
      await q.query(`UPDATE form_counters SET last = 0`);
      let imported = 0;
      for (const p of plan) {
        const s = await scheduleFor(q, p.employeeId);
        const inAt = cairoInstant(p.day, p.in);
        const outAt = p.out ? cairoInstant(p.day, p.out) : null;
        await q.query(`
          INSERT INTO attendance (employee_id, work_date, schedule_start, schedule_end, late_grace_minutes, early_grace_minutes,
            overtime_enabled, overtime_min_minutes, check_in_at, check_out_at, original_check_in_at, original_check_out_at, corrected, source)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$9,$10,false,'correction') ON CONFLICT (employee_id, work_date) DO NOTHING`,
          [p.employeeId, p.day, s.start_time, s.end_time, s.late_grace_minutes, s.early_grace_minutes,
           s.overtime_enabled, s.overtime_min_minutes, inAt, outAt]);
        imported++;
      }
      await audit(q, a.id, 'data.reset', 'company', null, before, { formsDeleted: forms.rowCount, attendanceImported: imported });
      return { wiped: before, formsDeleted: forms.rowCount ?? 0, attendanceImported: imported };
    });
    return ok({ dryRun: false, summary, ...done });
  });
};
