import { ok, type Module } from '../ctx.ts';
import { pushEnabled } from '../lib/fcm.ts';
import { webPushPublicKey } from '../lib/webpush.ts';
import { lastMailError, mailEnabled, otpMail, sendMail } from '../lib/mail.ts';
import { createHash, randomInt } from 'node:crypto';
import { one, type Q } from '../db.ts';
import { AppError, invalid } from '../http/errors.ts';
import { obj, reqStr } from '../http/validate.ts';
import { deviceApprovers } from './devices.ts';
import { notify } from './notify.ts';
import { authenticate, audit, effectivePermissions, SESSION_TTL_HOURS } from '../auth/context.ts';
import { hashPassword, newToken, passwordPolicyError, verifyPassword, PIN_ROLES } from '../auth/password.ts';
import { partnerOf } from '../auth/partner.ts';
import { clientIp, withIpLimit } from '../auth/ratelimit.ts';
import { ACCT_FREE, PAIR_FREE, accountBucket, clear, clearAccount, deviceBucket, pairBucket, reserve, unknownBucket } from '../auth/throttle.ts';
import { securityAlert } from '../auth/alerts.ts';

const DEVICE_RE = /^[A-Za-z0-9_-]{16,100}$/;

/** password-reset codes: per account per 24 hours — codes sent, and wrong codes over all of them (then 24 h off) */
const OTP_CODES_PER_DAY = 8, OTP_WRONG_PER_DAY = 10;

/** SEC-05: sign-in is throttled per account + network / known device / account-wide (auth/throttle.ts) — never a hard lock */
const LOCKED_MSG = 'Too many failed attempts. Try again later';
const lockedError = (retryAfterS: number) => new AppError('locked', LOCKED_MSG, { reason: 'throttled', retryAfterS });

/**
 * Reserve this attempt in the account's buckets before the password is checked. A device already approved for (or
 * last used by) this account gets its own bucket and skips the account-wide one; any other caller is counted per
 * network AND account-wide. Throws 423 (the same reply as before, with a retry time) while a bucket waits.
 */
async function reserveFor(q: Q, account: string, ip: string | null, knownDevice: string | null) {
  const primary = knownDevice ? deviceBucket(account, knownDevice) : pairBucket(account, ip);
  const acct = knownDevice ? null : accountBucket(account);
  if (acct) {
    const a = await reserve(q, acct);
    if (!a.ok) throw lockedError(a.retryAfterS);
    const p = await reserve(q, primary);
    if (!p.ok) throw lockedError(p.retryAfterS);
    return { primary, acct, fails: p.fails, acctFails: a.fails };
  }
  const p = await reserve(q, primary);
  if (!p.ok) throw lockedError(p.retryAfterS);
  return { primary, acct, fails: p.fails, acctFails: 0 };
}
// Constant-time-ish path for unknown users: verify against a fixed dummy hash.
let dummyHash: Promise<string> | null = null;

