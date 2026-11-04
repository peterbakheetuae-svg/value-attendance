import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });
const at = (iso: string) => { h.now.value = new Date(iso); };
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4, 0xff, 0xd9]).toString('base64');

test('selfie: required by settings, stored, visible to self and HR, hidden from other employees', async () => {
  await h.call(c.t.owner, 'PATCH', '/settings', { selfieRequired: true, selfieRetentionDays: 30 });
  assert.equal((await h.call(c.t.e1, 'GET', '/attendance/today')).body.selfieRequired, true);
  const no = await h.call(c.t.e1, 'POST', '/attendance/check-in', {});
  assert.equal(no.status, 422);
  assert.equal(no.body.error.details.reason, 'selfie_required');
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-in', { selfie: 'x'.repeat(600_000) })).status, 400, 'too large');
  const ok = await h.call(c.t.e1, 'POST', '/attendance/check-in', { selfie: JPEG, selfieMime: 'image/jpeg' });
  assert.equal(ok.status, 201);
  const id = ok.body.attendance.id;
  const mine = await h.call(c.t.e1, 'GET', `/attendance/${id}/selfie`);
  assert.equal(mine.status, 200);
  assert.equal(mine.headers.get('content-type'), 'image/jpeg');
  assert.equal((await h.call(c.t.hr, 'GET', `/attendance/${id}/selfie`)).status, 200);
  assert.equal((await h.call(c.t.e3, 'GET', `/attendance/${id}/selfie`)).status, 404, 'other team employee');
  const month = await h.call(c.t.e1, 'GET', '/attendance?month=2026-03');
  assert.equal(month.body.days.find((d: any) => d.date === '2026-03-10').attendance.hasSelfie, true);
});

test('selfie: deleted after the retention period on a later check-in', async () => {
  await h.call(c.t.owner, 'PATCH', '/settings', { selfieRetentionDays: 1 });
  at('2026-03-12T08:00:00Z');
  await h.call(c.t.e2, 'POST', '/attendance/check-in', { selfie: JPEG });
  const n = await h.db.query(`SELECT count(*)::int AS n FROM attendance_selfies WHERE employee_id = $1`, [c.ids.e1]);
  assert.equal(n.rows[0].n, 0);
});
