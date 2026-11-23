import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Server, type Socket } from 'node:net';
import { createHash } from 'node:crypto';
import nodemailer from 'nodemailer';
import { harness, cast, type Harness } from './helpers.ts';
import {
  sendMail, mailEnabled, mailTransport, smtpConfig, smtpTransportOptions, safeMailError, __setSmtpFactoryForTests,
  otpMail, passwordResetMail, actionCodeMail, emailChangeMail, lastMailError,
} from '../src/lib/mail.ts';
import * as mail from '../src/lib/mail.ts';

/**
 * Temporary Gmail SMTP transport. No real mail is sent: a local SMTP server stands in for smtp.gmail.com and records each
 * conversation. Only TLS is relaxed for that local server (the production options themselves are checked separately).
 */
const APP_PASSWORD = 'abcd efgh ijkl mnop'; // a fake App Password (shape of Google's 16 letters)
const USER = 'valunivo.mailer@gmail.com';

type Conv = { auth?: string; from?: string; rcpt: string[]; data?: string };
let server: Server; let port = 0;
let mode: 'ok' | 'auth_fail' | 'rcpt_fail' = 'ok';
let convs: Conv[] = []; let connections = 0;

function startSmtp() {
  return new Promise<void>((resolve) => {
    server = createServer((s: Socket) => {
      connections++;
      const c: Conv = { rcpt: [] }; convs.push(c);
      let inData = false; let buf = ''; let authStep: 'none' | 'login_user' | 'login_pass' = 'none'; let loginUser = '';
      const w = (l: string) => s.write(l + '\r\n');
      w('220 local.test ESMTP');
      s.on('data', (d) => {
        buf += d.toString('utf8');
        let i: number;
        while ((i = buf.indexOf('\r\n')) >= 0) {
          const line = buf.slice(0, i); buf = buf.slice(i + 2);
          if (inData) {
            if (line === '.') { inData = false; w('250 2.0.0 OK queued'); } else c.data = (c.data ?? '') + line + '\n';
            continue;
          }
          if (authStep === 'login_user') { loginUser = Buffer.from(line, 'base64').toString(); authStep = 'login_pass'; w('334 UGFzc3dvcmQ6'); continue; }
          if (authStep === 'login_pass') {
            authStep = 'none'; c.auth = `${loginUser}\0${Buffer.from(line, 'base64').toString()}`;
            mode === 'auth_fail' ? w(`535-5.7.8 Username and Password not accepted for ${loginUser}`) : w('235 2.7.0 Accepted');
            if (mode === 'auth_fail') w('535 5.7.8 https://support.google.com/mail/?p=BadCredentials');
            continue;
          }
          const cmd = line.toUpperCase();
          if (cmd.startsWith('EHLO') || cmd.startsWith('HELO')) { w('250-local.test'); w('250-AUTH PLAIN LOGIN'); w('250 8BITMIME'); }
          else if (cmd.startsWith('AUTH PLAIN')) {
            const [, , arg] = line.split(' ');
            c.auth = Buffer.from(arg ?? '', 'base64').toString().replace(/^\0/, '');
            if (mode === 'auth_fail') { w(`535-5.7.8 Username and Password not accepted for ${c.auth.split('\0')[0]}`); w('535 5.7.8 https://support.google.com/mail/?p=BadCredentials'); }
            else w('235 2.7.0 Accepted');
          } else if (cmd.startsWith('AUTH LOGIN')) { authStep = 'login_user'; w('334 VXNlcm5hbWU6'); }
          else if (cmd.startsWith('MAIL FROM')) { c.from = line; w('250 2.1.0 OK'); }
          else if (cmd.startsWith('RCPT TO')) { c.rcpt.push(line); mode === 'rcpt_fail' ? w(`550 5.1.1 ${line.slice(8)} User unknown`) : w('250 2.1.5 OK'); }
          else if (cmd === 'DATA') { inData = true; w('354 Go ahead'); }
          else if (cmd === 'QUIT') { w('221 bye'); s.end(); }
          else if (cmd === 'RSET') w('250 OK');
          else w('502 not implemented');
        }
      });
      s.on('error', () => {});
    });
    server.listen(0, '127.0.0.1', () => { port = (server.address() as any).port; resolve(); });
  });
}

