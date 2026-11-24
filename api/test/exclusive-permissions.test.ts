import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness, asLead } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

// Exclusive projects: a salesperson reaches only his own units / clients / papers whatever ids he sends, the client's
// contact details and the projects' money are separate from seeing a unit, a revoked permission stops at once
// (throwaway database; before migration 066 the two new keys resolve exactly as today: client details open, money = cash.office).
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let tGm = ''; let gmId = ''; let pid = ''; let u1 = ''; let u3 = ''; let file1 = '';
const PHONE1 = '01077700011';
const pdf = Buffer.from('%PDF-1.4\n% reservation form\n').toString('base64');

before(async () => {
  h = await harness('2026-11-10T10:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  gmId = gm.body.id;
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gmId]);
  tGm = await h.login('GM1', PW);
  const pr = await h.call(c.t.owner, 'POST', '/commissions/projects', { name: 'مشروع الصلاحيات', totalPct: 2, salesPct: 0.3, managerPct: 0.2, companyPct: 1.5 });
  assert.equal(pr.status, 201, JSON.stringify(pr.body));
  pid = pr.body.project.id;
  const a = await h.call(c.t.e1, 'POST', '/exclusive/units', await asLead(h, c.ids.e1, { projectId: pid, unitNo: 'P-1', clientName: 'عميل إي ون', clientPhone: PHONE1,
    clientNationalId: '29001011234567', clientAddress: 'مدينة نصر', unitPrice: 2_000_000, expectedContractDate: '2026-12-20' }));
  assert.equal(a.status, 201, JSON.stringify(a.body));
  u1 = a.body.unit.id;
  const b = await h.call(c.t.e3, 'POST', '/exclusive/units', await asLead(h, c.ids.e3, { projectId: pid, unitNo: 'P-3', clientName: 'عميل إي ثري', clientPhone: '01077700033',
    unitPrice: 1_500_000, expectedContractDate: '2026-12-20' }));
  assert.equal(b.status, 201, JSON.stringify(b.body));
  u3 = b.body.unit.id;
  const f = await h.call(c.t.e1, 'POST', `/exclusive/units/${u1}/files`, { kind: 'reservation_form', fileName: 'استمارة.pdf', data: pdf });
  assert.equal(f.status, 201, JSON.stringify(f.body));
  file1 = f.body.file.id;
});
after(async () => { await h.close(); });

test('another salesperson (same team or not) never reaches a unit, its client or its papers by id', async () => {
  for (const t of [c.t.e2, c.t.e3, c.t.sm1]) {
    assert.equal((await h.call(t, 'GET', `/exclusive/units/${u1}`)).status, 404);
    assert.equal((await h.call(t, 'GET', `/exclusive/units/${u1}/files/${file1}`)).status, 404);
    assert.equal((await h.call(t, 'POST', `/exclusive/units/${u1}/files`, { kind: 'reservation_form', fileName: 'x.pdf', data: pdf })).status, 404);
    assert.equal((await h.call(t, 'PATCH', `/exclusive/units/${u1}`, { clientName: 'تلاعب' })).status, 403);
    assert.equal((await h.call(t, 'POST', `/exclusive/units/${u1}/contract`, { paymentType: 'cash', paymentMethod: 'cash' })).status, 403);
    assert.equal((await h.call(t, 'POST', `/exclusive/units/${u1}/cancel`, { reason: 'تلاعب بالرقم' })).status, 403);
    const list = (await h.call(t, 'GET', `/exclusive/units?projectId=${pid}`)).body.units;
    assert.ok(!list.some((x: any) => x.id === u1));
    const cl = (await h.call(t, 'GET', '/exclusive/clients')).body.clients;
    assert.ok(!cl.some((x: any) => x.name === 'عميل إي ون'));
    assert.equal((await h.call(t, 'GET', `/exclusive/clients/lookup?phone=${PHONE1}`)).body.client, null, 'no client lookup across salespeople');
    const pg = (await h.call(t, 'GET', `/exclusive/projects/${pid}`)).body;
    assert.ok(!(pg.units ?? []).some((x: any) => x.id === u1));
    assert.equal(pg.statement, undefined);
  }
  assert.equal((await h.db.query(`SELECT client_name FROM ex_units WHERE id = $1`, [u1])).rows[0].client_name, 'عميل إي ون', 'unchanged');
  // his own: everything of his deal
  const own = (await h.call(c.t.e1, 'GET', `/exclusive/units/${u1}`)).body.unit;
  assert.deepEqual([own.clientPhone, own.form.clientNationalId, own.form.clientAddress, own.can.viewClient], [PHONE1, '29001011234567', 'مدينة نصر', true]);
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/clients/lookup?phone=${PHONE1}`)).body.client.nationalId, '29001011234567');
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/units/${u1}/files/${file1}`)).body.data, pdf);
});

