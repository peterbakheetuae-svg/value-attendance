import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { harness, cast, PW, type Harness, regrantAppRole } from './helpers.ts';
import { absenceThresholdMinutes, exitMinutes, exitTierFor, thresholdReached, shiftEligibility, validateExitTiers } from '../src/lib/attendance-policy.ts';
import { categoryOf, MANDATORY_TYPES } from '../src/lib/notification-categories.ts';
import { computeMonth } from '../src/modules/attendance-calc.ts';
import { computePayroll, loadRules } from '../src/modules/payroll-calc.ts';
import { notify, forgetPrefsTable } from '../src/modules/notify.ts';
import { forgetIncidentsInstalled } from '../src/modules/exit-incidents.ts';
import { escalateUnrouted } from '../src/modules/routing.ts';
import { createDb } from '../src/db.ts';

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
  assert.equal(thresholdReached(179, 180), false, 'before');
  assert.equal(thresholdReached(180, 180), true, 'exactly at');
  assert.equal(thresholdReached(181, 180), true, 'after');
  assert.equal(thresholdReached(500, null), false, 'disabled');
});

test('tracking eligibility: only inside the shift on a working day, never on leave / holiday', () => {
  const base = { nowMinutes: 12 * 60, isoDow: 2, weekendDays: [5], holiday: false, onLeave: false, shiftStart: '10:00', shiftEnd: '18:00', checkedIn: true, checkedOut: false };
  assert.deepEqual(shiftEligibility(base), { eligible: true, reason: null, endsInMinutes: 360 });
  assert.equal(shiftEligibility({ ...base, nowMinutes: 9 * 60 + 59 }).reason, 'before_shift');
  assert.equal(shiftEligibility({ ...base, nowMinutes: 9 * 60 + 15 }).startsInMinutes, 45, 'the app is told when the shift starts');
  assert.equal(shiftEligibility({ ...base, nowMinutes: 10 * 60 }).eligible, true, 'eligible exactly at the scheduled start');
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

test('an early check-in: no tracking before the scheduled shift start (config, pings, no incident); followed from the start', async () => {
  at('2026-03-10T07:45:00Z'); // 09:45 local, the shift starts at 10:00
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-in', {})).status, 201);
  const cfg = (await h.call(c.t.e1, 'GET', '/tracking/config')).body;
  assert.equal(cfg.enabled, false); assert.equal(cfg.reason, 'before_shift'); assert.equal(cfg.startsInMinutes, 15);
  const p = await ping(c.t.e1, OUT);
  assert.equal(p.body.tracking, false); assert.equal(p.body.reason, 'before_shift');
  assert.equal((await incidents(c.ids.e1)).length, 0, 'outside before the shift is no exit');
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM tracking_state WHERE employee_id = $1`, [c.ids.e1])).rows[0].n, 0, 'nothing recorded');
  at('2026-03-10T08:00:00Z'); // exactly 10:00 local
  assert.equal((await h.call(c.t.e1, 'GET', '/tracking/config')).body.enabled, true, 'eligible from the scheduled start');
});

test('the away manager is not alerted about an unauthorized exit; HR is; back at work → routing restored', async () => {
  at('2026-03-10T08:00:00Z'); // e1 checked in early (above)
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
  // a payroll sheet prepared now freezes the deduction in its snapshot — a later reversal never rewrites it
  const sheet = await h.call(c.t.hr, 'POST', '/payroll-batches', { month: '2026-03' });
  assert.equal(sheet.status, 201, JSON.stringify(sheet.body));
  const lineOf = async () => (await h.db.query(`SELECT snapshot FROM payroll_batch_lines WHERE batch_id = $1 AND employee_id = $2`,
    [sheet.body.batch.id, c.ids.e3])).rows[0]?.snapshot;
  const frozen = await lineOf();
  assert.equal(frozen.unauthorizedExit.amount, 50);
  assert.equal((await h.call(c.t.e3, 'POST', `/attendance/exit-incidents/${id}/reverse`, { reason: 'كان في معاينة' })).status, 403);
  assert.equal((await h.call(c.t.owner, 'POST', `/attendance/exit-incidents/${id}/reverse`, { reason: 'x' })).status, 400, 'a reason');
  const r = await h.call(c.t.owner, 'POST', `/attendance/exit-incidents/${id}/reverse`, { reason: 'المعاينة كانت متفق عليها شفهياً' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal((await h.call(c.t.owner, 'POST', `/attendance/exit-incidents/${id}/reverse`, { reason: 'تاني' })).status, 409);
  const p = await computePayroll(h.db, c.ids.e3, '2026-03-01', '2026-03-10', await loadRules(h.db));
  assert.equal(p.unauthorizedExit.amount, 0);
  assert.deepEqual(await lineOf(), frozen, 'the sheet snapshot is not rewritten by the reversal');
  assert.ok((await h.db.query(`SELECT 1 FROM audit_log WHERE action = 'exit_incident.reverse' AND entity_id = $1`, [id])).rows.length === 1, 'audited');
  assert.equal((await h.call(c.t.hr, 'POST', `/payroll-batches/${sheet.body.batch.id}/cancel`, {})).status, 200);
  const refuse = async (sql: string) => assert.rejects(h.db.query(sql, [id]), (e: any) => e.code === '23514', sql);
  await refuse(`UPDATE unauthorized_exit_incidents SET amount_egp = 1 WHERE id = $1`);
  await refuse(`UPDATE unauthorized_exit_incidents SET status = 'closed', reversed_at = NULL, reversed_by = NULL, reverse_reason = NULL WHERE id = $1`);
  await refuse(`UPDATE unauthorized_exit_incidents SET exit_at = exit_at + interval '1 minute' WHERE id = $1`);
  await refuse(`DELETE FROM unauthorized_exit_incidents WHERE id = $1`);
  const list = await h.call(c.t.sm2, 'GET', '/attendance/exit-incidents?month=2026-03');
  assert.ok(list.body.incidents.some((x: any) => x.id === id), 'his team manager sees it');
  assert.ok(!(await h.call(c.t.sm1, 'GET', '/attendance/exit-incidents?month=2026-03')).body.incidents.some((x: any) => x.employee_id === c.ids.e3), 'another team never');
});

// ================================================================================================ effective activation
test('effective deduction = automatic deductions on AND exit deduction on AND a matching tier — frozen at closing', async () => {
  // sm2 (team B manager) checks in late; two exits of 20 minutes (the 15–60 tier matches)
  at('2026-03-10T10:00:00Z');
  assert.equal((await h.call(c.t.sm2, 'POST', '/attendance/check-in', {})).status, 201);
  await ping(c.t.sm2, IN);
  // 1) global automatic deductions OFF, exit deduction on → recorded, no amount
  await h.call(c.t.owner, 'PATCH', '/settings', { payrollAutoDeductions: false });
  at('2026-03-10T10:05:00Z'); await ping(c.t.sm2, OUT);
  at('2026-03-10T10:25:00Z'); await ping(c.t.sm2, IN);
  // 2) global ON, exit deduction OFF → turning the general switch on does not activate the exit deduction
  await h.call(c.t.owner, 'PATCH', '/settings', { payrollAutoDeductions: true, unauthorizedExitDeduction: false });
  at('2026-03-10T10:30:00Z'); await ping(c.t.sm2, OUT);
  at('2026-03-10T10:50:00Z'); await ping(c.t.sm2, IN);
  const inc = await incidents(c.ids.sm2);
  assert.equal(inc.length, 2);
  for (const x of inc) {
    assert.equal(x.status, 'closed'); assert.equal(x.minutes, 20); assert.equal(x.tier.amount, 50, 'the tier matched');
    assert.equal(x.amount_egp, null, 'not effective → never deducted'); assert.equal(x.deduction_enabled, false);
  }
  // switching both on afterwards changes no closed incident (nothing retroactive)
  await h.call(c.t.owner, 'PATCH', '/settings', { unauthorizedExitDeduction: true });
  assert.ok((await incidents(c.ids.sm2)).every((x) => x.amount_egp === null));
  // the database refuses a second open incident for the same employee (any phone, any request)
  await h.db.query(`INSERT INTO unauthorized_exit_incidents (employee_id, work_date, attendance_id, period, exit_at, permission_state, shift_end_at)
                    SELECT employee_id, work_date, id, '2026-03-01', '2026-03-10T10:55:00Z', 'none', '2026-03-10T16:00:00Z' FROM attendance
                     WHERE employee_id = $1 AND work_date = '2026-03-10'`, [c.ids.sm2]);
  await assert.rejects(h.db.query(`INSERT INTO unauthorized_exit_incidents (employee_id, work_date, attendance_id, period, exit_at, permission_state, shift_end_at)
                    SELECT employee_id, work_date, id, '2026-03-01', '2026-03-10T10:56:00Z', 'none', '2026-03-10T16:00:00Z' FROM attendance
                     WHERE employee_id = $1 AND work_date = '2026-03-10'`, [c.ids.sm2]), (e: any) => e.code === '23505');
  at('2026-03-10T10:58:00Z'); await ping(c.t.sm2, IN); // closes the one opened above (returned)
});

// ================================================================================================ absence threshold
test('absence registration: before the threshold refused, exactly at / after it allowed; only a request, never automatic; duplicates refused', async () => {
  await h.call(c.t.owner, 'PATCH', '/settings', { absenceThresholdMode: 'fixed_hours', absenceThresholdHours: 3 });
  const today = { type: 'full_day_absence', startDate: '2026-03-10', endDate: '2026-03-10', absenceType: 'casual', reason: 'ظرف طارئ' };
  // solo: 10:00 shift, no check-in; the threshold is 13:00 local = 11:00Z
  at('2026-03-10T10:59:00Z');
  const before = await h.call(c.t.solo, 'POST', '/requests', today);
  assert.equal(before.status, 422); assert.equal(before.body.error.details.reason, 'absence_threshold_not_reached');
  assert.equal(before.body.error.details.availableAtMinutes, 13 * 60);
  const t1 = (await h.call(c.t.solo, 'GET', '/attendance/today')).body.absenceThreshold;
  assert.deepEqual([t1.configured, t1.reached, t1.thresholdMinutes], [true, false, 180]);
  at('2026-03-10T11:00:00Z');
  assert.equal((await h.call(c.t.solo, 'GET', '/attendance/today')).body.absenceThreshold.reached, true, 'exactly at');
  const at0 = await h.call(c.t.solo, 'POST', '/requests', today);
  assert.equal(at0.status, 201, JSON.stringify(at0.body));
  assert.ok(['pending_manager', 'pending_hr'].includes(at0.body.request.status), 'a request for review — not approved');
  const dup = await h.call(c.t.solo, 'POST', '/requests', today);
  assert.equal(dup.status, 409); assert.equal(dup.body.error.details.reason, 'pending_exists');
  // the threshold passing registered nothing for anybody else and changed no attendance
  const auto = await h.db.query(`SELECT count(*)::int AS n FROM requests WHERE type = 'full_day_absence' AND start_date = '2026-03-10'
                                  AND employee_id NOT IN ($1, $2, $3)`, [c.ids.solo, c.ids.sm1, (await h.db.query(`SELECT id FROM employees WHERE code = 'GM1'`)).rows[0].id]);
  assert.equal(auto.rows[0].n, 0, 'no automatic absence registration');
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM attendance WHERE employee_id = $1`, [c.ids.solo])).rows[0].n, 0, 'no attendance created');
  // a future day is not gated (planned leave as before); another shift length: half of a 6-hour shift = 3 hours
  assert.equal((await h.call(c.t.acc, 'POST', '/requests', { ...today, startDate: '2026-03-12', endDate: '2026-03-12' })).status, 201);
  await h.call(c.t.owner, 'PATCH', '/settings', { absenceThresholdMode: 'half_shift' });
  await h.db.query(`UPDATE employees SET work_start = '10:00', work_end = '16:00' WHERE id = $1`, [c.ids.acc]);
  at('2026-03-10T10:30:00Z'); // 12:30 local: 2.5 h
  assert.equal((await h.call(c.t.acc, 'POST', '/requests', today)).body.error.details.reason, 'absence_threshold_not_reached');
  at('2026-03-10T11:00:00Z'); // 13:00 local: 3 h of a 6-hour shift
  assert.equal((await h.call(c.t.acc, 'POST', '/requests', today)).status, 201);
  // half of the default 8-hour shift is 4 hours: HR (no check-in) is still before it at 13:30 local
  at('2026-03-10T11:30:00Z');
  assert.equal((await h.call(c.t.hr, 'POST', '/requests', today)).body.error.details.reason, 'absence_threshold_not_reached');
  // disabled → exactly as before 094 (no gate)
  await h.call(c.t.owner, 'PATCH', '/settings', { absenceThresholdMode: 'off' });
  assert.equal((await h.call(c.t.hr, 'POST', '/requests', today)).status, 201);
  assert.equal((await h.call(c.t.hr, 'GET', '/attendance/today')).body.absenceThreshold.configured, false);
  // a day that already has a check-in can never become an absence: refused for him and when HR records it
  const e1Day = await h.call(c.t.e1, 'POST', '/requests', today);
  assert.equal(e1Day.status, 409); assert.equal(e1Day.body.error.details.reason, 'attendance_exists');
  assert.deepEqual(e1Day.body.error.details.dates, ['2026-03-10']);
  const byHr = await h.call(c.t.hr, 'POST', '/requests', { ...today, employeeId: c.ids.e1, absenceType: 'annual', reason: 'تسجيل' });
  assert.equal(byHr.status, 409); assert.equal(byHr.body.error.details.reason, 'attendance_exists');
  // a range that includes the attended day is refused too
  assert.equal((await h.call(c.t.e1, 'POST', '/requests', { ...today, endDate: '2026-03-11' })).body.error.details.reason, 'attendance_exists');
  // submitted before checking in, then he checked in: it cannot be approved (the attendance stands); it can be rejected
  at('2026-03-10T11:31:00Z');
  const accReq = (await h.db.query(`SELECT id FROM requests WHERE employee_id = $1 AND type = 'full_day_absence' AND start_date = '2026-03-10'`, [c.ids.acc])).rows[0].id;
  assert.equal((await h.call(c.t.acc, 'POST', '/attendance/check-in', {})).status, 201);
  const checkIn = (await h.db.query(`SELECT check_in_at FROM attendance WHERE employee_id = $1 AND work_date = '2026-03-10'`, [c.ids.acc])).rows[0].check_in_at;
  const ap = await h.call(c.t.owner, 'POST', `/requests/${accReq}/decision`, { decision: 'approve' });
  assert.equal(ap.status, 409, JSON.stringify(ap.body)); assert.equal(ap.body.error.details.reason, 'attendance_exists');
  assert.ok(['pending_manager', 'pending_hr'].includes((await h.db.query(`SELECT status FROM requests WHERE id = $1`, [accReq])).rows[0].status), 'unchanged');
  assert.equal((await h.call(c.t.owner, 'POST', `/requests/${accReq}/decision`, { decision: 'reject', comment: 'حضر اليوم' })).status, 200);
  const after = (await h.db.query(`SELECT check_in_at FROM attendance WHERE employee_id = $1 AND work_date = '2026-03-10'`, [c.ids.acc])).rows[0].check_in_at;
  assert.equal(new Date(after).toISOString(), new Date(checkIn).toISOString(), 'the attendance record is kept as it was');
  await h.call(c.t.owner, 'PATCH', '/settings', { absenceThresholdMode: 'fixed_hours', absenceThresholdHours: 3 });
});

