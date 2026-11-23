import nodemailer, { type SendMailOptions } from 'nodemailer';

/**
 * Transactional email. Two transports, chosen only by environment variables on the API host (Vercel):
 *
 *  - SMTP (TEMPORARY: a dedicated Gmail account until the company's own sending domain is authenticated) — used when
 *    SMTP_HOST, SMTP_USER and SMTP_PASS are all set. SMTP_PORT (default 465) and SMTP_SECURE (default true for 465) are
 *    optional. The sender is SMTP_FROM, else SMTP_USER (Gmail only sends as the signed-in account). SMTP_PASS is a Google
 *    App Password, never the account password. Gmail is a low-volume provider (a few hundred messages a day at most, with throttling) — fine for
 *    these one-recipient codes, not a permanent transactional service.
 *  - Brevo HTTP API — used when SMTP is not configured and BREVO_API_KEY + MAIL_FROM are set (unchanged behaviour).
 *
 * Without either, email is simply off and callers fall back to showing the value on screen. One attempt per message, no
 * automatic retries. Acceptance by the provider is not proof of inbox delivery. Errors never carry secrets or addresses.
 */
type Smtp = { host: string; port: number; secure: boolean; user: string; pass: string; from: string };

export function smtpConfig(): Smtp | null {
  const host = process.env.SMTP_HOST?.trim(), user = process.env.SMTP_USER?.trim(), pass = process.env.SMTP_PASS;
  if (!host || !user || !pass) return null;
  const port = Number(process.env.SMTP_PORT ?? 465);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
  const sec = (process.env.SMTP_SECURE ?? '').trim().toLowerCase();
  const secure = sec === '' ? port === 465 : sec === 'true' || sec === '1';
  return { host, port, secure, user, pass, from: process.env.SMTP_FROM?.trim() || user };
}

/** Which transport a message would use now — for logs and diagnostics (never a secret). */
export const mailTransport = (): 'smtp' | 'brevo' | null =>
  smtpConfig() ? 'smtp' : process.env.BREVO_API_KEY && process.env.MAIL_FROM ? 'brevo' : null;

export const mailEnabled = () => mailTransport() !== null;

type Sender = (msg: SendMailOptions) => Promise<{ accepted?: unknown[]; rejected?: unknown[]; response?: string }>;
/** The connection settings for a configured SMTP account (exported for tests). */
export function smtpTransportOptions(c: Smtp) {
  return {
    host: c.host, port: c.port, secure: c.secure, auth: { user: c.user, pass: c.pass },
    requireTLS: !c.secure, // never send credentials or codes in clear text
    connectionTimeout: 8000, greetingTimeout: 8000, socketTimeout: 10000, // the request must not hang
    pool: false, // serverless: one short connection per message
  };
}
function defaultSmtp(c: Smtp): Sender {
  const t = nodemailer.createTransport(smtpTransportOptions(c));
  return (msg) => t.sendMail(msg);
}
let makeSmtp: (c: Smtp) => Sender = defaultSmtp;
/** tests only: replace the SMTP connection factory (e.g. to point at a local test server); null restores the default */
export function __setSmtpFactoryForTests(f: ((c: Smtp) => Sender) | null) { makeSmtp = f ?? defaultSmtp; }

/** A provider message reduced to something safe to store / log: no addresses, no credentials, bounded length. */
export function safeMailError(s: string, secrets: (string | undefined)[] = []): string {
  let out = s;
  for (const v of secrets) if (v && v.length >= 4) out = out.split(v).join('***');
  return out.replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '<addr>').replace(/\s+/g, ' ').slice(0, 300);
}

function logMail(level: 'info' | 'error', msg: string, extra: Record<string, unknown>) {
  const line = JSON.stringify({ t: new Date().toISOString(), level, msg, ...extra });
  level === 'error' ? console.error(line) : console.log(line);
}

