import { randomBytes } from 'node:crypto';
import { ok, type Module } from '../ctx.ts';
import { one } from '../db.ts';
import { forbidden, invalid, notFound } from '../http/errors.ts';
import { bool, date, num, obj, reqStr, str, time, uuid, isUuid } from '../http/validate.ts';
import { audit, authenticate, has, requirePerm } from '../auth/context.ts';

function dayDivisor(b: Record<string, unknown>) {
  if (b.dayDivisor === undefined) return undefined;
  if (b.dayDivisor !== 26 && b.dayDivisor !== 30) throw invalid('dayDivisor must be 26 or 30', { field: 'dayDivisor' });
  return b.dayDivisor;
}
function deductionMode(b: Record<string, unknown>) {
  if (b.deductionMode === undefined) return undefined;
  if (!['per_minute', 'tiers', 'hourly'].includes(b.deductionMode as string)) throw invalid('deductionMode must be per_minute, tiers or hourly', { field: 'deductionMode' });
  return b.deductionMode;
}
/** 0–6 tiers of { afterMinutes 1–600, amount 1–100000 }, distinct minutes. */
function tiers(b: Record<string, unknown>, field: string) {
  const v = b[field];
  if (v === undefined) return undefined;
  if (!Array.isArray(v) || v.length > 6) throw invalid(`${field} must be a list of up to 6 tiers`, { field });
  const out = v.map((t: any) => {
    const m = Number(t?.afterMinutes), a = Number(t?.amount);
    if (!Number.isInteger(m) || m < 1 || m > 600 || !Number.isFinite(a) || a <= 0 || a > 100000) throw invalid(`${field}: minutes 1–600 and a positive amount`, { field });
    return { afterMinutes: m, amount: Math.round(a * 100) / 100 };
  }).sort((x, y) => x.afterMinutes - y.afterMinutes);
  if (new Set(out.map((t) => t.afterMinutes)).size !== out.length) throw invalid(`${field}: each tier needs different minutes`, { field });
  return out;
}

