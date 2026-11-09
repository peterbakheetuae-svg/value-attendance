import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 9000, $2)`, [c.ids.e1, c.ids.owner]);
});
after(async () => { await h.close(); });

test('advances: the general manager (or the owner) approves — final; HR then pays and the employee confirms; nobody decides their own; payroll uses confirmed ones', async () => {
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  assert.equal(gm.status, 201);
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gm.body.id]);
  const tGm = await h.login('GM1', PW);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e1}`, { generalManagerId: c.ids.sm1 })).status, 400, 'a sales manager cannot be general manager');
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.e1}`, { generalManagerId: gm.body.id })).status, 200);

  const a1 = await h.call(c.t.e1, 'POST', '/advances', { kind: 'advance', amount: 1000, period: '2026-03-01', note: 'ظروف' });
  assert.equal(a1.status, 201);
  const id = a1.body.advance.id;
  assert.equal((await h.call(c.t.e1, 'POST', `/advances/${id}/decision`, { decision: 'confirm' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', `/advances/${id}/decision`, { decision: 'confirm' })).status, 403, 'HR cannot approve before the general manager');
  assert.equal((await h.call(c.t.acc, 'POST', `/advances/${id}/decision`, { decision: 'confirm' })).status, 403);
  const gmList = (await h.call(tGm, 'GET', '/advances')).body.advances;
  assert.equal(gmList.find((x: any) => x.id === id).canDecide, true);
  const n = await h.db.query(`SELECT 1 FROM notifications WHERE recipient_id = $1 AND entity_id = $2`, [gm.body.id, id]);
  assert.equal(n.rowCount, 1, 'the general manager is asked');
  const g = await h.call(tGm, 'POST', `/advances/${id}/decision`, { decision: 'confirm' });
  assert.equal(g.body.status, 'confirmed', 'the general manager\'s approval is final');
  assert.equal((await h.call(tGm, 'POST', `/advances/${id}/decision`, { decision: 'confirm' })).status, 409);
  // HR pays (صرف): the approved amount only, once; it leaves the HR cashbox when the employee confirms
  const hrRow = (await h.call(c.t.hr, 'GET', '/advances')).body.advances.find((x: any) => x.id === id);
  assert.equal(hrRow.canDecide, false);
  assert.equal(hrRow.canPay, true);
  assert.equal(hrRow.payment, 'unpaid');
  assert.equal((await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'advance', amount: 900, advanceId: id })).status, 400);
  assert.equal((await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'work_expense', amount: 1000, advanceId: id })).status, 400);
  const po = await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'advance', amount: 1000, month: '2026-03', advanceId: id });
  assert.equal(po.status, 201);
  assert.equal((await h.call(c.t.hr, 'POST', '/payouts', { employeeId: c.ids.e1, kind: 'advance', amount: 1000, advanceId: id })).status, 409);
  const mineRow = (await h.call(c.t.e1, 'GET', '/advances?scope=mine')).body.advances.find((x: any) => x.id === id);
  assert.equal(mineRow.canReceive, true);
  assert.equal((await h.call(c.t.hr, 'GET', '/cash/summary')).body.hr.bookBalance, 0, 'not out until received');
  assert.equal((await h.call(c.t.e1, 'POST', `/payouts/${po.body.payout.id}/receive`, {})).status, 200);
  assert.equal((await h.call(c.t.hr, 'GET', '/cash/summary')).body.hr.bookBalance, -1000);
  assert.equal((await h.call(c.t.e1, 'GET', '/advances?scope=mine')).body.advances.find((x: any) => x.id === id).payment, 'received');

  // recorded by finance for an employee: still the general manager approves; HR has no approval step
  const ex = await h.call(c.t.acc, 'POST', '/advances', { kind: 'work_expense', amount: 250, period: '2026-03-01', employeeId: c.ids.e1 });
  assert.equal(ex.body.advance.status, 'pending');
  assert.equal((await h.call(c.t.hr, 'POST', `/advances/${ex.body.advance.id}/decision`, { decision: 'confirm' })).status, 403);
  await h.call(tGm, 'POST', `/advances/${ex.body.advance.id}/decision`, { decision: 'confirm' });
  // no general manager set: the owner gives the first stage
  const a2 = await h.call(c.t.e2, 'POST', '/advances', { kind: 'advance', amount: 300, period: '2026-03-01' });
  assert.equal((await h.call(c.t.hr, 'POST', `/advances/${a2.body.advance.id}/decision`, { decision: 'confirm' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', `/advances/${a2.body.advance.id}/decision`, { decision: 'reject' })).body.status, 'rejected');

  assert.equal((await h.call(c.t.e2, 'GET', '/advances')).body.advances.length, 1, 'employees see only their own');
  assert.equal((await h.call(c.t.acc, 'GET', '/advances')).body.advances.length, 3);
  const p = (await h.call(c.t.e1, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-03`)).body.payroll;
  assert.equal(p.advances, 1000);
  assert.equal(p.workExpenses, 250);
  assert.equal(p.net, p.attendanceSalary - 1000 + 250, 'due = salary for the days − advance + work expenses');
});