test('a late check-in after the threshold stays a late attendance (timestamps kept), never an absence', async () => {
  at('2026-03-10T11:40:00Z'); // 13:40 local, 3 h 40 after the start
  assert.equal((await h.call(c.t.e2, 'POST', '/attendance/check-in', {})).status, 201);
  const m = await computeMonth(h.db, c.ids.e2, '2026-03-01', '2026-03-10');
  const d = m.days.find((x) => x.date === '2026-03-10')!;
  assert.equal(d.status, 'present'); assert.equal(d.attendance!.isLate, true); assert.ok(d.attendance!.lateMinutes >= 200, String(d.attendance!.lateMinutes));
  assert.equal(new Date(d.attendance!.checkIn).toISOString(), '2026-03-10T11:40:00.000Z');
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM requests WHERE employee_id = $1 AND type = 'full_day_absence' AND start_date = '2026-03-10'`,
    [c.ids.e2])).rows[0].n, 0, 'nothing registered for him');
});

// ================================================================================================ routing failure
test('no authorized recipient: the item stays pending; owners are told; with no owner the failure is recorded', async () => {
  const req = (await h.db.query(`SELECT id FROM requests WHERE employee_id = $1 AND status IN ('pending_manager','pending_hr') LIMIT 1`, [c.ids.solo])).rows[0].id;
  const r1 = await escalateUnrouted(h.db, { actorId: c.ids.solo, entity: 'request', entityId: req, title: 't', body: 'b' });
  assert.equal(r1, 'escalated');
  assert.ok((await types(c.ids.owner)).includes('routing_escalation'));
  // the only owner is the actor himself → nobody to tell: recorded in the audit log, nothing else happens
  const r2 = await escalateUnrouted(h.db, { actorId: c.ids.owner, entity: 'request', entityId: req, title: 't', body: 'b' });
  assert.equal(r2, 'recorded');
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM audit_log WHERE action = 'routing.unrouted' AND entity_id = $1`, [req])).rows[0].n, 1);
  assert.ok(['pending_manager', 'pending_hr'].includes((await h.db.query(`SELECT status FROM requests WHERE id = $1`, [req])).rows[0].status), 'still pending');
});

