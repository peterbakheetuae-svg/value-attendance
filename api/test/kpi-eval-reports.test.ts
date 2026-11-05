import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { achievement, summarize } from '../src/modules/kpi.ts';
import { overall } from '../src/modules/evaluations.ts';

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
let defs: Record<string, string> = {};
before(async () => {
  h = await harness('2026-03-10T08:00:00Z'); c = await cast(h);
  const d = await h.call(c.t.hr, 'GET', '/kpi/definitions');
  for (const x of d.body.definitions) defs[x.key] = x.id;
});
after(async () => { await h.close(); });

test('unit: achievement and weighted score never turn missing data into zero', () => {
  assert.equal(achievement(null, 10, true), null);
  assert.equal(achievement(5, 10, true), 50);
  assert.equal(achievement(20, 10, false), 50);
  const s = summarize([
    { id: '1', kpi_id: 'a', weight_snapshot: 60, target_snapshot: 10, actual: 12, state: 'completed', higher_is_better: true },
    { id: '2', kpi_id: 'b', weight_snapshot: 40, target_snapshot: 10, actual: null, state: 'not_evaluated', higher_is_better: true },
  ]);
  assert.equal(s.status, 'in_progress');
  assert.equal(s.weightedScore, 60, 'capped at 100% achievement × 60 weight');
  assert.equal(s.items[1].weightedScore, null);
  assert.equal(overall({ discipline: 5, attendance: 4 }), 90);
  assert.equal(overall({}), null);
});

test('KPI suggested templates are inactive until HR enables them', async () => {
  const d = await h.call(c.t.hr, 'GET', '/kpi/definitions');
  assert.ok(d.body.definitions.every((x: any) => x.active === false));
  for (const k of ['calls', 'viewings', 'closed_deals']) {
    assert.equal((await h.call(c.t.hr, 'PATCH', `/kpi/definitions/${defs[k]}`, { active: true })).status, 200);
  }
  assert.equal((await h.call(c.t.sm1, 'PATCH', `/kpi/definitions/${defs.calls}`, { active: false })).status, 403);
});

test('KPI set weights must total exactly 100 (API and database)', async () => {
  const bad = await h.call(c.t.hr, 'POST', '/kpi/sets', { name: 'خطأ', scopeType: 'job_title', jobTitle: 'مستشار عقاري',
    items: [{ kpiId: defs.calls, weight: 50, target: 300 }, { kpiId: defs.viewings, weight: 40, target: 20 }] });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.error.details.total, 90);
  // database refuses too, even if the API were bypassed
  await assert.rejects(h.db.tx(async (q) => {
    const s = await q.query(`INSERT INTO kpi_sets (name, scope_type, job_title, created_by) VALUES ('x','job_title','zzz',$1) RETURNING id`, [c.ids.hr]);
    await q.query(`INSERT INTO kpi_set_items VALUES ($1,$2,70,10)`, [s.rows[0].id, defs.calls]);
  }), /must be 100/);
  const ok = await h.call(c.t.hr, 'POST', '/kpi/sets', { name: 'مستشار عقاري — شهري', scopeType: 'job_title', jobTitle: 'مستشار عقاري',
    items: [{ kpiId: defs.calls, weight: 30, target: 300 }, { kpiId: defs.viewings, weight: 30, target: 20 }, { kpiId: defs.closed_deals, weight: 40, target: 2 }] });
  assert.equal(ok.status, 201);
});

