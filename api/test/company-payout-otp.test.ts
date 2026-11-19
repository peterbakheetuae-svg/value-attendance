import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, type Harness } from './helpers.ts';
import { forgetCompanyOtp, nextPaymentDate } from '../src/modules/company-payouts.ts';

/**
 * The marketing companies' money with the disbursement code (db/proposed/084, applied here to a throwaway database only):
 * a fixed company's monthly fee from the salaries page, a commission company's earnings from the commissions page on its
 * payment day; each waits for the company's code (out of the cashbox only then); only the company gets the code, only
 * the payer enters it. Before 084 nothing changes.
 */
const SQL = readFileSync(new URL('../../db/proposed/084_marketing_company_payment_otp.sql', import.meta.url), 'utf8');
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let fixed = ''; let comm = ''; let noApp = ''; let tFixed = ''; let tComm = '';
const hrBox = async () => (await h.call(c.t.hr, 'GET', '/cash/summary')).body.hr.bookBalance;

async function company(name: string, kind: 'fixed' | 'commission', extra: Record<string, unknown>, email?: string) {
  const r = await h.call(c.t.owner, 'POST', '/marketing-companies', { name, kind, ...extra });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  if (!email) return { id: r.body.company.id as string, token: '' };
  const l = await h.call(c.t.owner, 'PATCH', `/leads/partners/${r.body.company.id}/login`, { email, password: 'Start#2026x' });
  assert.equal(l.status, 200, JSON.stringify(l.body));
  await h.db.query(`UPDATE marketing_companies SET must_change_password = false WHERE id = $1`, [r.body.company.id]);
  const lg = await h.call(null, 'POST', '/auth/login', { identifier: email, password: 'Start#2026x', deviceId: `device-${name.length}-000000000000000000` });
  assert.equal(lg.status, 200, JSON.stringify(lg.body));
  return { id: r.body.company.id as string, token: lg.body.token as string };
}

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.call(c.t.owner, 'POST', '/cash/adjustments', { cashbox: 'hr', kind: 'opening', amount: 100000, reason: 'رصيد افتتاحي' });
  ({ id: fixed, token: tFixed } = await company('ميديا ثابت', 'fixed', { monthlyFee: 800 }, 'fixed@media.test'));
  ({ id: comm, token: tComm } = await company('ميديا عمولة', 'commission', { defaultPct: 1 }, 'comm@media.test'));
  ({ id: noApp } = await company('شركة من غير تطبيق', 'fixed', { monthlyFee: 500 }));
  // what the commission company earned: a contracted unit it brought (1% of 300,000)
  const proj = (await h.db.query(`INSERT INTO commission_projects (name, kind, total_pct, sales_pct, manager_pct, company_pct, created_by)
                                   VALUES ('مشروع', 'marketing', 2, 1, 0, 1, $1) RETURNING id`, [c.ids.owner])).rows[0]?.id;
  if (proj) {
    await h.db.query(`INSERT INTO ex_units (project_id, unit_no, client_name, unit_price, deposit_amount, sales_id, total_pct, contract_pct, sales_pct,
                        manager_pct, status, payment_type, down_payment, contracted_by, mk_company_id, mk_pct)
                      VALUES ($1, 'U1', 'عميل', 300000, 10000, $2, 2, 2, 1, 0, 'contracted', 'cash', 300000, $3, $4, 1)`, [proj, c.ids.e1, c.ids.owner, comm]);
  }
});
after(async () => { await h.close(); });

test('before 084: nothing changes (an expense to a company is posted as today; the new endpoints say «not installed»)', async () => {
  const x = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 100, category: 'شركة تسويق', reason: 'دفعة', beneficiary: 'ميديا', marketingCompanyId: noApp });
  assert.equal(x.status, 201, JSON.stringify(x.body));
  assert.equal(x.body.expense.status, 'posted');
  const p = await h.call(c.t.hr, 'POST', `/marketing-companies/${fixed}/pay`, { month: '2026-03' });
  assert.equal(p.status, 409); assert.equal(p.body.error.details.reason, 'module_not_installed');
  assert.equal((await h.call(c.t.hr, 'GET', '/payouts/salaries?month=2026-03')).body.companies, null);
  await h.db.tx(async (q) => { await q.query(SQL); });
  forgetCompanyOtp();
});

