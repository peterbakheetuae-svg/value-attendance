import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/**
 * One sales flow for both project kinds (حجز → تعاقد), marketing companies, the owner's injection and the cashbox
 * read the office's way (المتاح = بنك + نقدي مكتب + نقدي محاسب; الدخل = عمولات / مبيعات / ضخ / أمانات).
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-11-10T10:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

test('a marketing project: reservation → contract, a marketing company takes its % from the office share', async () => {
  const p = await h.call(c.t.owner, 'POST', '/commissions/projects', { name: 'Kayan', totalPct: 3, salesPct: 0.2, managerPct: 0.1, companyPct: 2.7 });
  assert.equal(p.status, 201, JSON.stringify(p.body));
  const pid = p.body.project.id;
  const ex = await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج', ownerName: 'أ. سامي' });
  // the unified list: both kinds, and each filter
  const all = await h.call(c.t.owner, 'GET', '/exclusive/projects?kind=all');
  assert.deepEqual(all.body.projects.map((x: any) => x.kind).sort(), ['exclusive', 'marketing']);
  assert.equal((await h.call(c.t.owner, 'GET', '/exclusive/projects?kind=marketing')).body.projects.length, 1);

  // marketing companies: owner only creates; the sales team picks from the active ones
  assert.equal((await h.call(c.t.e1, 'POST', '/marketing-companies', { name: 'X', kind: 'fixed' })).status, 403);
  const fixed = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة الراتب', kind: 'fixed', monthlyFee: 15000 });
  const mk = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة العمولة', kind: 'commission', defaultPct: 0.5 });
  assert.equal(mk.status, 201, JSON.stringify(mk.body));
  assert.equal((await h.call(c.t.e1, 'GET', '/marketing-companies')).body.companies.length, 2);

  // reserve a marketing unit through the same flow, client came from the commission company
  const tooMuch = await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'M-1', clientName: 'عميل تسويق', unitPrice: 2_000_000,
    depositAmount: 20_000, marketingCompanyId: mk.body.company.id, marketingPct: 3 });
  assert.equal(tooMuch.status, 400, 'more than the office share');
  const u = await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'M-1', clientName: 'عميل تسويق', clientPhone: '01011112222',
    unitPrice: 2_000_000, depositAmount: 20_000, marketingCompanyId: mk.body.company.id });
  assert.equal(u.status, 201, JSON.stringify(u.body));
  const uid = u.body.unit.id;
  assert.equal(u.body.unit.projectKind, 'marketing');
  assert.equal(u.body.unit.marketingPct, 0.5);
  assert.equal(u.body.unit.contractPct, undefined, 'the office figures are not the salesperson\'s');
  const asOwner = await h.call(c.t.owner, 'GET', `/exclusive/units/${u.body.unit.id}`);
  assert.equal(asOwner.body.unit.contractPct, 3, 'a marketing unit earns all its commission at the contract');
  const seen = (await h.call(c.t.e1, 'GET', '/exclusive/projects?kind=all')).body.projects;
  assert.ok(seen.every((x: any) => x.companyPct === undefined && x.totalPct === undefined));
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'reservation', amount: 20_000 })).status, 201);
  // reservations tab vs contracts tab
  assert.equal((await h.call(c.t.owner, 'GET', '/exclusive/units?stage=reservation')).body.units.length, 1);
  assert.equal((await h.call(c.t.owner, 'GET', '/exclusive/units?stage=contract')).body.units.length, 0);

  const k = await h.call(c.t.e1, 'POST', `/exclusive/units/${uid}/contract`, { paymentType: 'installments', downPayment: 200_000,
    installmentsCount: 4, everyMonths: 3, firstDueDate: '2027-01-01', installmentPct: 1 });
  assert.equal(k.status, 200, JSON.stringify(k.body));
  assert.equal(k.body.unit.contract.installmentPct, 0, 'no staged commission on a marketing project');
  const ap = await h.call(c.t.owner, 'POST', `/exclusive/units/${uid}/contract/decision`, { decision: 'approve' });
  assert.equal(ap.status, 200, JSON.stringify(ap.body));
  const cm = ap.body.unit.commission;
  assert.equal(cm.earned, 60_000, '3% at the contract');
  assert.equal(cm.staff, 6_000);
  assert.equal(cm.marketing, 10_000, '0.5% to the marketing company');
  assert.equal(cm.office, 44_000, 'office = 3% − 0.2% − 0.1% − 0.5%');
  assert.equal((await h.call(c.t.owner, 'GET', '/exclusive/units?stage=contract')).body.units.length, 1);
  const cos = (await h.call(c.t.owner, 'GET', '/marketing-companies')).body.companies;
  assert.equal(cos.find((x: any) => x.kind === 'commission').totals.due, 10_000);

  // the fixed company's monthly fee is an office expense paid from the bank
  const fee = await h.call(c.t.owner, 'POST', '/cash/expenses', { cashbox: 'office', amount: 15000, category: 'شركة تسويق', reason: 'رسوم نوفمبر',
    beneficiary: 'شركة الراتب', paymentMethod: 'bank', marketingCompanyId: fixed.body.company.id });
  assert.equal(fee.status, 201, JSON.stringify(fee.body));
  assert.equal(fee.body.expense.paymentMethod, 'bank');

  // clients: the buyer with what he paid; owners: the exclusive project's owner
  const cl = await h.call(c.t.owner, 'GET', '/exclusive/clients');
  assert.equal(cl.body.clients[0].name, 'عميل تسويق');
  assert.equal(cl.body.clients[0].paid, 20_000);
  const ow = await h.call(c.t.owner, 'GET', '/exclusive/owners');
  assert.equal(ow.status, 200);
  assert.equal(ow.body.owners[0].name, 'أ. سامي');
  assert.equal(ow.body.owners[0].projects[0].id, ex.body.project.id);
  assert.equal((await h.call(c.t.e1, 'GET', '/exclusive/owners')).status, 403);
});

test('injection + the cashbox overview: available (bank / office cash / accountant cash) and income by kind', async () => {
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/injections', { target: 'office', amount: 1000 })).status, 403, 'owner only');
  for (const [target, amount] of [['bank', 100_000], ['office', 30_000], ['hr', 10_000]] as const) {
    const r = await h.call(c.t.owner, 'POST', '/cash/injections', { target, amount, note: 'تكملة المرتبات' });
    assert.equal(r.status, 201, JSON.stringify(r.body));
  }
  // the developer pays the office its commission
  const cr = await h.call(c.t.owner, 'POST', '/cash/receipts', { recipient: 'manager', kind: 'commission', amount: 44_000, payerName: 'Kayan Developments',
    purpose: 'عمولة وحدة M-1', paymentMethod: 'bank_transfer' });
  assert.equal(cr.status, 201, JSON.stringify(cr.body));

  const o = await h.call(c.t.owner, 'GET', '/cash/overview?from=2026-11-01&to=2026-11-30');
  assert.equal(o.status, 200, JSON.stringify(o.body));
  const v = o.body.available;
  // bank: 100k injection + 44k commission − 15k fee = 129k; office cash 30k; accountant cash: 10k + 20k deposit
  assert.equal(v.bank, 129_000);
  assert.equal(v.office.cash, 30_000);
  assert.equal(v.hr.cash, 30_000);
  assert.equal(v.cash, 60_000);
  assert.equal(v.total, 189_000);
  assert.equal(o.body.income.injection, 140_000);
  assert.equal(o.body.income.sales.reservation, 20_000);
  assert.equal(o.body.income.commissions, 44_000);
  assert.equal(o.body.commissionSplit.marketing, 10_000);
  assert.equal(o.body.commissionSplit.office, 44_000);
  assert.equal(o.body.expenses.byCategory[0].name, 'شركة تسويق');
  assert.equal(o.body.result.net, 44_000 - 15_000);

  // المحاسب sees his own box only
  const acc = await h.call(c.t.hr, 'GET', '/cash/overview');
  assert.equal(acc.status, 200);
  assert.equal(acc.body.available.office, undefined);
  assert.equal(acc.body.available.total, undefined);
  assert.equal(acc.body.available.hr.cash, 30_000);
  assert.equal(acc.body.commissionSplit, undefined);
});
