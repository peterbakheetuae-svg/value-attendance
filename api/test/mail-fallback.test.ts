import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { sendMail, mailTransport, smtpNeverAccepted, fallbackAllowed, __setSmtpFactoryForTests, lastMailError } from '../src/lib/mail.ts';
import * as mail from '../src/lib/mail.ts';

/**
 * Email transport (SEC remediation H): Gmail SMTP stays the live transport; the Brevo fallback is OFF unless
 * MAIL_FALLBACK=brevo, and even then it is used only when SMTP certainly did not take the message (one attempt, never a
 * second copy of a code). No network: SMTP is a stub, Brevo's HTTP API is a stubbed fetch.
 */
const ENV = ['SMTP_HOST', 'SMTP_USER', 'SMTP_PASS', 'SMTP_PORT', 'SMTP_FROM', 'BREVO_API_KEY', 'MAIL_FROM', 'MAIL_FALLBACK', 'MAIL_FROM_NAME'];
const saved: Record<string, string | undefined> = {};
const realFetch = globalThis.fetch;
let smtpCalls: any[] = []; let brevoCalls: any[] = [];
let smtpResult: () => Promise<any> = async () => ({ accepted: ['x'], rejected: [], response: '250 OK' });
const msg = { to: 'employee@example.test', toName: 'موظف', subject: 'كود', html: '<p>1234</p>', text: '1234' };
const smtpErr = (code: string, command?: string) => Object.assign(new Error(`${code} failure for employee@example.test pass=gmail-app-pass`), { code, command });

beforeEach(() => {
  for (const k of ENV) { saved[k] = process.env[k]; delete process.env[k]; }
  Object.assign(process.env, { SMTP_HOST: 'smtp.gmail.com', SMTP_USER: 'valunivo.mailer@gmail.com', SMTP_PASS: 'gmail-app-pass',
    BREVO_API_KEY: 'xkeysib-test', MAIL_FROM: 'noreply@valueaqar.com' });
  smtpCalls = []; brevoCalls = [];
  __setSmtpFactoryForTests(() => async (m) => { smtpCalls.push(m); return smtpResult(); });
  globalThis.fetch = (async (url: string, init: any) => { brevoCalls.push({ url, body: JSON.parse(init.body), headers: init.headers }); return new Response('{}', { status: 201 }); }) as any;
});
afterEach(() => {
  for (const k of ENV) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  __setSmtpFactoryForTests(null); globalThis.fetch = realFetch;
  smtpResult = async () => ({ accepted: ['x'], rejected: [], response: '250 OK' });
});

test('SMTP success: one SMTP message, Brevo never called, sender identity kept', async () => {
  process.env.MAIL_FALLBACK = 'brevo';
  assert.equal(mailTransport(), 'smtp');
  assert.equal(await sendMail(msg), true);
  assert.equal(smtpCalls.length, 1); assert.equal(brevoCalls.length, 0);
  assert.equal(smtpCalls[0].from.address, 'valunivo.mailer@gmail.com');
});

test('SMTP failure with the fallback off (default): false, no Brevo call (current production behaviour)', async () => {
  smtpResult = async () => { throw smtpErr('EAUTH', 'AUTH PLAIN'); };
  assert.equal(fallbackAllowed(), false);
  assert.equal(await sendMail(msg), false);
  assert.equal(brevoCalls.length, 0);
  assert.ok(!String(lastMailError).includes('gmail-app-pass') && !String(lastMailError).includes('employee@example.test'), 'no secret / address in the error');
});

test('fallback success: SMTP sign-in refused → one Brevo message from MAIL_FROM', async () => {
  process.env.MAIL_FALLBACK = 'brevo';
  smtpResult = async () => { throw smtpErr('EAUTH', 'AUTH PLAIN'); };
  assert.equal(await sendMail(msg), true);
  assert.equal(smtpCalls.length, 1); assert.equal(brevoCalls.length, 1);
  assert.equal(brevoCalls[0].body.sender.email, 'noreply@valueaqar.com');
  assert.equal(brevoCalls[0].body.to[0].email, 'employee@example.test');
});

test('no duplicate codes: a failure during / after DATA, or a refused recipient, never falls back', async () => {
  process.env.MAIL_FALLBACK = 'brevo';
  for (const [code, cmd] of [['ETIMEDOUT', 'DATA'], ['ESOCKET', 'MESSAGE'], ['EENVELOPE', 'RCPT TO'], ['EMESSAGE', 'DATA']]) {
    brevoCalls = [];
    smtpResult = async () => { throw smtpErr(code, cmd); };
    assert.equal(await sendMail(msg), false, `${code}/${cmd}`);
    assert.equal(brevoCalls.length, 0, `${code}/${cmd}: no second copy`);
  }
  smtpResult = async () => ({ accepted: [], rejected: ['employee@example.test'], response: '550 no such user' });
  assert.equal(await sendMail(msg), false);
  assert.equal(brevoCalls.length, 0);
  assert.deepEqual([smtpNeverAccepted({ code: 'ECONNECTION', command: 'CONN' }), smtpNeverAccepted({ code: 'ETIMEDOUT', command: 'CONN' }),
    smtpNeverAccepted({ code: 'ETIMEDOUT', command: 'DATA' }), smtpNeverAccepted({ code: 'EDNS' })], [true, true, false, true]);
});

test('total delivery failure: SMTP down and Brevo refusing → false, one attempt each, reason kept without secrets', async () => {
  process.env.MAIL_FALLBACK = 'brevo';
  smtpResult = async () => { throw smtpErr('ECONNECTION', 'CONN'); };
  globalThis.fetch = (async (url: string, init: any) => { brevoCalls.push({ url, body: JSON.parse(init.body) }); return new Response('sender not verified', { status: 400 }); }) as any;
  assert.equal(await sendMail(msg), false);
  assert.equal(smtpCalls.length, 1); assert.equal(brevoCalls.length, 1);
  assert.match(String(mail.lastMailError), /^brevo 400/);
  assert.ok(!String(mail.lastMailError).includes('xkeysib-test'));
});

test('Brevo alone (no SMTP configured) behaves as before', async () => {
  delete process.env.SMTP_HOST;
  assert.equal(mailTransport(), 'brevo');
  assert.equal(await sendMail(msg), true);
  assert.equal(smtpCalls.length, 0); assert.equal(brevoCalls.length, 1);
});
