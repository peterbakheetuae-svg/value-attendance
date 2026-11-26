import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, forbidden, invalid } from '../http/errors.ts';
import { obj } from '../http/validate.ts';
import { audit, authenticate, isOwner } from '../auth/context.ts';
import { cairoInstant } from '../lib/time.ts';
import { fileHealth } from '../lib/files.ts';
import { hasBackupToken } from '../lib/backup-token.ts';
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
export const WIPE = [
  'cash_attachments', 'deals', 'lead_whatsapp', 'lead_exports', 'lead_targets', 'lead_checkins', 'lead_requests', 'lead_attachments', 'tasks', 'lead_referrals', 'lead_logs', 'lead_actions', 'leads', 'lead_campaigns',
  'attendance_breaks', 'attendance_corrections', 'attendance_selfies', 'attendance', 'tracking_pings', 'tracking_state',
  'request_actions', 'requests', 'outing_requests', 'notifications', 'kpi_results', 'evaluations',
  'salary_adjustments', 'advance_deductions', 'payouts', 'advance_requests', 'payroll_batch_lines', 'payroll_batches',
  'commission_entitlements', 'cash_receipts', 'cash_expenses', 'cash_transfers', 'cash_adjustments',
  'sale_installments', 'unit_sales', 'commission_requests', 'project_images', 'ex_inventory', 'developer_images', 'commission_projects', 'partner_units', 'partner_projects', 'ex_payments', 'ex_installments', 'ex_commission_transfers', 'ex_unit_files', 'ex_units', 'action_otps', 'partner_email_otps', 'partner_notifications', 'partner_sessions', 'meta_seen_campaigns', 'marketing_company_files', 'marketing_companies', 'developers', 'cash_bank_moves',
];
/**
 * Tables a later migration may add that hold foreign keys to WIPE tables (092 marketing intelligence:
 * lead_quality_events → leads, lead_campaign_owners → lead_campaigns / marketing_companies). PostgreSQL refuses to
 * TRUNCATE a referenced table unless every table referencing it is in the same TRUNCATE, so each one that exists joins
 * the same statement (never CASCADE: nothing outside these explicit lists is ever emptied). Before 092 none exists and
 * the reset is exactly as before.
 */
export const WIPE_IF_PRESENT = ['lead_quality_events', 'lead_campaign_owners'];
/** the WIPE_IF_PRESENT tables that exist in this database (checked inside the reset's transaction) */
export async function presentDependents(q: Q): Promise<string[]> {
  return presentTables(q, WIPE_IF_PRESENT);
}
/**
 * Activity tables of migration 092 that reference no WIPE table (so the TRUNCATE does not need them) but describe the
 * campaigns the reset removes: meta_insights_daily (Meta's daily spend / results per Meta campaign id, no foreign key).
 * Emptied with the rest of the activity when present, so a reset leaves no figures for campaigns that no longer exist.
 */
export const WIPE_ACTIVITY_IF_PRESENT = ['meta_insights_daily'];
/** the tables of `list` that exist in this database, in list order */
export async function presentTables(q: Q, list: readonly string[]): Promise<string[]> {
  return (await q.query(`SELECT t FROM unnest($1::text[]) WITH ORDINALITY AS x(t, n) WHERE to_regclass('public.' || t) IS NOT NULL ORDER BY n`,
    [list])).rows.map((r: any) => String(r.t));
}
/** WIPE plus the approved 092 tables that exist here: the tables this reset is allowed to empty with their rows */
export async function approvedWipeSet(q: Q): Promise<string[]> {
  return [...WIPE, ...await presentDependents(q), ...await presentTables(q, WIPE_ACTIVITY_IF_PRESENT)];
}

/**
 * Tables OUTSIDE `wipeSet` that hold a foreign key to a table being emptied — directly or through another such table
 * (the whole dependency graph), read from the catalogs (pg_constraint / pg_class / pg_namespace, schema public).
 * PostgreSQL refuses to TRUNCATE a referenced table unless every referencing table is in the same statement, so each of
 * these must either be empty (then it joins the TRUNCATE and nothing outside the approved scope is lost) or the reset is
 * refused. Example: brokerage_deals.lead_id → leads (migration 089). Sorted, so locks are always taken in one order.
 */