test('HR records a leave for an employee: approved on entry; employees cannot', async () => {
  const r = await h.call(c.t.hr, 'POST', '/requests', { type: 'full_day_absence', employeeId: c.ids.e2, startDate: '2026-03-15', endDate: '2026-03-16', absenceType: 'sick', reason: 'تقرير طبي' });
  assert.equal(r.status, 201);
  assert.equal(r.body.request.status, 'approved');
  assert.equal((await h.call(c.t.e1, 'POST', '/requests', { type: 'full_day_absence', employeeId: c.ids.e2, startDate: '2026-03-17', endDate: '2026-03-17', absenceType: 'sick', reason: 'xxx' })).status, 403);
});

test('holiday periods: add a range, edit, delete; clash refused', async () => {
  const r = await h.call(c.t.hr, 'POST', '/holiday-periods', { fromDate: '2026-04-20', toDate: '2026-04-22', holidayType: 'عيد', description: 'عيد الفطر' });
  assert.equal(r.status, 201);
  const list = (await h.call(c.t.e1, 'GET', '/holiday-periods')).body.periods;
  assert.equal(list[0].days, 3);
  assert.equal((await h.call(c.t.hr, 'POST', '/holiday-periods', { fromDate: '2026-04-21', toDate: '2026-04-21' })).status, 409);
  assert.equal((await h.call(c.t.hr, 'PUT', `/holiday-periods/${r.body.id}`, { fromDate: '2026-04-20', toDate: '2026-04-23', holidayType: 'عيد', description: 'عيد الفطر' })).status, 200);
  assert.equal((await h.call(c.t.e1, 'GET', '/holiday-periods')).body.periods[0].days, 4);
  assert.equal((await h.call(c.t.e1, 'DELETE', `/holiday-periods/${r.body.id}`)).status, 403);
  assert.equal((await h.call(c.t.hr, 'DELETE', `/holiday-periods/${r.body.id}`)).status, 200);
});

test('notifications: HR sends to employees, sees sent list; employee deletes own', async () => {
  const s = await h.call(c.t.hr, 'POST', '/notifications/send', { recipientIds: [c.ids.e1, c.ids.e2], title: 'اجتماع', content: 'الساعة 3' });
  assert.equal(s.body.sent, 2);
  assert.equal((await h.call(c.t.hr, 'GET', '/notifications/sent')).body.sent[0].recipients, 2);
  assert.equal((await h.call(c.t.e1, 'POST', '/notifications/send', { recipientIds: [c.ids.e2], title: 'xx', content: 'y' })).status, 403);
  const sm = await h.call(c.t.sm1, 'POST', '/notifications/send', { recipientIds: [c.ids.e3], title: 'xx', content: 'y' });
  assert.equal(sm.status, 403, 'manager cannot message other teams');
  const mine = (await h.call(c.t.e1, 'GET', '/notifications')).body.notifications.find((n: any) => n.title === 'اجتماع');
  assert.equal((await h.call(c.t.e1, 'DELETE', `/notifications/${mine.id}`)).status, 200);
});

test('own profile: contact + bank details', async () => {
  assert.equal((await h.call(c.t.e1, 'PATCH', '/me/profile', { bankName: 'بنك مصر', iban: 'EG380019000500000000263180002', phone: '01012345678' })).status, 200);
  const p = (await h.call(c.t.e1, 'GET', '/me/profile')).body.profile;
  assert.equal(p.bank_name, 'بنك مصر');
  assert.equal((await h.call(c.t.e1, 'PATCH', '/me/profile', { phone: 'abc' })).status, 400);
});
