import { ok, type Module } from '../ctx.ts';
import { mailEnabled, passwordResetMail, sendMail } from '../lib/mail.ts';
import { one, type Q } from '../db.ts';
import { forbidden, invalid, notFound, unprocessable } from '../http/errors.ts';
import { bool, date, num, obj, oneOf, reqStr, str, uuid, isUuid } from '../http/validate.ts';
import { assertCanRead, audit, authenticate, has, readableIds, requirePerm, SETTLED, type Actor } from '../auth/context.ts';
import { hashPassword, passwordPolicyError, tempPassword, tempPin, PIN_RE, PIN_ROLES } from '../auth/password.ts';

const ROLES = ['owner', 'manager', 'hr_manager', 'accountant', 'sales_manager', 'sales_employee'] as const;
const PRIVILEGED = new Set(['owner', 'manager', 'hr_manager', 'accountant']);
/** Direct manager (يتبع لـ): a sales manager, the manager or the owner. General manager: the manager or the owner. */
const DIRECT_MANAGER_ROLES = ['sales_manager', 'manager', 'owner'];
const GENERAL_MANAGER_ROLES = ['manager', 'owner'];
const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;
/** Salary-like values kept in the original JPH form fields: only salary readers get them. */
const LEGACY_SALARY_KEYS = ['salary', 'startSalary', 'dailyRate', 'increase'];
export function scrubSalary<T extends { legacy_fields?: any }>(e: T, canSalary: boolean): T {
  if (canSalary || !e.legacy_fields || typeof e.legacy_fields !== 'object') return e;
  const lf = { ...e.legacy_fields };
  for (const k of LEGACY_SALARY_KEYS) delete lf[k];
  return { ...e, legacy_fields: lf };
}
const CODE = /^[A-Za-z0-9_-]{2,20}$/;
const PHONE = /^\+?[0-9]{8,15}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MIME_OK = new Set(['image/jpeg', 'image/png', 'image/webp', 'application/pdf']);

const PROFILE_COLS = `
  e.id, e.code, e.full_name, e.phone, e.email, e.address, e.job_title,
  e.department_id, d.name_ar AS department_name, e.team_id, t.name AS team_name,
  e.sales_manager_id, m.full_name AS sales_manager_name, e.general_manager_id, gm.full_name AS general_manager_name,
  e.attendance_exempt, to_char(e.work_start, 'HH24:MI') AS work_start, to_char(e.work_end, 'HH24:MI') AS work_end, e.role_key, r.name_ar AS role_name_ar, r.name_en AS role_name_en,
  COALESCE(e.position_key, e.role_key) AS position_key, pos.name_ar AS position_name_ar, pos.name_en AS position_name_en,
  e.joining_date, e.status, e.schedule_id, ws.name AS schedule_name,
  e.emergency_contact_name, e.emergency_contact_phone, e.notes,
  (e.photo IS NOT NULL) AS has_photo, e.created_at, e.updated_at,
  (e.device_id IS NOT NULL) AS device_bound, e.device_lock, e.selfie_required, e.device_label, e.device_bound_at, e.legacy_fields`;
const PROFILE_FROM = `
  FROM employees e
  JOIN roles r ON r.key = e.role_key
  JOIN roles pos ON pos.key = COALESCE(e.position_key, e.role_key)
  LEFT JOIN departments d ON d.id = e.department_id
  LEFT JOIN teams t ON t.id = e.team_id
  LEFT JOIN employees m ON m.id = e.sales_manager_id
  LEFT JOIN employees gm ON gm.id = e.general_manager_id
  LEFT JOIN work_schedules ws ON ws.id = e.schedule_id`;

function assertAssignableRole(a: Actor, role: string) {
  if (PRIVILEGED.has(role) && !has(a, 'roles.manage')) throw forbidden('Only the owner can assign this role');
}