export async function sendMail(m: { to: string; toName?: string; subject: string; html: string; text: string }): Promise<boolean> {
  const smtp = smtpConfig();
  if (smtp) {
    try {
      const r = await makeSmtp(smtp)({
        // the name people see in their inbox (the address stays the Gmail account itself)
        from: { name: process.env.MAIL_FROM_NAME || 'VALUNIVO', address: smtp.from },
        to: m.toName ? { name: m.toName, address: m.to } : m.to,
        subject: m.subject, html: m.html, text: m.text,
      });
      const ok = Array.isArray(r.accepted) && r.accepted.length > 0 && !(Array.isArray(r.rejected) && r.rejected.length);
      if (ok) {
        lastMailError = null;
        // provider acceptance only (not inbox delivery); the SMTP reply code, never the address
        logMail('info', 'mail_accepted', { transport: 'smtp', reply: safeMailError(String(r.response ?? '').slice(0, 40), [smtp.pass, smtp.user]) });
      } else {
        lastMailError = `smtp rejected: ${safeMailError(String(r.response ?? ''), [smtp.pass, smtp.user])}`;
        logMail('error', 'mail_failed', { transport: 'smtp', detail: lastMailError });
      }
      return ok;
    } catch (e) {
      const err = e as { code?: string; responseCode?: number; message?: string };
      lastMailError = `smtp ${err.code ?? 'error'}${err.responseCode ? ' ' + err.responseCode : ''}: ${safeMailError(String(err.message ?? e), [smtp.pass, smtp.user])}`;
      logMail('error', 'mail_failed', { transport: 'smtp', detail: lastMailError });
      return false;
    }
  }
  if (!mailEnabled()) return false;
  try {
    const r = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: { 'api-key': process.env.BREVO_API_KEY!, 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({
        sender: { email: process.env.MAIL_FROM, name: process.env.MAIL_FROM_NAME || 'Value Attendance' },
        to: [{ email: m.to, name: m.toName || m.to }],
        subject: m.subject, htmlContent: m.html, textContent: m.text,
      }),
      signal: AbortSignal.timeout(8000),
    });
    if (!r.ok) {
      // never logs the key; Brevo's reason (e.g. sender not verified, account not activated) goes to the host logs
      lastMailError = `brevo ${r.status}: ${(await r.text().catch(() => '')).slice(0, 300)}`;
      console.error(JSON.stringify({ t: new Date().toISOString(), level: 'error', msg: 'mail_failed', detail: lastMailError }));
    } else lastMailError = null;
    return r.ok;
  } catch (e) {
    lastMailError = `network: ${String(e).slice(0, 200)}`;
    console.error(JSON.stringify({ t: new Date().toISOString(), level: 'error', msg: 'mail_failed', detail: lastMailError }));
    return false;
  }
}

/** Last send failure reason (no secrets, no addresses) — kept for the admin diagnostics. */
export let lastMailError: string | null = null;

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

/** Arabic RTL email with the new temporary password (must be changed at first sign-in). */
export function passwordResetMail(p: { name: string; code: string; password: string; company: string; isPin: boolean }) {
  const what = p.isPin ? 'الرقم السري الجديد' : 'كلمة المرور المؤقتة';
  const text = `أهلاً ${p.name}\n\nتم إعادة تعيين ${p.isPin ? 'الرقم السري' : 'كلمة المرور'} لحسابك في تطبيق الحضور (${p.company}).\n` +
    `كود الموظف: ${p.code}\n${what}: ${p.password}\n\n` +
    (p.isPin ? '' : 'هيطلب منك التطبيق تغييرها أول ما تسجّل دخول.\n') +
    'لو ماطلبتش ده، كلّم الموارد البشرية فوراً.\n\nللدعم: 01080660100 — info@valueaqar.com';
  const html = `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;font-size:15px;line-height:1.8;color:#111">
    <p>أهلاً ${esc(p.name)}،</p>
    <p>تم إعادة تعيين ${p.isPin ? 'الرقم السري' : 'كلمة المرور'} لحسابك في تطبيق الحضور (${esc(p.company)}).</p>
    <p>كود الموظف: <b>${esc(p.code)}</b><br>${what}: <b style="font-size:18px;letter-spacing:1px">${esc(p.password)}</b></p>
    ${p.isPin ? '' : '<p>هيطلب منك التطبيق تغييرها أول ما تسجّل دخول.</p>'}
    <p style="color:#a00">لو ماطلبتش ده، كلّم الموارد البشرية فوراً.</p>
    <p style="color:#666;font-size:13px">للدعم: 01080660100 — info@valueaqar.com</p></div>`;
  return { subject: `${what} — ${p.company}`, html, text };
}

