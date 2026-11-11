import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, insertEmployee, PW, type Harness } from './helpers.ts';

/**
 * المشاريع الحصري, one step after the other from «المبيعات»:
 *  حجز (the deposit goes into the accountant's cashbox, the commission is potential) → تعاقد by the salesperson
 *  (the down payment goes in, the commission becomes receivable, the staff commission waits for approval) →
 *  تم التحصيل by المالك / المدير العام (out of the owner's money into the commissions) → owner payout.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let owner2: string;
before(async () => {
  h = await harness('2026-11-10T10:00:00Z'); c = await cast(h);
  await insertEmployee(h.db, { code: 'OWNER2', name: 'مالك تاني', role: 'owner' });
  owner2 = await h.login('OWNER2', PW);
});
after(async () => { await h.close(); });

test('exclusive project: reservation → contract → collected → owner payout', async () => {
  assert.equal((await h.call(c.t.hr, 'POST', '/exclusive/projects', { name: 'برج النخيل', ownerName: 'أ. سامي' })).status, 403);
  const pr = await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج النخيل', ownerName: 'أ. سامي', ownerPhone: '0100', marketingPct: 0.5 });
  assert.equal(pr.status, 201, JSON.stringify(pr.body));
  const pid = pr.body.project.id;
  assert.deepEqual([pr.body.project.totalPct, pr.body.project.contractPct, pr.body.project.salesPct, pr.body.project.managerPct, pr.body.project.marketingPct],
    [5, 3, 0.2, 0.1, 0.5]);
  assert.ok(!(await h.call(c.t.owner, 'GET', '/commissions/projects')).body.projects.some((p: any) => p.id === pid), 'not in the marketing list');

  // حجز: the deposit waits for «تم استلام المبلغ» (the accountant / المدير العام are told); nobody types an amount
  assert.equal((await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'A-12', clientName: 'عميل حصري', unitPrice: 3_000_000 })).status, 400,
    'an exclusive reservation needs its deposit');
  const u = await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'A-12', clientName: 'عميل حصري', unitPrice: 3_000_000,
    depositAmount: 50_000, paymentMethod: 'bank_transfer' });
  assert.equal(u.status, 201, JSON.stringify(u.body));
  const uid = u.body.unit.id;
  assert.equal(u.body.unit.status, 'reserving');
  assert.equal(u.body.unit.money.pending, 50_000);
  assert.equal(u.body.unit.money.collected, 0);
  assert.deepEqual(u.body.unit.myCommission, { amount: 6000, state: 'potential' });
  const told = await h.db.query(`SELECT count(*)::int AS n FROM notifications WHERE type = 'exclusive_payment_pending'`);
  assert.ok(told.rows[0].n >= 2, 'the accountant and the managers are told');
  assert.equal((await h.call(c.t.e1, 'POST', `/exclusive/units/${uid}/contract`, { paymentType: 'cash' })).status, 409, 'not before the deposit is received');
  const pend = await h.call(c.t.hr, 'GET', '/exclusive/payments');
  assert.equal(pend.body.payments.length, 1);
  assert.equal(pend.body.payments[0].amount, 50_000);
  assert.equal((await h.call(c.t.e1, 'POST', `/exclusive/payments/${pend.body.payments[0].id}/receive`, {})).status, 403);
  const rcv = await h.call(c.t.hr, 'POST', `/exclusive/payments/${pend.body.payments[0].id}/receive`, {});
  assert.equal(rcv.status, 200, JSON.stringify(rcv.body));
  assert.equal(rcv.body.unit.status, 'reserved');
  assert.equal(rcv.body.unit.money.bank, 50_000);
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/payments/${pend.body.payments[0].id}/receive`, {})).status, 409, 'once');
  const box = await h.db.query(`SELECT cashbox, kind, amount_egp, payment_method FROM cash_receipts WHERE ex_unit_id = $1`, [uid]);
  assert.deepEqual(box.rows.map((x) => [x.cashbox, x.kind, Number(x.amount_egp), x.payment_method]), [['hr', 'reservation', 50000, 'bank_transfer']]);
  let d = await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`);
  assert.equal(d.body.project.stats.commission.potential, 150_000, 'potential: 5% of a reserved unit');
  assert.equal(d.body.project.stats.commission.earned, 0, 'a reservation earns nothing');
  assert.equal(d.body.project.stats.owner.inTrust, 50_000);

  // تعاقد by the salesperson himself: down 250k (the deposit counts), 8 installments every 3 months, 0.5% each
  assert.equal((await h.call(c.t.e2, 'POST', `/exclusive/units/${uid}/contract`, { paymentType: 'cash' })).status, 403, 'not his unit');
  assert.equal((await h.call(c.t.e1, 'POST', `/exclusive/units/${uid}/contract`, { paymentType: 'installments', downPayment: 40_000,
    installmentsCount: 8, everyMonths: 3, firstDueDate: '2027-02-01' })).status, 400, 'the down payment is bigger than the deposit');
  const k = await h.call(c.t.e1, 'POST', `/exclusive/units/${uid}/contract`, { paymentType: 'installments', downPayment: 250_000,
    installmentsCount: 8, everyMonths: 3, firstDueDate: '2027-02-01', installmentPct: 0.5 });
  assert.equal(k.status, 200, JSON.stringify(k.body));
  assert.equal(k.body.unit.status, 'contracted');
  assert.equal(k.body.unit.money.pending, 200_000, 'the rest of the down payment (the deposit counts) waits for «تم استلام المبلغ»');
  const dp = (await h.call(c.t.owner, 'GET', '/exclusive/payments')).body.payments[0];
  assert.equal(dp.kind, 'down_payment');
  const r2 = await h.call(c.t.owner, 'POST', `/exclusive/payments/${dp.id}/receive`, {});
  assert.equal(r2.status, 200, JSON.stringify(r2.body));
  assert.equal(r2.body.unit.money.collected, 250_000);
  assert.equal((await h.db.query(`SELECT cashbox FROM cash_receipts WHERE ex_unit_id = $1 AND kind = 'down_payment'`, [uid])).rows[0].cashbox, 'office',
    'received by المدير العام → خزنة المكتب');
  assert.equal(k.body.unit.myCommission.state, 'earned');
  // the staff commission waits for المالك / المدير العام's approval
  const cr = (await h.db.query(`SELECT id, status, sales_amount, manager_amount FROM commission_requests WHERE ex_unit_id = $1`, [uid])).rows[0];
  assert.deepEqual([cr.status, Number(cr.sales_amount), Number(cr.manager_amount)], ['pending', 6000, 3000]);
  assert.equal((await h.call(c.t.owner, 'POST', `/commissions/requests/${cr.id}/decision`, { decision: 'approve', month: '2026-11' })).status, 200);
  const ents = (await h.db.query(`SELECT role, amount_egp FROM commission_entitlements WHERE request_id = $1 ORDER BY role`, [cr.id])).rows;
  assert.deepEqual(ents.map((x) => [x.role, Number(x.amount_egp)]), [['manager', 3000], ['sales', 6000]]);

  d = await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`);
  let s = d.body.project.stats;
  assert.equal(s.commission.earned, 90_000, '3% at the contract');
  assert.equal(s.commission.upcoming, 60_000, 'the other 2% from installments');
  assert.equal(s.owner.inTrust, 250_000, 'nothing leaves the owner\'s money until the manager marks it collected');
  assert.equal(d.body.units[0].commission.receivable, 90_000);
  const unit = await h.call(c.t.hr, 'GET', `/exclusive/units/${uid}`);
  assert.equal(unit.body.installments.length, 8);
  assert.equal(unit.body.installments[0].amount, 343_750);
  assert.equal(unit.body.installments[1].dueDate, '2027-05-01');
  // the accountant collects 5 installments → +0.5% each, capped at the 5%
  for (let i = 0; i < 5; i++) {
    assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'installment' })).status, 201, 'the installment\'s own amount');
  }
  s = (await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`)).body.project.stats;
  assert.equal(s.commission.earned, 150_000, '3% + 4 × 0.5% = 5%, capped');

  // تم التحصيل: never more than earned; it leaves the owner's money and enters the commissions
  assert.equal((await h.call(c.t.e1, 'POST', `/exclusive/units/${uid}/commission-collected`, {})).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', `/exclusive/units/${uid}/commission-collected`, { amount: 150_001 })).status, 400);
  const col = await h.call(c.t.owner, 'POST', `/exclusive/units/${uid}/commission-collected`, { amount: 100_000 });
  assert.equal(col.status, 201, JSON.stringify(col.body));
  assert.equal(col.body.unit.commission.receivable, 50_000);
  assert.equal((await h.call(c.t.owner, 'POST', `/exclusive/units/${uid}/commission-collected`, {})).body.unit.commission.receivable, 0, 'the rest');
  s = (await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`)).body.project.stats;
  assert.equal(s.commission.transferred, 150_000);
  const collected = 250_000 + 5 * 343_750;
  assert.equal(s.owner.inTrust, collected - 150_000);
  assert.equal(s.owner.due, collected - 150_000);
  const ov = await h.call(c.t.owner, 'GET', '/cash/overview?from=2026-11-01&to=2026-11-30');
  assert.equal(ov.body.income.commissions, 150_000);

  // owner payout: office cashbox, approved by the other owner
  assert.equal((await h.call(c.t.owner, 'POST', `/exclusive/projects/${pid}/owner-payout`, { amount: collected })).status, 400);
  const po = await h.call(c.t.owner, 'POST', `/exclusive/projects/${pid}/owner-payout`, { amount: 500_000 });
  assert.equal(po.status, 201, JSON.stringify(po.body));
  assert.equal((await h.call(c.t.owner, 'POST', `/cash/expenses/${po.body.expense.id}/decision`, { decision: 'approve' })).status, 403, 'not his own');
  assert.equal((await h.call(owner2, 'POST', `/cash/expenses/${po.body.expense.id}/decision`, { decision: 'approve' })).status, 200);
  s = (await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`)).body.project.stats;
  assert.equal(s.owner.paid, 500_000);
  const st = (await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`)).body.statement;
  assert.ok(st.some((x: any) => x.type === 'owner_payout') && st.some((x: any) => x.type === 'commission_transfer'));
});

test('a direct cash contract (تعاقد جديد): the whole price in, 5% at once; a cancelled reservation gives the deposit back', async () => {
  const pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'كمبوند الواحة', ownerName: 'أ. هاني' })).body.project.id;
  const u = await h.call(c.t.e2, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'V1', clientName: 'عميل كاش', unitPrice: 1_000_000,
    contract: { paymentType: 'cash' } });
  assert.equal(u.status, 201, JSON.stringify(u.body));
  assert.equal(u.body.unit.status, 'contracted');
  assert.equal(u.body.unit.money.pending, 1_000_000, 'cash: the whole price waits for «تم استلام المبلغ»');
  const pay = (await h.call(c.t.hr, 'GET', '/exclusive/payments')).body.payments.find((x: any) => x.unitId === u.body.unit.id);
  const got = await h.call(c.t.hr, 'POST', `/exclusive/payments/${pay.id}/receive`, {});
  assert.equal(got.body.unit.status, 'completed', 'cash and fully paid');
  assert.equal(got.body.unit.money.collected, 1_000_000);
  let s = (await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`)).body.project.stats;
  assert.equal(s.commission.earned, 50_000, '5% at once');
  assert.equal(s.commission.staff, 3_000, '0.2% + 0.1% even for cash');

  // made by المالك / المدير العام for the salesperson → the staff commission is approved at once
  const m = await h.call(owner2, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'V3', clientName: 'عميل المدير', unitPrice: 500_000,
    depositAmount: 10_000, salesId: c.ids.e2 });
  assert.equal(m.status, 201, JSON.stringify(m.body));
  const mp = (await h.call(c.t.hr, 'GET', '/exclusive/payments')).body.payments.find((x: any) => x.unitId === m.body.unit.id);
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/payments/${mp.id}/receive`, {})).status, 200);
  assert.equal((await h.call(owner2, 'POST', `/exclusive/units/${m.body.unit.id}/contract`, { paymentType: 'cash' })).status, 200);
  assert.equal((await h.db.query(`SELECT status FROM commission_requests WHERE ex_unit_id = $1`, [m.body.unit.id])).rows[0].status, 'approved');

  const v = (await h.call(c.t.e2, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'V2', clientName: 'عميل لغى', unitPrice: 800_000, depositAmount: 30_000 })).body.unit;
  const vp = (await h.call(c.t.hr, 'GET', '/exclusive/payments')).body.payments.find((x: any) => x.unitId === v.id);
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/payments/${vp.id}/receive`, {})).status, 200);
  assert.equal((await h.call(c.t.e2, 'POST', `/exclusive/units/${v.id}/cancel`, { reason: 'العميل اعتذر' })).status, 200);
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${v.id}/refund`, { amount: 30_000 })).status, 409, 'not before the cancel is approved');
  assert.equal((await h.call(c.t.owner, 'POST', `/exclusive/units/${v.id}/cancel/decision`, { decision: 'approve' })).status, 200);
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${v.id}/refund`, { amount: 30_001 })).status, 400);
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${v.id}/refund`, { amount: 30_000 })).status, 201);
  s = (await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`)).body.project.stats;
  assert.equal(s.units.cancelled, 1);
  assert.equal(s.refunded, 30_000);
  assert.equal(s.commission.potential, 0);
  // the salesperson sees only his own units, no office commission figures
  const mine = await h.call(c.t.e2, 'GET', `/exclusive/projects/${pid}`);
  assert.equal(mine.body.units.length, 3);
  assert.equal(mine.body.units[0].commission, undefined);
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/projects/${pid}`)).body.units.length, 0);
});