/** Resolve a job position (built-in role or custom position) to its system role + stored position key. */
async function resolvePosition(q: Q, key: unknown): Promise<{ role: string; positionKey: string | null; nameAr: string }> {
  if (typeof key !== 'string' || !key) throw invalid('Choose a job position', { field: 'position' });
  const p = await one(q, `SELECT * FROM roles WHERE key = $1 AND active`, [key]);
  if (!p) throw invalid('Job position not found or disabled', { field: 'position' });
  return p.builtin ? { role: p.key, positionKey: null, nameAr: p.name_ar } : { role: p.base_key, positionKey: p.key, nameAr: p.name_ar };
}

async function assertOwnerRemains(q: Q, excludingId: string) {
  const r = await one(q, `SELECT count(*)::int AS n FROM employees WHERE role_key = 'owner' AND status = 'active' AND id <> $1`, [excludingId]);
  if (r.n < 1) throw unprocessable('The company must keep at least one active owner');
}

async function validateRefs(q: Q, f: { departmentId?: string | null; teamId?: string | null; salesManagerId?: string | null; generalManagerId?: string | null; scheduleId?: string | null }) {
  if (f.salesManagerId) {
    const m = await one(q, `SELECT role_key, status FROM employees WHERE id = $1`, [f.salesManagerId]);
    if (!m || m.status !== 'active') throw invalid('Direct manager not found', { field: 'salesManagerId' });
    if (!DIRECT_MANAGER_ROLES.includes(m.role_key)) throw invalid('The direct manager must be a sales manager, the manager or the owner', { field: 'salesManagerId' });
  }
  if (f.generalManagerId) {
    const m = await one(q, `SELECT role_key, status FROM employees WHERE id = $1`, [f.generalManagerId]);
    if (!m || m.status !== 'active') throw invalid('General manager not found', { field: 'generalManagerId' });
    if (!GENERAL_MANAGER_ROLES.includes(m.role_key)) throw invalid('The general manager must be the manager or the owner', { field: 'generalManagerId' });
  }
  if (f.teamId && !(await one(q, `SELECT 1 FROM teams WHERE id = $1 AND active`, [f.teamId]))) throw invalid('Team not found', { field: 'teamId' });
  if (f.departmentId && !(await one(q, `SELECT 1 FROM departments WHERE id = $1 AND active`, [f.departmentId]))) throw invalid('Department not found', { field: 'departmentId' });
  if (f.scheduleId && !(await one(q, `SELECT 1 FROM work_schedules WHERE id = $1`, [f.scheduleId]))) throw invalid('Schedule not found', { field: 'scheduleId' });
}

/** Personal shift (HH:MM–HH:MM) or none (company schedule applies). */
function workHours(b: Record<string, unknown>): { start: string | null; end: string | null } | undefined {
  if (!('workStart' in b) && !('workEnd' in b)) return undefined;
  const s = b.workStart, e = b.workEnd;
  if ((s === null || s === '') && (e === null || e === '')) return { start: null, end: null };
  if (typeof s !== 'string' || !HHMM.test(s)) throw invalid('Work start must be HH:MM', { field: 'workStart' });
  if (typeof e !== 'string' || !HHMM.test(e)) throw invalid('Work end must be HH:MM', { field: 'workEnd' });
  if (e <= s) throw invalid('Work end must be after work start', { field: 'workEnd' });
  return { start: s, end: e };
}

function decodeBase64(s: unknown, field: string): Buffer {
  if (typeof s !== 'string' || !/^[A-Za-z0-9+/=\s]+$/.test(s)) throw invalid(`${field} must be base64`, { field });
  const buf = Buffer.from(s, 'base64');
  if (!buf.length) throw invalid(`${field} is empty`, { field });
  if (buf.length > 5 * 1024 * 1024) throw invalid(`${field} is larger than 5 MB`, { field });
  return buf;
}

export const REQUIRED_DOCS = ['acknowledgment', 'job_description', 'national_id'] as const;
const DOC_TITLES: Record<string, string> = { acknowledgment: 'إقرار وتعهد الموظف', job_description: 'الوصف الوظيفي', national_id: 'صورة إثبات الشخصية' };