/** the production options, pointed at the local server (TLS off only because the local server has none) */
function useLocalServer() {
  __setSmtpFactoryForTests((c) => {
    const t = nodemailer.createTransport({ ...smtpTransportOptions(c), host: '127.0.0.1', port, secure: false, requireTLS: false, ignoreTLS: true });
    return (m) => t.sendMail(m);
  });
}

const ENV = ['SMTP_HOST', 'SMTP_PORT', 'SMTP_SECURE', 'SMTP_USER', 'SMTP_PASS', 'SMTP_FROM', 'BREVO_API_KEY', 'MAIL_FROM', 'MAIL_FROM_NAME'];
function clearEnv() { for (const k of ENV) delete process.env[k]; }
function gmailEnv() { process.env.SMTP_HOST = 'smtp.gmail.com'; process.env.SMTP_USER = USER; process.env.SMTP_PASS = APP_PASSWORD; }

/** console output captured while fn runs */
async function captureLogs<T>(fn: () => Promise<T>): Promise<{ r: T; out: string }> {
  const lines: string[] = []; const l = console.log, e = console.error;
  console.log = (...a: unknown[]) => { lines.push(a.join(' ')); }; console.error = (...a: unknown[]) => { lines.push(a.join(' ')); };
  try { return { r: await fn(), out: lines.join('\n') }; } finally { console.log = l; console.error = e; }
}

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { await startSmtp(); h = await harness(); c = await cast(h); });
after(async () => { clearEnv(); __setSmtpFactoryForTests(null); server.close(); await h.close(); });
beforeEach(() => { clearEnv(); mode = 'ok'; convs = []; connections = 0; useLocalServer(); });

test('configuration: SMTP only when host + user + App Password are all set; it takes precedence over Brevo; Brevo unchanged otherwise', () => {
  assert.equal(mailTransport(), null); assert.equal(mailEnabled(), false);
  process.env.BREVO_API_KEY = 'k'; process.env.MAIL_FROM = 'hr@value.test';
  assert.equal(mailTransport(), 'brevo');
  process.env.SMTP_HOST = 'smtp.gmail.com'; process.env.SMTP_USER = USER;
  assert.equal(mailTransport(), 'brevo', 'no password → SMTP not used');
  process.env.SMTP_PASS = APP_PASSWORD;
  assert.equal(mailTransport(), 'smtp'); assert.equal(mailEnabled(), true);
  const cfg = smtpConfig()!;
  assert.deepEqual({ port: cfg.port, secure: cfg.secure, from: cfg.from }, { port: 465, secure: true, from: USER }, 'Gmail defaults: 465 implicit TLS, sends as the account');
  process.env.SMTP_PORT = '587';
  assert.equal(smtpConfig()!.secure, false);
  const o587 = smtpTransportOptions(smtpConfig()!);
  assert.equal(o587.requireTLS, true, 'port 587 must upgrade with STARTTLS before AUTH');
  process.env.SMTP_PORT = '465'; process.env.SMTP_SECURE = 'false';
  assert.equal(smtpConfig()!.secure, false);
  process.env.SMTP_PORT = 'abc';
  assert.equal(smtpConfig(), null, 'an invalid port disables SMTP (falls back), never a guess');
  process.env.SMTP_PORT = '465'; delete process.env.SMTP_SECURE; process.env.SMTP_FROM = 'other@gmail.com';
  assert.equal(smtpConfig()!.from, 'other@gmail.com');
  const o = smtpTransportOptions(smtpConfig()!);
  assert.deepEqual([o.host, o.port, o.secure, o.requireTLS, o.pool, o.connectionTimeout, o.greetingTimeout, o.socketTimeout],
    ['smtp.gmail.com', 465, true, false, false, 8000, 8000, 10000]);
});