test('the inventory shows a unit is taken, but its client only to who may see that deal', async () => {
  const iv = await h.call(c.t.owner, 'POST', `/exclusive/projects/${pid}/inventory`, { unitNo: 'P-1', unitType: 'تجاري', unitPrice: 2_000_000 });
  assert.equal(iv.status, 201, JSON.stringify(iv.body));
  const by = async (t: string) => (await h.call(t, 'GET', `/exclusive/projects/${pid}/inventory`)).body.units.find((x: any) => x.unitNo === 'P-1');
  const other = await by(c.t.e3);
  assert.deepEqual([other.state, other.clientName, other.dealId], ['reserved', null, null]);
  assert.equal((await by(c.t.e1)).clientName, 'عميل إي ون');
  assert.equal((await by(c.t.owner)).clientName, 'عميل إي ون');
});

test('seeing a unit gives no money: the commission breakdown, project totals and statement are the finance view only', async () => {
  for (const t of [c.t.e1, c.t.hr, c.t.acc, c.t.sm1]) {
    const r = await h.call(t, 'GET', `/exclusive/units/${t === c.t.e1 ? u1 : u3}`);
    if (r.status !== 200) continue;
    assert.equal(r.body.unit.commission, undefined);
    assert.equal(r.body.unit.can.collectCommission, false);
    const pg = (await h.call(t, 'GET', `/exclusive/projects/${pid}`)).body;
    assert.equal(pg.statement, undefined);
    assert.ok(!pg.project?.stats || Object.keys(pg.project.stats).length === 0, 'no project money');
    assert.equal(pg.can?.finance, false);
    for (const [m, p] of [['POST', `/exclusive/projects/${pid}/commission-transfer`], ['POST', `/exclusive/projects/${pid}/owner-payout`],
      ['POST', `/exclusive/units/${u1}/commission-collected`]] as const) {
      assert.equal((await h.call(t, m, p, { amount: 1000 })).status, 403, `${p}`);
    }
  }
  // the salesperson keeps his own share only
  assert.ok((await h.call(c.t.e1, 'GET', `/exclusive/units/${u1}`)).body.unit.myCommission.amount > 0);
  // the office (cash.office) sees it — as before
  const ow = await h.call(c.t.owner, 'GET', `/exclusive/units/${u1}`);
  assert.ok(ow.body.unit.commission);
  assert.equal((await h.call(c.t.owner, 'GET', `/exclusive/projects/${pid}`)).body.can.finance, true);
});

test('only the management decides; a revoked «حجز وحدة» stops the salesperson at once (his units, papers, edits)', async () => {
  for (const t of [c.t.e1, c.t.sm1, c.t.e3]) {
    assert.equal((await h.call(t, 'POST', `/exclusive/units/${u3}/cancel/decision`, { decision: 'approve' })).status, 403);
  }
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'exclusive.reserve', false)`, [c.ids.e1]);
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/units/${u1}`)).status, 404);
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/units?projectId=${pid}`)).status, 403);
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/units/${u1}/files/${file1}`)).status, 404);
  assert.equal((await h.call(c.t.e1, 'PATCH', `/exclusive/units/${u1}`, { clientName: 'بعد السحب' })).status, 403);
  assert.equal((await h.call(c.t.e1, 'POST', `/exclusive/units/${u1}/contract`, { paymentType: 'cash', paymentMethod: 'cash' })).status, 403);
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/clients/lookup?phone=${PHONE1}`)).status, 403);
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.e1]);
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/units/${u1}`)).status, 200);
});