test('KPI results: missing ≠ zero, team manager enters, employee cannot, history preserved on new version', async () => {
  const view = await h.call(c.t.e1, 'GET', `/kpi/employees/${c.ids.e1}?month=2026-03`);
  assert.equal(view.status, 200);
  assert.equal(view.body.current.status, 'not_evaluated');
  assert.equal(view.body.current.weightedScore, null);
  assert.equal(view.body.canEnter, false);
  const items = view.body.current.items;
  const calls = items.find((i: any) => i.key === 'calls');
  assert.equal((await h.call(c.t.e1, 'PUT', `/kpi/results/${calls.id}`, { actual: 999, state: 'completed' })).status, 403);
  assert.equal((await h.call(c.t.sm2, 'PUT', `/kpi/results/${calls.id}`, { actual: 1, state: 'completed' })).status, 404, 'other team');
  assert.equal((await h.call(c.t.sm1, 'PUT', `/kpi/results/${calls.id}`, { actual: 240, state: 'completed' })).status, 200);
  const v2 = await h.call(c.t.sm1, 'GET', `/kpi/employees/${c.ids.e1}?month=2026-03`);
  assert.equal(v2.body.current.status, 'in_progress');
  const c2 = v2.body.current.items.find((i: any) => i.key === 'calls');
  assert.equal(c2.achievementPercent, 80);
  assert.equal(c2.state, 'below_target');
  assert.equal(v2.body.current.weightedScore, 24);
  // new version with different weights does not rewrite March snapshots
  const nv = await h.call(c.t.hr, 'POST', '/kpi/sets', { name: 'مستشار عقاري — v2', scopeType: 'job_title', jobTitle: 'مستشار عقاري',
    items: [{ kpiId: defs.calls, weight: 50, target: 100 }, { kpiId: defs.closed_deals, weight: 50, target: 3 }] });
  assert.equal(nv.status, 201);
  assert.equal(nv.body.set.version, 2);
  const v3 = await h.call(c.t.hr, 'GET', `/kpi/employees/${c.ids.e1}?month=2026-03`);
  assert.equal(v3.body.current.items.length, 3, 'March keeps its 3-KPI snapshot');
  assert.equal(v3.body.current.items.find((i: any) => i.key === 'calls').weight, 30);
  await assert.rejects(h.db.query(`DELETE FROM kpi_set_items WHERE set_id = (SELECT set_id FROM kpi_results LIMIT 1)`), /in use/);
});

test('evaluations: manager for own team, HR for all, self forbidden, publish freezes and notifies', async () => {
  const scores = { discipline: 4, attendance: 5, communication: 4, followUp: 3, teamwork: 4, salesPerformance: 3, initiative: 4, professionalBehavior: 5 };
  assert.equal((await h.call(c.t.sm2, 'POST', '/evaluations', { employeeId: c.ids.e1, month: '2026-03', ...scores })).status, 404);
  assert.equal((await h.call(c.t.e1, 'POST', '/evaluations', { employeeId: c.ids.e2, month: '2026-03', ...scores })).status, 404);
  assert.equal((await h.call(c.t.sm1, 'POST', '/evaluations', { employeeId: c.ids.sm1, month: '2026-03', ...scores })).status, 403);
  const draft = await h.call(c.t.sm1, 'POST', '/evaluations', { employeeId: c.ids.e1, month: '2026-03', discipline: 4, feedback: 'جيد' });
  assert.equal(draft.status, 201);
  const id = draft.body.evaluation.id;
  // employee cannot see a draft
  assert.equal((await h.call(c.t.e1, 'GET', `/evaluations?employeeId=${c.ids.e1}`)).body.evaluations.length, 0);
  const pub0 = await h.call(c.t.sm1, 'POST', `/evaluations/${id}/publish`);
  assert.equal(pub0.status, 400, 'all dimensions required');
  await h.call(c.t.sm1, 'PATCH', `/evaluations/${id}`, { ...scores, strengths: 'تواصل ممتاز', improvements: 'المتابعة', improvementPlan: 'متابعة يومية لكل عميل' });
  const pub = await h.call(c.t.sm1, 'POST', `/evaluations/${id}/publish`);
  assert.equal(pub.status, 200);
  assert.equal(pub.body.evaluation.overallPercent, 80);
  assert.equal((await h.call(c.t.sm1, 'PATCH', `/evaluations/${id}`, { discipline: 1 })).status, 409);
  await assert.rejects(h.db.query(`UPDATE evaluations SET discipline = 1 WHERE id = $1`, [id]), /permanent/);
  const mine = await h.call(c.t.e1, 'GET', `/evaluations?employeeId=${c.ids.e1}`);
  assert.equal(mine.body.evaluations.length, 1);
  assert.equal((await h.call(c.t.e1, 'PATCH', `/evaluations/${id}`, { discipline: 5 })).status, 404, 'employee cannot edit');
  const notes = await h.call(c.t.e1, 'GET', '/notifications');
  assert.ok(notes.body.notifications.some((n: any) => n.type === 'evaluation_published'));
  const hrEval = await h.call(c.t.hr, 'POST', '/evaluations', { employeeId: c.ids.e1, month: '2026-03', ...scores });
  assert.equal(hrEval.body.evaluation.evaluator_kind, 'hr');
  await h.call(c.t.hr, 'POST', `/evaluations/${hrEval.body.evaluation.id}/publish`);
});

