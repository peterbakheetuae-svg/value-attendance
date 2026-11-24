import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, type Harness, asLead } from './helpers.ts';
import { forgetPermissionKeys } from '../src/auth/context.ts';

// Unit sales: own / team / all on the server for every id and query, the team view is the record only (no client
// contact, collections or commission), client contact on «بيانات العملاء», commission for another salesperson on its
// own permission (throwaway database; before migration 066 the new keys resolve exactly as their fallbacks).
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let tGm = ''; let gmId = ''; let project = ''; let s1 = ''; let s3 = '';
const PHONE1 = '01099900011';
const sale = (unitNo: string, buyerName: string, buyerPhone: string, extra: Record<string, unknown> = {}) => ({ projectId: project, unitNo, buyerName, buyerPhone,
  totalPrice: 1_000_000, downPayment: 100_000, saleDate: '2026-11-10', downPaymentDueDate: '2026-11-12', frequency: 'monthly', installmentsCount: 10,
  firstDueDate: '2026-11-14', ...extra });

before(async () => {
  h = await harness('2026-11-10T08:00:00Z'); c = await cast(h);
  const gm = await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  gmId = gm.body.id;
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE id = $1`, [gmId]);
  tGm = await h.login('GM1', PW);
  project = (await h.call(tGm, 'POST', '/commissions/projects', { name: 'مشروع البيع', totalPct: 1.5, salesPct: 0.3, managerPct: 0.4, companyPct: 0.8 })).body.project.id;
  const a = await h.call(c.t.e1, 'POST', '/sales', await asLead(h, c.ids.e1, sale('S-1', 'عميل إي ون', PHONE1, { withCommission: true, pricePerM2: 10_000, areaM2: 100 })));
  assert.equal(a.status, 201, JSON.stringify(a.body));
  s1 = a.body.sale.id;
  const b = await h.call(c.t.e3, 'POST', '/sales', await asLead(h, c.ids.e3, sale('S-3', 'عميل إي ثري', '01099900033')));
  assert.equal(b.status, 201, JSON.stringify(b.body));
  s3 = b.body.sale.id;
  for (const id of [s1, s3]) assert.equal((await h.call(tGm, 'POST', `/sales/${id}/decision`, { decision: 'approve' })).status, 200);
});
after(async () => { await h.close(); });

test('a salesperson: his own sales only, whatever id or query he sends', async () => {
  for (const t of [c.t.e2, c.t.e3, c.t.solo]) assert.equal((await h.call(t, 'GET', `/sales/${s1}`)).status, 403);
  for (const q of ['', '?mine=0', '?team=1', `?q=${PHONE1}`, '?q=عميل', `?projectId=${project}`, '?status=active']) {
    const l = (await h.call(c.t.e2, 'GET', `/sales${q}`)).body.sales;
    assert.ok(!l.some((x: any) => x.id === s1 || x.id === s3), q);
  }
  for (const p of ['/sales/clients', '/sales/installments/due', `/sales/clients/detail?key=x`]) assert.equal((await h.call(c.t.e1, 'GET', p)).status, 403, p);
  const own = (await h.call(c.t.e1, 'GET', `/sales/${s1}`)).body;
  assert.equal(own.level, 'own');
  assert.equal(own.sale.buyerPhone, PHONE1);
  assert.ok(own.schedule.length > 0 && own.sale.commission, 'his own: the schedule and his commission request');
});

test('team manager: his team\'s sales — the record only; another team never', async () => {
  const d = await h.call(c.t.sm1, 'GET', `/sales/${s1}`);
  assert.equal(d.status, 200);
  assert.equal(d.body.level, 'team');
  assert.equal(d.body.sale.buyerName, 'عميل إي ون');
  for (const k of ['buyerPhone', 'buyerContact']) assert.equal(d.body.sale[k], null, k);
  for (const k of ['collected', 'remaining', 'refunded', 'downPaid', 'refundDue', 'commission']) assert.equal(d.body.sale[k], undefined, k);
  assert.deepEqual([d.body.schedule, d.body.receipts, d.body.refunds], [[], [], []]);
  assert.equal((await h.call(c.t.sm1, 'GET', `/sales/${s3}`)).status, 403, 'another team');
  assert.equal((await h.call(c.t.sm2, 'GET', `/sales/${s1}`)).status, 403);
  const list = await h.call(c.t.sm1, 'GET', '/sales?team=1');
  assert.equal(list.body.can.team, true);
  assert.ok(list.body.sales.some((x: any) => x.id === s1) && !list.body.sales.some((x: any) => x.id === s3));
  assert.ok(list.body.sales.every((x: any) => x.buyerPhone === null && x.collected === undefined));
  assert.ok(!(await h.call(c.t.sm1, 'GET', `/sales?team=1&q=${PHONE1}`)).body.sales.length, 'no searching by a number he cannot see');
  // revoked: at once
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'commission.read_team', false)`, [c.ids.sm1]);
  assert.equal((await h.call(c.t.sm1, 'GET', `/sales/${s1}`)).status, 403);
  assert.ok(!(await h.call(c.t.sm1, 'GET', '/sales')).body.sales.some((x: any) => x.id === s1));
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.sm1]);
});

