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
  'sale_installments', 'unit_sales', 'commission_requests', 'commission_projects',
];
const CONFIRM = 'امسح البيانات';

const digits = (v: unknown) => String(v ?? '').replace(/\D/g, '').replace(/^(20|0020)/, '').replace(/^(?!0)(1\d{9})$/, '0$1');
const norm = (v: unknown) => String(v ?? '').replace(/[ًٌٍَُِّْـ]/g, '').replace(/[إأآ]/g, 'ا').replace(/ى/g, 'ي').replace(/ة/g, 'ه')
  .replace(/چ/g, 'ج').replace(/\s+/g, ' ').trim().toLowerCase();
const isDay = (v: unknown) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v);
const isTime = (v: unknown) => typeof v === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(v);

export const dataResetModule: Module = (r, { db }) => {
  r.post('/admin/data-reset', async (req) => {
    const a = await authenticate(db, req);
    if (a.role !== 'owner') throw forbidden('Only the owner can reset the data');
    const b = obj(req.body);
    const dryRun = b.dryRun !== false;
    const people = Array.isArray(b.employees) ? b.employees.map((x) => obj(x)) : [];
    const rows = Array.isArray(b.attendance) ? b.attendance.map((x) => obj(x)) : [];
    if (rows.length > 5000) throw invalid('Too many rows');

    // match each old employee to a current one: phone first, then the name
    const current = (await db.query(`SELECT id, full_name, phone, status FROM employees`)).rows;
    const byPhone = new Map(current.filter((e) => e.phone).map((e) => [digits(e.phone), e]));
    const byName = new Map(current.map((e) => [norm(e.full_name), e]));
    const match = new Map<string, any>();
    const report = people.map((p) => {
      const e = (p.phone && byPhone.get(digits(p.phone))) || byName.get(norm(p.name));
      if (e) match.set(String(p.key), e);
      return { key: p.key, oldName: p.name, matched: e ? { id: e.id, name: e.full_name, status: e.status } : null };
    });
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
