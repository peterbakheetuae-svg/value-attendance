import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

// Commissions: whose commissions and which shares each account sees, changing ids never widens it, approval / void
// on their own permissions (throwaway database; before 066 «إلغاء عمولة معتمدة» stays the owner's, as today).
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let tGm = ''; let project = ''; let reqE1 = ''; let reqE3 = '';
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gm.body.id]);
  tGm = await h.login('GM1', PW);
  project = (await h.call(tGm, 'POST', '/commissions/projects', { name: 'Kayan', totalPct: 1.5, salesPct: 0.3, managerPct: 0.4, companyPct: 0.8 })).body.project.id;
  reqE1 = (await h.call(c.t.e1, 'POST', '/commissions/requests', { projectId: project, unitNo: 'A-1', pricePerM2: 30000, areaM2: 100 })).body.request.id;
  reqE3 = (await h.call(c.t.e3, 'POST', '/commissions/requests', { projectId: project, unitNo: 'C-1', pricePerM2: 20000, areaM2: 100 })).body.request.id;
  for (const id of [reqE1, reqE3]) assert.equal((await h.call(tGm, 'POST', `/commissions/requests/${id}/decision`, { decision: 'approve', month: '2026-04' })).status, 200);
});
after(async () => { await h.close(); });

test('a salesperson sees only his own commission and share — never another\'s, whatever ids he sends', async () => {
  const mine = (await h.call(c.t.e2, 'GET', '/commissions/requests')).body.requests;
  assert.equal(mine.length, 0, 'E2 has none');
  assert.equal((await h.call(c.t.e2, 'GET', '/commissions/requests?scope=all')).status, 403);
  assert.equal((await h.call(c.t.e2, 'GET', '/commissions/requests?scope=pending')).status, 403);
  assert.equal((await h.call(c.t.e2, 'GET', '/commissions/entitlements?scope=all')).status, 403);
  const ents = (await h.call(c.t.e2, 'GET', `/commissions/entitlements?employeeId=${c.ids.e1}`)).body.entitlements;
  assert.equal(ents.length, 0, 'another employee id is ignored for his own view');
  const units = (await h.call(c.t.e2, 'GET', `/commissions/projects/${project}`)).body.units;
  assert.equal(units.length, 0, 'project page: only his own units');
  // his own: his share, never the manager or the office share
  const own = (await h.call(c.t.e1, 'GET', '/commissions/requests')).body.requests.find((x: any) => x.id === reqE1);
  assert.ok(own.salesAmount > 0);
  for (const k of ['managerAmount', 'managerPct', 'companyAmount', 'companyPct', 'totalAmount', 'totalPct']) assert.equal(own[k], undefined, k);
  const p = (await h.call(c.t.e1, 'GET', '/commissions/projects')).body.projects.find((x: any) => x.id === project);
  for (const k of ['companyPct', 'managerPct', 'totalPct', 'companyCommission']) assert.equal(p[k], undefined, `project ${k}`);
});

test('team manager: his team\'s units and the manager share, no office share; another team never', async () => {
  const all = (await h.call(c.t.sm1, 'GET', '/commissions/requests?scope=all')).body.requests;
  assert.ok(all.some((x: any) => x.id === reqE1) && !all.some((x: any) => x.id === reqE3));
  const r = all.find((x: any) => x.id === reqE1);
  assert.ok(r.managerAmount > 0);
  assert.equal(r.companyAmount, undefined);
  const units = (await h.call(c.t.sm1, 'GET', `/commissions/projects/${project}`)).body.units;
  assert.ok(units.every((x: any) => x.id !== reqE3));
  // HR (read_all): every entitlement, still no office share
  const hr = (await h.call(c.t.hr, 'GET', '/commissions/requests?scope=all')).body.requests.find((x: any) => x.id === reqE3);
  assert.ok(hr && hr.companyAmount === undefined);
  // المدير (company_view): the office share
  assert.ok((await h.call(tGm, 'GET', '/commissions/requests?scope=all')).body.requests.find((x: any) => x.id === reqE3).companyAmount > 0);
});

test('approval and project management need their permissions; never your own', async () => {
  for (const t of [c.t.e1, c.t.sm1, c.t.hr]) {
    assert.equal((await h.call(t, 'POST', '/commissions/projects', { name: 'X', totalPct: 1, salesPct: 1, managerPct: 0, companyPct: 0 })).status, 403);
    assert.equal((await h.call(t, 'PATCH', `/commissions/projects/${project}`, { salesPct: 0.5 })).status, 403);
  }
  const r = await h.call(c.t.e2, 'POST', '/commissions/requests', { projectId: project, unitNo: 'B-9', pricePerM2: 10000, areaM2: 50 });
  for (const t of [c.t.e1, c.t.sm1, c.t.hr]) {
    assert.equal((await h.call(t, 'POST', `/commissions/requests/${r.body.request.id}/decision`, { decision: 'approve', month: '2026-04' })).status, 403);
  }
  // an approver who is also a salesperson cannot approve his own
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'commission.approve', true)`, [c.ids.e2]);
  assert.equal((await h.call(c.t.e2, 'POST', `/commissions/requests/${r.body.request.id}/decision`, { decision: 'approve', month: '2026-04' })).status, 403);
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.e2]);
});

test('voiding an approved commission: «إلغاء عمولة معتمدة» (the owner, until 066), never by someone who earns from it', async () => {
  assert.ok((await h.call(c.t.owner, 'GET', '/me')).body.permissions.includes('commission.void_approved'));
  assert.ok(!(await h.call(tGm, 'GET', '/me')).body.permissions.includes('commission.void_approved'));
  assert.equal((await h.call(tGm, 'GET', '/commissions/projects')).body.can.void, false);
  for (const t of [tGm, c.t.hr, c.t.sm1, c.t.e1]) {
    assert.equal((await h.call(t, 'POST', `/commissions/requests/${reqE3}/void`, { reason: 'اتلغت' })).status, 403);
  }
  assert.equal((await h.call(c.t.owner, 'POST', `/commissions/requests/${reqE3}/void`, { reason: 'العميل انسحب' })).status, 200);
  assert.equal((await h.call(c.t.owner, 'POST', `/commissions/requests/${reqE3}/void`, { reason: 'مرة تانية' })).status, 409, 'once');
});
