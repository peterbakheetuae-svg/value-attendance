import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });
const at = (iso: string) => { h.now.value = new Date(iso); };

test('break: needs check-in, one per day, blocks check-out while open, flags overrun', async () => {
  at('2026-03-10T08:00:00Z');
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/break-start', {})).status, 409, 'not checked in');
  await h.call(c.t.e1, 'POST', '/attendance/check-in', {});
  at('2026-03-10T11:00:00Z');
  const s = await h.call(c.t.e1, 'POST', '/attendance/break-start', {});
  assert.equal(s.status, 201);
  assert.equal(s.body.break.onBreak, true);
  assert.equal(s.body.break.allowedMinutes, 60);
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-out', {})).status, 409, 'on break');
  at('2026-03-10T12:15:00Z');
  const today = await h.call(c.t.e1, 'GET', '/attendance/today');
  assert.equal(today.body.break.minutes, 75);
  assert.equal(today.body.break.exceeded, true);
  const e = await h.call(c.t.e1, 'POST', '/attendance/break-end', {});
  assert.equal(e.status, 200);
  assert.equal(e.body.break.onBreak, false);
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/break-end', {})).status, 409, 'already ended');
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/break-start', {})).status, 409, 'one break per day');
  at('2026-03-10T16:00:00Z');
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-out', {})).status, 200);
});

test('break rows are append-only in the database', async () => {
  await assert.rejects(h.db.query(`UPDATE attendance_breaks SET started_at = started_at - interval '1 hour'`));
  await assert.rejects(h.db.query(`DELETE FROM attendance_breaks`));
});

test('break endpoints require sign-in', async () => {
  assert.equal((await h.call(null, 'POST', '/attendance/break-start', {})).status, 401);
  assert.equal((await h.call(null, 'POST', '/attendance/break-end', {})).status, 401);
});
