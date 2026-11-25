import { createHash, randomInt } from 'node:crypto';
import type { Q } from '../db.ts';
import { one } from '../db.ts';
import { AppError } from '../http/errors.ts';
import { actionCodeMail, mailEnabled, sendMail } from '../lib/mail.ts';
import type { Actor } from './context.ts';

/**
 * A sensitive change confirmed by a 4-digit code e-mailed to the person making it (082) — the same OTP page as
 * «نسيت كلمة المرور». sendActionCode e-mails it; takeActionCode checks it once (5 tries, 10 minutes).
 */
const sha = (s: string) => createHash('sha256').update(s).digest('hex');

export async function sendActionCode(q: Q, a: Actor, action: string, what: string): Promise<string> {
  const e = await one(q, `SELECT email, full_name FROM employees WHERE id = $1`, [a.id]);
  if (!e?.email) throw new AppError('unprocessable', 'مفيش إيميل على حسابك — لازم إيميل عشان يوصلك الكود', { reason: 'no_email' });
  if (!mailEnabled()) throw new AppError('unprocessable', 'الإيميل مش متظبط لسه', { reason: 'mail_off' });
  // the e-mailed codes only: Meta OAuth state nonces (action «meta_oauth_state», no e-mail) are not counted
  const recent = await one(q, `SELECT count(*)::int AS n FROM action_otps WHERE employee_id = $1 AND action <> 'meta_oauth_state' AND created_at > now() - interval '15 minutes'`, [a.id]);
  if (recent.n >= 3) throw new AppError('conflict', 'طلبت أكواد كتير — استنى ربع ساعة', { reason: 'otp_rate_limited' });
  const code = String(randomInt(0, 10_000)).padStart(4, '0');
  await q.query(`UPDATE action_otps SET expires_at = now() WHERE employee_id = $1 AND action = $2 AND used_at IS NULL AND expires_at > now()`, [a.id, action]);
  await q.query(`INSERT INTO action_otps (employee_id, action, code_hash, expires_at) VALUES ($1,$2,$3, now() + interval '10 minutes')`,
    [a.id, action, sha(`${a.id}:${action}:${code}`)]);
  const st = await one(q, `SELECT company_name_ar FROM company_settings`);
  const sent = await sendMail({ to: e.email, toName: e.full_name, ...actionCodeMail({ name: e.full_name, code, company: st?.company_name_ar ?? 'VALUNIVO', what }) });
  if (!sent) throw new AppError('unprocessable', 'مقدرناش نبعت الكود دلوقتي — جرّب تاني', { reason: 'mail_failed' });
  return String(e.email).replace(/^(.).*?(@.*)$/, '$1***$2');
}

export async function takeActionCode(q: Q, a: Actor, action: string, code: unknown): Promise<void> {
  const bad = () => new AppError('validation_failed', 'الكود غلط أو خلص وقته', { reason: 'otp_invalid', field: 'code' });
  if (typeof code !== 'string' || !/^\d{4}$/.test(code)) throw bad();
  const o = await one(q, `SELECT * FROM action_otps WHERE employee_id = $1 AND action = $2 AND used_at IS NULL AND expires_at > now()
                            ORDER BY created_at DESC LIMIT 1 FOR UPDATE`, [a.id, action]);
  if (!o || o.attempts >= 5) throw bad();
  if (o.code_hash !== sha(`${a.id}:${action}:${code}`)) {
    await q.query(`UPDATE action_otps SET attempts = attempts + 1 WHERE id = $1`, [o.id]);
    throw bad();
  }
  await q.query(`UPDATE action_otps SET used_at = now() WHERE id = $1`, [o.id]);
}
