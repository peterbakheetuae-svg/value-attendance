import nodemailer, { type SendMailOptions } from 'nodemailer';
import { ICON, WORDMARK } from './email-assets.ts';

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

/** an image shown inside the email body (<img src="cid:…">), sent as an inline attachment */
export type InlineImage = { cid: string; filename: string; contentType: string; base64: string };

export async function sendMail(m: { to: string; toName?: string; subject: string; html: string; text: string; inline?: InlineImage[] }): Promise<boolean> {
  const smtp = smtpConfig();
  if (smtp) {
    try {
      const r = await makeSmtp(smtp)({
        // the name people see in their inbox (the address stays the Gmail account itself)
        from: { name: process.env.MAIL_FROM_NAME || 'VALUNIVO', address: smtp.from },
        to: m.toName ? { name: m.toName, address: m.to } : m.to,
        subject: m.subject, html: m.html, text: m.text,
        ...(m.inline?.length ? { attachments: m.inline.map((i) => ({ filename: i.filename, contentType: i.contentType, cid: i.cid, content: Buffer.from(i.base64, 'base64') })) } : {}),
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
        // the Brevo API sends no inline images: the same page without them (the text logo stays)
        subject: m.subject, htmlContent: m.inline?.length ? withoutInlineImages(m.html) : m.html, textContent: m.text,
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

/** the page without its inline (cid:) images — for a transport that cannot attach them */
export function withoutInlineImages(html: string) {
  return html.replace(/<img\b[^>]*\bsrc="cid:[^"]*"[^>]*>/g, '').replace(/\sbackground="cid:[^"]*"/g, '');
}

/**
 * the images every VALUNIVO code email shows (logo, wordmark). No header texture: Gmail does not draw a cid: image used as a
 * background (the `background` attribute / CSS url), so it showed it as a loose picture under the message instead.
 */
export const CODE_MAIL_IMAGES: InlineImage[] = [
  { cid: 'valunivo-icon', ...ICON }, { cid: 'valunivo-wordmark', ...WORDMARK },
];
const APP_URL = 'https://jaurea.com/valunivo/';

/**
 * The VALUNIVO code email (dark card, orange accent, logo + wordmark, the code in a dashed box, expiry, security note).
 * Every dynamic value is HTML-escaped; `intro` is trusted markup from this file only.
 */
export function codeMailHtml(p: { title: string; name: string; intro: string; code: string; minutes: number; preheader: string }) {
  const name = esc(p.name.trim() || 'عزيزنا المستخدم');
  const code = esc(p.code);
  return `<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="X-UA-Compatible" content="IE=edge">
  <meta name="x-apple-disable-message-reformatting">
  <meta name="format-detection" content="telephone=no,address=no,email=no,date=no,url=no">
  <title>${esc(p.title)} - VALUNIVO</title>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Cairo:wght@400;600;700;800&display=swap');
    body, table, td, a { -webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; font-family: 'Cairo', 'Segoe UI', Tahoma, Geneva, Verdana, Arial, sans-serif; }
    table, td { mso-table-lspace: 0pt; mso-table-rspace: 0pt; border-collapse: collapse; }
    img { -ms-interpolation-mode: bicubic; border: 0; height: auto; line-height: 100%; outline: none; text-decoration: none; display: block; }
    body { margin: 0 !important; padding: 0 !important; width: 100% !important; background-color: #09090b; }
    @media screen and (max-width: 600px) {
      .container { width: 100% !important; padding: 15px !important; }
      .otp-code { font-size: 30px !important; letter-spacing: 5px !important; }
      .otp-cell { padding: 16px 18px !important; }
      .body-cell { padding: 28px 22px 20px 22px !important; }
      .title { font-size: 21px !important; }
    }
  </style>
</head>
<body style="margin: 0; padding: 0; background-color: #09090b; color: #ffffff; direction: rtl;">
  <div style="display:none; font-size:1px; color:#09090b; line-height:1px; max-height:0; max-width:0; opacity:0; overflow:hidden; mso-hide:all; mso-line-height-rule:exactly;">
    ${esc(p.preheader)}
  </div>
  <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="background-color: #09090b;">
    <tr>
      <td align="center" style="padding: 40px 15px;">
        <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" class="container" dir="rtl"
               style="max-width: 560px; background-color: #121215; border: 1px solid #27272a; border-radius: 16px; overflow: hidden; box-shadow: 0 20px 40px rgba(0,0,0,0.6);">
          <tr>
            <td height="5" style="background-color: #ff5500; background: linear-gradient(90deg, #ff5500 0%, #ff8800 50%, #ff4500 100%); font-size: 0; line-height: 0;">&nbsp;</td>
          </tr>
          <tr>
            <td align="center" bgcolor="#000000"
                style="padding: 35px 30px 25px 30px; background-color: #000000; border-bottom: 1px solid #1f1f23;">
              <img src="cid:valunivo-icon" alt="VALUNIVO Icon" width="100" height="54"
                   style="display: block; margin: 0 auto 14px auto; border: 0; outline: none; text-decoration: none;">
              <img src="cid:valunivo-wordmark" alt="VALUNIVO" width="180" height="21"
                   style="display: block; margin: 0 auto; border: 0; outline: none; text-decoration: none; color: #ffffff; font-size: 22px; font-weight: 800; letter-spacing: 2px;">
            </td>
          </tr>
          <tr>
            <td align="center" class="body-cell" style="padding: 35px 35px 25px 35px; text-align: center;">
              <h1 class="title" style="margin: 0 0 12px 0; font-size: 24px; font-weight: 800; color: #ffffff; letter-spacing: -0.5px; mso-line-height-rule: exactly; line-height: 1.3;">
                ${esc(p.title)}
              </h1>
              <p style="margin: 0 0 28px 0; font-size: 15px; line-height: 1.7; color: #a1a1aa; mso-line-height-rule: exactly;">
                مرحباً <strong style="color: #ffffff;">${name}</strong>،<br>
                ${p.intro}
              </p>
              <table role="presentation" border="0" cellpadding="0" cellspacing="0" align="center" style="margin: 0 auto 28px auto;">
                <tr>
                  <td align="center" class="otp-cell"
                      style="background-color: #18181b; border: 1.5px dashed #ff6b00; border-radius: 12px; padding: 20px 25px;">
                    <span class="otp-code" dir="ltr"
                          style="font-family: 'Courier New', Courier, monospace; font-size: 36px; font-weight: 800; letter-spacing: 10px; color: #ff6b00; display: block; padding-right: 10px; mso-line-height-rule: exactly; line-height: 1.1;">${code}</span>
                  </td>
                </tr>
              </table>
              <p style="margin: 0 0 25px 0; font-size: 14px; color: #d4d4d8; mso-line-height-rule: exactly; line-height: 1.6;">
                ⏳ هذا الرمز صالح لمدة <strong style="color: #ff6b00;">${p.minutes} دقائق</strong> فقط.
              </p>
              <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%"
                     style="background-color: #251913; border-right: 3px solid #ff6b00; border-radius: 8px;">
                <tr>
                  <td style="padding: 14px 16px; font-size: 13px; line-height: 1.6; color: #a1a1aa; text-align: right; mso-line-height-rule: exactly;">
                    <strong style="color: #ff8533;">تنبيه أمني:</strong> لا تشارك هذا الرمز مع أي شخص إطلاقاً، حتى لو ادّعى أنه من فريق دعم <strong style="color: #ffffff;">VALUNIVO</strong>. إذا لم تقم بطلب هذا الرمز، يرجى تجاهل هذه الرسالة أو تأمين حسابك فوراً.
                  </td>
                </tr>
              </table>
              <p style="margin: 20px 0 0 0; font-size: 13px; color: #71717a; mso-line-height-rule: exactly; line-height: 1.6;">
                لم تطلب هذا الرمز؟
                <a href="${APP_URL}" style="color: #ff8533; text-decoration: underline; font-weight: 600;">أمّن حسابك الآن</a>
              </p>
            </td>
          </tr>
          <tr>
            <td align="center" style="padding: 22px 30px; background-color: #0c0c0e; border-top: 1px solid #1f1f23; text-align: center;">
              <p style="margin: 0 0 8px 0; font-size: 12px; color: #71717a; mso-line-height-rule: exactly; line-height: 1.6;">
                تم إرسال هذا البريد الإلكتروني تلقائياً من نظام إدارة الأعمال <strong style="color: #a1a1aa;">VALUNIVO</strong> (CRM • HR • Finance).
              </p>
              <p style="margin: 0; font-size: 12px; color: #52525b; mso-line-height-rule: exactly; line-height: 1.6;">
                &copy; ${new Date().getFullYear()} VALUNIVO. جميع الحقوق محفوظة.
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

/** minutes every emailed code stays valid (password_otps / action_otps / partner e-mail codes: 10 minutes) */
const CODE_MINUTES = 10;
const VAL = '<strong style="color: #ff6b00;">VALUNIVO</strong>';

/** Arabic RTL email with the 4-digit "forgot password" code. */
export function otpMail(p: { name: string; code: string; company: string }) {
  const text = `أهلاً ${p.name}\n\nكود استعادة كلمة المرور لتطبيق الحضور (${p.company}): ${p.code}\n` +
    'الكود صالح لمدة 10 دقايق. لو ماطلبتش ده، تجاهل الرسالة.\n\nللدعم: 01080660100 — info@valueaqar.com';
  const html = codeMailHtml({ title: 'رمز التحقق الأمني (OTP)', name: p.name, code: p.code, minutes: CODE_MINUTES,
    preheader: `رمز التحقق الخاص بك من VALUNIVO صالح لمدة ${CODE_MINUTES} دقائق — لا تشاركه مع أي شخص.`,
    intro: `لقد تلقينا طلباً لتأكيد هويتك والدخول إلى حسابك في نظام ${VAL}. يرجى استخدام رمز التحقق التالي لإتمام العملية:` });
  return { subject: `كود استعادة كلمة المرور — ${p.company}`, html, text, inline: CODE_MAIL_IMAGES };
}

/** the 4-digit code that confirms a new e-mail for an account («تعديل الحساب») */
export function emailChangeMail(p: { name: string; code: string; company: string }) {
  const text = `أهلاً ${p.name}\n\nكود تأكيد الإيميل الجديد لحسابك على تطبيق ${p.company}: ${p.code}\n` +
    'الكود صالح لمدة 10 دقايق. لو ماطلبتش ده، تجاهل الرسالة.';
  const html = codeMailHtml({ title: 'رمز تأكيد البريد الإلكتروني', name: p.name, code: p.code, minutes: CODE_MINUTES,
    preheader: `رمز تأكيد بريدك الإلكتروني من VALUNIVO صالح لمدة ${CODE_MINUTES} دقائق — لا تشاركه مع أي شخص.`,
    intro: `لقد تلقينا طلباً لتأكيد البريد الإلكتروني الجديد لحسابك في نظام ${VAL}. يرجى استخدام رمز التحقق التالي لإتمام العملية:` });
  return { subject: `كود تأكيد الإيميل — ${p.company}`, html, text, inline: CODE_MAIL_IMAGES };
}

/** the 4-digit code that confirms a sensitive change in the settings */
export function actionCodeMail(p: { name: string; code: string; company: string; what: string }) {
  const text = `أهلاً ${p.name}\n\nكود تأكيد «${p.what}» على تطبيق ${p.company}: ${p.code}\n` +
    'الكود صالح لمدة 10 دقايق. لو ماطلبتش ده، كلّم الإدارة فورًا.';
  const html = codeMailHtml({ title: 'رمز التحقق الأمني (OTP)', name: p.name, code: p.code, minutes: CODE_MINUTES,
    preheader: `رمز تأكيد «${p.what}» من VALUNIVO صالح لمدة ${CODE_MINUTES} دقائق — لا تشاركه مع أي شخص.`,
    intro: `لقد تلقينا طلباً لتأكيد «${esc(p.what)}» في نظام ${VAL}. يرجى استخدام رمز التحقق التالي لإتمام العملية:` });
  return { subject: `كود تأكيد — ${p.company}`, html, text, inline: CODE_MAIL_IMAGES };
}