export const authModule: Module = (r, { db }) => {
  r.post('/auth/login', async (req) => withIpLimit(db, req, 'login', async () => {
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
      // not an employee: a marketing company's own sign-in (e-mail or mobile + password, 075)
      const digits = identifier.replace(/\D/g, '');
      const co = await one(db, `SELECT id, password_hash, status = 'active' AND login_active AS active, failed_logins, locked_until, must_change_password,
                                        device_lock, device_id FROM marketing_companies
                                 WHERE password_hash IS NOT NULL AND (lower(login_email) = lower(trim($1)) OR (length($2) >= 10 AND right(login_phone_norm, 10) = right($2, 10)))
                                 LIMIT 1`, [identifier.trim(), digits]);
      if (co) {
        const known = deviceId && co.device_id === deviceId ? deviceId : null;
        const res = await reserveFor(db, `c:${co.id}`, clientIp(req), known);
        if (!(await verifyPassword(password, co.password_hash))) {
          throw new AppError('unauthenticated', 'Wrong employee ID or password');
        }
        await clear(db, res.primary); if (res.acct) await clear(db, res.acct);
        await db.query(`UPDATE marketing_companies SET failed_logins = 0, locked_until = NULL WHERE id = $1`, [co.id]);
        if (!co.active) throw new AppError('forbidden', 'This account is deactivated');
        // «ربط الحساب بالجهاز»: the first device is its device; another one is refused until the administration frees it
        if (co.device_lock) {
          if (!deviceId) throw new AppError('forbidden', 'This device could not be identified', { reason: 'device_required' });
          if (co.device_id && co.device_id !== deviceId) {
            throw new AppError('forbidden', 'This account is linked to another device. Ask the administration', { reason: 'device_rejected' });
          }
        }
        const { token, hash } = newToken();
        await db.tx(async (q) => {
          await q.query(`UPDATE marketing_companies SET failed_logins = 0, locked_until = NULL,
                           device_id = CASE WHEN device_lock AND device_id IS NULL THEN $2 ELSE device_id END,
                           device_label = CASE WHEN device_lock AND device_id IS NULL THEN $3 ELSE device_label END WHERE id = $1`,
            [co.id, deviceId, deviceLabel]);
          await q.query(`INSERT INTO partner_sessions (token_hash, company_id, expires_at, user_agent)
                         VALUES ($1,$2, now() + make_interval(hours => $3), $4)`,
            [hash, co.id, SESSION_TTL_HOURS, String(req.headers['user-agent'] ?? '').slice(0, 200)]);
          await audit(q, null, 'partner.login', 'marketing_company', co.id);
        });
        return ok({ token, mustChangePassword: co.must_change_password, expiresInHours: SESSION_TTL_HOURS, partner: true });
      }
      // an unknown name is throttled exactly like a real account (same replies, same waits): no enumeration
      const u = await reserve(db, unknownBucket(identifier, clientIp(req)));
      if (!u.ok) throw lockedError(u.retryAfterS);
      dummyHash ??= hashPassword('dummy-password-1');
      await verifyPassword(password, await dummyHash);
      throw new AppError('unauthenticated', 'Wrong employee ID or password');
    }
    // a phone already approved for this account (or the device of its last sessions) has its own bucket
    const known = deviceId && await one(db, `SELECT 1 FROM employee_devices WHERE employee_id = $1 AND device_id = $2 AND status = 'approved'
                                              UNION ALL SELECT 1 FROM sessions WHERE employee_id = $1 AND device_id = $2 LIMIT 1`, [emp.id, deviceId]) ? deviceId : null;
    const res = await reserveFor(db, `e:${emp.id}`, clientIp(req), known);
    const good = await verifyPassword(password, emp.password_hash);
    if (!good) {
      if (res.fails === PAIR_FREE) {
        // suspicious: sign-in from this network / device now waits — the owners hear about it (once per wait window)
        await audit(db, emp.id, 'auth.locked', 'employee', emp.id, undefined, { scope: known ? 'device' : 'network' });
        const n = await one(db, `SELECT full_name FROM employees WHERE id = $1`, [emp.id]);
        await securityAlert(db, `lock:${emp.id}:${Math.floor(Date.now() / 900000)}`, 'تنبيه أمان: حساب اتقفل',
          `${n?.full_name ?? ''} — ${PAIR_FREE} محاولات دخول غلط، الدخول من نفس الشبكة أو الجهاز اتوقف مؤقتًا (الموظف يقدر يدخل من موبايله المعتمد)`);
      }
      if (res.acct && res.acctFails === ACCT_FREE) {
        await audit(db, emp.id, 'auth.distributed_attempts', 'employee', emp.id);
        const n = await one(db, `SELECT full_name FROM employees WHERE id = $1`, [emp.id]);
        await securityAlert(db, `acct:${emp.id}:${Math.floor(Date.now() / 3600000)}`, 'تنبيه أمان: محاولات دخول من شبكات كتير',
          `${n?.full_name ?? ''} — ${ACCT_FREE} محاولة غلط من أجهزة غير معتمدة خلال ساعة، الدخول من أجهزة جديدة بقى أبطأ`);
      }
      throw new AppError('unauthenticated', 'Wrong employee ID or password');
    }
    // the right password: the reserved attempts are given back (a phone waiting for approval is not a failure)
    await clear(db, res.primary); if (res.acct) await clear(db, res.acct);
    if (emp.status !== 'active') throw new AppError('forbidden', 'This account is deactivated');
    // «ربط الحساب بالجهاز» (never for owners): the first phone is linked by itself, any other phone waits for the
    // general manager / administrative officer to approve it — only approved phones sign in
    const bind = emp.device_lock === true && emp.role_key !== 'owner';
    if (bind && !deviceId) throw new AppError('forbidden', 'This device could not be identified', { reason: 'device_required' });
    if (bind) {
      const dev = await one(db, `SELECT id, status FROM employee_devices WHERE employee_id = $1 AND device_id = $2`, [emp.id, deviceId]);
      if (dev?.status === 'rejected') {
        throw new AppError('forbidden', 'The request to use this phone was refused. Ask the administration', { reason: 'device_rejected' });
      }
      if (dev?.status !== 'approved') {
        const any = await one(db, `SELECT 1 FROM employee_devices WHERE employee_id = $1 AND status = 'approved'`, [emp.id]);
        if (any) {
          // a new phone: ask for approval once (asking again from the same phone only repeats the message)
          await db.tx(async (q) => {
            const ins = await one(q, `INSERT INTO employee_devices (employee_id, device_id, label) VALUES ($1,$2,$3)
                                      ON CONFLICT (employee_id, device_id) DO NOTHING RETURNING id`, [emp.id, deviceId, deviceLabel]);
            if (!ins) return;
            await audit(q, emp.id, 'auth.device_requested', 'employee', emp.id, undefined, { label: deviceLabel });
            const who = await one(q, `SELECT full_name FROM employees WHERE id = $1`, [emp.id]);
            for (const to of await deviceApprovers(q, emp.id)) {
              await notify(q, { to, type: 'device_request', title: `${who.full_name} عايز يدخل من جهاز جديد 📱`,
                body: `${deviceLabel ?? 'جهاز'} — محتاج موافقتك من صفحة الموظف`, entity: 'employee', entityId: emp.id,
                dedupeKey: `device_request:${ins.id}` });
            }
          });
          throw new AppError('forbidden', 'This phone is waiting for the administration to approve it', { reason: 'device_pending' });
        }
      }
    }
    const { token, hash } = newToken();
    await db.tx(async (q) => {
      await q.query(`UPDATE employees SET failed_logins = 0, locked_until = NULL WHERE id = $1`, [emp.id]);
      if (bind) {
        // the first phone: linked by itself (no approved phone yet)
        const first = await one(q, `INSERT INTO employee_devices (employee_id, device_id, label, status, decided_at, last_login_at)
                                    VALUES ($1,$2,$3,'approved', now(), now())
                                    ON CONFLICT (employee_id, device_id) DO UPDATE SET last_login_at = now(),
                                      status = 'approved', decided_at = COALESCE(employee_devices.decided_at, now())
                                    RETURNING (xmax = 0) AS created`, [emp.id, deviceId, deviceLabel]);
        if (first?.created) await audit(q, emp.id, 'auth.device_bound', 'employee', emp.id, undefined, { label: deviceLabel });
      } else if (deviceId) {
        await q.query(`UPDATE employee_devices SET last_login_at = now() WHERE employee_id = $1 AND device_id = $2 AND status = 'approved'`, [emp.id, deviceId]);
      }
      await q.query(`INSERT INTO sessions (token_hash, employee_id, expires_at, user_agent, device_id)
                     VALUES ($1,$2, now() + make_interval(hours => $3), $4, $5)`,
        [hash, emp.id, SESSION_TTL_HOURS, String(req.headers['user-agent'] ?? '').slice(0, 200), deviceId]);
      await audit(q, emp.id, 'auth.login', 'employee', emp.id);
    });
    return ok({ token, mustChangePassword: emp.must_change_password, expiresInHours: SESSION_TTL_HOURS });
  }));

  r.post('/auth/logout', async (req) => {
    const p = await partnerOf(db, req);
    if (p) {
      await db.query(`UPDATE partner_sessions SET revoked_at = now() WHERE id = $1`, [p.sessionId]);
      return ok({ ok: true });
    }
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

  r.post('/auth/forgot', async (req) => withIpLimit(db, req, 'forgot', async () => {
    const b = obj(req.body);
    const identifier = reqStr(b, 'identifier', { max: 120 });
    if (!mailEnabled()) throw new AppError('unprocessable', 'Email is not set up yet — ask HR to reset your password', { reason: 'mail_off' });
    const e = await findAccount(identifier);
    // VA-10: the same reply whatever happens below (no account, no e-mail, too many codes, mail refused) — the caller
    // can never learn whether an employee code / phone / e-mail exists or has an e-mail
    if (e?.email) {
      // one request at a time per account (parallel requests can not slip past the limits), at most 3 codes in 15
      // minutes and 8 a day, and none while the account's daily wrong-code budget is used up
      const code = String(randomInt(0, 10_000)).padStart(4, '0');
      const made = await db.tx(async (q) => {
        await q.query(`SELECT 1 FROM employees WHERE id = $1 FOR UPDATE`, [e.id]);
        const n = await one(q, `SELECT count(*) FILTER (WHERE created_at > now() - interval '15 minutes')::int AS recent,
                                       count(*)::int AS day, COALESCE(sum(attempts), 0)::int AS wrong
                                  FROM password_otps WHERE employee_id = $1 AND created_at > now() - interval '24 hours'`, [e.id]);
        if (n.recent >= 3 || n.day >= OTP_CODES_PER_DAY || n.wrong >= OTP_WRONG_PER_DAY) {
          // when the next code may be asked for: the oldest code of the window that is full falls out of it
          const w = n.recent >= 3 ? `15 minutes` : `24 hours`;
          return { limited: true as const, why: n.recent >= 3 ? 'recent' : n.day >= OTP_CODES_PER_DAY ? 'day' : 'wrong',
            retryAt: (await one(q, `SELECT min(created_at) + interval '${w}' AS t FROM password_otps
                                     WHERE employee_id = $1 AND created_at > now() - interval '${w}'`, [e.id]))?.t as Date | null };
        }
        await q.query(`UPDATE password_otps SET expires_at = now() WHERE employee_id = $1 AND verified_at IS NULL AND expires_at > now()`, [e.id]);
        await q.query(`INSERT INTO password_otps (employee_id, code_hash, expires_at) VALUES ($1,$2, now() + interval '10 minutes')`, [e.id, sha(`${e.id}:${code}`)]);
        return true;
      });
      if (made !== true) {
        await audit(db, e.id, 'auth.otp_rate_limited', 'employee', e.id, undefined, { why: made.why });
        // the owner's choice (2026-11-23): say plainly that the limit is reached and when it frees up
        const at = made.retryAt ? new Date(made.retryAt) : null;
        const when = at ? at.toLocaleString('ar-EG', { timeZone: 'Africa/Cairo', hour: 'numeric', minute: '2-digit', weekday: 'long' }) : null;
        const msg = made.why === 'recent'
          ? `وصلت للحد المسموح به: 3 أكواد كل ربع ساعة — جرّب تاني${when ? ` بعد ${when}` : ' بعد ربع ساعة'}`
          : made.why === 'day'
            ? `وصلت للحد المسموح به: ${OTP_CODES_PER_DAY} أكواد في اليوم — جرّب تاني${when ? ` ${when}` : ' بكرة'}`
            : `وصلت للحد المسموح به من المحاولات الغلط النهارده — جرّب تاني${when ? ` ${when}` : ' بكرة'} أو كلّم الموارد البشرية`;
        throw new AppError('rate_limited', msg, { reason: 'otp_limit', why: made.why, retryAt: at ? at.toISOString() : null });
      }
      const st = await one(db, `SELECT company_name_ar FROM company_settings`);
      const sent = await sendMail({ to: e.email, toName: e.full_name, ...otpMail({ name: e.full_name, code, company: st.company_name_ar }) });
      await audit(db, e.id, sent ? 'auth.otp_sent' : 'auth.otp_send_failed', 'employee', e.id, undefined, sent ? undefined : { reason: lastMailError });
    } else if (e) {
      await audit(db, e.id, 'auth.otp_no_email', 'employee', e.id);
    }
    return ok({ ok: true, message: GENERIC });
  }, true));

  r.post('/auth/forgot/verify', async (req) => withIpLimit(db, req, 'otp', async () => {
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
      // the account's wrong codes over the last day (all its codes): a 4-digit code can not be guessed by asking again
      const day = await one(q, `SELECT COALESCE(sum(attempts), 0)::int AS wrong FROM password_otps
                                 WHERE employee_id = $1 AND created_at > now() - interval '24 hours'`, [e.id]);
      if (day.wrong >= OTP_WRONG_PER_DAY) return null;
      if (o.code_hash !== sha(`${e.id}:${code}`)) {
        await q.query(`UPDATE password_otps SET attempts = attempts + 1 WHERE id = $1`, [o.id]);
        if (day.wrong + 1 === OTP_WRONG_PER_DAY) {
          await audit(q, e.id, 'auth.otp_locked_day', 'employee', e.id);
          const { securityAlert } = await import('../auth/alerts.ts');
          await securityAlert(q, `otpday:${e.id}:${new Date().toISOString().slice(0, 10)}`, 'تنبيه أمان: محاولات كود استرجاع كتير',
            `${e.full_name ?? ''} — ${OTP_WRONG_PER_DAY} أكواد غلط النهارده، استرجاع الباسورد اتقفل للحساب ده 24 ساعة`);
        }
        return null;
      }
      await q.query(`UPDATE password_otps SET verified_at = now(), reset_token_hash = $2, reset_expires_at = now() + interval '15 minutes' WHERE id = $1`,
        [o.id, sha(token)]);
      return o;
    });
    if (!okRow) throw bad();
    return ok({ resetToken: token });
  }));

  r.post('/auth/forgot/reset', async (req) => withIpLimit(db, req, 'otp', async () => {
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
      await clearAccount(q, `e:${o.employee_id}`);
      await q.query(`UPDATE password_otps SET consumed_at = now() WHERE id = $1`, [o.id]);
      await audit(q, o.employee_id, 'auth.password_reset_by_otp', 'employee', o.employee_id);
      return true;
    });
    return ok({ ok: done });
  }));

  r.post('/auth/change-password', async (req) => {
    const p = await partnerOf(db, req);
    if (p) {
      const b = obj(req.body);
      const current = reqStr(b, 'currentPassword', { max: 128 });
      const next = b.newPassword;
      const policy = passwordPolicyError(next);
      if (policy) throw invalid(policy, { field: 'newPassword' });
      if (next === current) throw invalid('New password must differ from the current one', { field: 'newPassword' });
      const row = await one(db, `SELECT password_hash FROM marketing_companies WHERE id = $1`, [p.companyId]);
      if (!(await verifyPassword(current, row.password_hash))) throw invalid('Current password is wrong', { field: 'currentPassword' });
      const hash = await hashPassword(next as string);
      await db.tx(async (q) => {
        await q.query(`UPDATE marketing_companies SET password_hash = $2, must_change_password = false WHERE id = $1`, [p.companyId, hash]);
        await q.query(`UPDATE partner_sessions SET revoked_at = now() WHERE company_id = $1 AND id <> $2 AND revoked_at IS NULL`, [p.companyId, p.sessionId]);
        await audit(q, null, 'partner.password_changed', 'marketing_company', p.companyId);
      });
      return ok({ ok: true });
    }
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
    // a marketing company: the same shape the app reads, with the role «marketing_partner» and no permissions
    const p = await partnerOf(db, req);
    if (p) {
      const c = await one(db, `SELECT id, name, login_email AS email, login_phone AS phone, must_change_password FROM marketing_companies WHERE id = $1`, [p.companyId]);
      const s = await one(db, `SELECT company_name_ar, company_name_en, currency FROM company_settings`);
      return ok({
        employee: { id: c.id, code: `MK-${String(c.id).slice(0, 8).toUpperCase()}`, full_name: c.name, email: c.email, phone: c.phone, role_key: 'marketing_partner',
          role: 'marketing_partner', role_name_ar: 'شركة تسويق', role_name_en: 'Marketing company', partner: true,
          must_change_password: c.must_change_password, has_photo: false, manages_team: false, settled: false },
        permissions: [], company: s,
      });
    }
    const a = await authenticate(db, req, { allowPasswordChange: true });
    const e = await one(db, `
      SELECT e.id, e.code, e.full_name, e.job_title, e.role_key, e.email, e.phone,
             e.department_id, d.name_ar AS department_name, e.team_id, t.name AS team_name,
             e.sales_manager_id, m.full_name AS sales_manager_name, e.joining_date,
             e.must_change_password, (e.photo_mime IS NOT NULL) AS has_photo, e.role_key AS role,
             r.name_ar AS role_name_ar, r.name_en AS role_name_en, e.position_key, po.name_ar AS position_name_ar,
             EXISTS (SELECT 1 FROM teams WHERE manager_id = e.id AND active) AS manages_team,
             (e.legacy_fields->>'status' IS NOT DISTINCT FROM 'تم التصفيه') AS settled
        FROM employees e
        JOIN roles r ON r.key = e.role_key
        LEFT JOIN roles po ON po.key = e.position_key
        LEFT JOIN departments d ON d.id = e.department_id
        LEFT JOIN teams t ON t.id = e.team_id
        LEFT JOIN employees m ON m.id = e.sales_manager_id
       WHERE e.id = $1`, [a.id]);
    const s = await one(db, `SELECT company_name_ar, company_name_en, gps_required, currency, allow_pin, device_binding, break_minutes FROM company_settings`);
    return ok({ employee: e, permissions: effectivePermissions(a), company: s });
  });
};