test('monthly employee report is built from stored data, labelled incomplete, scoped', async () => {
  h.now.value = new Date('2026-03-10T08:30:00Z');
  await h.call(c.t.e1, 'POST', '/attendance/check-in', {});
  h.now.value = new Date('2026-03-10T16:00:00Z');
  await h.call(c.t.e1, 'POST', '/attendance/check-out', {});
  const r = await h.call(c.t.sm1, 'GET', `/reports/monthly/employee/${c.ids.e1}?month=2026-03`);
  assert.equal(r.status, 200);
  const rep = r.body.report;
  assert.equal(rep.complete, false);
  assert.equal(rep.attendance.attendedDays, 1);
  assert.equal(rep.attendance.lateArrivals, 1);
  assert.equal(rep.kpi.status, 'in_progress');
  assert.equal(rep.evaluation.managerScore, 80);
  assert.equal(rep.evaluation.recommendations, 'متابعة يومية لكل عميل');
  assert.deepEqual(rep.summary.components.sort(), ['attendance', 'evaluation', 'kpi']);
  assert.equal((await h.call(c.t.sm2, 'GET', `/reports/monthly/employee/${c.ids.e1}?month=2026-03`)).status, 404);
  assert.equal((await h.call(c.t.e2, 'GET', `/reports/monthly/employee/${c.ids.e1}?month=2026-03`)).status, 404);
  assert.equal((await h.call(c.t.e1, 'GET', `/reports/monthly/employee/${c.ids.e1}?month=2026-03`)).status, 200);
  assert.equal((await h.call(c.t.acc, 'GET', `/reports/monthly/employee/${c.ids.e1}?month=2026-03`)).status, 403, 'accountant gets payroll view only');
});

test('team report filters and XLSX export is a real workbook', async () => {
  const team = await h.call(c.t.sm1, 'GET', `/reports/monthly?month=2026-03`);
  assert.deepEqual(team.body.reports.map((x: any) => x.employee.id).sort(), [c.ids.e1, c.ids.e2].sort());
  const filtered = await h.call(c.t.hr, 'GET', `/reports/monthly?month=2026-03&teamId=${c.ids.teamB}`);
  assert.deepEqual(filtered.body.reports.map((x: any) => x.employee.id), [c.ids.e3]);
  const x = await h.call(c.t.hr, 'GET', `/reports/monthly.xlsx?month=2026-03`);
  assert.equal(x.status, 200);
  assert.match(x.headers.get('content-type')!, /spreadsheetml/);
  assert.equal(x.raw.subarray(0, 2).toString(), 'PK');
  assert.match(x.headers.get('content-disposition')!, /monthly-report-2026-03\.xlsx/);
});

