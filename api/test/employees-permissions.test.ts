import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

// Employees module: every action needs its own permission and the server enforces scope and sensitive fields
// (throwaway database; before migration 066 the fine keys resolve to the broad ones they were split from).
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => {
  h = await harness(); c = await cast(h);
  await h.db.query(`UPDATE employees SET phone = '+201000000001', email = 'e1@example.com', address = 'x',
                      emergency_contact_name = 'y', emergency_contact_phone = '+201000000002',
                      legacy_fields = '{"nationalIdNo":"29001010101010","birthDate":"1990-01-01","nationality":"مصري"}'::jsonb WHERE id = $1`, [c.ids.e1]);
});
after(async () => { await h.close(); });
const me = async (t: string) => (await h.call(t, 'GET', '/me')).body.permissions as string[];

test('/me tells the app the fine keys exactly as the server resolves them', async () => {
  const owner = await me(c.t.owner), hr = await me(c.t.hr), sm = await me(c.t.sm1), e = await me(c.t.e1);
  for (const k of ['employee.create', 'employee.edit', 'employee.deactivate', 'employee.reset_password', 'employee.view_contact']) {
    assert.ok(owner.includes(k), `owner ${k}`);
    assert.ok(hr.includes(k), `hr ${k}`);
    assert.ok(!sm.includes(k) && !e.includes(k), `not managers / employees: ${k}`);
  }
  assert.ok(owner.includes('data.reset') && owner.includes('commission.void_approved'));
  assert.ok(!hr.includes('data.reset') && !hr.includes('commission.void_approved'));
});

test('contact and identity details are removed from the API response without «عرض بيانات التواصل»', async () => {
  // team manager: his team member, list and profile
  const list = (await h.call(c.t.sm1, 'GET', '/employees')).body.employees;
  const row = list.find((x: any) => x.id === c.ids.e1);
  assert.ok(row);
  for (const k of ['phone', 'email', 'address', 'emergency_contact_name', 'emergency_contact_phone']) assert.ok(!row[k], `list ${k}`);
  assert.ok(!JSON.stringify(row).includes('29001010101010'));
  const one = (await h.call(c.t.sm1, 'GET', `/employees/${c.ids.e1}`)).body.employee;
  assert.ok(!one.phone && !JSON.stringify(one).includes('29001010101010'));
  // out of his scope: not found
  assert.equal((await h.call(c.t.sm2, 'GET', `/employees/${c.ids.e1}`)).status, 404);
  assert.equal((await h.call(c.t.e2, 'GET', `/employees/${c.ids.e1}`)).status, 404);
  // HR (employee.read_all → view_contact) and the employee himself see them
  const hrv = (await h.call(c.t.hr, 'GET', `/employees/${c.ids.e1}`)).body.employee;
  assert.equal(hrv.phone, '+201000000001');
  assert.equal(hrv.legacy_fields.nationalIdNo, '29001010101010');
  assert.equal((await h.call(c.t.e1, 'GET', `/employees/${c.ids.e1}`)).body.employee.phone, '+201000000001');
});

test('create / edit / deactivate / reset password: each refused without its permission (direct API access)', async () => {
  for (const t of [c.t.sm1, c.t.e2, c.t.acc]) {
    assert.equal((await h.call(t, 'POST', '/employees', { code: 'ZZ1', fullName: 'x', position: 'sales_employee', joiningDate: '2026-01-01' })).status, 403);
    assert.ok([403, 404].includes((await h.call(t, 'PATCH', `/employees/${c.ids.e1}`, { jobTitle: 'x' })).status));
    assert.equal((await h.call(t, 'POST', `/employees/${c.ids.e1}/status`, { status: 'inactive' })).status, 403);
    assert.equal((await h.call(t, 'POST', `/employees/${c.ids.e1}/reset-password`, {})).status, 403);
    assert.equal((await h.call(t, 'POST', `/employees/${c.ids.e1}/unbind-device`, {})).status, 403);
    assert.ok([403, 404].includes((await h.call(t, 'PATCH', `/employees/${c.ids.e1}`, { workTracking: false })).status));
  }
  // an individual restriction on the broad key takes effect at once for HR
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'employee.manage', false)`, [c.ids.hr]);
  assert.equal((await h.call(c.t.hr, 'POST', `/employees/${c.ids.e1}/reset-password`, {})).status, 403);
  assert.ok(!(await me(c.t.hr)).includes('employee.edit'));
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.hr]);
  // self-service stays: an employee edits his own contact details only
  assert.equal((await h.call(c.t.e1, 'PATCH', `/employees/${c.ids.e1}`, { address: 'new' })).status, 200);
  assert.equal((await h.call(c.t.e1, 'PATCH', `/employees/${c.ids.e1}`, { jobTitle: 'boss' })).status, 403);
});
