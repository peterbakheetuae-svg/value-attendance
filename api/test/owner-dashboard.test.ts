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
  const u = (await h.call(c.t.e1, 'POST', '/exclusive/units', { projectId: pid, unitNo: '1', clientName: 'عميل', unitPrice: 1_000_000, depositAmount: 40_000,
    paymentMethod: 'bank_transfer' })).body.unit;
  const pay = (await h.call(c.t.hr, 'GET', '/exclusive/payments')).body.payments[0];
  await h.call(c.t.hr, 'POST', `/exclusive/payments/${pay.id}/receive`, {});
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

test('employees view: «الموظفين دلوقتي» — online dot and where each one is during work hours', async () => {
  const at = (r: any) => r.body.presence.rows.find((x: any) => x.id === c.ids.e1);
  let r = await h.call(c.t.owner, 'GET', '/dashboard/owner?view=employees');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.presence.route, 'attendance_today');
  assert.equal(at(r).online, true, 'signed in just now');
  assert.equal(at(r).inHours, true, '12:00 Cairo on a Tuesday');
  assert.equal(at(r).status, 'لسه مسجلش حضور');
  await h.db.query(`INSERT INTO outing_requests (employee_id, kind, work_date, requested_at, expected_return_at, reason, status)
                    VALUES ($1, 'visit', '2026-11-10', '2026-11-10T09:00:00Z', '2026-11-10T14:00:00Z', 'زيارة عميل', 'approved')`, [c.ids.e1]);
  r = await h.call(c.t.owner, 'GET', '/dashboard/owner?view=employees');
  assert.equal(at(r).status, 'خارج المكتب بإذن زيارة');
  await h.db.query(`UPDATE sessions SET last_seen_at = now() - interval '30 days' WHERE employee_id = $1`, [c.ids.e1]);
  r = await h.call(c.t.owner, 'GET', '/dashboard/owner?view=employees');
  assert.equal(at(r).online, false);
  // the routes of the cards open their own pages
  const f = await h.call(c.t.owner, 'GET', '/dashboard/owner?view=finance');
  assert.equal(f.body.kpis[1].route, 'office_commissions');
  assert.equal(f.body.kpis[2].route, 'owners');
  assert.equal(f.body.coming.route, 'installments');
  assert.equal(r.body.latest.route, 'leave_requests');
});

test('sales view (لوحة السيلز): new leads, late follow-ups, actions, reservations against the target, stages, most active, waiting leads', async () => {
  assert.equal((await h.call(c.t.e1, 'GET', '/dashboard/owner?view=sales')).status, 403);
  const pr = await h.call(c.t.owner, 'POST', '/commissions/projects', { name: 'مشروع ليدز اللوحة', totalPct: 2, salesPct: 0.3, managerPct: 0.2, companyPct: 1.5 });
  assert.equal(pr.status, 201, JSON.stringify(pr.body));
  const projectId = pr.body.project.id;
  const add = await h.call(c.t.owner, 'POST', '/leads', { fullName: 'عميل اللوحة', phone: '01055550001', projectId, assignees: [c.ids.e1] });
  assert.equal(add.status, 201, JSON.stringify(add.body));
  assert.equal((await h.call(c.t.owner, 'POST', '/leads', { fullName: 'عميل مش متوزع', phone: '01055550002', projectId })).status, 201);
  const act = await h.call(c.t.e1, 'POST', `/leads/${add.body.lead.id}/actions`, { stage: 'following', answered: true, comment: 'كلمته',
    nextAt: '2026-11-10T10:30:00Z' });
  assert.ok(act.status === 200 || act.status === 201, JSON.stringify(act.body));
  h.now.value = new Date('2026-11-10T11:00:00Z');   // its follow-up time passed
  const r = await h.call(c.t.owner, 'GET', '/dashboard/owner?view=sales&range=14');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.view, 'sales');
  for (const k of CARDS) assert.ok(k in r.body, k);
  assert.equal(r.body.kpis.length, 4);
  const kp = Object.fromEntries(r.body.kpis.map((x: any) => [x.label, x]));
  assert.equal(kp['ليدز جديدة النهارده'].value, 2);
  assert.equal(kp['أكشنز النهارده'].value, 1);
  assert.equal(kp['متابعات متأخرة'].value, 1, 'its follow-up time passed');
  assert.match(kp['متابعات متأخرة'].foot, /1 مش متوزع/);
  assert.ok(r.body.ranked.rows.some((x: any) => x.value === 1), 'the most active salesman');
  assert.ok(r.body.latest.rows.some((x: any) => x.status === 'مش متوزع'));
  assert.ok(r.body.pipeline.rows.length > 0);
  assert.equal(r.body.chart.series.new.length, 14);
  assert.ok(r.body.attention.rows.some((x: any) => /مش متوزعين/.test(x.title)));
});