/** Arabic RTL email with the 4-digit "forgot password" code. */
export function otpMail(p: { name: string; code: string; company: string }) {
  const text = `أهلاً ${p.name}\n\nكود استعادة كلمة المرور لتطبيق الحضور (${p.company}): ${p.code}\n` +
    'الكود صالح لمدة 10 دقايق. لو ماطلبتش ده، تجاهل الرسالة.\n\nللدعم: 01080660100 — info@valueaqar.com';
  const html = `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;font-size:15px;line-height:1.8;color:#111">
    <p>أهلاً ${esc(p.name)}،</p><p>كود استعادة كلمة المرور لتطبيق الحضور (${esc(p.company)}):</p>
    <p style="font-size:30px;font-weight:bold;letter-spacing:10px;color:#4F46E5">${esc(p.code)}</p>
    <p>الكود صالح لمدة 10 دقايق. لو ماطلبتش ده، تجاهل الرسالة.</p>
    <p style="color:#666;font-size:13px">للدعم: 01080660100 — info@valueaqar.com</p></div>`;
  return { subject: `كود استعادة كلمة المرور — ${p.company}`, html, text };
}

/** the 4-digit code that confirms a new e-mail for an account («تعديل الحساب») */
export function emailChangeMail(p: { name: string; code: string; company: string }) {
  const text = `أهلاً ${p.name}\n\nكود تأكيد الإيميل الجديد لحسابك على تطبيق ${p.company}: ${p.code}\n` +
    'الكود صالح لمدة 10 دقايق. لو ماطلبتش ده، تجاهل الرسالة.';
  const html = `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;font-size:15px;line-height:1.8;color:#111">
    <p>أهلاً ${esc(p.name)}،</p><p>كود تأكيد الإيميل الجديد لحسابك على تطبيق ${esc(p.company)}:</p>
    <p style="font-size:30px;font-weight:bold;letter-spacing:10px;color:#4F46E5">${esc(p.code)}</p>
    <p>الكود صالح لمدة 10 دقايق. لو ماطلبتش ده، تجاهل الرسالة.</p></div>`;
  return { subject: `كود تأكيد الإيميل — ${p.company}`, html, text };
}

/** the 4-digit code that confirms a sensitive change in the settings */
export function actionCodeMail(p: { name: string; code: string; company: string; what: string }) {
  const text = `أهلاً ${p.name}\n\nكود تأكيد «${p.what}» على تطبيق ${p.company}: ${p.code}\n` +
    'الكود صالح لمدة 10 دقايق. لو ماطلبتش ده، كلّم الإدارة فورًا.';
  const html = `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;font-size:15px;line-height:1.8;color:#111">
    <p>أهلاً ${esc(p.name)}،</p><p>كود تأكيد «${esc(p.what)}» على تطبيق ${esc(p.company)}:</p>
    <p style="font-size:30px;font-weight:bold;letter-spacing:10px;color:#4F46E5">${esc(p.code)}</p>
    <p>الكود صالح لمدة 10 دقايق. لو ماطلبتش ده، كلّم الإدارة فورًا.</p></div>`;
  return { subject: `كود تأكيد — ${p.company}`, html, text };
}
