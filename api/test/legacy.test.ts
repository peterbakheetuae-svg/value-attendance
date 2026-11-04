import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 9000, $2)`, [c.ids.e1, c.ids.owner]);
});
after(async () => { await h.close(); });

test('advances: employee asks, accountant confirms (not own), payroll deducts advance and adds work expenses', async () => {
  const a1 = await h.call(c.t.e1, 'POST', '/advances', { kind: 'advance', amount: 1000, period: '2026-03-01', note: 'ظروف' });
  assert.equal(a1.status, 201);
  assert.equal(a1.body.advance.status, 'pending');
  assert.equal((await h.call(c.t.e1, 'POST', `/advances/${a1.body.advance.id}/decision`, { decision: 'confirm' })).status, 403);
  assert.equal((await h.call(c.t.acc, 'POST', `/advances/${a1.body.advance.id}/decision`, { decision: 'confirm' })).status, 200);
  const ex = await h.call(c.t.acc, 'POST', '/advances', { kind: 'work_expense', amount: 250, period: '2026-03-01', employeeId: c.ids.e1 });
  assert.equal(ex.body.advance.status, 'confirmed', 'finance recording for an employee is confirmed on entry');
  assert.equal((await h.call(c.t.e2, 'GET', '/advances')).body.advances.length, 0, 'employees see only their own');
  assert.equal((await h.call(c.t.acc, 'GET', '/advances')).body.advances.length, 2);
  const p = (await h.call(c.t.e1, 'GET', `/payroll/employee/${c.ids.e1}?month=2026-03`)).body.payroll;
  assert.equal(p.advances, 1000);
  assert.equal(p.workExpenses, 250);
  assert.equal(p.net, 9000 - 1000 + 250);
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