test('one unit number per project, whoever asks', async () => {
  const dup = await h.call(c.t.e2, 'POST', '/exclusive/units', await asLead(h, c.ids.e2, { projectId: pid, unitNo: 'p-1 ', clientName: 'عميل تاني', unitPrice: 1_000_000,
    expectedContractDate: '2026-12-20' }));
  assert.equal(dup.status, 409);
  const [x, y] = await Promise.all([1, 2].map(async (i) => h.call(c.t.e2, 'POST', '/exclusive/units', await asLead(h, c.ids.e2, { projectId: pid, unitNo: 'P-9',
    clientName: `عميل ${i}`, unitPrice: 1_000_000, expectedContractDate: '2026-12-20' }))));
  assert.deepEqual([x.status, y.status].sort(), [201, 409], 'two at once: one wins');
});

// last: the two keys as 066 would add them (only these two; the migration itself is not run) — each one alone
test('after 066: client details and the money are permissions of their own', async () => {
  await h.db.query(`INSERT INTO permissions (key, description) VALUES ('exclusive.view_client', 'x'), ('exclusive.view_finance', 'x')`);
  await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) SELECT r.key, 'exclusive.view_client' FROM roles r ON CONFLICT DO NOTHING`);
  await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) SELECT DISTINCT role_key, 'exclusive.view_finance' FROM role_permissions WHERE perm_key = 'cash.office' ON CONFLICT DO NOTHING`);
  forgetPermissionKeys();
  // same access as before
  let own = (await h.call(c.t.e1, 'GET', `/exclusive/units/${u1}`)).body.unit;
  assert.equal(own.clientPhone, PHONE1);
  assert.ok((await h.call(c.t.owner, 'GET', `/exclusive/units/${u1}`)).body.unit.commission);
  // the client's details withdrawn from E1: he still works on his unit, without the client's phone / id / address / papers
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'exclusive.view_client', false)`, [c.ids.e1]);
  own = (await h.call(c.t.e1, 'GET', `/exclusive/units/${u1}`)).body.unit;
  assert.deepEqual([own.clientName, own.clientPhone, own.form.clientNationalId, own.form.clientAddress, own.can.viewClient],
    ['عميل إي ون', null, null, null, false]);
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/units/${u1}/files/${file1}`)).status, 403);
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/clients/lookup?phone=${PHONE1}`)).body.client, null);
  assert.ok((await h.call(c.t.e1, 'GET', '/exclusive/clients')).body.clients.every((x: any) => !x.phone));
  // the screen sends the hidden fields blank: they are never overwritten
  assert.equal((await h.call(c.t.e1, 'PATCH', `/exclusive/units/${u1}`, { clientName: 'عميل إي ون', clientPhone: '', clientNationalId: '', clientAddress: '' })).status, 200);
  const row = (await h.db.query(`SELECT client_phone, client_national_id, client_address FROM ex_units WHERE id = $1`, [u1])).rows[0];
  assert.deepEqual([row.client_phone, row.client_national_id, row.client_address], [PHONE1, '29001011234567', 'مدينة نصر']);
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.e1]);
  // the money withdrawn from المدير العام: the units and the decisions stay, the figures go
  assert.ok((await h.call(tGm, 'GET', `/exclusive/units/${u1}`)).body.unit.commission, 'he had it');
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'exclusive.view_finance', false)`, [gmId]);
  const o = (await h.call(tGm, 'GET', `/exclusive/units/${u1}`)).body.unit;
  assert.equal(o.commission, undefined);
  assert.equal(o.clientPhone, PHONE1);
  const pg = (await h.call(tGm, 'GET', `/exclusive/projects/${pid}`)).body;
  assert.equal(pg.can.finance, false);
  assert.equal(pg.statement, undefined);
  assert.ok(!(await h.call(tGm, 'GET', '/me')).body.permissions.includes('exclusive.view_finance'));
  assert.equal((await h.call(tGm, 'POST', `/exclusive/projects/${pid}/owner-payout`, { amount: 1000 })).status, 403);
  assert.equal((await h.call(tGm, 'GET', `/exclusive/units?projectId=${pid}`)).status, 200);
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [gmId]);
  // a finance view alone gives nothing without the office permission it was split from
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'exclusive.view_finance', true)`, [c.ids.e1]);
  assert.equal((await h.call(c.t.e1, 'GET', `/exclusive/units/${u1}`)).body.unit.commission, undefined);
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.e1]);
});