export async function externalDependentTables(q: Q, wipeSet: readonly string[]): Promise<string[]> {
  const seen = new Set(wipeSet);
  const found: string[] = [];
  let frontier = [...wipeSet];
  while (frontier.length) {
    const r = await q.query(`SELECT DISTINCT src.relname AS t
        FROM pg_constraint k
        JOIN pg_class src ON src.oid = k.conrelid JOIN pg_namespace sn ON sn.oid = src.relnamespace
        JOIN pg_class dst ON dst.oid = k.confrelid JOIN pg_namespace dn ON dn.oid = dst.relnamespace
       WHERE k.contype = 'f' AND sn.nspname = 'public' AND dn.nspname = 'public' AND dst.relname = ANY($1::text[])`, [frontier]);
    frontier = r.rows.map((x: any) => String(x.t)).filter((t) => !seen.has(t));
    for (const t of frontier) { seen.add(t); found.push(t); }
  }
  return found.sort();
}

/** catalog table names → safely quoted identifiers (quote_ident on the server; never a name pasted into SQL as is) */
async function quoted(q: Q, tables: readonly string[]): Promise<Map<string, string>> {
  const r = await q.query(`SELECT t, 'public.' || quote_ident(t) AS i FROM unnest($1::text[]) AS t`, [tables]);
  return new Map(r.rows.map((x: any) => [String(x.t), String(x.i)]));
}

/** each table with its row count (identifiers quoted) */
export async function rowCounts(q: Q, tables: readonly string[]): Promise<{ table: string; rows: number }[]> {
  const ids = await quoted(q, tables);
  const out: { table: string; rows: number }[] = [];
  for (const t of tables) out.push({ table: t, rows: Number((await one(q, `SELECT count(*)::int AS n FROM ${ids.get(t)}`)).n) });
  return out;
}

const DEPENDENT_REFUSAL = 'مسح البيانات مرفوض: فيه سجلات في جداول تانية مرتبطة بالبيانات اللي هتتمسح (ومش ضمن المسح)';
const CONFIRM = 'امسح البيانات';

const digits = (v: unknown) => String(v ?? '').replace(/\D/g, '').replace(/^(20|0020)/, '').replace(/^(?!0)(1\d{9})$/, '0$1');
const norm = (v: unknown) => String(v ?? '').replace(/[ًٌٍَُِّْـ]/g, '').replace(/[إأآ]/g, 'ا').replace(/ى/g, 'ي').replace(/ة/g, 'ه')
  .replace(/چ/g, 'ج').replace(/\s+/g, ' ').trim().toLowerCase();
const isDay = (v: unknown) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v);
const isTime = (v: unknown) => typeof v === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(v);

/**
 * D3 (owner, 2026-11-25): the reset is refused ENTIRELY when it would take protected records or protected files with it.
 * Protected records = posted money / payroll / contract history (append-only by design; the reset never erases it).
 * Protected files   = files of class 'protected' (HR, payroll, finance, contracts) still referenced by a wiped table (091).
 * Attendance, requests and other day-to-day activity stay resettable as before.
 */
const PROTECTED_RECORDS = ['cash_receipts', 'cash_expenses', 'cash_transfers', 'cash_adjustments', 'cash_bank_moves', 'payouts',
  'unit_sales', 'sale_installments', 'ex_installments', 'ex_commission_transfers', 'commission_requests', 'commission_entitlements',
  'advance_requests', 'advance_deductions', 'salary_adjustments', 'payroll_batches'];

