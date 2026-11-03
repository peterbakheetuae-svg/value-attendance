import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { forbidden, invalid, notFound, unprocessable } from '../http/errors.ts';
import { bool, date, num, obj, oneOf, reqStr, str, uuid, isUuid } from '../http/validate.ts';
import { assertCanRead, audit, authenticate, has, readableIds, requirePerm, type Actor } from '../auth/context.ts';
import { hashPassword, tempPassword } from '../auth/password.ts';

const ROLES = ['owner', 'hr_manager', 'accountant', 'sales_manager', 'sales_employee'] as const;
const PRIVILEGED = new Set(['owner', 'hr_manager', 'accountant']);
const CODE = /^[A-Za-z0-9_-]{2,20}$/;
const PHONE = /^\+?[0-9]{8,15}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MIME_OK = new Set(['image/jpeg', 'image/png', 'image/webp', 'application/pdf']);

const PROFILE_COLS = `
  e.id, e.code, e.full_name, e.phone, e.email, e.address, e.job_title,
  e.department_id, d.name_ar AS department_name, e.team_id, t.name AS team_name,
  e.sales_manager_id, m.full_name AS sales_manager_name, e.role_key, r.name_ar AS role_name_ar, r.name_en AS role_name_en,
  e.joining_date, e.status, e.schedule_id, ws.name AS schedule_name,
  e.emergency_contact_name, e.emergency_contact_phone, e.notes,
  (e.photo IS NOT NULL) AS has_photo, e.created_at, e.updated_at`;
const PROFILE_FROM = `
  FROM employees e
  JOIN roles r ON r.key = e.role_key
  LEFT JOIN departments d ON d.id = e.department_id
  LEFT JOIN teams t ON t.id = e.team_id
  LEFT JOIN employees m ON m.id = e.sales_manager_id
  LEFT JOIN work_schedules ws ON ws.id = e.schedule_id`;

function assertAssignableRole(a: Actor, role: string) {
  if (PRIVILEGED.has(role) && !has(a, 'roles.manage')) throw forbidden('Only the owner can assign this role');
}

async function assertOwnerRemains(q: Q, excludingId: string) {
  const r = await one(q, `SELECT count(*)::int AS n FROM employees WHERE role_key = 'owner' AND status = 'active' AND id <> $1`, [excludingId]);
  if (r.n < 1) throw unprocessable('The company must keep at least one active owner');
}

async function validateRefs(q: Q, f: { departmentId?: string | null; teamId?: string | null; salesManagerId?: string | null; scheduleId?: string | null }) {
  if (f.salesManagerId) {
    const m = await one(q, `SELECT role_key, status FROM employees WHERE id = $1`, [f.salesManagerId]);
    if (!m || m.status !== 'active') throw invalid('Sales manager not found', { field: 'salesManagerId' });
    if (!['sales_manager', 'owner'].includes(m.role_key)) throw invalid('Assigned sales manager must have the Sales Manager role', { field: 'salesManagerId' });
  }
  if (f.teamId && !(await one(q, `SELECT 1 FROM teams WHERE id = $1 AND active`, [f.teamId]))) throw invalid('Team not found', { field: 'teamId' });
  if (f.departmentId && !(await one(q, `SELECT 1 FROM departments WHERE id = $1 AND active`, [f.departmentId]))) throw invalid('Department not found', { field: 'departmentId' });
  if (f.scheduleId && !(await one(q, `SELECT 1 FROM work_schedules WHERE id = $1`, [f.scheduleId]))) throw invalid('Schedule not found', { field: 'scheduleId' });
}

function decodeBase64(s: unknown, field: string): Buffer {
  if (typeof s !== 'string' || !/^[A-Za-z0-9+/=\s]+$/.test(s)) throw invalid(`${field} must be base64`, { field });
  const buf = Buffer.from(s, 'base64');
  if (!buf.length) throw invalid(`${field} is empty`, { field });
  if (buf.length > 5 * 1024 * 1024) throw invalid(`${field} is larger than 5 MB`, { field });
  return buf;
}

