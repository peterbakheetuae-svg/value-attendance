import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, PW, type Harness, regrantAppRole } from './helpers.ts';
import { absenceThresholdMinutes, exitMinutes, exitTierFor, lateIsAbsence, shiftEligibility, validateExitTiers } from '../src/lib/attendance-policy.ts';
import { categoryOf } from '../src/lib/notification-categories.ts';
import { computeMonth } from '../src/modules/attendance-calc.ts';
import { computePayroll, loadRules } from '../src/modules/payroll-calc.ts';
import { notify, forgetPrefsTable } from '../src/modules/notify.ts';
import { forgetIncidentsInstalled } from '../src/modules/exit-incidents.ts';

/**
 * Requirements 2026-11-26: shift-based tracking, sales-manager leave / absence routing, the absence threshold,
 * «شرائح خروج بدون إذن» (incidents → payroll exactly once) and «إعدادات الإشعارات». Production schema + proposed 094.
 * 2026-03-10 is a Tuesday; Cairo = UTC+2; the default schedule is 10:00–18:00 local.
 */
const SQL094 = readFileSync(new URL('../../db/proposed/094_shift_attendance_policies.sql', import.meta.url), 'utf8');
const OFFICE = { lat: 30.0286, lng: 31.4085 };
const OUT = { lat: OFFICE.lat + 0.01, lng: OFFICE.lng, accuracyM: 10 };   // ~1.1 km away
const IN = { lat: OFFICE.lat, lng: OFFICE.lng, accuracyM: 10 };
let h: Harness; let c: Awaited<ReturnType<typeof cast>>; let tGm = '';
const at = (iso: string) => { h.now.value = new Date(iso); };
const types = async (id: string) => (await h.db.query(`SELECT type FROM notifications WHERE recipient_id = $1`, [id])).rows.map((x) => x.type as string);
const incidents = async (id: string) => (await h.db.query(`SELECT * FROM unauthorized_exit_incidents WHERE employee_id = $1 ORDER BY exit_at`, [id])).rows;
const ping = (tok: string, p: object) => h.call(tok, 'POST', '/tracking/ping', p);

before(async () => {
  h = await harness('2026-03-10T07:30:00Z', { migrationsExcept: [] }); c = await cast(h);
  await h.db.tx(async (q) => { await q.query(SQL094); });
  await h.db.tx(async (q) => { await q.query(SQL094); }); // a second run changes nothing
  await regrantAppRole(h); forgetPrefsTable(); forgetIncidentsInstalled();
  await h.db.query(`INSERT INTO work_locations (name, lat, lng, radius_m) VALUES ('المكتب', $1, $2, 100)`, [OFFICE.lat, OFFICE.lng]);
  await h.call(c.t.owner, 'POST', '/employees', { code: 'GM1', fullName: 'المدير العام', role: 'manager' });
  await h.db.query(`UPDATE employees SET must_change_password = false, password_hash = (SELECT password_hash FROM employees WHERE code = 'E1') WHERE code = 'GM1'`);
  tGm = await h.login('GM1', PW);
  const s = await h.call(c.t.owner, 'PATCH', '/settings', { trackingEnabled: true, trackingStaleMinutes: 20, awayMarginM: 50, payrollAutoDeductions: true });
  assert.equal(s.status, 200, JSON.stringify(s.body));
  for (const id of [c.ids.e1, c.ids.e2, c.ids.e3, c.ids.solo]) {
    await h.db.query(`INSERT INTO employee_salaries (employee_id, base_salary, updated_by) VALUES ($1, 9000, $2)`, [id, c.ids.owner]);
  }
});
after(async () => { await h.close(); });

