import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

/**
 * Project commission management — acceptance scenarios 1–15.
 * Cast: owner, المدير (GM), HR, two sales managers (team A: e1, e2 / team B: e3), a salesperson with no manager (solo).
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let gmId = ''; let tGm = '';
let kayan = ''; let reqA = ''; let reqB = '';

before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  gmId = gm.body.id;
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gmId]);
  tGm = await h.login('GM1', PW);
  for (const id of [c.ids.e1, c.ids.e2, c.ids.sm1]) {
    await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 10000, $2)`, [id, c.ids.owner]);
  }
});
after(async () => { await h.close(); });

test('1–2. project with 1.50% total; the split must add up exactly and never be negative', async () => {
  const bad = [
    { name: 'خطأ', totalPct: 1.5, salesPct: 0.3, managerPct: 0.4, companyPct: 0.7 },   // 1.40 ≠ 1.50
    { name: 'خطأ', totalPct: 1.5, salesPct: -0.1, managerPct: 0.8, companyPct: 0.8 },  // negative
    { name: 'خطأ', totalPct: 0, salesPct: 0, managerPct: 0, companyPct: 0 },           // nothing to split
  ];
  for (const b of bad) assert.equal((await h.call(tGm, 'POST', '/commissions/projects', b)).status, 400, JSON.stringify(b));
  const mismatch = await h.call(tGm, 'POST', '/commissions/projects', bad[0]);
  assert.equal(mismatch.body.error.details.reason, 'split_mismatch');
  // only owner / المدير create projects
  assert.equal((await h.call(c.t.hr, 'POST', '/commissions/projects', { name: 'X', totalPct: 1, salesPct: 1, managerPct: 0, companyPct: 0 })).status, 403);
  assert.equal((await h.call(c.t.sm1, 'POST', '/commissions/projects', { name: 'X', totalPct: 1, salesPct: 1, managerPct: 0, companyPct: 0 })).status, 403);

  const p = await h.call(tGm, 'POST', '/commissions/projects', { name: 'Kayan', totalPct: 1.5, salesPct: 0.3, managerPct: 0.4, companyPct: 0.8 });
  assert.equal(p.status, 201, JSON.stringify(p.body));
  kayan = p.body.project.id;
  assert.equal(p.body.project.companyPct, 0.8);
  assert.equal((await h.call(tGm, 'POST', '/commissions/projects', { name: ' kayan ', totalPct: 1, salesPct: 1, managerPct: 0, companyPct: 0 })).status, 409, 'same name');
  // the salesperson share can go above 0.30% as long as the total still adds up
  const big = await h.call(c.t.owner, 'POST', '/commissions/projects', { name: 'Zed', totalPct: 2, salesPct: 0.75, managerPct: 0.25, companyPct: 1 });
  assert.equal(big.status, 201);
});

test('3–4. a salesperson submits a deal; the percentage and amounts come from the project, never from the app', async () => {
  const r = await h.call(c.t.e1, 'POST', '/commissions/requests', {
    projectId: kayan, unitNo: 'A-101', pricePerM2: 30000, areaM2: 150,
    // all of these are ignored — the server decides
    employeeId: c.ids.e2, salesPct: 5, salesAmount: 999999, status: 'approved',
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  reqA = r.body.request.id;
  assert.equal(r.body.request.employeeId, c.ids.e1, 'always the signed-in employee');
  assert.equal(r.body.request.unitValue, 4500000);
  assert.equal(r.body.request.salesPct, 0.3);
  assert.equal(r.body.request.salesAmount, 13500);
  assert.equal(r.body.request.status, 'pending');
  assert.equal(r.body.request.companyAmount, undefined, 'a salesperson never sees the company share');
  // the GM is told
  const n = await h.db.query(`SELECT 1 FROM notifications WHERE recipient_id = $1 AND type = 'commission_awaiting'`, [gmId]);
  assert.equal(n.rows.length, 1);
  // what a salesperson sees about projects: name + his percentage only
  const list = (await h.call(c.t.e1, 'GET', '/commissions/projects')).body.projects;
  const k = list.find((x: any) => x.id === kayan);
  assert.equal(k.salesPct, 0.3);
  assert.equal(k.companyPct, undefined);
  assert.equal(k.totalPct, undefined);
  assert.equal(k.units, undefined);
  // a pending request is not a sold unit
  const d = (await h.call(tGm, 'GET', `/commissions/projects/${kayan}`)).body;
  assert.equal(d.units.length, 0);
});

test('5. invalid or duplicate units are refused', async () => {
  const bad = [
    { projectId: kayan, unitNo: '', pricePerM2: 30000, areaM2: 150 },
    { projectId: kayan, unitNo: 'B-1', pricePerM2: 0, areaM2: 150 },
    { projectId: kayan, unitNo: 'B-1', pricePerM2: 30000, areaM2: -5 },
    { projectId: 'not-a-project', unitNo: 'B-1', pricePerM2: 30000, areaM2: 100 },
  ];
  for (const b of bad) assert.equal((await h.call(c.t.e2, 'POST', '/commissions/requests', b)).status, 400, JSON.stringify(b));
  const dup = await h.call(c.t.e2, 'POST', '/commissions/requests', { projectId: kayan, unitNo: ' a-101 ', pricePerM2: 31000, areaM2: 150 });
  assert.equal(dup.status, 409, 'same unit, same project, another salesperson');
  assert.equal(dup.body.error.details.reason, 'pending_exists');
  // a paused project takes no new deals
  const p = await h.call(tGm, 'POST', '/commissions/projects', { name: 'Paused', totalPct: 1, salesPct: 0.5, managerPct: 0.2, companyPct: 0.3, status: 'paused' });
  assert.equal((await h.call(c.t.e2, 'POST', '/commissions/requests', { projectId: p.body.project.id, unitNo: '1', pricePerM2: 1000, areaM2: 100 })).status, 422);
});

test('6–8. GM approves: amounts recalculated, snapshot frozen, payroll month chosen, double approve blocked', async () => {
  // only approvers see the queue; nobody approves his own deal
  assert.equal((await h.call(c.t.hr, 'GET', '/commissions/requests?scope=pending')).status, 403);
  assert.equal((await h.call(c.t.sm1, 'POST', `/commissions/requests/${reqA}/decision`, { decision: 'approve', month: '2026-03' })).status, 403);
  const queue = (await h.call(tGm, 'GET', '/commissions/requests?scope=pending')).body.requests;
  assert.equal(queue.length, 1);
  assert.equal(queue[0].companyAmount, 36000);
  assert.equal(queue[0].managerAmount, 18000);
  assert.equal(queue[0].totalAmount, 67500);
  // month rules
  assert.equal((await h.call(tGm, 'POST', `/commissions/requests/${reqA}/decision`, { decision: 'approve' })).status, 400, 'month required');
  assert.equal((await h.call(tGm, 'POST', `/commissions/requests/${reqA}/decision`, { decision: 'approve', month: '2025-01' })).status, 400, 'too old');
  // someone fiddles with the row before approval: the server recalculates from price × area
  await h.db.query(`UPDATE commission_requests SET sales_amount = 1 WHERE id = $1`, [reqA]);

  const [a1, a2] = await Promise.all([
    h.call(tGm, 'POST', `/commissions/requests/${reqA}/decision`, { decision: 'approve', month: '2026-04' }),
    h.call(c.t.owner, 'POST', `/commissions/requests/${reqA}/decision`, { decision: 'approve', month: '2026-04' }),
  ]);
  assert.deepEqual([a1.status, a2.status].sort(), [200, 409], 'exactly one approval wins');
  const ok = a1.status === 200 ? a1 : a2;
  const r = ok.body.request;
  assert.equal(r.status, 'approved');
  assert.equal(r.period, '2026-04');
  assert.equal(r.unitValue, 4500000);
  assert.equal(r.salesAmount, 13500);
  assert.equal(r.managerAmount, 18000);
  assert.equal(r.companyAmount, 36000);
  assert.equal(r.salesAmount + r.managerAmount + r.companyAmount, 67500);
  assert.equal(r.salesManagerId, c.ids.sm1, 'his sales team manager');
  const ents = await h.db.query(`SELECT role, employee_id, amount_egp::float AS amt, to_char(period,'YYYY-MM') AS m FROM commission_entitlements
                                  WHERE request_id = $1 ORDER BY role`, [reqA]);
  assert.deepEqual(ents.rows, [
    { role: 'manager', employee_id: c.ids.sm1, amt: 18000, m: '2026-04' },
    { role: 'sales', employee_id: c.ids.e1, amt: 13500, m: '2026-04' },
  ], 'one entitlement per role, no company row');
  // the snapshot is frozen in the database itself
  await assert.rejects(h.db.query(`UPDATE commission_requests SET sales_amount = 1 WHERE id = $1`, [reqA]), /immutable|cannot be changed/);
  await assert.rejects(h.db.query(`DELETE FROM commission_requests WHERE id = $1`, [reqA]), /never deleted/);
  // the unit is now a sold unit — exactly once
  const d = (await h.call(tGm, 'GET', `/commissions/projects/${kayan}`)).body;
  assert.equal(d.units.length, 1);
  assert.equal(d.project.units, 1);
  assert.equal(d.project.salesValue, 4500000);
  assert.equal(d.project.companyCommission, 36000);
  assert.equal(d.project.totalCommission, 67500);
  // and a sold unit can't be requested again
  const again = await h.call(c.t.e2, 'POST', '/commissions/requests', { projectId: kayan, unitNo: 'A-101', pricePerM2: 30000, areaM2: 150 });
  assert.equal(again.body.error.details.reason, 'unit_sold');
});

test('9–10. payroll: salesperson and sales manager get their share in the chosen month only', async () => {
  const pay = async (tok: string, id: string, m: string) => (await h.call(tok, 'GET', `/payroll/employee/${id}?month=${m}`)).body.payroll;
  const e1Apr = await pay(c.t.hr, c.ids.e1, '2026-04');
  assert.equal(e1Apr.commissions, 13500, JSON.stringify(e1Apr));
  const e1Mar = await pay(c.t.hr, c.ids.e1, '2026-03');
  assert.equal(e1Mar.commissions, 0, 'not in another month');
  const sm1Apr = await pay(c.t.hr, c.ids.sm1, '2026-04');
  assert.equal(sm1Apr.commissions, 18000);
  // net includes it, on top of everything else
  assert.equal(Math.round((e1Apr.net - (e1Apr.attendanceSalary - e1Apr.totalDeductions + e1Apr.bonuses - e1Apr.advances + e1Apr.workExpenses)) * 100) / 100, 13500);
});

test('11–12. company figures and role-based visibility are enforced by the API', async () => {
  // owner / GM: company share
  for (const tok of [c.t.owner, tGm]) {
    const p = (await h.call(tok, 'GET', '/commissions/projects')).body.projects.find((x: any) => x.id === kayan);
    assert.equal(p.companyPct, 0.8);
    assert.equal(p.companyCommission, 36000);
  }
  // HR: units and entitlements for payroll, no company figures
  const hrP = (await h.call(c.t.hr, 'GET', `/commissions/projects/${kayan}`)).body;
  assert.equal(hrP.units.length, 1);
  assert.equal(hrP.project.companyPct, undefined);
  assert.equal(hrP.project.companyCommission, undefined);
  assert.equal(hrP.project.totalCommission, undefined);
  assert.equal(hrP.units[0].companyAmount, undefined);
  assert.equal(hrP.units[0].companyPct, undefined);
  const hrE = (await h.call(c.t.hr, 'GET', '/commissions/entitlements?scope=all')).body;
  assert.equal(hrE.entitlements.length, 2);
  assert.ok(hrE.entitlements.every((x: any) => x.payment === 'unpaid' && x.payrollIncluded && x.projectName === 'Kayan' && x.unitNo === 'A-101'));
  // sales manager of the team: sees his team's unit and his own share, nothing about the company
  const sm = (await h.call(c.t.sm1, 'GET', `/commissions/projects/${kayan}`)).body;
  assert.equal(sm.units.length, 1);
  assert.equal(sm.units[0].managerAmount, 18000);
  assert.equal(sm.units[0].companyAmount, undefined);
  assert.equal(sm.project.companyPct, undefined);
  assert.equal(JSON.stringify(sm).includes('36000'), false, 'company amount nowhere in the response');
  const smList = (await h.call(c.t.sm1, 'GET', '/commissions/projects')).body.projects;
  assert.ok(smList.every((x: any) => x.companyPct === undefined && x.companyCommission === undefined));
  // the other team's sales manager sees no units of team A
  assert.equal((await h.call(c.t.sm2, 'GET', `/commissions/projects/${kayan}`)).body.units.length, 0);
  // another salesperson: neither the unit nor other people's money
  assert.equal((await h.call(c.t.e2, 'GET', `/commissions/projects/${kayan}`)).body.units.length, 0);
  assert.equal((await h.call(c.t.e2, 'GET', '/commissions/requests?scope=all')).status, 403);
  assert.equal((await h.call(c.t.e2, 'GET', '/commissions/entitlements?scope=all')).status, 403);
  assert.equal((await h.call(c.t.sm1, 'GET', '/commissions/entitlements?scope=all')).status, 403);
  // the salesperson sees his own approved commission and payroll month
  const mine = (await h.call(c.t.e1, 'GET', '/commissions/requests')).body.requests;
  assert.equal(mine.length, 1);
  assert.equal(mine[0].period, '2026-04');
  assert.equal(mine[0].companyAmount, undefined);
  assert.equal(mine[0].managerAmount, undefined, 'not his manager\'s share either');
  assert.equal(mine[0].payroll.length, 1);
  assert.equal(mine[0].payroll[0].amount, 13500);
  const myEnt = (await h.call(c.t.e1, 'GET', '/commissions/entitlements')).body;
  assert.equal(myEnt.totals.amount, 13500);
});

test('13. a rejection needs a reason and creates nothing in payroll', async () => {
  const r = await h.call(c.t.e3, 'POST', '/commissions/requests', { projectId: kayan, unitNo: 'C-7', pricePerM2: 25000, areaM2: 120 });
  assert.equal(r.status, 201);
  reqB = r.body.request.id;
  assert.equal((await h.call(tGm, 'POST', `/commissions/requests/${reqB}/decision`, { decision: 'reject' })).status, 400, 'reason required');
  const rej = await h.call(tGm, 'POST', `/commissions/requests/${reqB}/decision`, { decision: 'reject', reason: 'العقد لم يوقع' });
  assert.equal(rej.status, 200);
  assert.equal(rej.body.request.status, 'rejected');
  assert.equal((await h.db.query(`SELECT 1 FROM commission_entitlements WHERE request_id = $1`, [reqB])).rows.length, 0);
  assert.equal((await h.call(c.t.hr, 'GET', `/payroll/employee/${c.ids.e3}?month=2026-04`)).body.payroll.commissions, 0);
  assert.equal((await h.call(tGm, 'GET', `/commissions/projects/${kayan}`)).body.units.length, 1, 'not a sold unit');
  // the unit is free again after a rejection
  assert.equal((await h.call(c.t.e3, 'POST', '/commissions/requests', { projectId: kayan, unitNo: 'C-7', pricePerM2: 25000, areaM2: 120 })).status, 201);
});

test('14. changing the project split later never changes approved commissions', async () => {
  const up = await h.call(tGm, 'PATCH', `/commissions/projects/${kayan}`, { totalPct: 2, salesPct: 0.5, managerPct: 0.5, companyPct: 1 });
  assert.equal(up.status, 200, JSON.stringify(up.body));
  assert.equal((await h.call(tGm, 'PATCH', `/commissions/projects/${kayan}`, { salesPct: 0.9 })).status, 400, 'still has to add up');
  const d = (await h.call(c.t.owner, 'GET', `/commissions/projects/${kayan}`)).body;
  const u = d.units[0];
  assert.equal(u.salesPct, 0.3);
  assert.equal(u.salesAmount, 13500);
  assert.equal(u.companyAmount, 36000);
  assert.equal((await h.call(c.t.hr, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-04`)).body.payroll.commissions, 13500);
  // a new deal uses the new split
  const n = await h.call(c.t.e2, 'POST', '/commissions/requests', { projectId: kayan, unitNo: 'D-1', pricePerM2: 20000, areaM2: 100 });
  assert.equal(n.body.request.salesPct, 0.5);
  assert.equal(n.body.request.salesAmount, 10000);
  // the edit is in the audit log with the old values
  const log = await h.db.query(`SELECT before FROM audit_log WHERE action = 'commission.project.update' AND entity_id = $1`, [kayan]);
  assert.equal(Number(log.rows[0].before.salesPct), 0.3);
});

test('paying a commission through صرف مالية; a paid month is closed; a solo salesperson has no manager share; owner void', async () => {
  // cash for HR
  const fund = await h.call(tGm, 'POST', '/payouts', { employeeId: c.ids.hr, kind: 'fund', amount: 100000 });
  await h.call(c.t.hr, 'POST', `/payouts/${fund.body.payout.id}/receive`, {});
  const ent = (await h.call(c.t.hr, 'GET', '/commissions/entitlements?scope=all')).body.entitlements.find((x: any) => x.role === 'sales');
  // amount and month must match the approved entitlement
  assert.equal((await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'commission', amount: 20000, month: '2026-04', entitlementId: ent.id })).status, 400);
  assert.equal((await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e2, kind: 'commission', amount: 13500, month: '2026-04', entitlementId: ent.id })).status, 400);
  const p = await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'commission', amount: 13500, month: '2026-04', entitlementId: ent.id });
  assert.equal(p.status, 201, JSON.stringify(p.body));
  assert.equal((await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'commission', amount: 13500, month: '2026-04', entitlementId: ent.id })).status, 409, 'paid once');
  let e = (await h.call(c.t.hr, 'GET', '/commissions/entitlements?scope=all')).body.entitlements.find((x: any) => x.id === ent.id);
  assert.equal(e.payment, 'handed');
  await h.call(c.t.e1, 'POST', `/payouts/${p.body.payout.id}/receive`, {});
  e = (await h.call(c.t.hr, 'GET', '/commissions/entitlements?scope=all')).body.entitlements.find((x: any) => x.id === ent.id);
  assert.equal(e.payment, 'paid');
  // a paid commission can't be voided
  assert.equal((await h.call(c.t.owner, 'POST', `/commissions/requests/${reqA}/void`, { reason: 'الصفقة اتلغت' })).status, 409);

  // March salary of e2 handed over and received → March is closed for him
  const sal = await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e2, kind: 'salary', amount: 5000, month: '2026-03' });
  await h.call(c.t.e2, 'POST', `/payouts/${sal.body.payout.id}/receive`, {});
  const d1 = (await h.call(c.t.e2, 'GET', '/commissions/requests')).body.requests.find((x: any) => x.unitNo === 'D-1');
  const closed = await h.call(tGm, 'POST', `/commissions/requests/${d1.id}/decision`, { decision: 'approve', month: '2026-03' });
  assert.equal(closed.status, 422);
  assert.equal(closed.body.error.details.reason, 'month_closed');
  assert.equal((await h.call(tGm, 'POST', `/commissions/requests/${d1.id}/decision`, { decision: 'approve', month: '2026-05' })).status, 200);

  // a salesperson with no manager: only his own share goes to payroll
  const s = await h.call(c.t.solo, 'POST', '/commissions/requests', { projectId: kayan, unitNo: 'S-1', pricePerM2: 10000, areaM2: 100 });
  const sa = await h.call(c.t.owner, 'POST', `/commissions/requests/${s.body.request.id}/decision`, { decision: 'approve', month: '2026-04' });
  assert.equal(sa.status, 200);
  const rows = await h.db.query(`SELECT role FROM commission_entitlements WHERE request_id = $1`, [s.body.request.id]);
  assert.deepEqual(rows.rows.map((x) => x.role), ['sales']);

  // the owner can cancel an unpaid approved deal; the record stays, the payroll amount goes
  assert.equal((await h.call(tGm, 'POST', `/commissions/requests/${s.body.request.id}/void`, { reason: 'اتلغت' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', `/commissions/requests/${s.body.request.id}/void`, { reason: 'العميل انسحب' })).status, 200);
  assert.equal((await h.call(c.t.hr, 'GET', `/payroll/employee/${c.ids.solo}?month=2026-04`)).body.payroll.commissions, 0);
  const v = await h.db.query(`SELECT status, sales_amount::float AS amt FROM commission_requests WHERE id = $1`, [s.body.request.id]);
  assert.deepEqual(v.rows[0], { status: 'voided', amt: 5000 }, 'original values kept');
});

test('15. existing payroll is unchanged for people without commissions', async () => {
  const p = (await h.call(c.t.hr, 'GET', `/payroll/employee/${c.ids.e2}?month=2026-04`)).body.payroll;
  assert.equal(p.commissions, 0);
  assert.equal(p.net, Math.round((p.attendanceSalary - p.totalDeductions + p.bonuses - p.advances + p.workExpenses) * 100) / 100);
});
