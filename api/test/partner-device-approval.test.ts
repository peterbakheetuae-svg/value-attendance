import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, PW, dev as empDev, type Harness } from './helpers.ts';
import { deviceRef } from '../src/modules/devices.ts';

/**
 * A marketing company signing in from a new device (097): the request is kept, its approvers (the administrative officer
 * — devices.approve — and the company's general manager) are told and see it in their pending list, approve / refuse
 * work, and the employees' new-phone flow is unchanged.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let gm = ''; let tGm = ''; let co = '';
const PHONE = '01200000999', PASS = 'Start#2026x';
const dev = (x: string) => `partnerdev-${x}-000000000000`;
const login = (d: string) => h.call(null, 'POST', '/auth/login', { identifier: PHONE, password: PASS, deviceId: d, deviceLabel: `جهاز ${d.slice(11, 12)}` });
const company = async () => (await h.db.query(`SELECT device_id, pending_device_id, rejected_device_ids FROM marketing_companies WHERE id = $1`, [co])).rows[0];
const notices = async () => (await h.db.query(`SELECT recipient_id FROM notifications WHERE type = 'partner_device_request' AND entity_id = $1`, [co])).rows.map((r) => r.recipient_id).sort();

before(async () => {
  h = await harness('2026-11-26T10:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  assert.equal((await h.call(c.t.owner, 'POST', '/employees', { code: 'GM9', fullName: 'المدير العام', role: 'manager' })).status, 201);
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE code = 'GM9'`);
  gm = (await h.db.query(`SELECT id FROM employees WHERE code = 'GM9'`)).rows[0].id; tGm = await h.login('GM9', PW);
  co = (await h.call(c.t.owner, 'POST', '/marketing-companies', { name: 'شركة أصول', kind: 'commission', defaultPct: 1 })).body.company.id;
  assert.equal((await h.call(c.t.owner, 'PATCH', `/leads/partners/${co}/login`, { phone: PHONE, password: PASS })).status, 200);
  const p = await h.call(c.t.owner, 'PATCH', `/marketing-companies/${co}/profile`, { generalManagerId: gm, managerId: c.ids.acc });
  assert.equal(p.status, 200, JSON.stringify(p.body));
});
after(async () => { await h.close(); });

test('1. a recognized device signs in (the first device is linked by itself, then keeps working)', async () => {
  assert.equal((await login(dev('a'))).status, 200);
  assert.equal((await login(dev('a'))).status, 200);
  assert.equal((await company()).device_id, dev('a'));
});

test('2/3/6/11. a new device: the request is saved, the approvers are told once, retries do not repeat it', async () => {
  const r = await login(dev('b'));
  assert.equal(r.status, 403);
  assert.equal(r.body.error.details.reason, 'device_pending', 'the app says the request was sent');
  assert.equal((await company()).pending_device_id, dev('b'), 'persisted on the company');
  const owner = c.ids.owner, ao = c.ids.acc;
  assert.deepEqual(await notices(), [owner, ao, gm].sort(), 'administrative officer, owner (devices.approve) and the company general manager');
  for (let i = 0; i < 3; i++) assert.equal((await login(dev('b'))).body.error.details.reason, 'device_pending');
  assert.equal((await notices()).length, 3, 'no duplicate notices');
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM audit_log WHERE action = 'partner.device_requested'`)).rows[0].n, 1);
  assert.equal((await h.call(null, 'POST', '/auth/login', { identifier: PHONE, password: 'wrong-pass-1', deviceId: dev('z') })).status, 401, 'a wrong password never makes a request');
  assert.equal((await company()).pending_device_id, dev('b'));
});

test('4/5. visible to the administrative officer and the general manager — even when no notice arrived', async () => {
  await h.db.query(`DELETE FROM notifications WHERE type = 'partner_device_request'`); // as if every push / notice failed
  for (const t of [c.t.acc, tGm]) {
    const p = await h.call(t, 'GET', '/marketing-companies/devices/pending');
    assert.equal(p.status, 200);
    assert.deepEqual(p.body.devices.map((d: any) => [d.companyId, d.id, d.status]), [[co, deviceRef(dev('b')), 'pending']]);
    const box = await h.call(t, 'GET', `/marketing-companies/${co}/devices`);
    assert.equal(box.body.canApprove, true);
    assert.deepEqual(box.body.devices.map((d: any) => d.status), ['pending', 'approved']);
    assert.ok(!JSON.stringify(box.body).includes(dev('b')), 'the raw device id is never shown');
  }
  assert.deepEqual((await h.call(c.t.e1, 'GET', '/marketing-companies/devices/pending')).body.devices, [], 'an employee sees nothing');
  assert.equal((await h.call(c.t.e1, 'GET', `/marketing-companies/${co}/devices`)).status, 404);
});

test('10. unauthorized approvals are refused: an employee, HR, the company itself, a stale request id', async () => {
  const did = deviceRef(dev('b'));
  for (const t of [c.t.e1, c.t.hr, c.t.sm1]) assert.equal((await h.call(t, 'POST', `/marketing-companies/${co}/devices/${did}/approve`, {})).status, 403);
  const pt = (await login(dev('a'))).body.token;
  assert.equal((await h.call(pt, 'POST', `/marketing-companies/${co}/devices/${did}/approve`, {})).status, 403, 'the company cannot approve itself');
  assert.equal((await h.call(c.t.acc, 'POST', `/marketing-companies/${co}/devices/${'0'.repeat(24)}/approve`, {})).status, 409);
  assert.equal((await company()).pending_device_id, dev('b'), 'still waiting');
});

test('7/8. the general manager approves: the new device becomes the company device, the old one is signed out, no new approval needed', async () => {
  const before = (await h.db.query(`SELECT count(*)::int n FROM partner_sessions WHERE company_id = $1 AND revoked_at IS NULL`, [co])).rows[0].n;
  assert.ok(before > 0);
  const r = await h.call(tGm, 'POST', `/marketing-companies/${co}/devices/${deviceRef(dev('b'))}/approve`, {});
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const x = await company();
  assert.deepEqual([x.device_id, x.pending_device_id], [dev('b'), null]);
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM partner_sessions WHERE company_id = $1 AND revoked_at IS NULL`, [co])).rows[0].n, 0);
  for (let i = 0; i < 3; i++) assert.equal((await login(dev('b'))).status, 200, 'signs in, no repeated approval');
  assert.equal((await h.call(c.t.acc, 'POST', `/marketing-companies/${co}/devices/${deviceRef(dev('b'))}/approve`, {})).status, 409, 'already approved');
  assert.equal((await h.db.query(`SELECT count(*)::int n FROM audit_log WHERE action = 'marketing_company.device_approved'`)).rows[0].n, 1);
});

test('9. the administrative officer refuses a device: it stays refused (no new request, no new notice), the linked device keeps working', async () => {
  assert.equal((await login(dev('c'))).body.error.details.reason, 'device_pending');
  const n = (await notices()).length;
  assert.equal((await h.call(c.t.acc, 'POST', `/marketing-companies/${co}/devices/${deviceRef(dev('c'))}/reject`, {})).status, 200);
  for (let i = 0; i < 2; i++) {
    const r = await login(dev('c'));
    assert.equal(r.status, 403); assert.equal(r.body.error.details.reason, 'device_rejected');
  }
  assert.equal((await notices()).length, n);
  assert.deepEqual((await company()).rejected_device_ids, [dev('c')]);
  assert.equal((await login(dev('b'))).status, 200);
  // freeing the device (existing «فك الربط») clears a pending request too
  assert.equal((await login(dev('d'))).body.error.details.reason, 'device_pending');
  assert.equal((await h.call(c.t.owner, 'PATCH', `/marketing-companies/${co}/profile`, { resetDevice: true })).status, 200);
  assert.equal((await company()).pending_device_id, null);
});

test('12. employees: a second phone still asks through employee_devices and is approved there (unchanged)', async () => {
  const r = await h.call(null, 'POST', '/auth/login', { identifier: 'E2', password: PW, deviceId: empDev('E2-NEW-PHONE') });
  assert.equal(r.status, 403); assert.equal(r.body.error.details.reason, 'device_pending');
  const d = (await h.db.query(`SELECT id FROM employee_devices WHERE employee_id = $1 AND status = 'pending'`, [c.ids.e2])).rows[0];
  assert.ok(d);
  assert.ok((await h.db.query(`SELECT 1 FROM notifications WHERE type = 'device_request' AND entity_id = $1`, [c.ids.e2])).rowCount);
  assert.equal((await h.call(c.t.acc, 'POST', `/employees/${c.ids.e2}/devices/${d.id}/approve`, {})).status, 200);
  assert.equal((await h.call(null, 'POST', '/auth/login', { identifier: 'E2', password: PW, deviceId: empDev('E2-NEW-PHONE') })).status, 200);
  assert.equal((await h.call(c.t.acc, 'GET', '/marketing-companies/devices/pending')).body.devices.length, 0, 'employee phones are not mixed in');
});