test('send: one SMTP conversation authenticated with the App Password, sent as the Gmail account, Arabic content intact', async () => {
  gmailEnv(); process.env.MAIL_FROM_NAME = 'Value Square';
  const m = otpMail({ name: 'أحمد', code: '4821', company: 'فاليو' });
  const { r, out } = await captureLogs(() => sendMail({ to: 'employee@value.test', toName: 'أحمد', ...m }));
  assert.equal(r, true);
  assert.equal(convs.length, 1);
  assert.equal(convs[0].auth, `${USER}\0${APP_PASSWORD}`);
  assert.match(convs[0].from!, new RegExp(`<${USER}>`));
  assert.deepEqual(convs[0].rcpt, ['RCPT TO:<employee@value.test>']);
  const raw = convs[0].data!;
  assert.match(raw, /^From: .*Value Square.*<valunivo\.mailer@gmail\.com>/m);
  assert.match(raw, /^Subject: =\?UTF-8\?/m, 'subject encoded as UTF-8');
  const text = Buffer.from(raw.split(/\n\n/).slice(1).join('\n\n').replace(/=\r?\n/g, ''), 'latin1').toString();
  assert.ok(raw.includes('4821') || text.includes('4821') || /NDgyMQ|4821/.test(raw), 'the code is in the message');
  assert.equal(lastMailError, null);
  assert.match(out, /"msg":"mail_accepted","transport":"smtp","reply":"250 2\.0\.0 OK queued"/);
  assert.ok(!out.includes('employee@value.test') && !out.includes(APP_PASSWORD) && !out.includes(USER), 'log has no address, no password');
});

test('authentication refused (bad App Password): returns false once, no retry, error kept without password or addresses', async () => {
  gmailEnv(); mode = 'auth_fail';
  const { r, out } = await captureLogs(() => sendMail({ to: 'employee@value.test', subject: 's', html: 'h', text: 't' }));
  assert.equal(r, false);
  assert.equal(connections, 1, 'no automatic retry');
  assert.equal(convs[0].rcpt.length, 0, 'nothing sent after the refusal');
  const err = mail.lastMailError!;
  assert.match(err, /^smtp EAUTH 535/);
  for (const s of [APP_PASSWORD, USER, 'employee@value.test']) {
    assert.ok(!err.includes(s), `error does not contain ${s === APP_PASSWORD ? 'the password' : 'an address'}`);
    assert.ok(!out.includes(s), 'log does not either');
  }
  assert.match(out, /"msg":"mail_failed","transport":"smtp"/);
});

test('recipient refused: false, sanitized reason', async () => {
  gmailEnv(); mode = 'rcpt_fail';
  const { r, out } = await captureLogs(() => sendMail({ to: 'nobody@value.test', subject: 's', html: 'h', text: 't' }));
  assert.equal(r, false);
  assert.ok(!mail.lastMailError!.includes('nobody@value.test') && !out.includes('nobody@value.test'));
  assert.match(mail.lastMailError!, /^smtp E\w+/);
});

test('server unreachable: false quickly, sanitized, no retry', async () => {
  gmailEnv();
  __setSmtpFactoryForTests((cfg) => {
    const t = nodemailer.createTransport({ ...smtpTransportOptions(cfg), host: '127.0.0.1', port: 1, secure: false, requireTLS: false, ignoreTLS: true });
    return (m) => t.sendMail(m);
  });
  const t0 = Date.now();
  const { r } = await captureLogs(() => sendMail({ to: 'employee@value.test', subject: 's', html: 'h', text: 't' }));
  assert.equal(r, false);
  assert.ok(Date.now() - t0 < 9000);
  assert.match(mail.lastMailError!, /^smtp (ECONNECTION|ESOCKET|ECONNREFUSED)/);
});

test('safeMailError strips credentials and every address, and bounds the length', () => {
  const s = safeMailError(`535 Username and Password not accepted for ${USER} pass=${APP_PASSWORD} rcpt a.b+c@x.co ${'x'.repeat(500)}`, [APP_PASSWORD, USER]);
  assert.ok(!s.includes(APP_PASSWORD) && !s.includes(USER) && !s.includes('a.b+c@x.co'));
  assert.ok(s.length <= 300);
});

test('Brevo path unchanged when SMTP is not configured', async () => {
  process.env.BREVO_API_KEY = 'k'; process.env.MAIL_FROM = 'hr@value.test';
  const real = globalThis.fetch; let calls = 0;
  globalThis.fetch = (async (url: any) => { if (String(url).startsWith('https://api.brevo.com/')) { calls++; return new Response('{}', { status: 201 }); } return real(url); }) as typeof fetch;
  try {
    assert.equal(await sendMail({ to: 'x@value.test', subject: 's', html: 'h', text: 't' }), true);
    assert.equal(calls, 1); assert.equal(convs.length, 0);
  } finally { globalThis.fetch = real; }
});

