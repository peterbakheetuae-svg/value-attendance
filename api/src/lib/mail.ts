/**
 * Transactional email through Brevo (free plan: 300 emails/day, no card). Configured only by
 * environment variables on the API host (Vercel) — BREVO_API_KEY (secret) and MAIL_FROM (a sender verified in Brevo).
 * Without them, email is simply off and callers fall back to showing the value on screen.
 */
export const mailEnabled = () => !!process.env.BREVO_API_KEY && !!process.env.MAIL_FROM;

export async function sendMail(m: { to: string; toName?: string; subject: string; html: string; text: string }): Promise<boolean> {
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

/** Last Brevo failure reason (no secrets) — kept for the admin diagnostics. */
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