// ================================================================================================ pure policy functions
test('absence threshold: off, fixed hours, half of the actual shift (different durations)', () => {
  assert.equal(absenceThresholdMinutes(null, '10:00', '18:00'), null);
  assert.equal(absenceThresholdMinutes({ mode: null, hours: 3 }, '10:00', '18:00'), null, 'a value without a mode does nothing');
  assert.equal(absenceThresholdMinutes({ mode: 'fixed_hours', hours: null }, '10:00', '18:00'), null, 'a mode without its value does nothing');
  assert.equal(absenceThresholdMinutes({ mode: 'fixed_hours', hours: 2.5 }, '10:00', '18:00'), 150);
  assert.equal(absenceThresholdMinutes({ mode: 'half_shift', hours: null }, '10:00', '18:00'), 240, '8-hour shift');
  assert.equal(absenceThresholdMinutes({ mode: 'half_shift', hours: null }, '09:00', '15:00'), 180, '6-hour shift');
  assert.equal(absenceThresholdMinutes({ mode: 'half_shift', hours: null }, '10:00', '14:30'), 135, '4.5-hour shift');
  assert.equal(lateIsAbsence(179, 180), false, 'never before the threshold');
  assert.equal(lateIsAbsence(180, 180), true);
  assert.equal(lateIsAbsence(500, null), false);
});

test('tracking eligibility: only inside the shift on a working day, never on leave / holiday', () => {
  const base = { nowMinutes: 12 * 60, isoDow: 2, weekendDays: [5], holiday: false, onLeave: false, shiftStart: '10:00', shiftEnd: '18:00', checkedIn: true, checkedOut: false };
  assert.deepEqual(shiftEligibility(base), { eligible: true, reason: null, endsInMinutes: 360 });
  assert.equal(shiftEligibility({ ...base, nowMinutes: 9 * 60 + 59 }).reason, 'before_shift');
  assert.equal(shiftEligibility({ ...base, nowMinutes: 18 * 60 }).reason, 'shift_ended');
  assert.equal(shiftEligibility({ ...base, isoDow: 5 }).reason, 'not_working_day');
  assert.equal(shiftEligibility({ ...base, holiday: true }).reason, 'holiday');
  assert.equal(shiftEligibility({ ...base, onLeave: true }).reason, 'on_leave');
  assert.equal(shiftEligibility({ ...base, checkedIn: false }).reason, 'not_checked_in');
  assert.equal(shiftEligibility({ ...base, checkedOut: true }).reason, 'checked_out');
});

test('«شرائح خروج بدون إذن»: validation, deterministic tier, boundaries, minutes capped at the shift end', () => {
  const tiers = validateExitTiers([{ fromMinutes: 60, toMinutes: null, amount: 100 }, { fromMinutes: 15, toMinutes: 60, amount: 50 },
    { fromMinutes: 5, toMinutes: 15, amount: 20, enabled: false }]);
  assert.deepEqual(tiers.map((t) => t.fromMinutes), [5, 15, 60], 'priority = ascending start');
  assert.equal(exitTierFor(tiers, 14), null, 'a disabled tier never applies');
  assert.equal(exitTierFor(tiers, 15)?.amount, 50, 'lower bound inclusive');
  assert.equal(exitTierFor(tiers, 59)?.amount, 50);
  assert.equal(exitTierFor(tiers, 60)?.amount, 100, 'upper bound exclusive');
  assert.equal(exitTierFor(tiers, 600)?.amount, 100);
  assert.throws(() => validateExitTiers([{ fromMinutes: 10, toMinutes: 40, amount: 5 }, { fromMinutes: 30, toMinutes: null, amount: 9 }]), /overlap/);
  assert.throws(() => validateExitTiers([{ fromMinutes: 10, toMinutes: null, amount: 5 }, { fromMinutes: 30, toMinutes: 50, amount: 9 }]), /overlap/);
  assert.throws(() => validateExitTiers([{ fromMinutes: 30, toMinutes: 20, amount: 5 }]), /after/);
  assert.throws(() => validateExitTiers([{ fromMinutes: 10, toMinutes: null, amount: 0 }]), /positive/);
  validateExitTiers([{ fromMinutes: 10, toMinutes: 40, amount: 5 }, { fromMinutes: 20, toMinutes: 30, amount: 9, enabled: false }]); // disabled may overlap
  const t = (iso: string) => new Date(iso);
  assert.equal(exitMinutes(t('2026-03-10T14:00:00Z'), t('2026-03-10T14:35:30Z'), t('2026-03-10T16:00:00Z')), 35);
  assert.equal(exitMinutes(t('2026-03-10T15:30:00Z'), t('2026-03-10T19:00:00Z'), t('2026-03-10T16:00:00Z')), 30, 'after the shift never counts');
});