test('payroll summary for accountant: EGP only, money separated, salary only with salary_read', async () => {
  await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 12000, $2)`, [c.ids.e1, c.ids.owner]);
  const p = await h.call(c.t.acc, 'GET', '/reports/payroll?month=2026-03');
  assert.equal(p.status, 200);
  assert.equal(p.body.currency, 'EGP');
  const row = p.body.rows.find((r: any) => r.employee.id === c.ids.e1);
  assert.equal(row.money.baseSalary, 12000);
  assert.equal(row.kpi, undefined, 'no KPI mixed into payroll');
  const hr = await h.call(c.t.hr, 'GET', '/reports/payroll?month=2026-03');
  assert.equal(hr.body.rows.find((r: any) => r.employee.id === c.ids.e1).money.baseSalary, 12000, 'HR manager sees salaries');
  assert.equal((await h.call(c.t.sm1, 'GET', '/reports/payroll?month=2026-03')).status, 403);
  const xl = await h.call(c.t.acc, 'GET', '/reports/payroll.xlsx?month=2026-03');
  assert.equal(xl.status, 200);
});

test('finance adjustments: four-eyes rule', async () => {
  const a = await h.call(c.t.acc, 'POST', '/finance/adjustments', { employeeId: c.ids.e1, month: '2026-03', kind: 'deduction', amountEgp: 250, reason: 'غياب بدون إذن' });
  assert.equal(a.status, 201);
  assert.equal((await h.call(c.t.acc, 'POST', `/finance/adjustments/${a.body.adjustment.id}/decision`, { decision: 'approve' })).status, 403, 'creator cannot approve');
  assert.equal((await h.call(c.t.acc, 'POST', '/finance/adjustments', { employeeId: c.ids.acc, month: '2026-03', kind: 'bonus', amountEgp: 1, reason: 'لنفسي' })).status, 403);
  assert.equal((await h.call(c.t.hr, 'POST', `/finance/adjustments/${a.body.adjustment.id}/decision`, { decision: 'approve' })).status, 403, 'HR has no finance rights');
  assert.equal((await h.call(c.t.owner, 'POST', `/finance/adjustments/${a.body.adjustment.id}/decision`, { decision: 'approve' })).status, 200);
  const p = await h.call(c.t.acc, 'GET', '/reports/payroll?month=2026-03');
  assert.equal(p.body.rows.find((r: any) => r.employee.id === c.ids.e1).money.approvedDeductions, 250);
});

test('dashboards are role-shaped', async () => {
  const emp = await h.call(c.t.e1, 'GET', '/dashboard');
  assert.ok(emp.body.me);
  assert.equal(emp.body.team, undefined);
  assert.equal(emp.body.finance, undefined);
  const sm = await h.call(c.t.sm1, 'GET', '/dashboard');
  assert.equal(sm.body.team.scope, 'team');
  assert.equal(sm.body.team.activeEmployees, 2);
  assert.ok(sm.body.kpiOverview);
  assert.equal(sm.body.finance, undefined, 'no finance for sales managers');
  const own = await h.call(c.t.owner, 'GET', '/dashboard');
  assert.equal(own.body.team.scope, 'company');
  assert.ok(own.body.finance);
  const acc = await h.call(c.t.acc, 'GET', '/dashboard');
  assert.ok(acc.body.finance);
  assert.equal(acc.body.kpiOverview, undefined);
});

test('notifications are de-duplicated and private', async () => {
  const before = await h.db.query(`SELECT count(*)::int AS n FROM notifications`);
  await h.db.query(`INSERT INTO notifications (recipient_id, type, title, dedupe_key) VALUES ($1,'x','t','same') ON CONFLICT DO NOTHING`, [c.ids.e1]);
  await h.db.query(`INSERT INTO notifications (recipient_id, type, title, dedupe_key) VALUES ($1,'x','t','same') ON CONFLICT DO NOTHING`, [c.ids.e1]);
  const after = await h.db.query(`SELECT count(*)::int AS n FROM notifications`);
  assert.equal(after.rows[0].n - before.rows[0].n, 1);
  const n = await h.call(c.t.e1, 'GET', '/notifications');
  const someone = n.body.notifications[0].id;
  assert.equal((await h.call(c.t.e2, 'POST', `/notifications/${someone}/read`)).status, 404);
  assert.equal((await h.call(c.t.e1, 'POST', `/notifications/${someone}/read`)).status, 200);
});
