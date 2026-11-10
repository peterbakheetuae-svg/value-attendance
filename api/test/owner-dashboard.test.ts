import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/** The home of المالك / المدير العام: every card in one call; never for HR / employees. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-11-10T10:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

test('owner home: one call with every card, owner / general manager only', async () => {
  assert.equal((await h.call(c.t.hr, 'GET', '/dashboard/owner')).status, 403);
  assert.equal((await h.call(c.t.e1, 'GET', '/dashboard/owner')).status, 403);
  await h.call(c.t.e1, 'POST', '/advances', { kind: 'advance', amount: 500, note: 'test' });
  const r = await h.call(c.t.owner, 'GET', '/dashboard/owner?range=30');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const b = r.body;
  for (const k of ['summary', 'kpis', 'series', 'pipeline', 'topSales', 'latest', 'wallet', 'payroll', 'upcoming', 'attention']) assert.ok(k in b, k);
  assert.equal(b.range, 30);
  assert.equal(b.series.length, 30);
  assert.equal(b.series.at(-1).day, '2026-11-10');
  assert.ok(b.kpis.attendance.employees > 0);
  assert.equal(typeof b.kpis.cash.total, 'number');
  assert.ok(b.payroll.due >= 0);
  assert.ok(Array.isArray(b.attention.absent));
});
