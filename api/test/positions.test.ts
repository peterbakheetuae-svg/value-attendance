import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

let pos = '';

test('existing role permissions are unchanged by the migration (no accidental grants)', async () => {
  const r = await h.call(c.t.owner, 'GET', '/roles');
  assert.equal(r.status, 200);
  const by = Object.fromEntries(r.body.roles.map((x: any) => [x.key, x.permissions]));
  assert.deepEqual(by.sales_employee, []);
  assert.ok(!by.sales_manager.some((p: string) => p.startsWith('custody') || p.startsWith('documents') || p === 'positions.manage'));
  assert.ok(!by.accountant.some((p: string) => p.startsWith('custody') || p.startsWith('documents')));
  assert.ok(by.hr_manager.includes('custody.manage') && by.hr_manager.includes('documents.manage'));
  assert.equal(by.owner.length, r.body.permissions.length, 'owner keeps everything');
});

test('new position appears in the permissions list with exactly its base role permissions', async () => {
  assert.equal((await h.call(c.t.e1, 'POST', '/roles', { nameAr: 'قائد فريق', baseKey: 'sales_manager' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', '/roles', { nameAr: 'محاسب أول', baseKey: 'accountant' })).status, 403, 'admin positions are owner-only');
  assert.equal((await h.call(c.t.hr, 'POST', '/roles', { nameAr: 'المالك ٢', baseKey: 'owner' })).status, 400);
  const r = await h.call(c.t.hr, 'POST', '/roles', { nameAr: 'قائد فريق', baseKey: 'sales_manager', description: 'يقود فريق صغير' });
  assert.equal(r.status, 201);
  pos = r.body.role.key;
  assert.equal((await h.call(c.t.hr, 'POST', '/roles', { nameAr: 'قائد فريق', baseKey: 'sales_manager' })).status, 400, 'duplicate name');
  const roles = (await h.call(c.t.owner, 'GET', '/roles')).body.roles;
  const mine = roles.find((x: any) => x.key === pos);
  const base = roles.find((x: any) => x.key === 'sales_manager');
  assert.deepEqual(mine.permissions, base.permissions);
  assert.ok((await h.call(c.t.e1, 'GET', '/positions')).body.positions.some((x: any) => x.key === pos));
});

test('permissions follow the employee position (server-side)', async () => {
  const add = await h.call(c.t.hr, 'POST', '/employees', { code: 'TL1', fullName: 'قائد ١', position: pos, password: PW });
  assert.equal(add.status, 201);
  const emp = (await h.call(c.t.hr, 'GET', `/employees/${add.body.id}`)).body.employee;
  assert.equal(emp.role_key, 'sales_manager');
  assert.equal(emp.position_key, pos);
  assert.equal(emp.job_title, 'قائد فريق');
  // owner narrows the position: it loses kpi.read_team; the built-in sales_manager keeps it
  const perms = (await h.call(c.t.owner, 'GET', '/roles')).body.roles.find((x: any) => x.key === pos).permissions.filter((p: string) => p !== 'kpi.read_team');
  assert.equal((await h.call(c.t.hr, 'PUT', `/roles/${pos}/permissions`, { permissions: perms })).status, 403, 'only the owner edits permissions');
  assert.equal((await h.call(c.t.owner, 'PUT', `/roles/${pos}/permissions`, { permissions: perms })).status, 200);
  await h.db.query(`UPDATE employees SET must_change_password = false WHERE id = $1`, [add.body.id]);
  const tl = await h.login('TL1', PW);
  assert.equal((await h.call(tl, 'GET', '/kpi/overview')).status, 403);
  assert.equal((await h.call(c.t.sm1, 'GET', '/kpi/overview')).status, 200);
});

test('positions can be renamed and disabled safely; built-ins cannot be disabled', async () => {
  assert.equal((await h.call(c.t.hr, 'PATCH', '/roles/sales_manager', { active: false })).status, 403);
  assert.equal((await h.call(c.t.hr, 'PATCH', `/roles/${pos}`, { active: false })).status, 400, 'still has employees');
  assert.equal((await h.call(c.t.hr, 'PATCH', `/roles/${pos}`, { nameAr: 'قائد فريق مبيعات' })).status, 200);
  const extra = await h.call(c.t.hr, 'POST', '/roles', { nameAr: 'مستشار تحت التدريب', baseKey: 'sales_employee' });
  assert.equal((await h.call(c.t.hr, 'PATCH', `/roles/${extra.body.role.key}`, { active: false })).status, 200);
  assert.ok(!(await h.call(c.t.e1, 'GET', '/positions')).body.positions.some((x: any) => x.key === extra.body.role.key));
  assert.equal((await h.call(c.t.hr, 'POST', '/employees', { code: 'TR1', fullName: 'متدرب', position: extra.body.role.key })).status, 400, 'disabled position');
  await assert.rejects(h.db.query(`DELETE FROM roles WHERE key = $1`, [extra.body.role.key]));
});

test('each position gets its own KPI set; the employee dashboard picks it automatically', async () => {
  const defs = (await h.call(c.t.hr, 'GET', '/kpi/definitions')).body.definitions;
  const [k1, k2] = defs.slice(0, 2);
  for (const d of [k1, k2]) await h.call(c.t.hr, 'PATCH', `/kpi/definitions/${d.id}`, { active: true });
  const s = await h.call(c.t.hr, 'POST', '/kpi/sets', { scopeType: 'position', positionKey: pos, name: 'مؤشرات قائد الفريق',
    items: [{ kpiId: k1.id, weight: 60, target: 10 }, { kpiId: k2.id, weight: 40, target: 5 }] });
  assert.equal(s.status, 201);
  const other = await h.call(c.t.hr, 'POST', '/kpi/sets', { scopeType: 'position', positionKey: 'sales_employee', name: 'مؤشرات المستشار',
    items: [{ kpiId: k1.id, weight: 100, target: 30 }] });
  assert.equal(other.status, 201);
  const tlId = (await h.db.query(`SELECT id FROM employees WHERE code = 'TL1'`)).rows[0].id;
  const tl = await h.call(c.t.hr, 'GET', `/kpi/employees/${tlId}`);
  assert.equal(tl.body.current.items.length, 2);
  const e1 = await h.call(c.t.hr, 'GET', `/kpi/employees/${c.ids.e1}`);
  assert.equal(e1.body.current.items.length, 1);
  assert.equal(e1.body.current.items[0].target, 30);
  const sets = (await h.call(c.t.hr, 'GET', '/kpi/sets')).body.sets;
  assert.ok(sets.some((x: any) => x.position_key === pos && x.position_name === 'قائد فريق مبيعات'));
});
