import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, insertEmployee, PW, type Harness } from './helpers.ts';

/**
 * المشاريع الحصري: reservation → contract (approved by المالك / المدير العام) → money into the accountant's cashbox
 * (نقدي / بنك) held for the owner → commission earned in stages, moved by the manager → owner payout (other owner approves).
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let owner2: string;
before(async () => {
  h = await harness('2026-11-10T10:00:00Z'); c = await cast(h);
  await insertEmployee(h.db, { code: 'OWNER2', name: 'مالك تاني', role: 'owner' });
  owner2 = await h.login('OWNER2', PW);
});
after(async () => { await h.close(); });

test('exclusive project: the full cycle with the agreed rules', async () => {
  // project — المالك / المدير العام only
  assert.equal((await h.call(c.t.hr, 'POST', '/exclusive/projects', { name: 'برج النخيل', ownerName: 'أ. سامي' })).status, 403);
  const pr = await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'برج النخيل', ownerName: 'أ. سامي', ownerPhone: '0100' });
  assert.equal(pr.status, 201, JSON.stringify(pr.body));
  const pid = pr.body.project.id;
  assert.deepEqual([pr.body.project.totalPct, pr.body.project.contractPct, pr.body.project.salesPct, pr.body.project.managerPct], [5, 3, 0.2, 0.1]);
  // not in the marketing list
  const mk = await h.call(c.t.owner, 'GET', '/commissions/projects');
  assert.ok(!mk.body.projects.some((p: any) => p.id === pid));

  // the salesperson reserves; the accountant records the deposit (bank) → reserved
  const u = await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'A-12', clientName: 'عميل حصري', unitPrice: 3_000_000, depositAmount: 50_000 });
  assert.equal(u.status, 201, JSON.stringify(u.body));
  const uid = u.body.unit.id;
  assert.equal(u.body.unit.status, 'reserving');
  assert.equal((await h.call(c.t.e1, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'reservation', amount: 50_000 })).status, 403, 'only the accountant records money');
  assert.equal((await h.call(c.t.owner, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'reservation', amount: 50_000 })).status, 403);
  const dep = await h.call(c.t.hr, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'reservation', amount: 50_000, paymentMethod: 'bank_transfer' });
  assert.equal(dep.status, 201, JSON.stringify(dep.body));
  let d = await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`);
  assert.equal(d.body.units[0].status, 'reserved');
  assert.equal(d.body.project.stats.commission.potential, 150_000, 'potential: 5% of a reserved unit');
  assert.equal(d.body.project.stats.commission.earned, 0, 'a reservation earns nothing');
  assert.equal(d.body.project.stats.owner.inTrust, 50_000);

  // contract with installments: down 250k (deposit counts), 8 installments every 3 months, 0.5% per installment
  const k = await h.call(c.t.e1, 'POST', `/exclusive/units/${uid}/contract`, { paymentType: 'installments', downPayment: 250_000,
    installmentsCount: 8, everyMonths: 3, firstDueDate: '2027-02-01', installmentPct: 0.5 });
  assert.equal(k.status, 200, JSON.stringify(k.body));
  assert.equal((await h.call(c.t.e1, 'POST', `/exclusive/units/${uid}/contract/decision`, { decision: 'approve' })).status, 403);
  const ap = await h.call(c.t.owner, 'POST', `/exclusive/units/${uid}/contract/decision`, { decision: 'approve' });
  assert.equal(ap.status, 200, JSON.stringify(ap.body));
  assert.equal(ap.body.unit.status, 'contracted');
  // staff commission at the contract: 0.2% salesperson, 0.1% his sales manager
  const ents = (await h.db.query(`SELECT role, amount_egp FROM commission_entitlements ce JOIN commission_requests cr ON cr.id = ce.request_id WHERE cr.ex_unit_id = $1 ORDER BY role`, [uid])).rows;
  assert.deepEqual(ents.map((x) => [x.role, Number(x.amount_egp)]), [['manager', 3000], ['sales', 6000]]);
  // down payment still due = 250k − 50k
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'down_payment', amount: 200_001 })).status, 400);
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'down_payment', amount: 200_000 })).status, 201);
  d = await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`);
  let s = d.body.project.stats;
  assert.equal(s.commission.earned, 90_000, '3% at the contract');
  assert.equal(s.commission.upcoming, 60_000, 'the other 2% from installments');
  assert.equal(s.owner.inTrust, 250_000, 'nothing leaves the owner\'s money until the manager moves it');
  assert.equal(s.owner.due, 160_000);
  assert.equal(s.bank, 50_000);
  // the schedule: (3,000,000 − 250,000) / 8
  const unit = await h.call(c.t.hr, 'GET', `/exclusive/units/${uid}`);
  assert.equal(unit.body.installments.length, 8);
  assert.equal(unit.body.installments[0].amount, 343_750);
  assert.equal(unit.body.installments[1].dueDate, '2027-05-01');
  // collect 4 installments → +0.5% each, then the 2% is complete
  for (let i = 0; i < 5; i++) {
    assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${uid}/receipts`, { kind: 'installment', amount: 343_750 })).status, 201);
  }
  s = (await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`)).body.project.stats;
  assert.equal(s.commission.earned, 150_000, '3% + 4 × 0.5% = 5%, capped');
  assert.equal(s.commission.upcoming, 0);

  // the manager moves commission out of the owner's money — never more than earned
  assert.equal((await h.call(c.t.owner, 'POST', `/exclusive/projects/${pid}/commission-transfer`, { amount: 150_001 })).status, 400);
  assert.equal((await h.call(c.t.owner, 'POST', `/exclusive/projects/${pid}/commission-transfer`, { amount: 100_000 })).status, 201);
  s = (await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`)).body.project.stats;
  assert.equal(s.commission.transferred, 100_000);
  assert.equal(s.commission.pending, 50_000);
  const collected = 250_000 + 5 * 343_750;
  assert.equal(s.owner.inTrust, collected - 100_000);
  assert.equal(s.owner.due, collected - 150_000);

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

test('cash sale: 5% at once; a cancelled reservation gives the deposit back', async () => {
  const pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'كمبوند الواحة', ownerName: 'أ. هاني' })).body.project.id;
  const u = (await h.call(c.t.e2, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'V1', clientName: 'عميل كاش', unitPrice: 1_000_000, depositAmount: 20_000 })).body.unit;
  await h.call(c.t.hr, 'POST', `/exclusive/units/${u.id}/receipts`, { kind: 'reservation', amount: 20_000 });
  assert.equal((await h.call(c.t.e2, 'POST', `/exclusive/units/${u.id}/contract`, { paymentType: 'cash', downPayment: 900_000 })).status, 400, 'cash pays the whole price');
  assert.equal((await h.call(c.t.e2, 'POST', `/exclusive/units/${u.id}/contract`, { paymentType: 'cash', downPayment: 1_000_000 })).status, 200);
  await h.call(owner2, 'POST', `/exclusive/units/${u.id}/contract/decision`, { decision: 'approve' });
  let s = (await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`)).body.project.stats;
  assert.equal(s.commission.earned, 50_000, '5% at once');
  assert.equal(s.commission.staff, 3_000, '0.2% + 0.1% even for cash');

  const v = (await h.call(c.t.e2, 'POST', '/exclusive/units', { projectId: pid, unitNo: 'V2', clientName: 'عميل لغى', unitPrice: 800_000, depositAmount: 30_000 })).body.unit;
  await h.call(c.t.hr, 'POST', `/exclusive/units/${v.id}/receipts`, { kind: 'reservation', amount: 30_000 });
  assert.equal((await h.call(c.t.e2, 'POST', `/exclusive/units/${v.id}/cancel`, { reason: 'العميل اعتذر' })).status, 200);
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${v.id}/refund`, { amount: 30_000 })).status, 409, 'not before the cancel is approved');
  assert.equal((await h.call(c.t.owner, 'POST', `/exclusive/units/${v.id}/cancel/decision`, { decision: 'approve' })).status, 200);
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${v.id}/refund`, { amount: 30_001 })).status, 400);
  assert.equal((await h.call(c.t.hr, 'POST', `/exclusive/units/${v.id}/refund`, { amount: 30_000 })).status, 201);
  s = (await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`)).body.project.stats;
  assert.equal(s.units.cancelled, 1);
  assert.equal(s.refunded, 30_000);
  assert.equal(s.commission.potential, 0);
  // the salesperson sees only his own units, no commission figures
  const mine = await h.call(c.t.e2, 'GET', `/exclusive/projects/${pid}`);
  assert.equal(mine.body.units.length, 2);
  assert.equal(mine.body.units[0].commission, undefined);
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/projects/${pid}`)).body.units.length, 0);
});