export const employeesModule: Module = (r, { db, clock }) => {
  r.get('/employees', async (req) => {
    const a = await authenticate(db, req);
    const ids = await readableIds(db, a, 'employee');
    const where: string[] = []; const vals: unknown[] = [];
    if (ids) { vals.push(ids); where.push(`e.id = ANY($${vals.length}::uuid[])`); }
    const status = req.query.get('status') ?? 'active';
    if (status !== 'all') { vals.push(status); where.push(`e.status = $${vals.length}`); }
    for (const [k, col] of [['departmentId', 'e.department_id'], ['teamId', 'e.team_id'], ['salesManagerId', 'e.sales_manager_id']] as const) {
      const v = req.query.get(k);
      if (v) { if (!isUuid(v)) throw invalid(`${k} must be an id`); vals.push(v); where.push(`${col} = $${vals.length}`); }
    }
    const role = req.query.get('role');
    if (role) { vals.push(role); where.push(`e.role_key = $${vals.length}`); }
    const search = req.query.get('q');
    if (search) { vals.push(`%${search}%`); where.push(`(e.full_name ILIKE $${vals.length} OR e.code ILIKE $${vals.length} OR e.job_title ILIKE $${vals.length})`); }
    const rows = await db.query(`SELECT ${PROFILE_COLS} ${PROFILE_FROM}
      ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY e.full_name LIMIT 500`, vals);
    // Team-scoped readers get a reduced card, never contact/emergency/notes of others
    const full = has(a, 'employee.read_all');
    return ok({ employees: rows.rows.map((e) => full || e.id === a.id ? e : teamCard(e)) });
  });

  r.get('/employees/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const scope = await assertCanRead(db, a, req.params.id, 'employee');
    const e = await one(db, `SELECT ${PROFILE_COLS} ${PROFILE_FROM} WHERE e.id = $1`, [req.params.id]);
    if (!e) throw notFound();
    const out: any = scope === 'team' ? teamCard(e) : e;
    if (has(a, 'employee.salary_read')) {
      out.salary = (await one(db, `SELECT base_salary, currency, updated_at FROM employee_salaries WHERE employee_id = $1`, [e.id])) ?? null;
    }
    return ok({ employee: out, scope });
  });

  r.post('/employees', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'employee.manage');
    const b = obj(req.body);
    const role = oneOf(b, 'role', ROLES)!;
    assertAssignableRole(a, role);
    const f = {
      code: reqStr(b, 'code', { pattern: CODE }).toUpperCase(),
      fullName: reqStr(b, 'fullName', { min: 2, max: 120 }),
      phone: str(b, 'phone', { optional: true, pattern: PHONE }) ?? null,
      email: str(b, 'email', { optional: true, pattern: EMAIL, max: 160 })?.toLowerCase() ?? null,
      address: str(b, 'address', { optional: true, max: 300 }) ?? null,
      jobTitle: str(b, 'jobTitle', { optional: true, max: 80 }) ?? '',
      departmentId: uuid(b, 'departmentId', true) ?? null,
      teamId: uuid(b, 'teamId', true) ?? null,
      salesManagerId: uuid(b, 'salesManagerId', true) ?? null,
      scheduleId: uuid(b, 'scheduleId', true) ?? null,
      joiningDate: date(b, 'joiningDate', true) ?? null,
      ecName: str(b, 'emergencyContactName', { optional: true, max: 120 }) ?? null,
      ecPhone: str(b, 'emergencyContactPhone', { optional: true, pattern: PHONE }) ?? null,
      notes: str(b, 'notes', { optional: true, max: 2000 }) ?? null,
    };
    const salary = num(b, 'baseSalary', { optional: true, min: 0, max: 10_000_000 });
    if (salary !== undefined && !has(a, 'employee.salary_manage')) throw forbidden('You cannot set salary information');
    await validateRefs(db, f);
    const pw = tempPassword();
    const hash = await hashPassword(pw);
    const created = await db.tx(async (q) => {
      const e = await one(q, `
        INSERT INTO employees (code, full_name, phone, email, address, job_title, department_id, team_id,
          sales_manager_id, role_key, joining_date, schedule_id, emergency_contact_name, emergency_contact_phone,
          notes, password_hash)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,COALESCE($11::date, (now() AT TIME ZONE 'Africa/Cairo')::date),$12,$13,$14,$15,$16)
        RETURNING id, code`,
        [f.code, f.fullName, f.phone, f.email, f.address, f.jobTitle, f.departmentId, f.teamId, f.salesManagerId,
         role, f.joiningDate, f.scheduleId, f.ecName, f.ecPhone, f.notes, hash]);
      if (salary !== undefined) {
        await q.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1,$2,$3)`, [e.id, salary, a.id]);
      }
      const year = Number((clock().toISOString()).slice(0, 4));
      await q.query(`INSERT INTO leave_balances (employee_id, year, updated_by) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, [e.id, year, a.id]);
      await audit(q, a.id, 'employee.create', 'employee', e.id, undefined, { ...f, role, salarySet: salary !== undefined });
      return e;
    });
    // the temporary password is shown exactly once; the employee must change it at first sign-in
    return ok({ id: created.id, code: created.code, temporaryPassword: pw }, 201);
  });

  r.patch('/employees/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const isSelf = req.params.id === a.id;
    if (!has(a, 'employee.manage')) {
      // self-service: contact fields only
      if (!isSelf) throw notFound('Employee not found');
      const allowed = new Set(['phone', 'email', 'address', 'emergencyContactName', 'emergencyContactPhone']);
      for (const k of Object.keys(b)) if (!allowed.has(k)) throw forbidden(`You cannot change ${k}`);
    }
    const before = await one(db, `SELECT * FROM employees WHERE id = $1`, [req.params.id]);
    if (!before) throw notFound();
    const sets: string[] = []; const vals: unknown[] = [req.params.id];
    const put = (col: string, v: unknown) => { vals.push(v); sets.push(`${col} = $${vals.length}`); };
    const opt = (k: string) => k in b;
    if (opt('fullName')) put('full_name', reqStr(b, 'fullName', { min: 2, max: 120 }));
    if (opt('phone')) put('phone', str(b, 'phone', { optional: true, pattern: PHONE }) ?? null);
    if (opt('email')) put('email', str(b, 'email', { optional: true, pattern: EMAIL, max: 160 })?.toLowerCase() ?? null);
    if (opt('address')) put('address', str(b, 'address', { optional: true, max: 300 }) ?? null);
    if (opt('jobTitle')) put('job_title', str(b, 'jobTitle', { optional: true, max: 80 }) ?? '');
    if (opt('emergencyContactName')) put('emergency_contact_name', str(b, 'emergencyContactName', { optional: true, max: 120 }) ?? null);
    if (opt('emergencyContactPhone')) put('emergency_contact_phone', str(b, 'emergencyContactPhone', { optional: true, pattern: PHONE }) ?? null);
    if (opt('notes')) put('notes', str(b, 'notes', { optional: true, max: 2000 }) ?? null);
    if (opt('joiningDate')) put('joining_date', date(b, 'joiningDate'));
    const refs: any = {};
    if (opt('departmentId')) { refs.departmentId = uuid(b, 'departmentId', true) ?? null; put('department_id', refs.departmentId); }
    if (opt('teamId')) { refs.teamId = uuid(b, 'teamId', true) ?? null; put('team_id', refs.teamId); }
    if (opt('salesManagerId')) {
      refs.salesManagerId = uuid(b, 'salesManagerId', true) ?? null;
      if (refs.salesManagerId === req.params.id) throw invalid('An employee cannot be their own sales manager', { field: 'salesManagerId' });
      put('sales_manager_id', refs.salesManagerId);
    }
    if (opt('scheduleId')) { refs.scheduleId = uuid(b, 'scheduleId', true) ?? null; put('schedule_id', refs.scheduleId); }
    if (opt('role')) {
      const role = oneOf(b, 'role', ROLES)!;
      if (isSelf) throw forbidden('You cannot change your own role');
      assertAssignableRole(a, role);
      if (PRIVILEGED.has(before.role_key) && !has(a, 'roles.manage')) throw forbidden('Only the owner can change this role');
      put('role_key', role);
    }
    await validateRefs(db, refs);
    if (!sets.length) throw invalid('Nothing to update');
    const after = await db.tx(async (q) => {
      if (opt('role') && before.role_key === 'owner') await assertOwnerRemains(q, before.id);
      const r2 = await one(q, `UPDATE employees SET ${sets.join(', ')}, updated_at = now() WHERE id = $1 RETURNING *`, vals);
      await audit(q, a.id, 'employee.update', 'employee', before.id, diff(before, r2), undefined);
      return r2;
    });
    return ok({ id: after.id });
  });

  r.post('/employees/:id/status', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'employee.manage');
    if (!isUuid(req.params.id)) throw notFound();
    const status = oneOf(obj(req.body), 'status', ['active', 'inactive'] as const)!;
    if (req.params.id === a.id) throw forbidden('You cannot change your own account status');
    await db.tx(async (q) => {
      const e = await one(q, `SELECT id, role_key, status FROM employees WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!e) throw notFound();
      if (PRIVILEGED.has(e.role_key) && !has(a, 'roles.manage')) throw forbidden('Only the owner can change this account');
      if (status === 'inactive' && e.role_key === 'owner') await assertOwnerRemains(q, e.id);
      await q.query(`UPDATE employees SET status = $2, updated_at = now() WHERE id = $1`, [e.id, status]);
      if (status === 'inactive') await q.query(`UPDATE sessions SET revoked_at = now() WHERE employee_id = $1 AND revoked_at IS NULL`, [e.id]);
      await audit(q, a.id, `employee.${status === 'active' ? 'activate' : 'deactivate'}`, 'employee', e.id, { status: e.status }, { status });
    });
    return ok({ ok: true });
  });

  r.post('/employees/:id/reset-password', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'employee.manage');
    if (!isUuid(req.params.id) || req.params.id === a.id) throw forbidden('Use change password for your own account');
    const e = await one(db, `SELECT id, role_key FROM employees WHERE id = $1`, [req.params.id]);
    if (!e) throw notFound();
    if (PRIVILEGED.has(e.role_key) && !has(a, 'roles.manage')) throw forbidden('Only the owner can reset this account');
    const pw = tempPassword();
    const hash = await hashPassword(pw);
    await db.tx(async (q) => {
      await q.query(`UPDATE employees SET password_hash = $2, must_change_password = true, failed_logins = 0, locked_until = NULL WHERE id = $1`, [e.id, hash]);
      await q.query(`UPDATE sessions SET revoked_at = now() WHERE employee_id = $1 AND revoked_at IS NULL`, [e.id]);
      await audit(q, a.id, 'employee.reset_password', 'employee', e.id);
    });
    return ok({ temporaryPassword: pw });
  });

  r.put('/employees/:id/salary', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'employee.salary_manage');
    if (!isUuid(req.params.id)) throw notFound();
    if (req.params.id === a.id) throw forbidden('You cannot change your own salary');
    const amount = num(obj(req.body), 'baseSalary', { min: 0, max: 10_000_000 })!;
    await db.tx(async (q) => {
      const before = await one(q, `SELECT base_salary FROM employee_salaries WHERE employee_id = $1`, [req.params.id]);
      if (!(await one(q, `SELECT 1 FROM employees WHERE id = $1`, [req.params.id]))) throw notFound();
      await q.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1,$2,$3)
                     ON CONFLICT (employee_id) DO UPDATE SET base_salary = EXCLUDED.base_salary, updated_by = EXCLUDED.updated_by, updated_at = now()`,
        [req.params.id, amount, a.id]);
      await audit(q, a.id, 'employee.salary_set', 'employee', req.params.id, before ?? null, { base_salary: amount });
    });
    return ok({ ok: true });
  });

  r.get('/employees/:id/history', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    if (!has(a, 'employee.read_all') && !has(a, 'audit.read')) throw forbidden();
    const rows = await db.query(`
      SELECT l.id, l.action, l.before, l.after, l.at, x.full_name AS actor_name
        FROM audit_log l LEFT JOIN employees x ON x.id = l.actor_id
       WHERE l.entity = 'employee' AND l.entity_id = $1 AND l.action <> 'auth.login'
       ORDER BY l.at DESC LIMIT 200`, [req.params.id]);
    // never leak salary values through history to readers without salary rights
    const canSalary = has(a, 'employee.salary_read');
    return ok({ history: rows.rows.map((h) => h.action === 'employee.salary_set' && !canSalary ? { ...h, before: null, after: null } : h) });
  });

  // ---------------------------------------------------------------- photo
  r.put('/employees/:id/photo', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    if (req.params.id !== a.id && !has(a, 'employee.manage')) throw forbidden();
    const b = obj(req.body);
    const mime = oneOf(b, 'mime', ['image/jpeg', 'image/png', 'image/webp'] as const)!;
    const buf = decodeBase64(b.data, 'data');
    if (buf.length > 2 * 1024 * 1024) throw invalid('Photo must be smaller than 2 MB', { field: 'data' });
    const r2 = await db.query(`UPDATE employees SET photo = $2, photo_mime = $3, updated_at = now() WHERE id = $1`, [req.params.id, buf, mime]);
    if (!r2.rowCount) throw notFound();
    await audit(db, a.id, 'employee.photo', 'employee', req.params.id);
    return ok({ ok: true });
  });

  r.get('/employees/:id/photo', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    await assertCanRead(db, a, req.params.id, 'employee');
    const p = await one(db, `SELECT photo, photo_mime FROM employees WHERE id = $1`, [req.params.id]);
    if (!p?.photo) throw notFound('No photo');
    return { binary: p.photo, contentType: p.photo_mime };
  });

  // ---------------------------------------------------------------- documents
  r.get('/employees/:id/documents', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    if (req.params.id !== a.id && !has(a, 'employee.read_all')) throw notFound('Employee not found');
    const rows = await db.query(`SELECT id, title, file_name, mime, size_bytes, created_at FROM employee_documents
                                  WHERE employee_id = $1 ORDER BY created_at DESC`, [req.params.id]);
    return ok({ documents: rows.rows });
  });

  r.post('/employees/:id/documents', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    if (req.params.id !== a.id && !has(a, 'employee.manage')) throw forbidden();
    const b = obj(req.body);
    const mime = reqStr(b, 'mime');
    if (!MIME_OK.has(mime)) throw invalid('Only JPEG, PNG, WEBP or PDF files are accepted', { field: 'mime' });
    const buf = decodeBase64(b.data, 'data');
    const fileName = reqStr(b, 'fileName', { max: 120 });
    const title = str(b, 'title', { optional: true, max: 120 }) ?? fileName;
    const d = await one(db, `INSERT INTO employee_documents (employee_id, title, file_name, mime, size_bytes, content, uploaded_by)
                             VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`, [req.params.id, title, fileName, mime, buf.length, buf, a.id]);
    await audit(db, a.id, 'employee.document_upload', 'employee', req.params.id, undefined, { documentId: d.id, title });
    return ok({ id: d.id }, 201);
  });

  r.get('/documents/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const d = await one(db, `SELECT employee_id, file_name, mime, content FROM employee_documents WHERE id = $1`, [req.params.id]);
    if (!d) throw notFound();
    if (d.employee_id !== a.id && !has(a, 'employee.read_all')) {
      // a request approver may open an attachment of a request they can see
      const viaReq = await one(db, `SELECT employee_id FROM requests WHERE attachment_id = $1`, [req.params.id]);
      if (!viaReq) throw notFound();
      await assertCanRead(db, a, viaReq.employee_id, 'request');
    }
    return { binary: d.content, contentType: d.mime, fileName: d.file_name };
  });
};

function teamCard(e: any) {
  const { id, code, full_name, job_title, department_id, department_name, team_id, team_name,
    sales_manager_id, sales_manager_name, role_key, role_name_ar, role_name_en, status, joining_date, has_photo } = e;
  return { id, code, full_name, job_title, department_id, department_name, team_id, team_name,
    sales_manager_id, sales_manager_name, role_key, role_name_ar, role_name_en, status, joining_date, has_photo };
}

function diff(before: any, after: any) {
  const skip = new Set(['password_hash', 'photo', 'updated_at', 'failed_logins', 'locked_until']);
  const out: Record<string, { from: unknown; to: unknown }> = {};
  for (const k of Object.keys(after)) {
    if (skip.has(k)) continue;
    if (JSON.stringify(before[k]) !== JSON.stringify(after[k])) out[k] = { from: before[k], to: after[k] };
  }
  return out;
}
