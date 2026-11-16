import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

// Permissions / outings / leave requests: viewing, approving, cancelling and recording for others are separate,
// scoped on the server, and attachments cannot point at another employee's documents (throwaway database).
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });
const hourly = (extra: Record<string, unknown> = {}) => ({ type: 'hourly_permission', day: '2026-03-12', fromTime: '12:00', toTime: '14:30', reason: 'مشوار بنك', ...extra });

test('a request cannot attach another employee\'s document', async () => {
  const pdf = Buffer.from('%PDF-1.4\n%%EOF').toString('base64');
  const up = await h.call(c.t.hr, 'POST', `/employees/${c.ids.e3}/documents`, { kind: 'other', title: 'خاص', mime: 'application/pdf', data: pdf, fileName: 'x.pdf' });
  assert.equal(up.status, 201);
  const r = await h.call(c.t.e1, 'POST', '/requests', hourly({ attachmentId: up.body.id }));
  assert.equal(r.status, 400, 'another employee\'s document is refused');
  // his own file is fine
  const mine = await h.call(c.t.e1, 'POST', `/employees/${c.ids.e1}/documents`, { kind: 'other', title: 'إيصال', mime: 'application/pdf', data: pdf, fileName: 'y.pdf' });
  assert.equal((await h.call(c.t.e1, 'POST', '/requests', hourly({ attachmentId: mine.body.id }))).status, 201);
});

test('recording a request for someone else needs its own permission', async () => {
  for (const t of [c.t.sm1, c.t.e2, c.t.acc]) {
    assert.equal((await h.call(t, 'POST', '/requests', hourly({ employeeId: c.ids.e1, day: '2026-03-13' }))).status, 403);
  }
  assert.ok((await h.call(c.t.hr, 'GET', '/me')).body.permissions.includes('request.create_for_others'));
  assert.ok(!(await h.call(c.t.sm1, 'GET', '/me')).body.permissions.includes('request.create_for_others'));
});

test('requests: reading is scoped; deciding needs the right stage; cancelling is the owner of the request only', async () => {
  const r = await h.call(c.t.e2, 'POST', '/requests', hourly({ day: '2026-03-14' }));
  const id = r.body.request.id;
  assert.equal((await h.call(c.t.sm2, 'GET', `/requests/${id}`)).status, 404, 'other team manager');
  assert.equal((await h.call(c.t.e1, 'GET', `/requests/${id}`)).status, 404, 'colleague');
  assert.equal((await h.call(c.t.sm2, 'POST', `/requests/${id}/decision`, { decision: 'approve' })).status, 404);
  assert.equal((await h.call(c.t.hr, 'POST', `/requests/${id}/decision`, { decision: 'approve' })).status, 403, 'HR waits for the manager stage');
  assert.equal((await h.call(c.t.sm1, 'POST', `/requests/${id}/cancel`, {})).status, 404, 'only the employee cancels');
  assert.equal((await h.call(c.t.e2, 'POST', `/requests/${id}/decision`, { decision: 'approve' })).status, 403, 'never your own');
  const list = (await h.call(c.t.e1, 'GET', '/requests')).body.requests;
  assert.ok(!list.some((x: any) => x.id === id), 'a colleague\'s request is not listed');
});

test('outings: an HR approver sees the pending ones to decide, the history only within the reading scope', async () => {
  const o = await h.call(c.t.e1, 'POST', '/outings', { kind: 'visit', expectedReturn: '13:00', reason: 'معاينة شقة' });
  assert.equal(o.status, 201);
  const id = o.body.outing.id;
  assert.ok(!(await h.call(c.t.e2, 'GET', '/outings')).body.outings.some((x: any) => x.id === id), 'colleague');
  assert.ok(!(await h.call(c.t.sm2, 'GET', '/outings')).body.outings.some((x: any) => x.id === id), 'other team manager');
  assert.equal((await h.call(c.t.sm2, 'POST', `/outings/${id}/decision`, { decision: 'approve' })).status, 403);
  assert.equal((await h.call(c.t.e2, 'POST', `/outings/${id}/cancel`, {})).status, 404, 'only the employee cancels');
  // an account that may approve at HR but has no request reading: sees it while pending, not after
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'request.approve_hr', true)`, [c.ids.acc]);
  assert.ok((await h.call(c.t.acc, 'GET', '/outings')).body.outings.some((x: any) => x.id === id));
  assert.equal((await h.call(c.t.acc, 'POST', `/outings/${id}/decision`, { decision: 'approve' })).status, 200);
  assert.ok(!(await h.call(c.t.acc, 'GET', '/outings')).body.outings.some((x: any) => x.id === id), 'decided: no longer his to see');
  await h.db.query(`DELETE FROM employee_permissions WHERE employee_id = $1`, [c.ids.acc]);
  // the readers still see it
  assert.ok((await h.call(c.t.hr, 'GET', '/outings')).body.outings.some((x: any) => x.id === id));
  assert.ok((await h.call(c.t.sm1, 'GET', '/outings')).body.outings.some((x: any) => x.id === id));
});
