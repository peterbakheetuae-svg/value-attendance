import { ok, type Module } from '../ctx.ts';
import { one } from '../db.ts';
import { AppError, invalid } from '../http/errors.ts';
import { obj, reqStr } from '../http/validate.ts';
import { authenticate, audit, SESSION_TTL_HOURS } from '../auth/context.ts';
import { hashPassword, newToken, passwordPolicyError, verifyPassword, PIN_ROLES } from '../auth/password.ts';

const DEVICE_RE = /^[A-Za-z0-9_-]{16,100}$/;

const MAX_FAILS = 5;
const LOCK_MINUTES = 15;
// Constant-time-ish path for unknown users: verify against a fixed dummy hash.
let dummyHash: Promise<string> | null = null;

export const authModule: Module = (r, { db }) => {
  r.post('/auth/login', async (req) => {
    const b = obj(req.body);
    const identifier = reqStr(b, 'identifier', { max: 120 });
    const password = reqStr(b, 'password', { max: 128 });
    const deviceId = typeof b.deviceId === 'string' && DEVICE_RE.test(b.deviceId) ? b.deviceId : null;
    const deviceLabel = typeof b.deviceLabel === 'string' ? b.deviceLabel.slice(0, 120) : null;
    const emp = await one(db, `
      SELECT id, password_hash, status, failed_logins, locked_until, must_change_password, role_key, device_id
        FROM employees
       WHERE upper(code) = upper($1) OR lower(email) = lower($1) OR phone = $1
       LIMIT 1`, [identifier]);
    if (!emp) {
      dummyHash ??= hashPassword('dummy-password-1');
      await verifyPassword(password, await dummyHash);
      throw new AppError('unauthenticated', 'Wrong employee ID or password');
    }
    if (emp.locked_until && new Date(emp.locked_until) > new Date()) {
      throw new AppError('locked', `Too many failed attempts. Try again after ${LOCK_MINUTES} minutes`);
    }
    const good = await verifyPassword(password, emp.password_hash);
    if (!good) {
      const fails = emp.failed_logins + 1;
      await db.query(`UPDATE employees SET failed_logins = $2::int,
                        locked_until = CASE WHEN $2::int >= $3::int THEN now() + make_interval(mins => $4) ELSE locked_until END
                      WHERE id = $1`, [emp.id, fails, MAX_FAILS, LOCK_MINUTES]);
      throw new AppError('unauthenticated', 'Wrong employee ID or password');
    }
    if (emp.status !== 'active') throw new AppError('forbidden', 'This account is deactivated');
    const st = await one(db, `SELECT device_binding FROM company_settings`);
    const bind = st.device_binding && emp.role_key !== 'owner';
    if (bind) {
      if (!deviceId) throw new AppError('forbidden', 'This device could not be identified', { reason: 'device_required' });
      if (emp.device_id && emp.device_id !== deviceId) {
        throw new AppError('forbidden', 'This account is registered on another phone. Ask HR to unlink it', { reason: 'device_mismatch' });
      }
    }
    const { token, hash } = newToken();
    await db.tx(async (q) => {
      await q.query(`UPDATE employees SET failed_logins = 0, locked_until = NULL WHERE id = $1`, [emp.id]);
      if (bind && !emp.device_id) {
        await q.query(`UPDATE employees SET device_id = $2, device_label = $3, device_bound_at = now() WHERE id = $1 AND device_id IS NULL`, [emp.id, deviceId, deviceLabel]);
        await audit(q, emp.id, 'auth.device_bound', 'employee', emp.id, undefined, { label: deviceLabel });
      }
      await q.query(`INSERT INTO sessions (token_hash, employee_id, expires_at, user_agent)
                     VALUES ($1,$2, now() + make_interval(hours => $3), $4)`,
        [hash, emp.id, SESSION_TTL_HOURS, String(req.headers['user-agent'] ?? '').slice(0, 200)]);
      await audit(q, emp.id, 'auth.login', 'employee', emp.id);
    });
    return ok({ token, mustChangePassword: emp.must_change_password, expiresInHours: SESSION_TTL_HOURS });
  });

  r.post('/auth/logout', async (req) => {
    const a = await authenticate(db, req, { allowPasswordChange: true });
    await db.query(`UPDATE sessions SET revoked_at = now() WHERE id = $1`, [a.sessionId]);
    return ok({ ok: true });
  });

  r.post('/auth/change-password', async (req) => {
    const a = await authenticate(db, req, { allowPasswordChange: true });
    const b = obj(req.body);
    const current = reqStr(b, 'currentPassword', { max: 128 });
    const next = b.newPassword;
    const st = await one(db, `SELECT allow_pin FROM company_settings`);
    const policy = passwordPolicyError(next, { allowPin: st.allow_pin && PIN_ROLES.has(a.role) });
    if (policy) throw invalid(policy, { field: 'newPassword' });
    if (next === current) throw invalid('New password must differ from the current one', { field: 'newPassword' });
    const row = await one(db, `SELECT password_hash FROM employees WHERE id = $1`, [a.id]);
    if (!(await verifyPassword(current, row.password_hash))) throw invalid('Current password is wrong', { field: 'currentPassword' });
    const hash = await hashPassword(next as string);
    await db.tx(async (q) => {
      await q.query(`UPDATE employees SET password_hash = $2, must_change_password = false, updated_at = now() WHERE id = $1`, [a.id, hash]);
      // every other session is signed out
      await q.query(`UPDATE sessions SET revoked_at = now() WHERE employee_id = $1 AND id <> $2 AND revoked_at IS NULL`, [a.id, a.sessionId]);
      await audit(q, a.id, 'auth.password_changed', 'employee', a.id);
    });
    return ok({ ok: true });
  });

  r.get('/me', async (req) => {
    const a = await authenticate(db, req, { allowPasswordChange: true });
    const e = await one(db, `
      SELECT e.id, e.code, e.full_name, e.job_title, e.role_key, e.email, e.phone,
             e.department_id, d.name_ar AS department_name, e.team_id, t.name AS team_name,
             e.sales_manager_id, m.full_name AS sales_manager_name, e.joining_date,
             e.must_change_password, (e.photo IS NOT NULL) AS has_photo, e.role_key AS role,
             r.name_ar AS role_name_ar, r.name_en AS role_name_en,
             EXISTS (SELECT 1 FROM teams WHERE manager_id = e.id AND active) AS manages_team
        FROM employees e
        JOIN roles r ON r.key = e.role_key
        LEFT JOIN departments d ON d.id = e.department_id
        LEFT JOIN teams t ON t.id = e.team_id
        LEFT JOIN employees m ON m.id = e.sales_manager_id
       WHERE e.id = $1`, [a.id]);
    const s = await one(db, `SELECT company_name_ar, company_name_en, gps_required, currency, allow_pin, device_binding, break_minutes FROM company_settings`);
    return ok({ employee: e, permissions: [...a.perms].sort(), company: s });
  });
};
