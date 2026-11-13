import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, insertEmployee, PW, type Harness } from './helpers.ts';

/**
 * One sales flow for both project kinds (حجز → تعاقد), marketing companies, the owner's injection and the cashbox
 * read the office's way (المتاح = بنك + نقدي مكتب + نقدي محاسب; الدخل = عمولات / مبيعات / ضخ / أمانات).
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-11-10T10:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

test('a marketing project: reservation → contract, a marketing company takes its % from the office share', async () => {
  const p = await h.call(c.t.owner, 'POST', '/commissions/projects', { name: 'Kayan', totalPct: 3, salesPct: 0.2, managerPct: 0.1, companyPct: 2.7, marketingPct: 0.5 });
  assert.equal(p.status, 201, JSON.stringify(p.body));
  assert.equal(p.body.project.marketingPct, 0.5);
  const pid = p.body.project.id;
  const ex = await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج', ownerName: 'أ. سامي' });
  // the unified list: both kinds, and each filter
  const all = await h.call(c.t.owner, 'GET', '/exclusive/projects?kind=all');
  assert.deepEqual(all.body.projects.map((x: any) => x.kind).sort(), ['exclusive', 'marketing']);
  assert.equal((await h.call(c.t.owner, 'GET', '/exclusive/projects?kind=marketing')).body.projects.length, 1);

  // marketing companies: owner only creates; the sales team picks from the active ones
  assert.equal((await h.call(c.t.e1, 'POST', '/marketing-companies', { name: 'X', kind: 'fixed' })).status, 403);
  const fixed = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة الراتب', kind: 'fixed', monthlyFee: 15000 });
  const mk = await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة العمولة', kind: 'commission' });
  assert.equal(mk.status, 201, JSON.stringify(mk.body));
  assert.equal((await h.call(c.t.e1, 'GET', '/marketing-companies')).body.companies.length, 2);
  assert.equal((await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'F-1', clientName: 'عميل', unitPrice: 1_000_000,
    marketingCompanyId: fixed.body.company.id })).status, 400, 'the client source is the office or a company paid by commission');
  assert.equal((await h.call(c.t.owner, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'M-9', clientName: 'عميل', unitPrice: 1_000_000,
    marketingCompanyId: mk.body.company.id, marketingPct: 3 })).status, 400, 'more than the office share');

  // حجز تسويق: no money of ours, only the potential commission; مصدر العميل = the commission company (the project's 0.5%)
  const u = await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'M-1', clientName: 'عميل تسويق', clientPhone: '01011112222',
    unitPrice: 2_000_000, marketingCompanyId: mk.body.company.id });
  assert.equal(u.status, 201, JSON.stringify(u.body));
  const uid = u.body.unit.id;
  assert.equal(u.body.unit.status, 'reserved');
  assert.equal(u.body.unit.projectKind, 'marketing');
  assert.equal(u.body.unit.marketingPct, undefined, 'the marketing company % is hidden from the salesperson');
  assert.equal(u.body.unit.money.collected, 0);
  assert.equal(u.body.unit.contractPct, undefined, 'the office figures are not the salesperson\'s');
  assert.equal(u.body.unit.can.collect, false, 'nothing to collect on a marketing unit');
  const asOwner = await h.call(c.t.owner, 'GET', `/exclusive/units/${uid}`);
  assert.equal(asOwner.body.unit.contractPct, 3, 'a marketing unit earns all its commission at the contract');
  assert.equal(asOwner.body.unit.marketingPct, 0.5);
  assert.equal(asOwner.body.unit.commission.potential, 60_000);
  const seen = (await h.call(c.t.e1, 'GET', '/exclusive/projects?kind=all')).body.projects;
  assert.ok(seen.every((x: any) => x.companyPct === undefined && x.totalPct === undefined));
  assert.equal((await h.call(c.t.owner, 'GET', '/exclusive/units?stage=reservation')).body.units.length, 1);
  assert.equal((await h.call(c.t.owner, 'GET', '/exclusive/units?stage=contract')).body.units.length, 0);

  // تعاقد by the salesperson: the commission becomes receivable
  const k = await h.call(c.t.e1, 'POST', `/exclusive/units/${uid}/contract`, {});
  assert.equal(k.status, 200, JSON.stringify(k.body));
  assert.equal(k.body.unit.status, 'contracted');
  const cm = (await h.call(c.t.owner, 'GET', `/exclusive/units/${uid}`)).body.unit.commission;
  assert.equal(cm.earned, 60_000, '3% at the contract');
  assert.equal(cm.receivable, 60_000);
  assert.equal(cm.staff, 6_000);
  assert.equal(cm.marketing, 10_000, '0.5% to the marketing company');
  assert.equal(cm.office, 44_000, 'office = 3% − 0.2% − 0.1% − 0.5%');
  assert.equal((await h.call(c.t.owner, 'GET', '/exclusive/units?stage=contract')).body.units.length, 1);
  const cos = (await h.call(c.t.owner, 'GET', '/marketing-companies')).body.companies;
  assert.equal(cos.find((x: any) => x.kind === 'commission').totals.due, 10_000);

  // تم التحصيل: the developer paid the commission into the bank → it is in the commissions
  const col = await h.call(c.t.owner, 'POST', `/exclusive/units/${uid}/commission-collected`, { paymentMethod: 'bank_transfer' });
  assert.equal(col.status, 201, JSON.stringify(col.body));
  assert.equal(col.body.unit.commission.receivable, 0);
  assert.equal(col.body.unit.money.collected, 0, 'the commission is not the client\'s money');

  // the fixed company's monthly fee is an office expense paid from the bank
  const fee = await h.call(c.t.owner, 'POST', '/cash/expenses', { cashbox: 'office', amount: 15000, category: 'شركة تسويق', reason: 'رسوم نوفمبر',
    beneficiary: 'شركة الراتب', paymentMethod: 'bank', marketingCompanyId: fixed.body.company.id });
  assert.equal(fee.status, 201, JSON.stringify(fee.body));
  assert.equal(fee.body.expense.paymentMethod, 'bank');

  // clients: the buyer with what he paid; owners: the exclusive project's owner
  const cl = await h.call(c.t.owner, 'GET', '/exclusive/clients');
  assert.equal(cl.body.clients[0].name, 'عميل تسويق');
  assert.equal(cl.body.clients[0].paid, 0);
  const ow = await h.call(c.t.owner, 'GET', '/exclusive/owners');
  assert.equal(ow.status, 200);
  assert.equal(ow.body.owners[0].name, 'أ. سامي');
  assert.equal(ow.body.owners[0].projects[0].id, ex.body.project.id);
  assert.equal((await h.call(c.t.e1, 'GET', '/exclusive/owners')).status, 403);
});

test('injection + the cashbox overview: available (bank / office cash / accountant cash) and income by kind', async () => {
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/injections', { target: 'office', amount: 1000 })).status, 403, 'owner only');
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/injections', { target: 'hr', amount: 10_000 })).status, 400, 'no injection into the accountant box');
  for (const [target, amount] of [['bank', 100_000], ['office', 30_000]] as const) {
    const r = await h.call(c.t.owner, 'POST', '/cash/injections', { target, amount, note: 'تكملة المرتبات' });
    assert.equal(r.status, 201, JSON.stringify(r.body));
  }
  const o = await h.call(c.t.owner, 'GET', '/cash/overview?from=2026-11-01&to=2026-11-30');
  assert.equal(o.status, 200, JSON.stringify(o.body));
  const v = o.body.available;
  // bank: 100k injection + 60k commission − 15k fee = 145k; office cash 30k; accountant cash 0
  assert.equal(v.bank, 145_000);
  assert.equal(v.office.cash, 30_000);
  assert.equal(v.hr.cash, 0);
  assert.equal(v.cash, 30_000);
  assert.equal(v.total, 175_000);
  assert.equal(o.body.income.injection, 130_000);
  assert.equal(o.body.income.sales.reservation, 0);
  assert.equal(o.body.income.commissions, 60_000);
  assert.equal(o.body.commissionSplit.marketing, 10_000);
  assert.equal(o.body.commissionSplit.office, 44_000);
  assert.equal(o.body.expenses.byCategory[0].name, 'شركة تسويق');
  assert.equal(o.body.result.net, 60_000 - 15_000);

  // المحاسب sees his own box only
  const acc = await h.call(c.t.hr, 'GET', '/cash/overview');
  assert.equal(acc.status, 200);
  assert.equal(acc.body.available.office, undefined);
  assert.equal(acc.body.available.total, undefined);
  assert.equal(acc.body.available.hr.cash, 0);
  assert.equal(acc.body.commissionSplit, undefined);
});

test('المطورين: every project belongs to a developer, with his accounts per kind', async () => {
  const ex = await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج المطور', developerName: 'شركة المستقبل', developerPhone: '0122' });
  assert.equal(ex.status, 201, JSON.stringify(ex.body));
  assert.equal(ex.body.project.ownerName, 'شركة المستقبل', 'an exclusive project\'s developer is its owner');
  const mk = await h.call(c.t.owner, 'POST', '/commissions/projects', { name: 'كمبوند المستقبل', totalPct: 3, salesPct: 0.2, managerPct: 0.1, companyPct: 2.7,
    developerName: 'شركة المستقبل' });
  assert.equal(mk.status, 201, JSON.stringify(mk.body));
  const list = await h.call(c.t.owner, 'GET', '/exclusive/developers');
  assert.equal(list.status, 200, JSON.stringify(list.body));
  const dev = list.body.developers.find((d: any) => d.name === 'شركة المستقبل');
  assert.equal(dev.exclusive.projects, 1);
  assert.equal(dev.marketing.projects, 1, 'one developer, both kinds');
  assert.equal((await h.call(c.t.e1, 'GET', '/exclusive/developers')).status, 403);
  // a marketing sale of his: the commission he owes
  const u = await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: mk.body.project.id, unitNo: 'D-1', clientName: 'عميل المطور', unitPrice: 1_000_000,
    contract: { paymentType: 'cash' } });
  assert.equal(u.status, 201, JSON.stringify(u.body));
  const one = await h.call(c.t.owner, 'GET', `/exclusive/developers/${dev.id}`);
  assert.equal(one.body.developer.marketing.commissionRemaining, 30_000);
  // a project moves to another developer; renaming the developer renames the exclusive owner
  const other = (await h.call(c.t.owner, 'POST', '/exclusive/developers', { name: 'مطور تاني' })).body.developer;
  assert.equal((await h.call(c.t.owner, 'POST', `/exclusive/projects/${ex.body.project.id}/developer`, { developerId: other.id })).status, 200);
  assert.equal((await h.call(c.t.owner, 'PATCH', `/exclusive/developers/${other.id}`, { name: 'مطور تاني جديد' })).status, 200);
  const p = await h.call(c.t.owner, 'GET', `/exclusive/projects/${ex.body.project.id}`);
  assert.deepEqual([p.body.project.developerName, p.body.project.ownerName], ['مطور تاني جديد', 'مطور تاني جديد']);
});

test('the projects\' setup (kind / developer) is المالك / المدير العام\'s and the accountant\'s only', async () => {
  const m = await h.call(c.t.hr, 'POST', '/exclusive/projects', { name: 'تسويق المحاسب', kind: 'marketing', totalPct: 3, developerName: 'مطور المحاسب' });
  assert.equal(m.status, 201, JSON.stringify(m.body));
  assert.equal(m.body.project.kind, 'marketing');
  assert.equal((await h.call(c.t.hr, 'GET', '/exclusive/developers')).status, 200);
  assert.equal((await h.call(c.t.e1, 'POST', '/exclusive/projects', { name: 'x', developerName: 'y' })).status, 403);
  const list = await h.call(c.t.e1, 'GET', '/exclusive/projects?kind=all');
  assert.equal(list.body.canSetup, false);
});

test('ضخ أموال: the injections, each owner\'s share and his part of the net profit', async () => {
  assert.equal((await h.call(c.t.hr, 'GET', '/cash/injections')).status, 403, 'المالك / المدير العام only');
  const ownerId = (await h.db.query(`SELECT id FROM employees WHERE code = 'OWNER'`)).rows[0].id;
  assert.equal((await h.call(c.t.owner, 'PUT', '/cash/owners', { owners: [{ employeeId: ownerId, pct: 120 }] })).status, 400);
  assert.equal((await h.call(c.t.owner, 'PUT', '/cash/owners', { owners: [{ employeeId: ownerId, pct: 50 }] })).status, 200);
  const r = await h.call(c.t.owner, 'GET', '/cash/injections');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const me = r.body.owners.find((o: any) => o.id === ownerId);
  assert.equal(me.pct, 50);
  assert.equal(me.injected, r.body.total, 'every injection here was his');
  assert.ok(r.body.injections.length >= 2);
  assert.equal(me.profit, Math.round(r.body.net * 50) / 100);
});

test('مسحوبات الملاك: an owner withdraws from his own account, another owner approves, it is not a cost', async () => {
  // alone, nobody can approve his withdrawal
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/owner-draws', { amount: 1000, paymentMethod: 'bank' })).status, 400);
  await insertEmployee(h.db, { code: 'OWNER2', name: 'مالك تاني', role: 'owner' });
  const o2 = await h.login('OWNER2', PW);
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/owner-draws', { amount: 1000 })).status, 403);
  const acc = (await h.call(c.t.owner, 'GET', '/cash/injections')).body;
  const ownerId = (await h.db.query(`SELECT id FROM employees WHERE code = 'OWNER'`)).rows[0].id;
  const mine = acc.owners.find((o: any) => o.id === ownerId).account;
  assert.equal(mine.balance, Math.round((mine.injected + mine.profit) * 100) / 100);
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/owner-draws', { amount: mine.balance + 1, paymentMethod: 'bank' })).status, 400, 'not more than his account');
  const d = await h.call(c.t.owner, 'POST', '/cash/owner-draws', { amount: 1000, paymentMethod: 'bank', note: 'أرباح' });
  assert.equal(d.status, 201, JSON.stringify(d.body));
  const before = (await h.call(c.t.owner, 'GET', '/cash/overview')).body;
  assert.equal((await h.call(c.t.owner, 'POST', `/cash/expenses/${d.body.draw.id}/decision`, { decision: 'approve' })).status, 403, 'not his own');
  assert.equal((await h.call(o2, 'POST', `/cash/expenses/${d.body.draw.id}/decision`, { decision: 'approve' })).status, 200);
  const after = (await h.call(c.t.owner, 'GET', '/cash/overview')).body;
  assert.equal(after.available.bank, before.available.bank - 1000, 'the money left the bank');
  assert.equal(after.expenses.ownerDraws, 1000);
  assert.equal(after.expenses.total, before.expenses.total, 'not one of the office\'s costs');
  const acc2 = (await h.call(o2, 'GET', '/cash/injections')).body;
  const mine2 = acc2.owners.find((o: any) => o.id === ownerId).account;
  assert.equal(mine2.withdrawn, 1000);
  assert.equal(acc2.draws[0].status, 'posted');
});

test('مصروفات ثابتة (once a month, the signed receipt photo after) and moving money from the bank to the office cash', async () => {
  const f = await h.call(c.t.owner, 'POST', '/cash/fixed-expenses', { name: 'إيجار المكتب', category: 'إيجار', amount: 20_000, beneficiary: 'أ. صاحب العقار',
    cashbox: 'office', paymentMethod: 'cash' });
  assert.equal(f.status, 201, JSON.stringify(f.body));
  const pay = await h.call(c.t.owner, 'POST', `/cash/fixed-expenses/${f.body.fixed.id}/pay`, {});
  assert.equal(pay.status, 201, JSON.stringify(pay.body));
  assert.equal(pay.body.expense.fixedExpenseId, f.body.fixed.id);
  assert.equal(pay.body.expense.cashbox, 'office', 'المدير pays from the office box');
  // the accountant pays a fixed expense from his own box (the same list for both)
  const ob = await h.call(c.t.hr, 'POST', '/cash/fixed-expenses', { name: 'الأوفيس بوي', category: 'مرتب أوفيس بوي', amount: 500, beneficiary: 'عم سيد' });
  assert.equal(ob.status, 201, JSON.stringify(ob.body));
  const hp = await h.call(c.t.hr, 'POST', `/cash/fixed-expenses/${ob.body.fixed.id}/pay`, {});
  assert.equal(hp.status, 201, JSON.stringify(hp.body));
  assert.equal(hp.body.expense.cashbox, 'hr');
  assert.equal((await h.call(c.t.hr, 'GET', '/cash/fixed-expenses')).body.fixed.length, 2);
  assert.equal((await h.call(c.t.owner, 'POST', `/cash/fixed-expenses/${f.body.fixed.id}/pay`, {})).status, 409, 'once a month');
  const list = await h.call(c.t.owner, 'GET', '/cash/fixed-expenses');
  assert.ok(list.body.fixed.every((x: any) => x.paid?.status === 'posted'));
  assert.equal((await h.call(c.t.owner, 'PATCH', `/cash/fixed-expenses/${f.body.fixed.id}`, { amount: 22_000 })).body.fixed.amount, 22_000);
  assert.equal((await h.call(c.t.e1, 'GET', '/cash/fixed-expenses')).status, 403);
  // the signed receipt's photo
  const png = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex').toString('base64');
  assert.equal((await h.call(c.t.owner, 'POST', `/cash/expenses/${pay.body.expense.id}/attachment`, { attachment: png })).status, 200);
  assert.equal((await h.call(c.t.owner, 'GET', `/cash/expenses/${pay.body.expense.id}/attachment`)).body.attachment, png);

  // bank → office cash: the box total stays, only its bank part becomes cash
  const before = (await h.call(c.t.owner, 'GET', '/cash/overview')).body.available;
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/bank-moves', { amount: before.bank + 1 })).status, 400);
  assert.equal((await h.call(c.t.hr, 'POST', '/cash/bank-moves', { amount: 1000 })).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/bank-moves', { amount: 10_000, note: 'سحب' })).status, 201);
  const after = (await h.call(c.t.owner, 'GET', '/cash/overview')).body.available;
  assert.equal(after.total, before.total);
  assert.equal(after.bank, before.bank - 10_000);
  assert.equal(after.office.cash, before.office.cash + 10_000);
  // توريد كاش للبنك: the other way, never more than the office's cash
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/bank-moves', { direction: 'cash_to_bank', amount: after.office.cash + 1 })).status, 400);
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/bank-moves', { direction: 'cash_to_bank', amount: 4_000 })).status, 201);
  const dep = (await h.call(c.t.owner, 'GET', '/cash/overview')).body.available;
  assert.equal(dep.total, before.total);
  assert.equal(dep.bank, after.bank + 4_000);
  assert.equal(dep.office.cash, after.office.cash - 4_000);
  // المدير العام can ask for money to go to the accountant too
  assert.equal((await h.call(c.t.owner, 'POST', '/cash/transfers', { direction: 'office_to_hr', amount: 500, reason: 'مصاريف' })).status, 201);
});