test('all-scope (sales.view): everything as before; the clients\' keys never carry the phone number', async () => {
  const d = (await h.call(c.t.hr, 'GET', `/sales/${s3}`)).body;
  assert.equal(d.level, 'all');
  assert.equal(d.sale.buyerPhone, '01099900033');
  const cl = (await h.call(c.t.hr, 'GET', '/sales/clients')).body.clients;
  const me = cl.find((x: any) => x.name === 'عميل إي ون');
  assert.equal(me.phone, PHONE1);
  assert.ok(!String(me.key).includes('9990001'), 'opaque key');
  assert.equal((await h.call(c.t.hr, 'GET', `/sales/clients/detail?key=${encodeURIComponent(me.key)}`)).body.client.phone, PHONE1);
  assert.equal((await h.call(c.t.hr, 'GET', `/sales/clients/detail?key=${encodeURIComponent(`p:${PHONE1.slice(-10)}`)}`)).status, 404, 'a guessed number is not a key');
  const inst = (await h.call(c.t.hr, 'GET', '/sales/installments/due?all=1')).body.installments;
  assert.ok(inst.some((x: any) => x.buyerPhone === PHONE1));
});

test('operations need their permissions; never your own approval; duplicates refused without the buyer\'s identity', async () => {
  const p = await h.call(c.t.e2, 'POST', '/sales', await asLead(h, c.ids.e2, sale('S-2', 'عميل إي تو', '01099900022')));
  assert.equal(p.body.sale.status, 'pending');
  const line = p.body.schedule[0].id;
  for (const t of [c.t.e1, c.t.sm1, c.t.e2]) {
    assert.equal((await h.call(t, 'POST', `/sales/${p.body.sale.id}/decision`, { decision: 'approve' })).status, 403);
    assert.equal((await h.call(t, 'POST', `/sales/${s1}/collect`, { installmentId: line, amount: 10, paymentMethod: 'cash' })).status, 403);
    assert.equal((await h.call(t, 'POST', `/sales/${s1}/collect-auto`, { amount: 10, paymentMethod: 'cash' })).status, 403);
    assert.equal((await h.call(t, 'POST', `/sales/${s1}/cancel`, { reason: 'تلاعب بالرقم' })).status, 403);
    assert.equal((await h.call(t, 'POST', `/sales/${s1}/refund`, { cashbox: 'hr', amount: 10 })).status, 403);
  }
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'sales.approve', true)`, [c.ids.e2]);
  assert.equal((await h.call(c.t.e2, 'POST', `/sales/${p.body.sale.id}/decision`, { decision: 'approve' })).status, 403, 'not his own');
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.e2]);
  // one live sale per unit: told so, without who bought it
  const dup = await h.call(c.t.e3, 'POST', '/sales', await asLead(h, c.ids.e3, sale('s-1', 'حد تاني', '01000000000')));
  assert.equal(dup.status, 409);
  assert.ok(!JSON.stringify(dup.body).includes('عميل إي ون') && !JSON.stringify(dup.body).includes(PHONE1));
  const [x, y] = await Promise.all([1, 2].map(async (i) => h.call(c.t.e3, 'POST', '/sales', await asLead(h, c.ids.e3, sale('S-9', `عميل ${i}`, `0109990009${i}`)))));
  assert.deepEqual([x.status, y.status].sort(), [201, 409], 'two at once: one wins');
});

test('a commission for another salesperson: only with that permission (sales.manage before 066)', async () => {
  const mine = await h.call(c.t.e1, 'POST', '/sales', await asLead(h, c.ids.e1, sale('S-4', 'عميل 4', '01099900044', { withCommission: true, pricePerM2: 10_000, areaM2: 100, employeeId: c.ids.e2 })));
  assert.equal(mine.status, 201, JSON.stringify(mine.body));
  const r1 = await h.db.query(`SELECT employee_id FROM commission_requests WHERE id = (SELECT commission_request_id FROM unit_sales WHERE id = $1)`, [mine.body.sale.id]);
  assert.equal(r1.rows[0].employee_id, c.ids.e1, 'another employee id is ignored');
  assert.equal((await h.call(c.t.e1, 'GET', '/sales')).body.can.onBehalf, false);
  assert.equal((await h.call(tGm, 'GET', '/sales')).body.can.onBehalf, true);
  const gm = await h.call(tGm, 'POST', '/sales', await asLead(h, gmId, sale('S-5', 'عميل 5', '01099900055', { withCommission: true, pricePerM2: 10_000, areaM2: 100, employeeId: c.ids.e2 })));
  const r2 = await h.db.query(`SELECT employee_id FROM commission_requests WHERE id = (SELECT commission_request_id FROM unit_sales WHERE id = $1)`, [gm.body.sale.id]);
  assert.equal(r2.rows[0].employee_id, c.ids.e2);
});

// last: the new keys as 066 would add them (only these; the migration itself is not run) — each one on its own
test('after 066: client contact, team sales and filing for others are permissions of their own', async () => {
  await h.db.query(`INSERT INTO permissions (key, description) VALUES ('exclusive.view_client', 'x'), ('sales.read_team', 'x'), ('commission.create_for_others', 'x')`);
  await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) SELECT r.key, 'exclusive.view_client' FROM roles r ON CONFLICT DO NOTHING`);
  await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) SELECT DISTINCT role_key, 'sales.read_team' FROM role_permissions WHERE perm_key = 'commission.read_team' ON CONFLICT DO NOTHING`);
  await h.db.query(`INSERT INTO role_permissions (role_key, perm_key) SELECT DISTINCT role_key, 'commission.create_for_others' FROM role_permissions WHERE perm_key = 'sales.manage' ON CONFLICT DO NOTHING`);
  forgetPermissionKeys();
  // the same as before
  assert.equal((await h.call(c.t.sm1, 'GET', `/sales/${s1}`)).body.level, 'team');
  assert.equal((await h.call(c.t.hr, 'GET', `/sales/${s1}`)).body.sale.buyerPhone, PHONE1);
  // team sales withdrawn on their own (his commission team view stays)
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'sales.read_team', false)`, [c.ids.sm1]);
  assert.equal((await h.call(c.t.sm1, 'GET', `/sales/${s1}`)).status, 403);
  assert.ok((await h.call(c.t.sm1, 'GET', '/me')).body.permissions.includes('commission.read_team'));
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.sm1]);
  // client contact withdrawn from the finance side: the records, the reminders and the amounts stay — no numbers
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'exclusive.view_client', false)`, [gmId]);
  const d = (await h.call(tGm, 'GET', `/sales/${s1}`)).body;
  assert.equal(d.level, 'all');
  assert.equal(d.sale.buyerPhone, null);
  assert.ok(d.schedule.length > 0, 'still the schedule');
  const cl = (await h.call(tGm, 'GET', '/sales/clients')).body.clients;
  assert.ok(cl.length && cl.every((x: any) => x.phone === null));
  assert.equal((await h.call(tGm, 'GET', `/sales/clients?q=${PHONE1.slice(-6)}`)).body.clients.length, 0, 'no searching by number');
  const inst = (await h.call(tGm, 'GET', '/sales/installments/due?all=1')).body.installments;
  assert.ok(inst.length && inst.every((x: any) => x.buyerPhone === null));
  for (const key of ['installments_week', 'units_remaining']) {
    const r = await h.call(tGm, 'GET', `/finance/dashboard/details?key=${key}`);
    assert.equal(r.status, 200, key);
    assert.ok(!JSON.stringify(r.body).includes('0109990'), `${key}: the reminder without the number`);
  }
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [gmId]);
  const back = await h.call(tGm, 'GET', '/finance/dashboard/details?key=units_remaining');
  assert.ok(JSON.stringify(back.body).includes(PHONE1), 'with both permissions: the number');
  // filing for others withdrawn: sales.manage alone no longer does it
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'commission.create_for_others', false)`, [gmId]);
  const g = await h.call(tGm, 'POST', '/sales', await asLead(h, gmId, sale('S-6', 'عميل 6', '01099900066', { withCommission: true, pricePerM2: 10_000, areaM2: 100, employeeId: c.ids.e2 })));
  const r = await h.db.query(`SELECT employee_id FROM commission_requests WHERE id = (SELECT commission_request_id FROM unit_sales WHERE id = $1)`, [g.body.sale.id]);
  assert.equal(r.rows[0].employee_id, gmId);
  assert.equal((await h.call(tGm, 'GET', '/sales')).body.can.onBehalf, false);
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [gmId]);
});