/** Validate an uploaded file: declared type must match the kind AND the real file signature. */
function readDocument(b: Record<string, unknown>, kind: string) {
  const mime = reqStr(b, 'mime');
  if (!MIME_OK.has(mime)) throw invalid('Only JPEG, PNG, WEBP or PDF files are accepted', { field: 'mime' });
  if ((kind === 'acknowledgment' || kind === 'job_description') && mime !== 'application/pdf') throw invalid('This document must be a PDF file', { field: 'mime' });
  if (kind === 'national_id' && !mime.startsWith('image/')) throw invalid('The identity document must be an image', { field: 'mime' });
  const buf = decodeBase64(b.data, 'data');
  const sig = buf.subarray(0, 12);
  const real = sig.subarray(0, 4).toString('latin1') === '%PDF' ? 'application/pdf'
    : sig[0] === 0xff && sig[1] === 0xd8 && sig[2] === 0xff ? 'image/jpeg'
    : sig.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) ? 'image/png'
    : sig.subarray(0, 4).toString('latin1') === 'RIFF' && sig.subarray(8, 12).toString('latin1') === 'WEBP' ? 'image/webp' : null;
  if (real !== mime) throw invalid('The file content does not match its type', { field: 'data' });
  const fileName = reqStr(b, 'fileName', { max: 120 }).replace(/[\\/\u0000-\u001f]/g, '_');
  return { kind, mime, buf, fileName, title: str(b, 'title', { optional: true, max: 120 }) ?? DOC_TITLES[kind] ?? fileName };
}

/** Free-form fields from the original JPH employee form (flat strings/numbers/booleans, ≤ 40 keys). */
function legacyFields(v: unknown): Record<string, string | number | boolean | null> {
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw invalid('legacyFields must be an object', { field: 'legacyFields' });
  const out: Record<string, string | number | boolean | null> = {};
  const entries = Object.entries(v as Record<string, unknown>);
  if (entries.length > 40) throw invalid('Too many legacy fields', { field: 'legacyFields' });
  for (const [k, x] of entries) {
    if (!/^[A-Za-z_]{1,40}$/.test(k)) throw invalid('Invalid legacy field name', { field: 'legacyFields' });
    if (x === null || typeof x === 'number' || typeof x === 'boolean') out[k] = x;
    else if (typeof x === 'string') out[k] = x.slice(0, 200);
    else throw invalid('Legacy fields must be plain values', { field: 'legacyFields' });
  }
  return out;
}