async function resetBlockers(q: Q): Promise<{ table: string; rows: number }[]> {
  const out: { table: string; rows: number }[] = [];
  for (const t of PROTECTED_RECORDS.filter((x) => WIPE.includes(x))) {
    if (!(await one(q, `SELECT to_regclass($1) IS NOT NULL AS ok`, [`public.${t}`]))?.ok) continue;
    const n = Number((await one(q, `SELECT count(*)::int AS n FROM ${t}`)).n);
    if (n > 0) out.push({ table: t, rows: n });
  }
  if ((await one(q, `SELECT to_regclass('public.file_objects') IS NOT NULL AS ok`))?.ok) {
    const n = Number((await one(q, `SELECT count(*)::int AS n FROM file_objects WHERE ref_count = 1 AND retention_class = 'protected'`)).n);
    if (n > 0) out.push({ table: 'file_objects (protected files)', rows: n });
  }
  return out;
}

export const dataResetModule: Module = (r, { db }) => {
  /**
   * Storage health (read-only, counts only): orphan / unfinished / never-linked file records. For the owner, or the
   * scheduler's X-Backup-Token (the GitHub files-health check fails, and GitHub e-mails the owner, while `alert` is true).
   */
  r.get('/admin/files/health', async (req) => {
    if (!hasBackupToken(req.headers)) {
      const a = await authenticate(db, req);
      if (!isOwner(a)) throw forbidden('Only the owner');
    }
    return ok(await fileHealth(db));
  });

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
    // «استيراد ومسح البيانات» (data.reset): strictly an owner account — never granted, delegated or inherited
    if (!isOwner(a)) throw forbidden('Only the owner can import');
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
    if (!isOwner(a)) throw forbidden('Only the owner can add it');
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
    if (!isOwner(a)) throw forbidden('Only the owner can reset the data');
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
    const blockers = await resetBlockers(db);
    // tables outside the reset that point at what it empties: listed in the dry run; any holding rows refuses the reset
    const dependents = await rowCounts(db, await externalDependentTables(db, await approvedWipeSet(db)));
    const dependencyBlockers = dependents.filter((d) => d.rows > 0);
    if (dryRun) return ok({ dryRun: true, summary, rows: plan.length, skipped, blockers, dependents, dependencyBlockers });
    if (blockers.length) throw new AppError('conflict', 'مسح البيانات مرفوض: فيه سجلات مالية / ملفات محمية مش بتتمسح', { reason: 'protected_data', blockers });
    if (dependencyBlockers.length) throw new AppError('conflict', DEPENDENT_REFUSAL, { reason: 'dependent_records', dependents: dependencyBlockers });

    if (b.confirm !== CONFIRM) throw invalid(`Type "${CONFIRM}" to confirm`, { field: 'confirm' });
    const done = await db.tx(async (q) => {
      // re-checked inside the transaction (nothing may slip in between the check and the wipe)
      if ((await resetBlockers(q)).length) throw new AppError('conflict', 'مسح البيانات مرفوض: فيه سجلات مالية / ملفات محمية مش بتتمسح', { reason: 'protected_data' });
      const approved = await approvedWipeSet(q);
      // the dependents are locked BEFORE they are counted (no row can be added between the check and the TRUNCATE),
      // always in the same (sorted) order; any that holds rows refuses the whole reset and nothing is changed
      const external = await externalDependentTables(q, approved);
      if (external.length) {
        const ids = await quoted(q, external);
        await q.query(`LOCK TABLE ${external.map((t) => ids.get(t)).join(', ')} IN ACCESS EXCLUSIVE MODE`);
        const held = (await rowCounts(q, external)).filter((d) => d.rows > 0);
        if (held.length) throw new AppError('conflict', DEPENDENT_REFUSAL, { reason: 'dependent_records', dependents: held });
      }
      const all = [...approved, ...external];   // the external ones are empty here: they only satisfy the TRUNCATE
      const ids = await quoted(q, all);
      const before: Record<string, number> = {};
      for (const t of all) before[t] = Number((await one(q, `SELECT count(*)::int AS n FROM ${ids.get(t)}`)).n);
      await q.query(`UPDATE integrations SET campaign_id = NULL`);   // the campaigns go; the integrations' keys stay
      await q.query(`TRUNCATE ${all.map((t) => ids.get(t)).join(', ')}`);
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
