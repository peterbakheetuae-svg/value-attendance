import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness(); c = await cast(h); });
after(async () => { await h.close(); });

test('employee list is scoped: self / team card / full', async () => {
  const self = await h.call(c.t.e1, 'GET', '/employees');
  assert.deepEqual(self.body.employees.map((e: any) => e.id), [c.ids.e1]);
  const team = await h.call(c.t.sm1, 'GET', '/employees');
  const ids = team.body.employees.map((e: any) => e.id).sort();
  assert.deepEqual(ids, [c.ids.e1, c.ids.e2, c.ids.sm1].sort());
  const card = team.body.employees.find((e: any) => e.id === c.ids.e1);
  assert.equal(card.phone, undefined, 'manager does not get private contact details');
  assert.equal(card.emergency_contact_phone, undefined);
  const all = await h.call(c.t.hr, 'GET', '/employees');
  assert.ok(all.body.employees.length >= 9);
});

test('private profile: other employees get 404; unassigned team is invisible to a manager', async () => {
  assert.equal((await h.call(c.t.e1, 'GET', `/employees/${c.ids.e2}`)).status, 404);
  assert.equal((await h.call(c.t.sm1, 'GET', `/employees/${c.ids.e3}`)).status, 404);
  assert.equal((await h.call(c.t.sm1, 'GET', `/employees/${c.ids.e1}`)).body.scope, 'team');
});

test('salary: set only by salary managers, visible only to salary readers, never on employee screens', async () => {
  const create = await h.call(c.t.hr, 'POST', '/employees', { code: 'SAL1', fullName: 'صاحب مرتب', role: 'sales_employee', baseSalary: 9000 });
  assert.equal(create.status, 403, 'HR has no salary_manage');
  const ok = await h.call(c.t.owner, 'POST', '/employees', { code: 'SAL1', fullName: 'صاحب مرتب', role: 'sales_employee', baseSalary: 9000, jobTitle: 'مستشار عقاري' });
  assert.equal(ok.status, 201);
  const id = ok.body.id;
  const hrView = await h.call(c.t.hr, 'GET', `/employees/${id}`);
  assert.equal(hrView.body.employee.salary, undefined, 'HR without salary_read sees no salary');
  const ownerView = await h.call(c.t.owner, 'GET', `/employees/${id}`);
  assert.equal(ownerView.body.employee.salary.base_salary, 9000);
  assert.equal(ownerView.body.employee.salary.currency, 'EGP');
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [id]);
  const tok = await h.login('SAL1', PW);
  const selfView = await h.call(tok, 'GET', `/employees/${id}`);
  assert.equal(selfView.body.employee.salary, undefined, 'no salary on employee-facing screens');
  const hist = await h.call(c.t.hr, 'GET', `/employees/${id}/history`);
  assert.ok(hist.body.history.length >= 1);
  assert.equal((await h.call(c.t.owner, 'PUT', `/employees/${c.ids.owner}/salary`, { baseSalary: 1 })).status, 403, 'nobody sets own salary');
});

test('sales manager assignment must be a sales manager; no self-assignment', async () => {
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.solo}`, { salesManagerId: c.ids.e1 })).status, 400);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.sm1}`, { salesManagerId: c.ids.sm1 })).status, 400);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.solo}`, { salesManagerId: c.ids.sm2 })).status, 200);
  // solo is now visible to sm2 through the direct assignment
  assert.equal((await h.call(c.t.sm2, 'GET', `/employees/${c.ids.solo}`)).status, 200);
  await h.call(c.t.hr, 'PATCH', `/employees/${c.ids.solo}`, { salesManagerId: null });
});

test('teams: manager must have the sales manager role', async () => {
  const bad = await h.call(c.t.hr, 'POST', '/teams', { name: 'فريق خطأ', managerId: c.ids.e1 });
  assert.equal(bad.status, 422);
  const good = await h.call(c.t.hr, 'POST', '/teams', { name: 'فريق ج', managerId: c.ids.sm2 });
  assert.equal(good.status, 201);
  assert.equal((await h.call(c.t.sm1, 'POST', '/teams', { name: 'x', managerId: c.ids.sm1 })).status, 403);
  const deps = await h.call(c.t.hr, 'POST', '/departments', { nameAr: 'المبيعات', nameEn: 'Sales' });
  assert.equal(deps.status, 201);
});

test('employees are never physically deleted (no DELETE route, deactivate instead)', async () => {
  assert.equal((await h.call(c.t.owner, 'DELETE', `/employees/${c.ids.e2}`)).status, 404);
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.hr}/status`, { status: 'inactive' })).status, 403, 'not self');
});

test('photos and documents: owner of the file or HR; others 404', async () => {
  const png = Buffer.from('89504e470d0a1a0a0000000d4948445200000001000000010806000000', 'hex').toString('base64');
  assert.equal((await h.call(c.t.e1, 'PUT', `/employees/${c.ids.e1}/photo`, { mime: 'image/png', data: png })).status, 200);
  assert.equal((await h.call(c.t.e1, 'PUT', `/employees/${c.ids.e2}/photo`, { mime: 'image/png', data: png })).status, 403);
  const photo = await h.call(c.t.sm1, 'GET', `/employees/${c.ids.e1}/photo`);
  assert.equal(photo.status, 200);
  assert.equal(photo.headers.get('content-type'), 'image/png');
  const doc = await h.call(c.t.e1, 'POST', `/employees/${c.ids.e1}/documents`, { mime: 'application/pdf', fileName: 'note.pdf', data: Buffer.from('%PDF-1.4 test').toString('base64') });
  assert.equal(doc.status, 201);
  assert.equal((await h.call(c.t.e2, 'GET', `/documents/${doc.body.id}`)).status, 404);
  assert.equal((await h.call(c.t.hr, 'GET', `/documents/${doc.body.id}`)).status, 200);
  assert.equal((await h.call(c.t.e1, 'POST', `/employees/${c.ids.e1}/documents`, { mime: 'text/html', fileName: 'x.html', data: 'PGI+' })).status, 400);
});