test('a fixed company\'s fee: in the salaries page; paid with the company\'s code; out of the cashbox only then; never twice', async () => {
  const rows = (await h.call(c.t.hr, 'GET', '/payouts/salaries?month=2026-03')).body.companies;
  const row = rows.find((x: any) => x.companyId === fixed);
  assert.deepEqual([row.due, row.left, row.status, row.canPay], [800, 800, 'unpaid', true]);
  assert.ok(!rows.some((x: any) => x.companyId === comm), 'a commission company is not in the salaries');
  assert.equal((await h.call(c.t.e1, 'GET', '/payouts/salaries?month=2026-03')).status, 403);
  // a company without the app can not be paid this way
  const na = await h.call(c.t.hr, 'POST', `/marketing-companies/${noApp}/pay`, { month: '2026-03' });
  assert.equal(na.status, 422); assert.equal(na.body.error.details.reason, 'company_no_app');
  const before = await hrBox();
  const p = await h.call(c.t.hr, 'POST', `/marketing-companies/${fixed}/pay`, { month: '2026-03' });
  assert.equal(p.status, 201, JSON.stringify(p.body));
  assert.deepEqual([p.body.payment.amount, p.body.payment.status], [800, 'awaiting_otp']);
  assert.equal(await hrBox(), before, 'not out of the cashbox before the code');
  const again = await h.call(c.t.hr, 'POST', `/marketing-companies/${fixed}/pay`, { month: '2026-03' });
  assert.equal(again.body.error.details.reason, 'already_paid', 'the month is waiting already');
  // the company is told, without the code; only the company gets the code
  const notes = (await h.call(tFixed, 'GET', '/notifications')).body.notifications;
  const note = notes.find((n: any) => n.type === 'payment_otp');
  assert.ok(note, 'the company is told');
  const mine = (await h.call(tFixed, 'GET', '/partner/payments')).body.payments;
  assert.equal(mine.length, 1);
  assert.equal((await h.call(tComm, 'POST', `/partner/payments/${p.body.payment.id}/code`, {})).status, 404, 'another company');
  assert.equal((await h.call(c.t.hr, 'POST', `/partner/payments/${p.body.payment.id}/code`, {})).status, 401, 'an employee token is not a company');
  const k = await h.call(tFixed, 'POST', `/partner/payments/${p.body.payment.id}/code`, {});
  assert.equal(k.status, 200); assert.match(k.body.code, /^\d{4}$/);
  assert.ok(!`${note.title} ${note.body}`.replace(/2026-03/g, '').includes(k.body.code), 'the code is not in the notification');
  // wrong code / another employee / the right code once
  const wrong = k.body.code === '0000' ? '1111' : '0000';
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/expenses/${p.body.payment.id}/verify`, { code: wrong })).status, 400);
  assert.equal((await h.call(c.t.owner, 'POST', `/cash/expenses/${p.body.payment.id}/verify`, { code: k.body.code })).status, 404, 'only the payer');
  const ok = await h.call(c.t.hr, 'POST', `/cash/expenses/${p.body.payment.id}/verify`, { code: k.body.code });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/expenses/${p.body.payment.id}/verify`, { code: k.body.code })).status, 409, 'once');
  assert.equal(await hrBox(), before - 800, 'out of the cashbox once, now');
  const after = (await h.call(c.t.hr, 'GET', '/payouts/salaries?month=2026-03')).body.companies.find((x: any) => x.companyId === fixed);
  assert.deepEqual([after.paid, after.left, after.status], [800, 0, 'received']);
  assert.ok(!JSON.stringify((await h.db.query(`SELECT * FROM action_otps`)).rows).includes(`"${k.body.code}"`), 'only a hash stored');
});

