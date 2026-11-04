import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-03-10T08:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

test('break was replaced: starting one is refused, old breaks stay readable and closable', async () => {
  await h.call(c.t.e1, 'POST', '/attendance/check-in', {});
  const r = await h.call(c.t.e1, 'POST', '/attendance/break-start', {});
  assert.equal(r.status, 409);
  assert.equal(r.body.error.details.reason, 'break_removed');
  // a break opened before the change can still be ended
  const att = (await h.db.query(`SELECT id FROM attendance WHERE employee_id = $1`, [c.ids.e1])).rows[0].id;
  await h.db.query(`INSERT INTO attendance_breaks (attendance_id, employee_id, started_at, allowed_minutes) VALUES ($1,$2,'2026-03-10T07:59:00Z',60)`, [att, c.ids.e1]);
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/break-end', {})).status, 200);
});

test('break rows are append-only in the database', async () => {
  await assert.rejects(h.db.query(`UPDATE attendance_breaks SET started_at = started_at - interval '1 hour'`));
  await assert.rejects(h.db.query(`DELETE FROM attendance_breaks`));
});
