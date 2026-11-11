import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';

/** The home of المالك / المدير العام: two views (المالية / الموظفين), the same card shapes; never for HR / employees. */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
before(async () => { h = await harness('2026-11-10T10:00:00Z'); c = await cast(h); });
after(async () => { await h.close(); });

const CARDS = ['summary', 'kpis', 'chart', 'pipeline', 'ranked', 'latest', 'wallet', 'ring', 'coming', 'attention'];

test('finance view: cashboxes (cash / bank), owners\' money, my commission, cover the costs', async () => {
  assert.equal((await h.call(c.t.hr, 'GET', '/dashboard/owner')).status, 403);
  assert.equal((await h.call(c.t.e1, 'GET', '/dashboard/owner?view=employees')).status, 403);
  const pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'مشروع لوحة', ownerName: 'مالك' })).body.project.id;
  const u = (await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: '1', clientName: 'عميل', unitPrice: 1_000_000, depositAmount: 40_000 })).body.unit;
  await h.call(c.t.hr, 'POST', `/exclusive/units/${u.id}/receipts`, { kind: 'reservation', amount: 40_000, paymentMethod: 'bank_transfer' });
  const r = await h.call(c.t.owner, 'GET', '/dashboard/owner?view=finance&range=30');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  for (const k of CARDS) assert.ok(k in r.body, k);
  assert.equal(r.body.kpis.length, 4);
  assert.equal(r.body.kpis[0].value, 40_000, 'in the cashboxes');
  assert.match(r.body.kpis[0].foot, /بنك 40/);
  assert.equal(r.body.chart.series.k_all.length, 30);
  assert.equal(r.body.chart.series.k_all.at(-1).value, 40_000);
  assert.equal(r.body.pipeline.rows[0].value, 1, 'one unit reserved');
  assert.equal(r.body.ranked.rows[0].detail.inTrust, 40_000);
  assert.equal(r.body.wallet.spark.length, 30);
  assert.ok(r.body.ring.extra.some((x: any) => x.value === 50_000), 'potential commission 5% of the reserved unit');
  const w = await h.call(c.t.owner, 'GET', '/dashboard/owner?view=finance&range=91');
  assert.equal(w.body.chart.series.k_all.length, 13, '13 weeks');
});

test('employees view: attendance, best employees, KPIs, leave / outings', async () => {
  const r = await h.call(c.t.owner, 'GET', '/dashboard/owner?view=employees&range=14');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  for (const k of CARDS) assert.ok(k in r.body, k);
  assert.equal(r.body.view, 'employees');
  assert.ok(r.body.kpis[1].value > 0, 'employees counted');
  assert.equal(r.body.chart.series.present.length, 14);
  assert.equal(r.body.pipeline.rows.length, 5);
});