test('a commission company: in the commissions page; paid on its payment day only; with its code', async () => {
  const earned = (await h.call(c.t.hr, 'GET', '/commissions/entitlements?scope=all')).body.companies;
  const row = earned?.find((x: any) => x.companyId === comm);
  assert.ok(row, 'the commission company with what it earned');
  assert.equal(row.left, 3000);
  // payment day 15: on the 10th it is not payable yet
  assert.equal((await h.call(c.t.owner, 'PATCH', `/marketing-companies/${comm}/payment-day`, { paymentDay: 15 })).status, 200);
  const r2 = (await h.call(c.t.hr, 'GET', '/commissions/entitlements?scope=all')).body.companies.find((x: any) => x.companyId === comm);
  assert.deepEqual([r2.payableNow, r2.nextPaymentDate, r2.canPay], [false, '2026-03-15', false]);
  const early = await h.call(c.t.hr, 'POST', `/marketing-companies/${comm}/pay`, {});
  assert.equal(early.status, 422); assert.equal(early.body.error.details.reason, 'not_payment_day');
  h.now.value = new Date('2026-03-15T09:00:00Z');
  const over = await h.call(c.t.hr, 'POST', `/marketing-companies/${comm}/pay`, { amount: 3500 });
  assert.equal(over.body.error.details.reason, 'over_pay');
  const p = await h.call(c.t.owner, 'POST', `/marketing-companies/${comm}/pay`, { cashbox: 'office', amount: 1000 });
  assert.equal(p.status, 201, JSON.stringify(p.body));
  const k = (await h.call(tComm, 'POST', `/partner/payments/${p.body.payment.id}/code`, {})).body.code;
  assert.equal((await h.call(c.t.owner, 'POST', `/cash/expenses/${p.body.payment.id}/verify`, { code: k })).status, 200);
  const r3 = (await h.call(c.t.hr, 'GET', '/commissions/entitlements?scope=all')).body.companies.find((x: any) => x.companyId === comm);
  assert.equal(r3.left, 2000);
});

test('the general expense form to a company follows the same code; a payment waiting can be taken back; nothing paid by a wrong code', async () => {
  const x = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 200, category: 'شركة تسويق', reason: 'إعلان', beneficiary: 'ميديا', marketingCompanyId: fixed });
  assert.equal(x.status, 201, JSON.stringify(x.body));
  assert.equal(x.body.expense.status, 'awaiting_otp');
  const na = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 200, category: 'شركة تسويق', reason: 'إعلان', beneficiary: 'شركة', marketingCompanyId: noApp });
  assert.equal(na.status, 422);
  const before = await hrBox();
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/expenses/${x.body.expense.id}/cancel-payment`, { reason: 'اتلغى الإعلان' })).status, 200);
  assert.equal(await hrBox(), before);
  assert.equal((await h.call(tFixed, 'POST', `/partner/payments/${x.body.expense.id}/code`, {})).status, 409, 'no code for a cancelled one');
  // above the approval threshold: approved first, then the company's code
  const big = await h.call(c.t.hr, 'POST', '/cash/expenses', { cashbox: 'hr', amount: 5000, category: 'شركة تسويق', reason: 'حملة', beneficiary: 'ميديا', marketingCompanyId: fixed });
  assert.equal(big.body.expense.status, 'pending_approval');
  assert.equal((await h.call(c.t.owner, 'POST', `/cash/expenses/${big.body.expense.id}/decision`, { decision: 'approve' })).status, 200);
  assert.equal((await h.db.query(`SELECT status FROM cash_expenses WHERE id = $1`, [big.body.expense.id])).rows[0].status, 'awaiting_otp');
  assert.equal(await hrBox(), before, 'approved is not paid');
  const k = (await h.call(tFixed, 'POST', `/partner/payments/${big.body.expense.id}/code`, {})).body.code;
  assert.equal((await h.call(c.t.hr, 'POST', `/cash/expenses/${big.body.expense.id}/verify`, { code: k })).status, 200);
  assert.equal(await hrBox(), before - 5000);
});

test('payment day helper', () => {
  assert.equal(nextPaymentDate('2026-03-10', 15), '2026-03-15');
  assert.equal(nextPaymentDate('2026-03-20', 15), '2026-04-15');
  assert.equal(nextPaymentDate('2026-12-20', 5), '2027-01-05');
  assert.equal(nextPaymentDate('2026-12-20', null), null);
});