test('notification categories reuse the existing types; the mandatory ones are not categories', () => {
  assert.equal(categoryOf('unauthorized_exit'), 'unauthorized_exit');
  assert.equal(categoryOf('outing_awaiting'), 'outings');
  assert.equal(categoryOf('request_awaiting'), 'requests');
  assert.equal(categoryOf('not_checked_in'), 'lateness_absence');
  assert.equal(categoryOf('back_in_office'), 'attendance');
  assert.equal(categoryOf('payout_received'), 'finance');
  assert.equal(categoryOf('message'), 'announcements');
  for (const m of ['security_alert', 'unauthorized_exit_self', 'payout_otp', 'tracking_phone_off', 'checkin_other_phone']) assert.equal(categoryOf(m), null);
  assert.equal(categoryOf('lead_assigned'), null, 'other types are always delivered');
});

// ================================================================================================ settings (094 installed)
test('settings: no defaults invented; fixed hours need their value; the deduction needs an enabled tier; overlaps refused', async () => {
  const s = (await h.call(c.t.owner, 'GET', '/settings')).body.settings;
  assert.equal(s.absence_threshold_mode, null); assert.equal(s.absence_threshold_hours, null);
  assert.deepEqual(s.unauthorized_exit_tiers, []); assert.equal(s.unauthorized_exit_deduction, false);
  assert.equal((await h.call(c.t.owner, 'PATCH', '/settings', { absenceThresholdMode: 'fixed_hours' })).status, 400);
  assert.equal((await h.call(c.t.owner, 'PATCH', '/settings', { unauthorizedExitDeduction: true })).body.error.details.reason, 'no_tiers');
  const bad = await h.call(c.t.owner, 'PATCH', '/settings', { unauthorizedExitTiers: [{ fromMinutes: 10, toMinutes: 40, amount: 5 }, { fromMinutes: 30, toMinutes: null, amount: 9 }] });
  assert.equal(bad.body.error.details.reason, 'tiers_overlap');
  // a refused value changed nothing (validated before anything was written)
  assert.equal((await h.call(c.t.owner, 'GET', '/settings')).body.settings.tracking_enabled, true);
  assert.equal((await h.call(c.t.e1, 'PATCH', '/settings', { absenceThresholdMode: 'half_shift' })).status, 403, 'settings.manage only');
});