// ================================================================================================ runtime role
test('the restricted runtime role cannot delete incidents, disable their trigger or edit frozen figures', async (t) => {
  if (process.env.TEST_APP_ROLE !== '1') { t.skip('the restricted role exists only in the least-privilege run'); return; }
  const u = new URL(process.env.TEST_PG_URL!); u.username = 'va_app_test'; u.password = 'app-role-test-only'; u.pathname = `/${h.dbName}`;
  const app = createDb(u.toString());
  try {
    const id = (await incidents(c.ids.e3))[0].id;
    await assert.rejects(app.query(`DELETE FROM unauthorized_exit_incidents WHERE id = $1`, [id]), (e: any) => e.code === '42501', 'no DELETE grant');
    await assert.rejects(app.query(`ALTER TABLE unauthorized_exit_incidents DISABLE TRIGGER ALL`), (e: any) => e.code === '42501', 'not the owner');
    await assert.rejects(app.query(`UPDATE unauthorized_exit_incidents SET amount_egp = 1 WHERE id = $1`, [id]), (e: any) => e.code === '23514');
    await assert.rejects(app.query(`DELETE FROM notification_preferences`), (e: any) => e.code === '42501');
    await assert.rejects(app.query(`TRUNCATE unauthorized_exit_incidents`), (e: any) => e.code === '42501');
  } finally { await app.end(); }
});