test('forgot password through SMTP: same reply, one email with a working code; a refused send is audited without secrets', async () => {
  gmailEnv();
  await h.db.query(`UPDATE employees SET email = 'solo@value.test' WHERE code = 'SOLO'`);
  const r = await h.call(null, 'POST', '/auth/forgot', { identifier: 'SOLO' });
  assert.equal(r.status, 200);
  assert.equal(convs.length, 1);
  assert.deepEqual(convs[0].rcpt, ['RCPT TO:<solo@value.test>']);
  // the code in the message is the one stored (hashed) for the account
  const raw = convs[0].data!;
  const body = raw.includes('Content-Transfer-Encoding: base64')
    ? raw.split(/\n\n/).slice(1).map((p) => { try { return Buffer.from(p.replace(/\n/g, ''), 'base64').toString('utf8'); } catch { return p; } }).join('\n')
    : raw.replace(/=\n/g, '');
  const decoded = body.replace(/=([0-9A-F]{2})/g, (_, x) => String.fromCharCode(parseInt(x, 16)));
  const codes = [...new Set([...decoded.matchAll(/\b(\d{4})\b/g)].map((m) => m[1]))];
  const row = (await h.db.query(`SELECT code_hash FROM password_otps WHERE employee_id = $1 ORDER BY created_at DESC LIMIT 1`, [c.ids.solo])).rows[0];
  const code = codes.find((x) => createHash('sha256').update(`${c.ids.solo}:${x}`).digest('hex') === row.code_hash);
  assert.ok(code, 'the emailed code matches the stored one');
  const v = await h.call(null, 'POST', '/auth/forgot/verify', { identifier: 'SOLO', code });
  assert.equal(v.status, 200, JSON.stringify(v.body));
  assert.ok(v.body.resetToken);
  const sent = (await h.db.query(`SELECT count(*)::int AS n FROM audit_log WHERE action = 'auth.otp_sent'`)).rows[0].n;
  assert.ok(sent >= 1);

  mode = 'auth_fail';
  await h.db.query(`UPDATE password_otps SET created_at = now() - interval '1 hour' WHERE employee_id = $1`, [c.ids.solo]);
  const r2 = await captureLogs(() => h.call(null, 'POST', '/auth/forgot', { identifier: 'SOLO' }));
  assert.equal(r2.r.status, 200, 'same reply to the caller whatever the mail result');
  const failed = (await h.db.query(`SELECT after AS details FROM audit_log WHERE action = 'auth.otp_send_failed' ORDER BY id DESC LIMIT 1`)).rows[0];
  assert.ok(failed, 'the refused send is audited');
  const d = JSON.stringify(failed.details);
  assert.match(d, /smtp EAUTH 535/);
  assert.ok(!d.includes(APP_PASSWORD) && !d.includes(USER) && !d.includes('solo@value.test'));
});

test('HR password reset email goes through the same SMTP transport', async () => {
  gmailEnv();
  await h.db.query(`UPDATE employees SET email = 'e1@value.test' WHERE code = 'E1'`);
  const r = await h.call(c.t.hr, 'POST', `/employees/${c.ids.e1}/reset-password`, {});
  assert.ok([200, 201].includes(r.status), JSON.stringify(r.body));
  assert.equal(convs.length, 1);
  assert.deepEqual(convs[0].rcpt, ['RCPT TO:<e1@value.test>']);
});

test('the sender people see is exactly «VALUNIVO» on all four emails (forgot password, payout code, HR reset, marketing company code)', async () => {
  gmailEnv();
  const four = {
    'forgot-password OTP': otpMail({ name: 'أحمد', code: '4821', company: 'فاليو' }),
    'payout confirmation OTP': actionCodeMail({ name: 'أحمد', code: '7310', company: 'فاليو', what: 'استلام صرف' }),
    'HR password reset': passwordResetMail({ name: 'أحمد', code: 'E1', password: 'Temp-1234', company: 'فاليو', isPin: false }),
    'marketing-company email code': emailChangeMail({ name: 'شركة', code: '5512', company: 'فاليو' }),
  };
  for (const [flow, m] of Object.entries(four)) {
    convs = [];
    assert.equal(await sendMail({ to: 'someone@value.test', toName: 'أحمد', ...m }), true, flow);
    assert.equal(convs.length, 1, flow);
    const from = convs[0].data!.split('\n').find((l) => /^From: /.test(l));
    assert.equal(from, `From: VALUNIVO <${USER}>`, `${flow}: visible sender`);
    assert.match(convs[0].from!, new RegExp(`^MAIL FROM:<${USER.replace(/\./g, '\\.')}>`), `${flow}: the Gmail account is still the sender address`);
  }
});