// ================================================================================================ manager leave / absence
test('a sales manager on approved leave: no team notifications; requests go to the next approver; nothing auto-decided', async () => {
  at('2026-03-10T07:40:00Z');
  const leave = await h.call(c.t.hr, 'POST', '/requests', { employeeId: c.ids.sm1, type: 'full_day_absence', startDate: '2026-03-10', endDate: '2026-03-10',
    absenceType: 'annual', reason: 'إجازة سنوية' });
  assert.equal(leave.status, 201, JSON.stringify(leave.body));
  const before = await types(c.ids.sm1);
  // an hourly permission of his team member: HR decides it (route hr_only), he is not told
  const r = await h.call(c.t.e1, 'POST', '/requests', { type: 'hourly_permission', day: '2026-03-10', fromTime: '12:00', toTime: '13:00', reason: 'مشوار بنك' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.request.status, 'pending_hr'); assert.equal(r.body.request.manager_id, null);
  assert.ok((await types(c.ids.hr)).includes('request_awaiting'), 'HR (authorized for it) is told');
  // a leave request: the general manager takes the first stage, as when there is no manager
  const lv = await h.call(c.t.e2, 'POST', '/requests', { type: 'full_day_absence', startDate: '2026-03-12', endDate: '2026-03-12', absenceType: 'casual', reason: 'ظرف عائلي' });
  assert.equal(lv.status, 201, JSON.stringify(lv.body));
  assert.equal(lv.body.request.status, 'pending_manager');
  const gmId = (await h.db.query(`SELECT id FROM employees WHERE code = 'GM1'`)).rows[0].id;
  assert.ok(lv.body.request.manager_id === gmId || lv.body.request.manager_id === c.ids.owner, 'next configured approver (GM / owner), never the away manager');
  // an outing: HR (who may decide it) is told, he is not
  const o = await h.call(c.t.e1, 'POST', '/outings', { kind: 'visit', reason: 'معاينة عميل', expectedReturn: '13:00' });
  assert.equal(o.status, 201, JSON.stringify(o.body));
  assert.ok((await types(c.ids.hr)).includes('outing_awaiting'));
  assert.deepEqual((await types(c.ids.sm1)).filter((t) => !before.includes(t)), [], 'nothing reached the away manager');
  // the audit history records why
  assert.ok((await h.db.query(`SELECT 1 FROM audit_log WHERE action = 'request.submit' AND after::text LIKE $1`, [`%${c.ids.sm1}%`])).rows.length >= 1);
  // nothing was decided for anyone
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM requests WHERE status = 'approved' AND employee_id <> $1`, [c.ids.sm1])).rows[0].n, 0);
  await h.call(c.t.e1, 'POST', `/outings/${o.body.outing.id}/cancel`, {});
});

test('the away manager is not alerted about an unauthorized exit; HR is; back at work → routing restored', async () => {
  at('2026-03-10T08:00:00Z');
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-in', {})).status, 201);
  assert.equal((await ping(c.t.e1, IN)).body.inside, true);
  at('2026-03-10T08:10:00Z');
  assert.equal((await ping(c.t.e1, OUT)).body.inside, false);
  assert.ok((await types(c.ids.hr)).includes('unauthorized_exit'));
  assert.ok(!(await types(c.ids.sm1)).includes('unauthorized_exit'), 'away manager silent');
  at('2026-03-10T08:20:00Z');
  await ping(c.t.e1, IN);
});

test('shift-based tracking: on leave / before the shift → not followed; inside the shift → followed', async () => {
  // the GM is on leave today (recorded by HR): he is not followed
  const gmId = (await h.db.query(`SELECT id FROM employees WHERE code = 'GM1'`)).rows[0].id;
  await h.call(c.t.hr, 'POST', '/requests', { employeeId: gmId, type: 'full_day_absence', startDate: '2026-03-10', endDate: '2026-03-10', absenceType: 'annual', reason: 'إجازة' });
  const cfg = await h.call(tGm, 'GET', '/tracking/config');
  assert.equal(cfg.body.enabled, false); assert.equal(cfg.body.reason, 'on_leave');
  assert.equal((await ping(tGm, IN)).body.reason, 'on_leave');
  const e3 = await h.call(c.t.e3, 'GET', '/tracking/config');
  assert.equal(e3.body.enabled, true); assert.equal(e3.body.endsInMinutes, 18 * 60 - (10 * 60 + 20));
});

test('unauthorized exit before approval: one incident (replays and parallel pings too), a later approval never erases it', async () => {
  await h.call(c.t.owner, 'PATCH', '/settings', { unauthorizedExitTiers: [{ fromMinutes: 15, toMinutes: 60, amount: 50 }, { fromMinutes: 60, toMinutes: null, amount: 100 }],
    unauthorizedExitDeduction: true });
  at('2026-03-10T08:25:00Z');
  assert.equal((await h.call(c.t.e3, 'POST', '/attendance/check-in', {})).status, 201);
  await ping(c.t.e3, IN);
  const o = await h.call(c.t.e3, 'POST', '/outings', { kind: 'visit', reason: 'معاينة شقة', expectedReturn: '14:00' });
  assert.equal(o.status, 201, JSON.stringify(o.body));
  at('2026-03-10T08:30:00Z');
  await ping(c.t.e3, OUT);
  at('2026-03-10T08:31:00Z');
  await ping(c.t.e3, OUT);
  at('2026-03-10T08:32:00Z');
  await Promise.all([1, 2, 3, 4].map(() => ping(c.t.e3, OUT)));
  let inc = await incidents(c.ids.e3);
  assert.equal(inc.length, 1, 'one incident');
  assert.equal(inc[0].status, 'open'); assert.equal(inc[0].permission_state, 'pending', 'the pending request is recorded, not ignored');
  at('2026-03-10T09:05:00Z');
  await ping(c.t.e3, IN);
  inc = await incidents(c.ids.e3);
  assert.equal(inc[0].status, 'closed'); assert.equal(inc[0].end_reason, 'returned'); assert.equal(inc[0].minutes, 35);
  assert.equal(Number(inc[0].amount_egp), 50); assert.equal(inc[0].tier.amount, 50);
  // the visit is approved afterwards: the incident (and its deduction) stays
  assert.equal((await h.call(c.t.hr, 'POST', `/outings/${o.body.outing.id}/decision`, { decision: 'approve' })).status, 200);
  assert.equal(Number((await incidents(c.ids.e3))[0].amount_egp), 50);
});

test('payroll receives the deduction exactly once; a short exit (no tier) is recorded with no amount', async () => {
  at('2026-03-10T09:20:00Z');
  await h.call(c.t.e3, 'POST', '/outings/return', {}).catch(() => undefined);
  await ping(c.t.e3, IN);
  at('2026-03-10T09:40:00Z');
  await ping(c.t.e3, OUT);
  at('2026-03-10T09:50:00Z');
  assert.equal((await h.call(c.t.e3, 'POST', '/attendance/check-out', {})).status, 200);
  const inc = await incidents(c.ids.e3);
  const last = inc[inc.length - 1];
  assert.equal(last.end_reason, 'checked_out'); assert.equal(last.minutes, 10); assert.equal(last.amount_egp, null);
  const rules = await loadRules(h.db);
  const p1 = await computePayroll(h.db, c.ids.e3, '2026-03-01', '2026-03-10', rules);
  assert.equal(p1.unauthorizedExit.amount, 50);
  const p2 = await computePayroll(h.db, c.ids.e3, '2026-03-01', '2026-03-10', rules);
  assert.equal(p2.unauthorizedExit.amount, 50, 'reading it again never adds it again');
  assert.equal((await h.call(c.t.hr, 'GET', `/payroll/employee/${c.ids.e3}?month=2026-03`)).body.payroll.unauthorizedExit.amount, 50);
});

test('reversal: payroll approver only, never one\'s own, once, with a reason — the database keeps the figures', async () => {
  const id = (await incidents(c.ids.e3))[0].id;
  assert.equal((await h.call(c.t.e3, 'POST', `/attendance/exit-incidents/${id}/reverse`, { reason: 'كان في معاينة' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', `/attendance/exit-incidents/${id}/reverse`, { reason: 'x' })).status, 400, 'a reason');
  const r = await h.call(c.t.owner, 'POST', `/attendance/exit-incidents/${id}/reverse`, { reason: 'المعاينة كانت متفق عليها شفهياً' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal((await h.call(c.t.owner, 'POST', `/attendance/exit-incidents/${id}/reverse`, { reason: 'تاني' })).status, 409);
  const p = await computePayroll(h.db, c.ids.e3, '2026-03-01', '2026-03-10', await loadRules(h.db));
  assert.equal(p.unauthorizedExit.amount, 0);
  const refuse = async (sql: string) => assert.rejects(h.db.query(sql, [id]), (e: any) => e.code === '23514', sql);
  await refuse(`UPDATE unauthorized_exit_incidents SET amount_egp = 1 WHERE id = $1`);
  await refuse(`UPDATE unauthorized_exit_incidents SET status = 'closed', reversed_at = NULL, reversed_by = NULL, reverse_reason = NULL WHERE id = $1`);
  await refuse(`UPDATE unauthorized_exit_incidents SET exit_at = exit_at + interval '1 minute' WHERE id = $1`);
  await refuse(`DELETE FROM unauthorized_exit_incidents WHERE id = $1`);
  const list = await h.call(c.t.sm2, 'GET', '/attendance/exit-incidents?month=2026-03');
  assert.ok(list.body.incidents.some((x: any) => x.id === id), 'his team manager sees it');
  assert.ok(!(await h.call(c.t.sm1, 'GET', '/attendance/exit-incidents?month=2026-03')).body.incidents.some((x: any) => x.employee_id === c.ids.e3), 'another team never');
});

test('an exit still open at the scheduled shift end is closed at the shift end; after it nobody is followed', async () => {
  at('2026-03-10T15:30:00Z'); // 17:30 local
  assert.equal((await h.call(c.t.e2, 'POST', '/attendance/check-in', {})).status, 201);
  await ping(c.t.e2, IN);
  at('2026-03-10T15:40:00Z');
  await ping(c.t.e2, OUT);
  at('2026-03-10T16:30:00Z'); // 18:30 local: the shift ended at 18:00
  assert.equal((await ping(c.t.e2, OUT)).body.reason, 'shift_ended');
  await h.call(c.t.hr, 'GET', '/tracking/live'); // runs the sweep
  const inc = await incidents(c.ids.e2);
  assert.equal(inc.length, 1); assert.equal(inc[0].end_reason, 'shift_end'); assert.equal(inc[0].minutes, 20);
  assert.equal(new Date(inc[0].ended_at).toISOString(), '2026-03-10T16:00:00.000Z');
});

// ================================================================================================ absence threshold
test('absence threshold: a check-in at / after it is an absence (kept timestamps, not also late); before it is late', async () => {
  await h.call(c.t.owner, 'PATCH', '/settings', { absenceThresholdMode: 'fixed_hours', absenceThresholdHours: 3 });
  // solo: 10:00 shift; checks in at 13:00 local exactly → absent
  const ci = await h.db.query(`INSERT INTO attendance (employee_id, work_date, schedule_start, schedule_end, late_grace_minutes, early_grace_minutes,
      overtime_enabled, overtime_min_minutes, check_in_at, geofence_status, original_check_in_at)
    VALUES ($1, '2026-03-09', '10:00', '18:00', 10, 10, false, 0, '2026-03-09T11:00:00Z', 'not_required', '2026-03-09T11:00:00Z'),
           ($1, '2026-03-08', '10:00', '18:00', 10, 10, false, 0, '2026-03-08T10:59:00Z', 'not_required', '2026-03-08T10:59:00Z')
    RETURNING id`, [c.ids.solo]);
  assert.equal(ci.rows.length, 2);
  let m = await computeMonth(h.db, c.ids.solo, '2026-03-01', '2026-03-10');
  const d9 = m.days.find((d) => d.date === '2026-03-09')!, d8 = m.days.find((d) => d.date === '2026-03-08')!;
  assert.equal(d9.status, 'absent'); assert.equal(d9.lateAsAbsence, true); assert.ok(d9.attendance, 'timestamps kept');
  assert.equal(d9.attendance!.isLate, false, 'not double counted');
  assert.equal(d8.status, 'present'); assert.equal(d8.attendance!.lateMinutes, 179, 'one minute before the threshold: late');
  const p = await computePayroll(h.db, c.ids.solo, '2026-03-01', '2026-03-10', await loadRules(h.db));
  assert.equal(p.late.days, 1, 'only the 8th is a late day');
  // half of the actual shift: a 6-hour shift (10:00–16:00) → 3 hours as well; the 8-hour one → 4 hours (179 and 180 late: present)
  await h.call(c.t.owner, 'PATCH', '/settings', { absenceThresholdMode: 'half_shift' });
  m = await computeMonth(h.db, c.ids.solo, '2026-03-01', '2026-03-10');
  assert.equal(m.days.find((d) => d.date === '2026-03-09')!.status, 'present', '8-hour shift: 4-hour threshold');
  await h.db.query(`UPDATE attendance SET schedule_end = '16:00' WHERE employee_id = $1 AND work_date = '2026-03-09'`, [c.ids.solo]);
  m = await computeMonth(h.db, c.ids.solo, '2026-03-01', '2026-03-10');
  assert.equal(m.days.find((d) => d.date === '2026-03-09')!.status, 'absent', '6-hour shift: 3-hour threshold');
  // off again → today's behaviour exactly
  await h.call(c.t.owner, 'PATCH', '/settings', { absenceThresholdMode: 'off' });
  m = await computeMonth(h.db, c.ids.solo, '2026-03-01', '2026-03-10');
  assert.equal(m.days.find((d) => d.date === '2026-03-09')!.status, 'present');
});

// ================================================================================================ notification preferences
test('notification preferences: per person, only suppress, mandatory ones protected, history kept', async () => {
  at('2026-03-10T16:40:00Z');
  const g = await h.call(c.t.e1, 'GET', '/me/notification-preferences');
  assert.equal(g.status, 200);
  const keys = g.body.categories.map((x: any) => x.key);
  assert.ok(!keys.includes('unauthorized_exit'), 'a salesman is not offered the exit alarm of others');
  assert.ok(g.body.categories.every((x: any) => x.enabled === true), 'nobody silenced by default');
  assert.equal((await h.call(c.t.e1, 'PUT', '/me/notification-preferences', { categories: [{ key: 'unauthorized_exit', enabled: false }] })).body.error.details.reason, 'not_available');
  // history first, then off
  await notify(h.db, { to: c.ids.e1, type: 'advance_confirmed', title: 'قبل', dedupeKey: 'pref:before' });
  assert.equal((await h.call(c.t.e1, 'PUT', '/me/notification-preferences', { categories: [{ key: 'finance', enabled: false }] })).status, 200);
  assert.equal(await notify(h.db, { to: c.ids.e1, type: 'advance_confirmed', title: 'بعد', dedupeKey: 'pref:after' }), null);
  const titles = (await h.db.query(`SELECT title FROM notifications WHERE recipient_id = $1 AND dedupe_key LIKE 'pref:%'`, [c.ids.e1])).rows.map((x) => x.title);
  assert.deepEqual(titles, ['قبل'], 'the earlier one stays, the new one is not delivered');
  // mandatory types are never categories: still delivered
  await notify(h.db, { to: c.ids.e1, type: 'payout_otp', title: 'كود', dedupeKey: 'pref:otp' });
  assert.ok((await types(c.ids.e1)).includes('payout_otp'));
  // another person's preference never affects him
  await notify(h.db, { to: c.ids.e2, type: 'advance_confirmed', title: 'e2', dedupeKey: 'pref:e2' });
  assert.ok((await types(c.ids.e2)).includes('advance_confirmed'));
  // HR keeps the approvals and the exit alarm; the owner keeps everything
  assert.equal((await h.call(c.t.hr, 'PUT', '/me/notification-preferences', { categories: [{ key: 'requests', enabled: false }] })).body.error.details.reason, 'mandatory');
  assert.equal((await h.call(c.t.owner, 'PUT', '/me/notification-preferences', { categories: [{ key: 'finance', enabled: false }] })).body.error.details.reason, 'mandatory');
  assert.ok((await h.call(c.t.hr, 'GET', '/me/notification-preferences')).body.categories.find((x: any) => x.key === 'requests').locked);
  // a team manager may turn his exit alarm off; even off, a preference adds nothing anywhere else
  assert.equal((await h.call(c.t.sm2, 'PUT', '/me/notification-preferences', { categories: [{ key: 'unauthorized_exit', enabled: false }] })).status, 200);
  assert.equal(await notify(h.db, { to: c.ids.sm2, type: 'unauthorized_exit', title: 'x', dedupeKey: 'pref:sm2' }), null);
  // back on
  assert.equal((await h.call(c.t.e1, 'PUT', '/me/notification-preferences', { categories: [{ key: 'finance', enabled: true }] })).status, 200);
  assert.notEqual(await notify(h.db, { to: c.ids.e1, type: 'advance_confirmed', title: 'تاني', dedupeKey: 'pref:again' }), null);
});

test('the manager is back the next day (his leave ended): routing to him is restored automatically', async () => {
  at('2026-03-11T08:30:00Z'); // Wednesday 10:30 local
  assert.equal((await h.call(c.t.sm1, 'POST', '/attendance/check-in', {})).status, 201);
  const r = await h.call(c.t.e2, 'POST', '/requests', { type: 'hourly_permission', day: '2026-03-11', fromTime: '15:00', toTime: '16:00', reason: 'مشوار' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.request.status, 'pending_manager'); assert.equal(r.body.request.manager_id, c.ids.sm1);
  assert.ok((await types(c.ids.sm1)).includes('request_awaiting'));
});