test('an exit still open at the scheduled shift end is closed at the shift end; after it nobody is followed', async () => {
  at('2026-03-10T15:30:00Z'); // 17:30 local (e2 checked in late, above)
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

test('all seven categories: off suppresses only his own delivery, on delivers; routing and authorization never change', async () => {
  at('2026-03-10T16:45:00Z');
  const SAMPLE: Record<string, string> = { unauthorized_exit: 'unauthorized_exit', outings: 'outing_awaiting', requests: 'request_awaiting',
    lateness_absence: 'not_checked_in', attendance: 'back_in_office', finance: 'advance_confirmed', announcements: 'message' };
  const offered = (await h.call(c.t.sm2, 'GET', '/me/notification-preferences')).body.categories.map((x: any) => x.key).sort();
  assert.deepEqual(offered, Object.keys(SAMPLE).sort(), 'a team manager is offered all seven');
  let n = 0;
  for (const [cat, type] of Object.entries(SAMPLE)) {
    assert.equal(categoryOf(type), cat);
    assert.equal((await h.call(c.t.sm2, 'PUT', '/me/notification-preferences', { categories: [{ key: cat, enabled: false }] })).status, 200, cat);
    assert.equal(await notify(h.db, { to: c.ids.sm2, type, title: cat, dedupeKey: `cat:${cat}:off:${n}` }), null, `${cat} off → not delivered`);
    assert.notEqual(await notify(h.db, { to: c.ids.sm1, type, title: cat, dedupeKey: `cat:${cat}:other:${n}` }), null, `${cat}: another person unaffected`);
    assert.equal((await h.call(c.t.sm2, 'PUT', '/me/notification-preferences', { categories: [{ key: cat, enabled: true }] })).status, 200, cat);
    assert.notEqual(await notify(h.db, { to: c.ids.sm2, type, title: cat, dedupeKey: `cat:${cat}:on:${n}` }), null, `${cat} on → delivered`);
    n++;
  }
  // everything off: the mandatory alerts still arrive
  assert.equal((await h.call(c.t.sm2, 'PUT', '/me/notification-preferences', { categories: Object.keys(SAMPLE).map((key) => ({ key, enabled: false })) })).status, 200);
  for (const type of MANDATORY_TYPES) {
    assert.equal(categoryOf(type), null);
    assert.notEqual(await notify(h.db, { to: c.ids.sm2, type, title: type, dedupeKey: `cat:mand:${type}` }), null, `${type} is mandatory`);
  }
  // off never changes routing: his team member's request is still his to decide (he is just not pinged)
  const r = await h.call(c.t.e3, 'POST', '/requests', { type: 'hourly_permission', day: '2026-03-17', fromTime: '15:00', toTime: '15:30', reason: 'مشوار' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.request.manager_id, c.ids.sm2); assert.equal(r.body.request.status, 'pending_manager');
  const pinged = async (to: string, id: string) => (await h.db.query(`SELECT count(*)::int AS n FROM notifications WHERE recipient_id = $1 AND entity_id = $2`, [to, id])).rows[0].n;
  assert.equal(await pinged(c.ids.sm2, r.body.request.id), 0);
  // on never grants: a salesman cannot take a category he cannot receive, and even a stored «on» row adds no recipient
  assert.equal((await h.call(c.t.e1, 'PUT', '/me/notification-preferences', { categories: [{ key: 'unauthorized_exit', enabled: true }] })).body.error.details.reason, 'not_available');
  await h.db.query(`INSERT INTO notification_preferences (employee_id, category, enabled) SELECT $1, x, true FROM unnest($2::text[]) x
                    ON CONFLICT (employee_id, category) DO UPDATE SET enabled = true`, [c.ids.e1, Object.keys(SAMPLE)]);
  assert.equal(await pinged(c.ids.e1, r.body.request.id), 0, 'not a recipient of another team\'s request');
  // the away manager (sm1, on leave today), with every category explicitly on, still gets nothing of his team
  await h.db.query(`INSERT INTO notification_preferences (employee_id, category, enabled) SELECT $1, x, true FROM unnest($2::text[]) x
                    ON CONFLICT (employee_id, category) DO UPDATE SET enabled = true`, [c.ids.sm1, Object.keys(SAMPLE)]);
  const r2 = await h.call(c.t.e2, 'POST', '/requests', { type: 'hourly_permission', day: '2026-03-17', fromTime: '12:00', toTime: '12:30', reason: 'مشوار' });
  assert.equal(r2.status, 201, JSON.stringify(r2.body));
  assert.equal(r2.body.request.manager_id, null); assert.equal(r2.body.request.status, 'pending_hr');
  assert.equal(await pinged(c.ids.sm1, r2.body.request.id), 0, 'away → not a recipient whatever his preferences');
  assert.ok(await pinged(c.ids.hr, r2.body.request.id) >= 1, 'HR (authorized) is');
  // back to defaults for the following tests
  await h.db.query(`DELETE FROM notification_preferences WHERE employee_id = ANY($1::uuid[])`, [[c.ids.sm2, c.ids.e1, c.ids.sm1]]);
});

test('the manager is back the next day (his leave ended): routing to him is restored automatically', async () => {
  at('2026-03-11T08:30:00Z'); // Wednesday 10:30 local
  assert.equal((await h.call(c.t.sm1, 'POST', '/attendance/check-in', {})).status, 201);
  const r = await h.call(c.t.e2, 'POST', '/requests', { type: 'hourly_permission', day: '2026-03-11', fromTime: '15:00', toTime: '16:00', reason: 'مشوار' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.request.status, 'pending_manager'); assert.equal(r.body.request.manager_id, c.ids.sm1);
  assert.ok((await types(c.ids.sm1)).includes('request_awaiting'));
});

test('an unresponsive manager (no check-in once the threshold passed) is away for routing only; his records untouched; checking in restores him', async () => {
  // Wednesday: sm2 (team B) has not checked in. Threshold 3 h → 13:00 local.
  at('2026-03-11T10:50:00Z'); // 12:50 local: not yet away
  const r0 = await h.call(c.t.e3, 'POST', '/requests', { type: 'hourly_permission', day: '2026-03-11', fromTime: '15:00', toTime: '15:30', reason: 'مشوار' });
  assert.equal(r0.status, 201, JSON.stringify(r0.body));
  assert.equal(r0.body.request.manager_id, c.ids.sm2, 'before the threshold he is still the approver');
  at('2026-03-11T11:05:00Z'); // 13:05 local: past it, still no check-in
  const r1 = await h.call(c.t.e3, 'POST', '/requests', { type: 'hourly_permission', day: '2026-03-16', fromTime: '16:00', toTime: '16:30', reason: 'مشوار تاني' });
  assert.equal(r1.status, 201, JSON.stringify(r1.body));
  assert.equal(r1.body.request.status, 'pending_hr'); assert.equal(r1.body.request.manager_id, null, 'routed past the unresponsive manager');
  // nothing was registered for him: no absence request, no attendance row
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM requests WHERE employee_id = $1`, [c.ids.sm2])).rows[0].n, 0);
  assert.equal((await h.db.query(`SELECT count(*)::int AS n FROM attendance WHERE employee_id = $1 AND work_date = '2026-03-11'`, [c.ids.sm2])).rows[0].n, 0);
  // he checks in (late) → normal routing resumes immediately
  at('2026-03-11T11:20:00Z');
  assert.equal((await h.call(c.t.sm2, 'POST', '/attendance/check-in', {})).status, 201);
  const r2 = await h.call(c.t.e3, 'POST', '/requests', { type: 'hourly_permission', day: '2026-03-12', fromTime: '15:00', toTime: '15:30', reason: 'مشوار' });
  assert.equal(r2.status, 201, JSON.stringify(r2.body));
  assert.equal(r2.body.request.manager_id, c.ids.sm2);
});

test('approved outing: tracking continues; outside inside the interval is no incident; return recorded; expiry restores enforcement', async () => {
  at('2026-03-11T11:30:00Z'); // 13:30 local
  assert.equal((await h.call(c.t.e1, 'POST', '/attendance/check-in', {})).status, 201);
  await ping(c.t.e1, IN);
  // only today's incidents (his 10 March exit is an earlier test's)
  const today11 = async () => (await incidents(c.ids.e1)).filter((x) => x.work_date === '2026-03-11');
  const outing = async (ret: string) => {
    const o = await h.call(c.t.e1, 'POST', '/outings', { kind: 'visit', reason: 'معاينة عميل', expectedReturn: ret });
    assert.equal(o.status, 201, JSON.stringify(o.body));
    assert.equal((await h.call(c.t.hr, 'POST', `/outings/${o.body.outing.id}/decision`, { decision: 'approve' })).status, 200);
    return (await h.db.query(`SELECT * FROM outing_requests WHERE id = $1`, [o.body.outing.id])).rows[0];
  };
  // 1) out and back inside the approved interval: followed, no incident, the return is recorded
  const o1 = await outing('14:00');
  assert.equal(new Date(o1.expected_return_at).toISOString(), '2026-03-11T12:00:00.000Z', '«14:00» is Cairo time');
  at('2026-03-11T11:35:00Z');
  const p1 = await ping(c.t.e1, OUT);
  assert.equal(p1.body.tracking, true, 'tracking continues during the outing'); assert.equal(p1.body.inside, false);
  at('2026-03-11T11:40:00Z');
  await Promise.all([1, 2, 3, 4].map(() => ping(c.t.e1, OUT)));
  assert.equal((await today11()).length, 0, 'authorized: no incident (parallel pings too)');
  assert.ok((await h.db.query(`SELECT 1 FROM audit_log WHERE action = 'tracking.authorized_exit' AND entity_id = $1`, [o1.id])).rows.length === 1);
  at('2026-03-11T11:50:00Z');
  await ping(c.t.e1, IN);
  assert.equal(new Date((await h.db.query(`SELECT returned_at FROM outing_requests WHERE id = $1`, [o1.id])).rows[0].returned_at).toISOString(), '2026-03-11T11:50:00.000Z');
  // 2) still outside when the return time passes: authorized until the exact second before; from it, normal enforcement
  at('2026-03-11T12:01:00Z');
  const o2 = await outing('14:30'); // 12:30Z
  at('2026-03-11T12:02:00Z'); await ping(c.t.e1, OUT);
  at('2026-03-11T12:29:59Z'); await ping(c.t.e1, OUT);
  assert.equal((await today11()).length, 0, 'one second before the return time: still authorized');
  at('2026-03-11T12:30:00Z');
  await Promise.all([1, 2, 3].map(() => ping(c.t.e1, OUT)));
  at('2026-03-11T12:31:00Z');
  await Promise.all([1, 2, 3].map(() => ping(c.t.e1, OUT)));
  let inc = await today11();
  assert.equal(inc.length, 1, 'exactly one incident at expiry (concurrent pings)');
  assert.equal(new Date(inc[0].exit_at).toISOString(), '2026-03-11T12:30:00.000Z');
  assert.equal(inc[0].permission_state, 'expired'); assert.equal(inc[0].outing_id, o2.id); assert.equal(inc[0].amount_egp, null, 'open: no amount yet');
  at('2026-03-11T12:50:00Z'); await ping(c.t.e1, IN);
  inc = await today11();
  assert.equal(inc[0].status, 'closed'); assert.equal(inc[0].end_reason, 'returned'); assert.equal(inc[0].minutes, 20, 'counted from the expiry, not the departure');
  assert.equal(Number(inc[0].amount_egp), 50, 'effective rule: all switches on and the 15–60 tier');
  assert.ok((await h.db.query(`SELECT returned_at FROM outing_requests WHERE id = $1`, [o2.id])).rows[0].returned_at, 'return recorded');
  // 3) the return time passed while he was inside: leaving afterwards is an ordinary unauthorized exit
  at('2026-03-11T12:55:00Z');
  const o3 = await outing('15:00'); // 13:00Z
  at('2026-03-11T13:05:00Z'); await ping(c.t.e1, OUT);
  inc = await today11();
  assert.equal(inc.length, 2); assert.equal(inc[1].permission_state, 'expired'); assert.equal(inc[1].outing_id, o3.id);
  at('2026-03-11T13:10:00Z'); await ping(c.t.e1, IN);
  assert.equal((await today11())[1].minutes, 5);
});