/** PIN instead of a password: requested, allowed by the company, and only for sales roles. */
async function pinFor(q: Q, kind: unknown, role: string): Promise<boolean> {
  if (kind === undefined || kind === 'password') return false;
  if (kind !== 'pin') throw invalid('kind must be pin or password', { field: 'kind' });
  const st = await one(q, `SELECT allow_pin FROM company_settings`);
  if (!st.allow_pin) throw invalid('PINs are turned off in the company settings', { field: 'kind' });
  if (!PIN_ROLES.has(role)) throw invalid('Admin roles must use a password', { field: 'kind' });
  return true;
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
    const canSal = has(a, 'employee.salary_read');
    const out = rows.rows.map((e) => scrubSalary(full || e.id === a.id ? e : teamCard(e), canSal || e.id === a.id));
    if (has(a, 'employee.salary_read') && out.length) {
      const sal = await db.query(`SELECT employee_id, base_salary FROM employee_salaries WHERE employee_id = ANY($1::uuid[])`, [out.map((e: any) => e.id)]);
      const by = new Map(sal.rows.map((x) => [x.employee_id, x.base_salary]));
      for (const e of out as any[]) e.base_salary = by.get(e.id) ?? null;
    }
    return ok({ employees: out });
  });

  r.get('/employees/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const scope = await assertCanRead(db, a, req.params.id, 'employee');
    const e = await one(db, `SELECT ${PROFILE_COLS} ${PROFILE_FROM} WHERE e.id = $1`, [req.params.id]);
    if (!e) throw notFound();
    const out: any = scrubSalary(scope === 'team' ? teamCard(e) : e, has(a, 'employee.salary_read') || e.id === a.id);
    if (has(a, 'employee.salary_read')) {
      out.salary = (await one(db, `SELECT base_salary, currency, updated_at FROM employee_salaries WHERE employee_id = $1`, [e.id])) ?? null;
    }
    return ok({ employee: out, scope });
  });

  r.post('/employees', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'employee.manage');
    const b = obj(req.body);
    const pos = b.position !== undefined && b.position !== null && b.position !== ''
      ? await resolvePosition(db, b.position) : { role: oneOf(b, 'role', ROLES)!, positionKey: null, nameAr: '' };
    const role = pos.role;
    assertAssignableRole(a, role);
    const f = {
      code: reqStr(b, 'code', { pattern: CODE }).toUpperCase(),
      fullName: reqStr(b, 'fullName', { min: 2, max: 120 }),
      phone: str(b, 'phone', { optional: true, pattern: PHONE }) ?? null,
      email: str(b, 'email', { optional: true, pattern: EMAIL, max: 160 })?.toLowerCase() ?? null,
      address: str(b, 'address', { optional: true, max: 300 }) ?? null,
      jobTitle: str(b, 'jobTitle', { optional: true, max: 80 }) || pos.nameAr,
      departmentId: uuid(b, 'departmentId', true) ?? null,
      teamId: uuid(b, 'teamId', true) ?? null,
      salesManagerId: uuid(b, 'salesManagerId', true) ?? null,
      generalManagerId: uuid(b, 'generalManagerId', true) ?? null,
      scheduleId: uuid(b, 'scheduleId', true) ?? null,
      joiningDate: date(b, 'joiningDate', true) ?? null,
      ecName: str(b, 'emergencyContactName', { optional: true, max: 120 }) ?? null,
      ecPhone: str(b, 'emergencyContactPhone', { optional: true, pattern: PHONE }) ?? null,
      notes: str(b, 'notes', { optional: true, max: 2000 }) ?? null,
    };
    const salary = num(b, 'baseSalary', { optional: true, min: 0, max: 10_000_000 });
    if (salary !== undefined && !has(a, 'employee.salary_manage')) throw forbidden('You cannot set salary information');
    const exempt = b.attendanceExempt === undefined ? role === 'owner' : bool(b, 'attendanceExempt')!;
    if (b.attendanceExempt !== undefined && exempt !== (role === 'owner') && !has(a, 'employee.attendance_exempt')) {
      throw forbidden('Only the owner can change "no attendance"');
    }
    const hours = workHours(b) ?? { start: null, end: null };
    const deviceLock = role === 'owner' ? false
      : (bool(b, 'deviceLock') ?? (await one(db, `SELECT device_binding FROM company_settings`)).device_binding === true);
    const selfieReq = bool(b, 'selfieRequired') ?? (await one(db, `SELECT selfie_required FROM company_settings`)).selfie_required === true;
    await validateRefs(db, f);
    // required documents (uploaded first via POST /documents/staged) — checked before anything is created
    const docIn = b.documents === undefined || b.documents === null ? {} : obj(b.documents);
    const docIds: Record<string, string> = {};
    for (const [k, field] of [['acknowledgment', 'acknowledgment'], ['job_description', 'jobDescription'], ['national_id', 'nationalId']] as const) {
      const v = docIn[field];
      if (v !== undefined && v !== null && v !== '') docIds[k] = uuid(docIn, field)!;
    }
    const missingDocs = REQUIRED_DOCS.filter((k) => !docIds[k]);
    if (missingDocs.length && (await one(db, `SELECT require_employee_documents AS r FROM company_settings`)).r) {
      throw invalid('Attach the acknowledgment PDF, the job description PDF and the ID image', { field: 'documents', missing: missingDocs });
    }
    let usePin = await pinFor(db, b.loginKind, role);
    // the original JPH form lets HR type the first password/PIN
    const typed = typeof b.password === 'string' && b.password.trim() ? b.password.trim() : null;
    if (typed) {
      const st = await one(db, `SELECT allow_pin FROM company_settings`);
      const pol = passwordPolicyError(typed, { allowPin: st.allow_pin && PIN_ROLES.has(role) });
      if (pol) throw invalid(pol, { field: 'password' });
      usePin = PIN_RE.test(typed);
    }
    const pw = typed ?? (usePin ? tempPin() : tempPassword());
    const hash = await hashPassword(pw);
    const created = await db.tx(async (q) => {
      const e = await one(q, `
        INSERT INTO employees (code, full_name, phone, email, address, job_title, department_id, team_id,
          sales_manager_id, role_key, joining_date, schedule_id, emergency_contact_name, emergency_contact_phone,
          notes, password_hash, must_change_password, legacy_fields, position_key,
          general_manager_id, attendance_exempt, work_start, work_end, device_lock, selfie_required)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,COALESCE($11::date, (now() AT TIME ZONE 'Africa/Cairo')::date),$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25)
        RETURNING id, code`,
        [f.code, f.fullName, f.phone, f.email, f.address, f.jobTitle, f.departmentId, f.teamId, f.salesManagerId,
         role, f.joiningDate, f.scheduleId, f.ecName, f.ecPhone, f.notes, hash, !usePin,
         JSON.stringify(b.legacyFields === undefined ? {} : legacyFields(b.legacyFields)), pos.positionKey,
         f.generalManagerId, exempt, hours.start, hours.end, deviceLock, selfieReq]);
      if (salary !== undefined) {
        await q.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1,$2,$3)`, [e.id, salary, a.id]);
      }
      for (const [k, docId] of Object.entries(docIds)) {
        const d = await one(q, `UPDATE employee_documents SET employee_id = $1, staged_by = NULL
                                 WHERE id = $2 AND employee_id IS NULL AND staged_by = $3 AND kind = $4 RETURNING id`, [e.id, docId, a.id, k]);
        if (!d) throw invalid('An attached document was not found — upload it again', { field: 'documents', kind: k });
      }
      const year = Number((clock().toISOString()).slice(0, 4));
      await q.query(`INSERT INTO leave_balances (employee_id, year, updated_by) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, [e.id, year, a.id]);
      await audit(q, a.id, 'employee.create', 'employee', e.id, undefined, { ...f, role, position: pos.positionKey, salarySet: salary !== undefined, documents: docIds });
      return e;
    });
    // the temporary password is shown exactly once; the employee must change it at first sign-in
    return ok({ id: created.id, code: created.code, temporaryPassword: usePin ? undefined : pw, pin: usePin ? pw : undefined }, 201);
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
    if (opt('legacyFields')) {
      const lf = legacyFields(b.legacyFields);
      // someone who cannot see salaries never changes (or wipes) the salary values kept in the old form fields
      if (!has(a, 'employee.salary_read')) {
        for (const k of LEGACY_SALARY_KEYS) delete lf[k];
        const prev = (before.legacy_fields ?? {}) as Record<string, any>;
        for (const k of LEGACY_SALARY_KEYS) if (k in prev) lf[k] = prev[k];
      }
      // «تم التصفيه» only once every custody item he holds has been received back
      const prevStatus = (before.legacy_fields ?? {})?.status;
      if (lf.status === SETTLED && prevStatus !== SETTLED) {
        const open = await one(db, `SELECT count(*)::int AS n FROM custody_items WHERE employee_id = $1 AND status = 'assigned'`, [req.params.id]);
        if (open.n > 0) throw invalid(`لازم تستلم العهدة اللي مع الموظف الأول (${open.n}) قبل «تم التصفيه»`, { field: 'status', reason: 'open_custody', count: open.n });
      }
      put('legacy_fields', JSON.stringify(lf));
    }
    const refs: any = {};
    if (opt('departmentId')) { refs.departmentId = uuid(b, 'departmentId', true) ?? null; put('department_id', refs.departmentId); }
    if (opt('teamId')) { refs.teamId = uuid(b, 'teamId', true) ?? null; put('team_id', refs.teamId); }
    if (opt('salesManagerId')) {
      refs.salesManagerId = uuid(b, 'salesManagerId', true) ?? null;
      if (refs.salesManagerId === req.params.id) throw invalid('An employee cannot be their own sales manager', { field: 'salesManagerId' });
      put('sales_manager_id', refs.salesManagerId);
    }
    if (opt('generalManagerId')) {
      refs.generalManagerId = uuid(b, 'generalManagerId', true) ?? null;
      if (refs.generalManagerId === req.params.id) throw invalid('An employee cannot be their own general manager', { field: 'generalManagerId' });
      put('general_manager_id', refs.generalManagerId);
    }
    if (opt('attendanceExempt')) {
      if (!has(a, 'employee.attendance_exempt')) throw forbidden('Only the owner can change "no attendance"');
      put('attendance_exempt', bool(b, 'attendanceExempt', false));
    }
    const hours = workHours(b);
    if (hours) { put('work_start', hours.start); put('work_end', hours.end); }
    if (opt('selfieRequired')) {
      if (!has(a, 'employee.manage')) throw forbidden('You cannot change this');
      put('selfie_required', bool(b, 'selfieRequired', false));
    }
    let lockTurnedOn = false;
    if (opt('deviceLock')) {
      if (!has(a, 'employee.manage')) throw forbidden('You cannot change the phone lock');
      const on = bool(b, 'deviceLock', false)!;
      if (on && before.role_key === 'owner') throw invalid('The owner account is never locked to one phone', { field: 'deviceLock' });
      lockTurnedOn = on && !before.device_lock;
      put('device_lock', on);
    }
    if (opt('scheduleId')) { refs.scheduleId = uuid(b, 'scheduleId', true) ?? null; put('schedule_id', refs.scheduleId); }
    if (opt('role') || opt('position')) {
      const pos = opt('position') ? await resolvePosition(db, b.position) : { role: oneOf(b, 'role', ROLES)!, positionKey: null, nameAr: '' };
      if (isSelf) throw forbidden('You cannot change your own role');
      assertAssignableRole(a, pos.role);
      if (PRIVILEGED.has(before.role_key) && !has(a, 'roles.manage')) throw forbidden('Only the owner can change this role');
      put('role_key', pos.role);
      if (pos.role === 'owner' && !opt('deviceLock')) put('device_lock', false);
      put('position_key', pos.positionKey);
      if (pos.nameAr && !opt('jobTitle')) put('job_title', pos.nameAr);
    }
    await validateRefs(db, refs);
    if (!sets.length) throw invalid('Nothing to update');
    const after = await db.tx(async (q) => {
      if ((opt('role') || opt('position')) && before.role_key === 'owner') await assertOwnerRemains(q, before.id);
      const r2 = await one(q, `UPDATE employees SET ${sets.join(', ')}, updated_at = now() WHERE id = $1 RETURNING *`, vals);
      // lock switched on: every open session ends; the next sign-in binds the phone it comes from
      if (lockTurnedOn) await q.query(`UPDATE sessions SET revoked_at = now() WHERE employee_id = $1 AND revoked_at IS NULL`, [before.id]);
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
    const e = await one(db, `SELECT id, role_key, email, full_name, code FROM employees WHERE id = $1`, [req.params.id]);
    if (!e) throw notFound();
    if (PRIVILEGED.has(e.role_key) && !has(a, 'roles.manage')) throw forbidden('Only the owner can reset this account');
    const usePin = await pinFor(db, obj(req.body ?? {}).kind, e.role_key);
    const pw = usePin ? tempPin() : tempPassword();
    const hash = await hashPassword(pw);
    await db.tx(async (q) => {
      // a PIN is the employee's own (Value HR); a temporary password must be replaced at first sign-in
      await q.query(`UPDATE employees SET password_hash = $2, must_change_password = $3, failed_logins = 0, locked_until = NULL WHERE id = $1`, [e.id, hash, !usePin]);
      await q.query(`UPDATE sessions SET revoked_at = now() WHERE employee_id = $1 AND revoked_at IS NULL`, [e.id]);
      await audit(q, a.id, usePin ? 'employee.reset_pin' : 'employee.reset_password', 'employee', e.id);
    });
    // email it to the employee when possible; the value is then not shown to the admin
    let emailed = false;
    if (e.email && obj(req.body ?? {}).sendEmail !== false) {
      const st = await one(db, `SELECT company_name_ar FROM company_settings`);
      emailed = await sendMail({ to: e.email, toName: e.full_name,
        ...passwordResetMail({ name: e.full_name, code: e.code, password: pw, company: st.company_name_ar, isPin: usePin }) });
      await audit(db, a.id, emailed ? 'employee.reset_password_emailed' : 'employee.reset_password_email_failed', 'employee', e.id);
    }
    const mask = e.email ? e.email.replace(/^(.).*(@.*)$/, '$1***$2') : null;
    if (emailed) return ok({ emailed: true, emailTo: mask });
    return usePin ? ok({ pin: pw, emailed: false, emailTo: mask, mailConfigured: mailEnabled() })
      : ok({ temporaryPassword: pw, emailed: false, emailTo: mask, mailConfigured: mailEnabled() });
  });

  r.post('/employees/:id/unbind-device', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'employee.manage');
    if (!isUuid(req.params.id)) throw notFound();
    const e = await one(db, `SELECT id, role_key, device_id, device_label FROM employees WHERE id = $1`, [req.params.id]);
    if (!e) throw notFound();
    if (PRIVILEGED.has(e.role_key) && !has(a, 'roles.manage') && e.id !== a.id) throw forbidden('Only the owner can unlink this account');
    await db.tx(async (q) => {
      await q.query(`UPDATE employees SET device_id = NULL, device_label = NULL, device_bound_at = NULL WHERE id = $1`, [e.id]);
      await q.query(`UPDATE sessions SET revoked_at = now() WHERE employee_id = $1 AND revoked_at IS NULL`, [e.id]);
      await audit(q, a.id, 'employee.unbind_device', 'employee', e.id, { label: e.device_label }, undefined);
    });
    return ok({ ok: true });
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
  // Required employee documents (acknowledgment PDF, job description PDF, national-ID image) + free attachments.
  // Private: served only through the authenticated /documents/:id endpoint, never through public URLs.
  const canReadDocs = (a: Actor, employeeId: string) => employeeId === a.id || has(a, 'documents.read') || has(a, 'employee.read_all');
  const canManageDocs = (a: Actor) => has(a, 'documents.manage') || has(a, 'employee.manage');

  r.get('/employees/:id/documents', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    if (!canReadDocs(a, req.params.id)) throw notFound('Employee not found');
    const rows = await db.query(`SELECT d.id, d.kind, d.title, d.file_name, d.mime, d.size_bytes, d.created_at, d.replaced_at, d.replaced_by,
                                        u.full_name AS uploaded_by_name
                                   FROM employee_documents d JOIN employees u ON u.id = d.uploaded_by
                                  WHERE d.employee_id = $1 ORDER BY d.created_at DESC`, [req.params.id]);
    const current: Record<string, unknown> = {};
    for (const k of REQUIRED_DOCS) current[k] = rows.rows.find((d) => d.kind === k && !d.replaced_at) ?? null;
    return ok({ documents: rows.rows, required: current, missing: REQUIRED_DOCS.filter((k) => !current[k]), canManage: canManageDocs(a) });
  });

  /** Stage a required document before the employee exists (claimed by POST /employees). */
  r.post('/documents/staged', async (req) => {
    const a = await authenticate(db, req);
    if (!canManageDocs(a)) throw forbidden();
    const b = obj(req.body);
    const f = readDocument(b, oneOf(b, 'kind', REQUIRED_DOCS)!);
    const d = await one(db, `INSERT INTO employee_documents (employee_id, kind, title, file_name, mime, size_bytes, content, uploaded_by, staged_by)
                             VALUES (NULL,$1,$2,$3,$4,$5,$6,$7,$7) RETURNING id`, [f.kind, f.title, f.fileName, f.mime, f.buf.length, f.buf, a.id]);
    return ok({ id: d.id }, 201);
  });

  /** Upload / replace a document of an existing employee (replacing keeps the old file as history). */
  r.post('/employees/:id/documents', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const kind = b.kind === undefined ? 'other' : oneOf(b, 'kind', [...REQUIRED_DOCS, 'other'] as const)!;
    // employees may attach their own files to requests; required documents are HR/owner only
    if (kind !== 'other' || req.params.id !== a.id) { if (!canManageDocs(a)) throw forbidden(); }
    if (!(await one(db, `SELECT 1 FROM employees WHERE id = $1`, [req.params.id]))) throw notFound();
    const f = readDocument(b, kind);
    const id = await db.tx(async (q) => {
      const prev = kind === 'other' ? null : await one(q, `SELECT id FROM employee_documents WHERE employee_id = $1 AND kind = $2
                                                            AND replaced_at IS NULL FOR UPDATE`, [req.params.id, kind]);
      if (prev) await q.query(`UPDATE employee_documents SET replaced_at = now() WHERE id = $1`, [prev.id]);
      const d = await one(q, `INSERT INTO employee_documents (employee_id, kind, title, file_name, mime, size_bytes, content, uploaded_by)
                              VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`, [req.params.id, kind, f.title, f.fileName, f.mime, f.buf.length, f.buf, a.id]);
      if (prev) await q.query(`UPDATE employee_documents SET replaced_by = $2 WHERE id = $1`, [prev.id, d.id]);
      await audit(q, a.id, prev ? 'employee.document_replace' : 'employee.document_upload', 'employee', req.params.id, prev ? { documentId: prev.id } : undefined,
        { documentId: d.id, kind, title: f.title, size: f.buf.length });
      return d.id;
    });
    return ok({ id }, 201);
  });

  r.get('/documents/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const d = await one(db, `SELECT employee_id, staged_by, file_name, mime, content FROM employee_documents WHERE id = $1`, [req.params.id]);
    if (!d) throw notFound();
    if (d.employee_id === null) { if (d.staged_by !== a.id) throw notFound(); }
    else if (!canReadDocs(a, d.employee_id)) {
      // a request approver may open an attachment of a request they can see
      const viaReq = await one(db, `SELECT employee_id FROM requests WHERE attachment_id = $1`, [req.params.id]);
      if (!viaReq) throw notFound();
      await assertCanRead(db, a, viaReq.employee_id, 'request');
    }
    if (d.employee_id && d.employee_id !== a.id) await audit(db, a.id, 'employee.document_view', 'employee', d.employee_id, undefined, { documentId: req.params.id });
    return { binary: d.content, contentType: d.mime, fileName: d.file_name };
  });
};

function teamCard(e: any) {
  const { id, code, full_name, job_title, department_id, department_name, team_id, team_name,
    sales_manager_id, sales_manager_name, role_key, role_name_ar, role_name_en, status, joining_date, has_photo } = e;
  // work_status: على رأس العمل / مغادر / تم التصفيه / إجازة — so a team manager's lists show only those on duty
  const work_status = typeof e.legacy_fields?.status === 'string' ? e.legacy_fields.status : null;
  return { id, code, full_name, job_title, department_id, department_name, team_id, team_name,
    sales_manager_id, sales_manager_name, role_key, role_name_ar, role_name_en, status, joining_date, has_photo, work_status };
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