export const orgModule: Module = (r, { db }) => {
  // ---------------------------------------------------------------- departments
  r.get('/departments', async (req) => {
    await authenticate(db, req);
    const rows = await db.query(`
      SELECT d.*, (SELECT count(*)::int FROM employees e WHERE e.department_id = d.id AND e.status = 'active') AS employee_count
        FROM departments d ORDER BY d.active DESC, d.name_ar`);
    return ok({ departments: rows.rows });
  });
  r.post('/departments', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'org.manage');
    const b = obj(req.body);
    const d = await one(db, `INSERT INTO departments (name_ar, name_en) VALUES ($1,$2) RETURNING *`,
      [reqStr(b, 'nameAr', { min: 2, max: 80 }), str(b, 'nameEn', { optional: true, max: 80 }) ?? '']);
    await audit(db, a.id, 'department.create', 'department', d.id, undefined, d);
    return ok({ department: d }, 201);
  });
  r.patch('/departments/:id', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'org.manage');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const before = await one(db, `SELECT * FROM departments WHERE id = $1`, [req.params.id]);
    if (!before) throw notFound();
    const d = await one(db, `UPDATE departments SET name_ar = $2, name_en = $3, active = $4 WHERE id = $1 RETURNING *`, [
      before.id, str(b, 'nameAr', { optional: true, min: 2, max: 80 }) ?? before.name_ar,
      str(b, 'nameEn', { optional: true, max: 80 }) ?? before.name_en, bool(b, 'active') ?? before.active]);
    await audit(db, a.id, 'department.update', 'department', d.id, before, d);
    return ok({ department: d });
  });

  // ---------------------------------------------------------------- teams
  r.get('/teams', async (req) => {
    await authenticate(db, req);
    const rows = await db.query(`
      SELECT t.*, d.name_ar AS department_name, m.full_name AS manager_name,
             (SELECT count(*)::int FROM employees e WHERE e.team_id = t.id AND e.status = 'active') AS member_count
        FROM teams t LEFT JOIN departments d ON d.id = t.department_id LEFT JOIN employees m ON m.id = t.manager_id
       ORDER BY t.active DESC, t.name`);
    return ok({ teams: rows.rows });
  });
  r.post('/teams', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'org.manage');
    const b = obj(req.body);
    const t = await one(db, `INSERT INTO teams (name, department_id, manager_id) VALUES ($1,$2,$3) RETURNING *`,
      [reqStr(b, 'name', { min: 2, max: 80 }), uuid(b, 'departmentId', true) ?? null, uuid(b, 'managerId', true) ?? null]);
    await audit(db, a.id, 'team.create', 'team', t.id, undefined, t);
    return ok({ team: t }, 201);
  });
  r.patch('/teams/:id', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'org.manage');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const before = await one(db, `SELECT * FROM teams WHERE id = $1`, [req.params.id]);
    if (!before) throw notFound();
    const t = await one(db, `UPDATE teams SET name = $2, department_id = $3, manager_id = $4, active = $5 WHERE id = $1 RETURNING *`, [
      before.id, str(b, 'name', { optional: true, min: 2, max: 80 }) ?? before.name,
      'departmentId' in b ? uuid(b, 'departmentId', true) ?? null : before.department_id,
      'managerId' in b ? uuid(b, 'managerId', true) ?? null : before.manager_id,
      bool(b, 'active') ?? before.active]);
    await audit(db, a.id, 'team.update', 'team', t.id, before, t);
    return ok({ team: t });
  });

  // ---------------------------------------------------------------- schedules
  r.get('/schedules', async (req) => {
    await authenticate(db, req);
    return ok({ schedules: (await db.query(`SELECT * FROM work_schedules ORDER BY is_default DESC, name`)).rows });
  });
  const scheduleBody = (b: Record<string, unknown>, before?: any) => {
    const weekend = b.weekendDays ?? before?.weekend_days ?? [5];
    if (!Array.isArray(weekend) || weekend.some((d) => !Number.isInteger(d) || d < 1 || d > 7) || weekend.length > 3) {
      throw invalid('weekendDays must be ISO weekdays 1–7 (max 3)', { field: 'weekendDays' });
    }
    return [
      str(b, 'name', { optional: !!before, min: 2, max: 60 }) ?? before?.name,
      time(b, 'startTime', !!before) ?? before?.start_time,
      time(b, 'endTime', !!before) ?? before?.end_time,
      num(b, 'lateGraceMinutes', { optional: true, int: true, min: 0, max: 240 }) ?? before?.late_grace_minutes ?? 15,
      num(b, 'earlyGraceMinutes', { optional: true, int: true, min: 0, max: 240 }) ?? before?.early_grace_minutes ?? 0,
      weekend,
      bool(b, 'overtimeEnabled') ?? before?.overtime_enabled ?? false,
      num(b, 'overtimeMinMinutes', { optional: true, int: true, min: 0, max: 600 }) ?? before?.overtime_min_minutes ?? 30,
    ];
  };
  r.post('/schedules', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'attendance.config');
    const s = await one(db, `INSERT INTO work_schedules (name, start_time, end_time, late_grace_minutes, early_grace_minutes,
      weekend_days, overtime_enabled, overtime_min_minutes) VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`, scheduleBody(obj(req.body)));
    await audit(db, a.id, 'schedule.create', 'schedule', s.id, undefined, s);
    return ok({ schedule: s }, 201);
  });
  r.patch('/schedules/:id', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'attendance.config');
    if (!isUuid(req.params.id)) throw notFound();
    const before = await one(db, `SELECT * FROM work_schedules WHERE id = $1`, [req.params.id]);
    if (!before) throw notFound();
    // past attendance keeps its snapshot; only future days use the new values
    const s = await one(db, `UPDATE work_schedules SET name=$2, start_time=$3, end_time=$4, late_grace_minutes=$5,
      early_grace_minutes=$6, weekend_days=$7, overtime_enabled=$8, overtime_min_minutes=$9 WHERE id = $1 RETURNING *`,
      [before.id, ...scheduleBody(obj(req.body), before)]);
    await audit(db, a.id, 'schedule.update', 'schedule', s.id, before, s);
    return ok({ schedule: s });
  });

  // ---------------------------------------------------------------- holidays
  r.get('/holidays', async (req) => {
    await authenticate(db, req);
    const year = req.query.get('year');
    const rows = year && /^\d{4}$/.test(year)
      ? await db.query(`SELECT * FROM holidays WHERE extract(year FROM day) = $1 ORDER BY day`, [Number(year)])
      : await db.query(`SELECT * FROM holidays ORDER BY day DESC LIMIT 100`);
    return ok({ holidays: rows.rows });
  });
  r.post('/holidays', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'attendance.config');
    const b = obj(req.body);
    const h = await one(db, `INSERT INTO holidays (day, name) VALUES ($1,$2) RETURNING *`, [date(b, 'day'), reqStr(b, 'name', { min: 2, max: 80 })]);
    await audit(db, a.id, 'holiday.create', 'holiday', h.id, undefined, h);
    return ok({ holiday: h }, 201);
  });
  r.delete('/holidays/:id', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'attendance.config');
    if (!isUuid(req.params.id)) throw notFound();
    const h = await one(db, `DELETE FROM holidays WHERE id = $1 RETURNING *`, [req.params.id]);
    if (!h) throw notFound();
    await audit(db, a.id, 'holiday.delete', 'holiday', h.id, h, undefined);
    return ok({ ok: true });
  });

  // ---------------------------------------------------------------- work locations
  r.get('/work-locations', async (req) => {
    await authenticate(db, req);
    return ok({ locations: (await db.query(`SELECT * FROM work_locations ORDER BY active DESC, name`)).rows });
  });
  r.post('/work-locations', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'attendance.config');
    const b = obj(req.body);
    const l = await one(db, `INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ($1,$2,$3,$4) RETURNING *`, [
      reqStr(b, 'name', { min: 2, max: 80 }), num(b, 'lat', { min: -90, max: 90 }), num(b, 'lng', { min: -180, max: 180 }),
      num(b, 'radiusM', { int: true, min: 50, max: 5000 })]);
    await audit(db, a.id, 'location.create', 'work_location', l.id, undefined, l);
    return ok({ location: l }, 201);
  });
  r.patch('/work-locations/:id', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'attendance.config');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const before = await one(db, `SELECT * FROM work_locations WHERE id = $1`, [req.params.id]);
    if (!before) throw notFound();
    const l = await one(db, `UPDATE work_locations SET name=$2, lat=$3, lng=$4, radius_m=$5, active=$6 WHERE id = $1 RETURNING *`, [
      before.id, str(b, 'name', { optional: true, min: 2, max: 80 }) ?? before.name,
      num(b, 'lat', { optional: true, min: -90, max: 90 }) ?? before.lat, num(b, 'lng', { optional: true, min: -180, max: 180 }) ?? before.lng,
      num(b, 'radiusM', { optional: true, int: true, min: 50, max: 5000 }) ?? before.radius_m, bool(b, 'active') ?? before.active]);
    await audit(db, a.id, 'location.update', 'work_location', l.id, before, l);
    return ok({ location: l });
  });

  // ---------------------------------------------------------------- settings
  r.get('/settings', async (req) => {
    await authenticate(db, req);
    return ok({ settings: await one(db, `SELECT * FROM company_settings`) });
  });
  r.patch('/settings', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'settings.manage');
    const b = obj(req.body);
    const before = await one(db, `SELECT * FROM company_settings`);
    const lateRule = [
      num(b, 'lateFixedAfterMinutes', { optional: true, int: true, min: 0, max: 59 }) ?? before.late_fixed_after_minutes,
      num(b, 'lateFixedAmount', { optional: true, min: 0, max: 100000 }) ?? before.late_fixed_amount,
      num(b, 'lateHourAmount', { optional: true, min: 0, max: 100000 }) ?? before.late_hour_amount];
    const s = await one(db, `UPDATE company_settings SET company_name_ar=$1, company_name_en=$2, gps_required=$3,
      request_backdate_days=$4, break_minutes=$5, payroll_auto_deductions=$6, day_divisor=$7, deduction_mode=$8,
      late_tiers=$9::jsonb, early_tiers=$10::jsonb, absence_penalty_days=$11, allow_pin=$12, device_binding=$13,
      selfie_required=$14, selfie_retention_days=$15, checkin_reminder_minutes=$16, tracking_enabled=$17,
      tracking_interval_minutes=$18, tracking_stale_minutes=$19, away_margin_m=$20, updated_at = now() RETURNING *`, [
      str(b, 'companyNameAr', { optional: true, min: 2, max: 120 }) ?? before.company_name_ar,
      str(b, 'companyNameEn', { optional: true, min: 2, max: 120 }) ?? before.company_name_en,
      bool(b, 'gpsRequired') ?? before.gps_required,
      num(b, 'requestBackdateDays', { optional: true, int: true, min: 0, max: 365 }) ?? before.request_backdate_days,
      num(b, 'breakMinutes', { optional: true, int: true, min: 0, max: 240 }) ?? before.break_minutes,
      bool(b, 'payrollAutoDeductions') ?? before.payroll_auto_deductions,
      dayDivisor(b) ?? before.day_divisor,
      deductionMode(b) ?? before.deduction_mode,
      JSON.stringify(tiers(b, 'lateTiers') ?? before.late_tiers),
      JSON.stringify(tiers(b, 'earlyTiers') ?? before.early_tiers),
      num(b, 'absencePenaltyDays', { optional: true, min: 0, max: 5 }) ?? before.absence_penalty_days,
      bool(b, 'allowPin') ?? before.allow_pin,
      bool(b, 'deviceBinding') ?? before.device_binding,
      bool(b, 'selfieRequired') ?? before.selfie_required,
      num(b, 'selfieRetentionDays', { optional: true, int: true, min: 1, max: 365 }) ?? before.selfie_retention_days,
      num(b, 'checkinReminderMinutes', { optional: true, int: true, min: 0, max: 240 }) ?? before.checkin_reminder_minutes,
      bool(b, 'trackingEnabled') ?? before.tracking_enabled,
      num(b, 'trackingIntervalMinutes', { optional: true, int: true, min: 1, max: 30 }) ?? before.tracking_interval_minutes,
      num(b, 'trackingStaleMinutes', { optional: true, int: true, min: 0, max: 240 }) ?? before.tracking_stale_minutes,
      num(b, 'awayMarginM', { optional: true, int: true, min: 0, max: 5000 }) ?? before.away_margin_m]);
    // the company-wide phone lock switches every (non-owner) employee at once; HR fine-tunes per employee after
    if (typeof b.deviceBinding === 'boolean' && b.deviceBinding !== before.device_binding) {
      await db.query(`UPDATE employees SET device_lock = $1 WHERE role_key <> 'owner'`, [b.deviceBinding]);
    }
    if (typeof b.selfieRequired === 'boolean' && b.selfieRequired !== before.selfie_required) {
      await db.query(`UPDATE employees SET selfie_required = $1`, [b.selfieRequired]);
    }
    // simple lateness rule (late > N min → fixed amount; late ≥ 1 h → amount per hour)
    const s2 = await one(db, `UPDATE company_settings SET late_fixed_after_minutes = $1, late_fixed_amount = $2, late_hour_amount = $3 RETURNING *`, lateRule);
    await audit(db, a.id, 'settings.update', 'settings', null, before, s2);
    return ok({ settings: s2 });
  });

  // ---------------------------------------------------------------- roles & permissions
  r.get('/roles', async (req) => {
    const a = await authenticate(db, req);
    if (!['roles.manage', 'employee.manage', 'positions.manage', 'kpi.config'].some((p) => has(a, p))) throw forbidden();
    const roles = await db.query(`
      SELECT r.*, b.name_ar AS base_name_ar,
             COALESCE((SELECT array_agg(rp.perm_key ORDER BY rp.perm_key) FROM role_permissions rp WHERE rp.role_key = r.key), '{}') AS permissions,
             (SELECT count(*)::int FROM employees e WHERE e.status = 'active'
                AND COALESCE(e.position_key, e.role_key) = r.key) AS employee_count
        FROM roles r LEFT JOIN roles b ON b.key = r.base_key
       ORDER BY r.active DESC, COALESCE(b.rank, r.rank) DESC, r.builtin DESC, r.name_ar`);
    const perms = await db.query(`SELECT * FROM permissions ORDER BY key`);
    return ok({ roles: roles.rows, permissions: perms.rows, canEditPermissions: has(a, 'roles.manage'),
      canManagePositions: has(a, 'positions.manage') || has(a, 'roles.manage') });
  });

  /** Active positions for employee forms (any signed-in user with employee.manage sees all; others just names). */
  r.get('/positions', async (req) => {
    await authenticate(db, req);
    const rows = await db.query(`SELECT key, name_ar, name_en, description, base_key, builtin, COALESCE(base_key, key) AS system_role
                                   FROM roles WHERE active ORDER BY rank DESC, name_ar`);
    return ok({ positions: rows.rows });
  });

  /** New job position: follows one system role; starts with exactly that role's permissions (never more). */
  r.post('/roles', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'positions.manage', 'roles.manage');
    const b = obj(req.body);
    const baseKey = reqStr(b, 'baseKey', { max: 40 });
    if (!['manager', 'hr_manager', 'accountant', 'sales_manager', 'sales_employee'].includes(baseKey)) throw invalid('Choose the system role this position follows', { field: 'baseKey' });
    if (['hr_manager', 'accountant'].includes(baseKey) && !has(a, 'roles.manage')) throw forbidden('Only the owner can create admin positions');
    const nameAr = reqStr(b, 'nameAr', { min: 2, max: 80 });
    const role = await db.tx(async (q) => {
      if (await one(q, `SELECT 1 FROM roles WHERE lower(name_ar) = lower($1)`, [nameAr])) throw invalid('A position with this name already exists', { field: 'nameAr' });
      const base = await one(q, `SELECT * FROM roles WHERE key = $1`, [baseKey]);
      const key = 'pos_' + randomBytes(5).toString('hex');
      const r2 = await one(q, `INSERT INTO roles (key, name_ar, name_en, rank, description, base_key, created_by)
                               VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING *`, [key, nameAr,
        str(b, 'nameEn', { optional: true, max: 80 }) || nameAr, base.rank - 1, str(b, 'description', { optional: true, max: 500 }) ?? '', baseKey, a.id]);
      await q.query(`INSERT INTO role_permissions (role_key, perm_key) SELECT $1, perm_key FROM role_permissions WHERE role_key = $2`, [key, baseKey]);
      await audit(q, a.id, 'position.create', 'role', key, undefined, r2);
      return r2;
    });
    return ok({ role }, 201);
  });

  r.patch('/roles/:key', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'positions.manage', 'roles.manage');
    const b = obj(req.body);
    const before = await one(db, `SELECT * FROM roles WHERE key = $1`, [req.params.key]);
    if (!before) throw notFound();
    if (before.builtin && 'active' in b && b.active === false) throw forbidden('Built-in roles cannot be disabled');
    if (before.builtin && !has(a, 'roles.manage')) throw forbidden('Only the owner can rename built-in roles');
    const active = bool(b, 'active') ?? before.active;
    if (!active && before.active) {
      const n = await one(db, `SELECT count(*)::int AS n FROM employees WHERE status = 'active' AND position_key = $1`, [before.key]);
      if (n.n) throw invalid(`Move the ${n.n} employee(s) in this position first`, { field: 'active', employees: n.n });
    }
    const r2 = await one(db, `UPDATE roles SET name_ar = $2, name_en = $3, description = $4, active = $5 WHERE key = $1 RETURNING *`, [before.key,
      str(b, 'nameAr', { optional: true, min: 2, max: 80 }) ?? before.name_ar, str(b, 'nameEn', { optional: true, max: 80 }) ?? before.name_en,
      str(b, 'description', { optional: true, max: 500 }) ?? before.description, active]);
    await audit(db, a.id, 'position.update', 'role', before.key, before, r2);
    return ok({ role: r2 });
  });

  r.put('/roles/:key/permissions', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'roles.manage');
    if (req.params.key === 'owner') throw forbidden('The owner role always has every permission');
    const b = obj(req.body);
    const list = b.permissions;
    if (!Array.isArray(list) || list.some((p) => typeof p !== 'string')) throw invalid('permissions must be a list', { field: 'permissions' });
    const known = new Set((await db.query(`SELECT key FROM permissions`)).rows.map((x) => x.key));
    for (const p of list) if (!known.has(p)) throw invalid(`Unknown permission ${p}`, { field: 'permissions' });
    if (req.params.key === 'sales_employee' && list.length) throw invalid('Sales employees are self-service only');
    await db.tx(async (q) => {
      const role = await one(q, `SELECT key FROM roles WHERE key = $1`, [req.params.key]);
      if (!role) throw notFound();
      const before = (await q.query(`SELECT perm_key FROM role_permissions WHERE role_key = $1 ORDER BY 1`, [role.key])).rows.map((x) => x.perm_key);
      await q.query(`DELETE FROM role_permissions WHERE role_key = $1`, [role.key]);
      for (const p of new Set(list as string[])) await q.query(`INSERT INTO role_permissions VALUES ($1,$2)`, [role.key, p]);
      await audit(q, a.id, 'role.permissions', 'role', role.key, before, [...new Set(list)].sort());
    });
    return ok({ ok: true });
  });

  // ---------------------------------------------------------------- audit log
  r.get('/audit', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'audit.read');
    const vals: unknown[] = []; const where: string[] = [];
    const entity = req.query.get('entity'); if (entity) { vals.push(entity); where.push(`l.entity = $${vals.length}`); }
    const entityId = req.query.get('entityId'); if (entityId) { vals.push(entityId); where.push(`l.entity_id = $${vals.length}`); }
    const limit = Math.min(Number(req.query.get('limit') ?? 100) || 100, 500);
    const rows = await db.query(`SELECT l.*, x.full_name AS actor_name FROM audit_log l LEFT JOIN employees x ON x.id = l.actor_id
      ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY l.id DESC LIMIT ${limit}`, vals);
    // salary values are visible only to salary readers
    const canSalary = has(a, 'employee.salary_read');
    return ok({ entries: rows.rows.map((e) => e.action === 'employee.salary_set' && !canSalary ? { ...e, before: null, after: null } : e) });
  });
};
