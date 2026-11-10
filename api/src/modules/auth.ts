import { ok, type Module } from '../ctx.ts';
import { pushEnabled } from '../lib/fcm.ts';
import { webPushPublicKey } from '../lib/webpush.ts';
import { lastMailError, mailEnabled, otpMail, sendMail } from '../lib/mail.ts';
import { createHash, randomInt } from 'node:crypto';
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
      SELECT id, password_hash, status, failed_logins, locked_until, must_change_password, role_key, device_id, device_lock
        FROM employees
       WHERE upper(code) = upper($1) OR lower(email) = lower(trim($1)) OR phone = $1
          -- mobile typed in any form (01xxxxxxxxx / +201xxxxxxxxx / 00201...): compare the last 10 digits
          OR (length($2) >= 10 AND right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 10) = right($2, 10))
       ORDER BY (upper(code) = upper($1)) DESC, (status = 'active') DESC
       LIMIT 1`, [identifier.trim(), identifier.replace(/\D/g, '').length === identifier.replace(/[\s+()-]/g, '').length ? identifier.replace(/\D/g, '') : '']);
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
    // one phone per account when "lock to device" is on for this employee (never for owners)
    const bind = emp.device_lock === true && emp.role_key !== 'owner';
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
    await db.query(`DELETE FROM push_tokens WHERE session_id = $1`, [a.sessionId]);
    await db.query(`DELETE FROM web_push_subscriptions WHERE session_id = $1`, [a.sessionId]);
    return ok({ ok: true });
  });

  /** Register this device for phone pushes (Firebase). Re-registering moves the token to this session. */
  r.post('/me/push-token', async (req) => {
    const a = await authenticate(db, req, { allowPasswordChange: true });
    const b = obj(req.body);
    const token = reqStr(b, 'token', { min: 20, max: 4096 });
    const platform = ['android', 'ios', 'web'].includes(String(b.platform)) ? String(b.platform) : 'android';
    await db.query(`INSERT INTO push_tokens (token, employee_id, session_id, platform) VALUES ($1,$2,$3,$4)
      ON CONFLICT (token) DO UPDATE SET employee_id = EXCLUDED.employee_id, session_id = EXCLUDED.session_id,
        platform = EXCLUDED.platform, updated_at = now()`, [token, a.id, a.sessionId, platform]);
    return ok({ ok: true, pushEnabled: pushEnabled() });
  });

  /** Web Push (the web app on iPhone / browsers): the server's public key, then the browser's subscription. */
  r.get('/me/web-push', async (req) => {
    await authenticate(db, req, { allowPasswordChange: true });
    return ok({ publicKey: webPushPublicKey() });
  });

  r.post('/me/web-push', async (req) => {
    const a = await authenticate(db, req, { allowPasswordChange: true });
    const b = obj(req.body);
    const endpoint = reqStr(b, 'endpoint', { min: 12, max: 2000 });
    if (!/^https:\/\//.test(endpoint)) throw invalid('Bad endpoint', { field: 'endpoint' });
    const k = obj(b.keys);
    const p256dh = reqStr(k, 'p256dh', { min: 80, max: 100 }), auth = reqStr(k, 'auth', { min: 16, max: 30 });
    if (Buffer.from(p256dh, 'base64url').length !== 65 || Buffer.from(auth, 'base64url').length !== 16) throw invalid('Bad keys', { field: 'keys' });
    await db.query(`INSERT INTO web_push_subscriptions (employee_id, session_id, endpoint, p256dh, auth, user_agent) VALUES ($1,$2,$3,$4,$5,$6)
      ON CONFLICT (endpoint) DO UPDATE SET employee_id = EXCLUDED.employee_id, session_id = EXCLUDED.session_id,
        p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth, user_agent = EXCLUDED.user_agent`,
      [a.id, a.sessionId, endpoint, p256dh, auth, String(req.headers['user-agent'] ?? '').slice(0, 300)]);
    return ok({ ok: true });
  });

  // ---------------------------------------------------------------- forgot password (OTP by email)
  const sha = (s: string) => createHash('sha256').update(s).digest('hex');
  const findAccount = (identifier: string) => {
    const digits = identifier.replace(/\D/g, '');
    const phoneLike = digits.length >= 10 && digits.length === identifier.replace(/[\s+()-]/g, '').length;
    return one(db, `SELECT id, full_name, email, status, role_key FROM employees
       WHERE status = 'active' AND (upper(code) = upper($1) OR lower(email) = lower($1)
          OR ($2 <> '' AND right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 10) = right($2, 10)))
       ORDER BY (upper(code) = upper($1)) DESC LIMIT 1`, [identifier.trim(), phoneLike ? digits : '']);
  };
  const GENERIC = 'If the account has an email, a 4-digit code was sent to it';

  r.post('/auth/forgot', async (req) => {
    const b = obj(req.body);
    const identifier = reqStr(b, 'identifier', { max: 120 });
    if (!mailEnabled()) throw new AppError('unprocessable', 'Email is not set up yet — ask HR to reset your password', { reason: 'mail_off' });
    const e = await findAccount(identifier);
    if (e?.email) {
      const recent = await one(db, `SELECT count(*)::int AS n FROM password_otps WHERE employee_id = $1 AND created_at > now() - interval '15 minutes'`, [e.id]);
      if (recent.n >= 3) throw new AppError('conflict', 'Too many codes requested — wait 15 minutes', { reason: 'otp_rate_limited' });
      const code = String(randomInt(0, 10_000)).padStart(4, '0');
      await db.query(`UPDATE password_otps SET expires_at = now() WHERE employee_id = $1 AND verified_at IS NULL AND expires_at > now()`, [e.id]);
      await db.query(`INSERT INTO password_otps (employee_id, code_hash, expires_at) VALUES ($1,$2, now() + interval '10 minutes')`, [e.id, sha(`${e.id}:${code}`)]);
      const st = await one(db, `SELECT company_name_ar FROM company_settings`);
      const sent = await sendMail({ to: e.email, toName: e.full_name, ...otpMail({ name: e.full_name, code, company: st.company_name_ar }) });
      await audit(db, e.id, sent ? 'auth.otp_sent' : 'auth.otp_send_failed', 'employee', e.id, undefined, sent ? undefined : { reason: lastMailError });
      if (!sent) throw new AppError('unprocessable', 'The code could not be emailed right now — try again or ask HR', { reason: 'mail_failed' });
      return ok({ ok: true, message: GENERIC, sentTo: e.email.replace(/^(.).*?(@.*)$/, '$1***$2') });
    }
    if (e && !e.email) throw new AppError('unprocessable', 'No email is registered for this account — ask HR to add one or reset your password', { reason: 'no_email' });
    return ok({ ok: true, message: GENERIC });
  });

  r.post('/auth/forgot/verify', async (req) => {
    const b = obj(req.body);
    const identifier = reqStr(b, 'identifier', { max: 120 });
    const code = reqStr(b, 'code', { pattern: /^\d{4}$/ });
    const e = await findAccount(identifier);
    const bad = () => new AppError('validation_failed', 'The code is wrong or expired', { reason: 'otp_invalid', field: 'code' });
    if (!e) throw bad();
    const token = newToken().token;
    const okRow = await db.tx(async (q) => {
      const o = await one(q, `SELECT * FROM password_otps WHERE employee_id = $1 AND verified_at IS NULL AND expires_at > now()
                                ORDER BY created_at DESC LIMIT 1 FOR UPDATE`, [e.id]);
      if (!o || o.attempts >= 5) return null;
      if (o.code_hash !== sha(`${e.id}:${code}`)) {
        await q.query(`UPDATE password_otps SET attempts = attempts + 1 WHERE id = $1`, [o.id]);
        return null;
      }
      await q.query(`UPDATE password_otps SET verified_at = now(), reset_token_hash = $2, reset_expires_at = now() + interval '15 minutes' WHERE id = $1`,
        [o.id, sha(token)]);
      return o;
    });
    if (!okRow) throw bad();
    return ok({ resetToken: token });
  });

  r.post('/auth/forgot/reset', async (req) => {
    const b = obj(req.body);
    const token = reqStr(b, 'resetToken', { max: 200 });
    const next = b.newPassword;
    const done = await db.tx(async (q) => {
      const o = await one(q, `SELECT o.*, e.role_key FROM password_otps o JOIN employees e ON e.id = o.employee_id
          WHERE o.reset_token_hash = $1 AND o.consumed_at IS NULL AND o.reset_expires_at > now() AND e.status = 'active' FOR UPDATE OF o`, [sha(token)]);
      if (!o) throw new AppError('validation_failed', 'This reset link expired — request a new code', { reason: 'reset_expired' });
      const st = await one(q, `SELECT allow_pin FROM company_settings`);
      const policy = passwordPolicyError(next, { allowPin: st.allow_pin && PIN_ROLES.has(o.role_key) });
      if (policy) throw invalid(policy, { field: 'newPassword' });
      const hash = await hashPassword(next as string);
      await q.query(`UPDATE employees SET password_hash = $2, must_change_password = false, failed_logins = 0, locked_until = NULL, updated_at = now() WHERE id = $1`, [o.employee_id, hash]);
      await q.query(`UPDATE sessions SET revoked_at = now() WHERE employee_id = $1 AND revoked_at IS NULL`, [o.employee_id]);
      await q.query(`UPDATE password_otps SET consumed_at = now() WHERE id = $1`, [o.id]);
      await audit(q, o.employee_id, 'auth.password_reset_by_otp', 'employee', o.employee_id);
      return true;
    });
    return ok({ ok: done });
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
