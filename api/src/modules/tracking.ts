import { ok, type Module } from '../ctx.ts';
import { assignWaiting } from './lead_routing.ts';
import { one, type Q } from '../db.ts';
import { conflict, invalid, notFound } from '../http/errors.ts';
import { isUuid, num, obj } from '../http/validate.ts';
import { audit, authenticate, readableIds, requirePerm } from '../auth/context.ts';
import { local, timeToMinutes, actionTime } from '../lib/time.ts';
import { haversineM } from './attendance.ts';
import { generalManagerOf, holdersOf, notify } from './notify.ts';
import { WORK_TRACKING_SQL } from './employees.ts';
import type { PushResult } from '../lib/fcm.ts';
import { leadsSweep } from './leads.ts';
import { leadsAutoReassign } from './leads2.ts';
import { activeOuting, markReturned } from './outings.ts';

/** Who hears about an employee: HR/owner (attendance.read_all) + the employee's sales manager(s). */
async function watchersOf(q: Q, employeeId: string): Promise<string[]> {
  const all = await holdersOf(q, 'attendance.read_all', [employeeId]);
  const mgr = await q.query<{ id: string }>(`
    SELECT DISTINCT x.id FROM employees e
      LEFT JOIN teams t ON t.id = e.team_id
      JOIN employees x ON x.id IN (t.manager_id, e.sales_manager_id)
     WHERE e.id = $1 AND x.id <> $1 AND x.status = 'active'`, [employeeId]);
  return [...new Set([...all, ...mgr.rows.map((r) => r.id)])];
}

async function tellWatchers(q: Q, employeeId: string, type: string, title: string, body: string, dedupeKey: string) {
  for (const to of await watchersOf(q, employeeId)) {
    await notify(q, { to, type, title, body, entity: 'employee', entityId: employeeId, dedupeKey });
  }
}

/**
 * Who hears a confirmed unauthorized exit (besides the employee): his general manager, the administrative officer(s),
 * and those who already followed him (HR / owner / his sales manager). Resolved from the RBAC data, never by guessing:
 *  - the general manager = employees.general_manager_id; when none is set, whoever holds the «manager» (المدير) role
 *    or a position based on it
 *  - the administrative officer = the «مسؤول إداري» position (key admin_officer, or the position named so)
 * One person once (several roles → one notification; his phones each get it once: tokens are unique).
 */
export async function exitRecipients(q: Q, employeeId: string): Promise<string[]> {
  const gm = await generalManagerOf(q, employeeId);
  const roles = await q.query<{ id: string }>(`
    SELECT e.id FROM employees e JOIN roles r ON r.key = COALESCE(e.position_key, e.role_key)
     WHERE e.status = 'active' AND e.id <> $1
       AND ((r.key = 'admin_officer' OR r.name_ar = 'مسؤول إداري')
            OR ($2::uuid IS NULL AND (r.key = 'manager' OR r.base_key = 'manager')))`, [employeeId, gm]);
  return [...new Set([...(gm ? [gm] : []), ...roles.rows.map((x) => x.id), ...await watchersOf(q, employeeId)])];
}

/**
 * The employee-side conditions of the alarm (the shift, the office and the permission are checked on each ping):
 * the company follow-up is on, «تتبع أثناء العمل» is on for him, and he has «حضور وانصراف».
 */
export async function trackingEligibility(q: Q, employeeId: string): Promise<{ on: boolean; reason: string | null }> {
  const r = await one(q, `
    SELECT s.tracking_enabled AS company, ${WORK_TRACKING_SQL('e')} AS employee, NOT e.attendance_exempt AS attendance
      FROM employees e CROSS JOIN company_settings s WHERE e.id = $1`, [employeeId]);
  const reason = !r ? 'no_employee' : !r.company ? 'company_off' : !r.employee ? 'employee_off' : !r.attendance ? 'no_attendance' : null;
  return { on: reason === null, reason };
}

/** a short, location-free summary of what the pushes did (for the audit log) */
type PushSum = { fcm: { devices: number; sent: number; failed: number; removed: number }; web: { devices: number; sent: number; failed: number; removed: number }; duplicates: number; fcmOff: boolean };
const pushSum = (rs: (PushResult | null)[]) => rs.reduce<PushSum>((t, x) => {
  if (!x) { t.duplicates++; return t; }
  t.fcm.devices += x.fcm.devices; t.fcm.sent += x.fcm.sent; t.fcm.failed += x.fcm.failed; t.fcm.removed += x.fcm.removed;
  t.web.devices += x.web.devices; t.web.sent += x.web.sent; t.web.failed += x.web.failed; t.web.removed += x.web.removed;
  if (x.fcm.off) t.fcmOff = true;
  return t;
}, { fcm: { devices: 0, sent: 0, failed: 0, removed: 0 }, web: { devices: 0, sent: 0, failed: 0, removed: 0 }, duplicates: 0, fcmOff: false });

const SWEEP_EVERY_MS = 60 * 1000;

/**
 * Reminders and alerts: runs at most once a minute — called every minute by the owner's Google Apps Script
 * (POST /backup/sweep) and also triggered by normal traffic — tracking pings during shifts and managers opening boards.
 */
export async function sweep(q: Q, now: Date) {
  const claimed = await one(q, `
    UPDATE company_settings SET last_sweep_at = $1
     WHERE last_sweep_at IS NULL OR last_sweep_at < $1::timestamptz - make_interval(secs => $2)
     RETURNING checkin_reminder_minutes, tracking_enabled, tracking_stale_minutes`, [now, SWEEP_EVERY_MS / 1000]);
  if (!claimed) return;
  // abandoned staged uploads (employee never created) are discarded after a day
  await q.query(`DELETE FROM employee_documents WHERE employee_id IS NULL AND created_at < $1::timestamptz - interval '1 day'`, [now]);
  // the leads' follow-ups, leads nobody acted on, tasks — every day (holidays too)
  await leadsSweep(q, now);
  await leadsAutoReassign(q, now);
  // a new lead that found no salesman online → the first chosen one who comes online
  await assignWaiting(q, now);
  const l = local(now);
  if (await one(q, `SELECT 1 FROM holidays WHERE day = $1`, [l.date])) return;
  const rows = await q.query(`
    SELECT e.id, e.full_name, COALESCE(e.work_start, ws.start_time) AS start_time, COALESCE(e.work_end, ws.end_time) AS end_time, ws.weekend_days,
           a.id AS att_id, a.check_out_at,
           EXISTS (SELECT 1 FROM requests r WHERE r.employee_id = e.id AND r.status = 'approved'
                     AND r.type = 'full_day_absence' AND r.start_date <= $1 AND r.end_date >= $1) AS on_leave,
           EXISTS (SELECT 1 FROM attendance_breaks b WHERE b.attendance_id = a.id AND b.ended_at IS NULL) AS on_break,
           (SELECT max(ts.last_ping_at) FROM tracking_state ts WHERE ts.employee_id = e.id AND ts.work_date = $1) AS last_ping_at,
           ${WORK_TRACKING_SQL('e')} AS work_tracking
      FROM employees e
      JOIN work_schedules ws ON ws.id = COALESCE(e.schedule_id, (SELECT id FROM work_schedules WHERE is_default))
      LEFT JOIN attendance a ON a.employee_id = e.id AND a.work_date = $1
     WHERE e.status = 'active' AND NOT e.attendance_exempt AND e.joining_date <= $1`, [l.date]);
  // approved permission / visit whose return time passed: ring the employee and the approvers once
  const overdue = await q.query(`
    SELECT o.*, e.full_name FROM outing_requests o JOIN employees e ON e.id = o.employee_id
      LEFT JOIN attendance t ON t.employee_id = o.employee_id AND t.work_date = o.work_date
     WHERE (t.id IS NULL OR t.check_out_at IS NULL) AND o.work_date = $1 AND o.status = 'approved' AND o.returned_at IS NULL AND o.overdue_alerted_at IS NULL
       AND o.expected_return_at < $2 FOR UPDATE OF o`, [l.date, now]);
  for (const o of overdue.rows) {
    await q.query(`UPDATE outing_requests SET overdue_alerted_at = $2 WHERE id = $1`, [o.id, now]);
    await notify(q, { to: o.employee_id, type: 'outing_overdue', title: 'ميعاد رجوعك عدّى ⏰',
      body: 'سجّل رجوعك، أو اطلب تمديد، أو قدّم طلب جديد.', entity: 'outing_request', entityId: o.id, dedupeKey: `outing:${o.id}:overdue` });
    await tellWatchers(q, o.employee_id, 'outing_overdue_watch', `${o.full_name} لسه مرجعش`,
      `ميعاد الرجوع المعتمد عدّى.`, `outing:${o.id}:overdue_watch`);
  }

  const remind = claimed.checkin_reminder_minutes;
  for (const r of rows.rows) {
    if (r.on_leave || (r.weekend_days as number[]).includes(l.isoDow)) continue;
    const start = timeToMinutes(r.start_time), end = timeToMinutes(r.end_time);
    if (remind > 0 && !r.att_id && l.minutes >= start + remind && l.minutes < end) {
      await notify(q, { to: r.id, type: 'checkin_reminder', title: 'سجّلت حضورك النهارده؟ ⏰', body: 'لسه مسجلتش حضور.',
        dedupeKey: `checkin_reminder:${l.date}` });
      await tellWatchers(q, r.id, 'not_checked_in', `${r.full_name} لسه مسجلش حضور`, `عدّى ${remind} دقيقة على ميعاد الحضور.`,
        `not_checked_in:${r.id}:${l.date}`);
    }
    if (remind > 0 && r.att_id && !r.check_out_at && !r.on_break && l.minutes >= end + remind) {
      await notify(q, { to: r.id, type: 'checkout_reminder', title: 'متنساش تسجّل انصراف 👋', body: 'ميعاد الانصراف عدّى.',
        dedupeKey: `checkout_reminder:${l.date}` });
      await tellWatchers(q, r.id, 'not_checked_out', `${r.full_name} مسجلش انصراف`, 'ميعاد الانصراف عدّى ولسه مسجلش.',
        `not_checked_out:${r.id}:${l.date}`);
    }
    const stale = claimed.tracking_stale_minutes;
    if (claimed.tracking_enabled && r.work_tracking && stale > 0 && r.att_id && !r.check_out_at) {
      const last = r.last_ping_at ? new Date(r.last_ping_at).getTime() : null;
      const silentMin = last === null ? null : Math.floor((now.getTime() - last) / 60000);
      if (silentMin !== null && silentMin >= stale) {
        await tellWatchers(q, r.id, 'tracking_stopped', `التتبع وقف عند ${r.full_name}`,
          `آخر موقع من ${silentMin} دقيقة (قفل التطبيق أو الـ GPS أو النت).`, `tracking_stopped:${r.id}:${l.date}:${Math.floor(last! / 3_600_000)}`);
      }
    }
  }
}

export const trackingModule: Module = (r, { db, clock }) => {
  /** The app reports its position while the employee is checked in (Android keeps doing it in the background). */
  r.post('/tracking/ping', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const lat = num(b, 'lat', { min: -90, max: 90 })!;
    const lng = num(b, 'lng', { min: -180, max: 180 })!;
    const acc = num(b, 'accuracyM', { optional: true, min: 0, max: 100000 }) ?? null;
    const { at: now, offline } = actionTime(b, clock()); const l = local(now);
    const cfg = await one(db, `SELECT tracking_enabled, tracking_interval_minutes, away_margin_m FROM company_settings`);
    // the company follow-up + «تتبع أثناء العمل» + «حضور وانصراف»: otherwise nothing is followed (the app stops)
    const elig = await trackingEligibility(db, a.id);
    if (!elig.on) return ok({ tracking: false, reason: elig.reason });
    // the phone rang by itself (it saw the office left with no permission) — logged, no location kept
    const localAlarm = b.localAlarm === true;
    const att = await one(db, `SELECT id, check_out_at FROM attendance WHERE employee_id = $1 AND work_date = $2`, [a.id, l.date]);
    if (!att || att.check_out_at) throw conflict('Tracking runs only between check-in and check-out');
    const locs = (await db.query(`SELECT * FROM work_locations WHERE active`)).rows;
    const outside = locs.length ? Math.min(...locs.map((x) => haversineM(lat, lng, x.lat, x.lng) - x.radius_m)) : null;
    // poor GPS fixes never count as "left the office"
    const inside = outside === null ? null : (acc !== null && acc > 200) ? null : outside <= cfg.away_margin_m;
    // every phone of the account is followed on its own: any phone that leaves the office raises the alert
    const dv = await one(db, `
      SELECT COALESCE(s.device_id, '') AS key, d.label,
             (SELECT count(*)::int FROM employee_devices x WHERE x.employee_id = s.employee_id AND x.status = 'approved') AS phones
        FROM sessions s LEFT JOIN employee_devices d ON d.employee_id = s.employee_id AND d.device_id = s.device_id
       WHERE s.id = $1`, [a.sessionId]);
    const deviceKey: string = dv?.key ?? '';
    const deviceLabel: string | null = dv?.label ?? null;
    const onPhone = (dv?.phones ?? 0) > 1 && deviceLabel ? ` (من جهاز: ${deviceLabel})` : '';
    await db.tx(async (q) => {
      const prev = await one(q, `SELECT * FROM tracking_state WHERE employee_id = $1 AND device_key = $2 FOR UPDATE`, [a.id, deviceKey]);
      if (offline && prev && new Date(prev.last_ping_at) > now) {
        // a point recorded offline that is older than what we already know: history only, no alerts
        await q.query(`INSERT INTO tracking_pings (employee_id, at, lat, lng, accuracy_m, inside, offline, device_key) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
          [a.id, now, lat, lng, acc, inside, offline, deviceKey]);
        return;
      }
      const sameDay = prev && prev.work_date === l.date;
      let awaySince: Date | null = sameDay && prev.away_since ? new Date(prev.away_since) : null;
      let awayMinutes = sameDay ? prev.away_minutes : 0;
      const wasInside = sameDay ? prev.inside : true;
      const outing = await activeOuting(q, a.id, l.date, now);
      const authorized = !!outing && new Date(outing.expected_return_at) > now;
      const hhmm = (d: Date) => { const m = local(d).minutes; return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`; };
      if (inside === false && wasInside !== false) {
        awaySince = now;
        // stages (location-free): departure detected → eligibility verified (above) → permission checked
        const stages = { departure: true, eligible: true, permission: authorized ? 'approved' : outing ? 'expired' : 'none', localAlarm, device: deviceLabel };
        if (authorized) {
          // approved permission / visit: expected exit, no violation
          await audit(q, a.id, 'tracking.authorized_exit', 'outing_request', outing.id, undefined, { at: now, ...stages });
        } else {
          const where = `على بُعد ${Math.round(outside!)} متر من المكتب — الساعة ${hhmm(now)}`;
          const why = outing ? 'عدّى ميعاد الرجوع المسموح' : 'من غير إذن أو زيارة معتمدة';
          await audit(q, a.id, 'tracking.unauthorized_exit', 'employee', a.id, undefined, { at: now, lat, lng, acc, outsideM: Math.round(outside!), ...stages });
          // the alarm: the employee (all his phones) + his general manager + the administrative officer (+ his watchers)
          const event = `${a.id}:${deviceKey}:${now.getTime()}`;
          const to = await exitRecipients(q, a.id);
          const sent: (PushResult | null)[] = [];
          for (const r of to) {
            sent.push(await notify(q, { to: r, type: 'unauthorized_exit', title: `خروج غير مصرح: ${a.fullName}${onPhone}`, body: `${why}. ${where}.`,
              entity: 'employee', entityId: a.id, dedupeKey: `unauthorized_exit:${event}` }));
          }
          const self = await notify(q, { to: a.id, type: 'unauthorized_exit_self', title: 'إنت برة المكتب من غير إذن معتمد',
            body: `لو خارج لشغل أو مشوار اطلب «زيارة» أو «إذن ساعات» من التطبيق.${onPhone}`, dedupeKey: `unauthorized_exit_self:${event}` });
          // dispatched → what each push service said (accepted ≠ shown ≠ heard: those happen on the phone)
          await audit(q, a.id, 'tracking.alert_dispatch', 'employee', a.id, undefined,
            { event, recipients: to.length, employee: pushSum([self]), others: pushSum(sent) });
        }
      } else if (inside === true && wasInside === false && awaySince) {
        const mins = Math.max(0, Math.round((now.getTime() - awaySince.getTime()) / 60000));
        awayMinutes += mins; awaySince = null;
        await tellWatchers(q, a.id, 'back_in_office', `${a.fullName} رجع المكتب${onPhone}`, `كان برة ${mins} دقيقة.`,
          `back_in_office:${a.id}:${deviceKey}:${now.getTime()}`);
      }
      // back inside while out on a permission / visit → it is closed automatically — unless another of his
      // phones is still outside right now (a tablet left at the desk must not end a visit)
      if (inside === true && outing) {
        const otherOut = await one(q, `SELECT 1 FROM tracking_state WHERE employee_id = $1 AND device_key <> $2 AND work_date = $3
                                         AND inside = false AND last_ping_at > $4::timestamptz - interval '15 minutes'`, [a.id, deviceKey, l.date, now]);
        if (!otherOut) await markReturned(q, outing, now, null, 'geofence');
      }
      await q.query(`
        INSERT INTO tracking_state (employee_id, work_date, last_ping_at, lat, lng, accuracy_m, inside, distance_m, away_since, away_minutes, device_key, device_label)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
        ON CONFLICT (employee_id, device_key) DO UPDATE SET work_date = EXCLUDED.work_date, last_ping_at = EXCLUDED.last_ping_at, device_label = EXCLUDED.device_label,
          lat = EXCLUDED.lat, lng = EXCLUDED.lng, accuracy_m = EXCLUDED.accuracy_m,
          inside = COALESCE(EXCLUDED.inside, tracking_state.inside), distance_m = EXCLUDED.distance_m,
          away_since = EXCLUDED.away_since, away_minutes = EXCLUDED.away_minutes`,
        [a.id, l.date, now, lat, lng, acc, inside ?? (sameDay ? prev.inside : null), outside === null ? null : Math.max(0, Math.round(outside)), awaySince, awayMinutes, deviceKey, deviceLabel]);
      await q.query(`INSERT INTO tracking_pings (employee_id, at, lat, lng, accuracy_m, inside, offline, device_key) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`, [a.id, now, lat, lng, acc, inside, offline, deviceKey]);
      await q.query(`DELETE FROM tracking_pings WHERE at < $1::timestamptz - interval '14 days'`, [now]);
    });
    // a ring the phone did by itself while it was already known outside (e.g. its own check before the ping)
    if (localAlarm) await audit(db, a.id, 'tracking.local_alarm', 'employee', a.id, undefined, { at: now, device: deviceLabel, inside });
    await sweep(db, clock());
    return ok({ tracking: true, inside, intervalMinutes: cfg.tracking_interval_minutes });
  });

  /** Tracking settings the app needs (any signed-in user). */
  r.get('/tracking/config', async (req) => {
    const a = await authenticate(db, req);
    const s = await one(db, `SELECT tracking_enabled, tracking_interval_minutes, away_margin_m FROM company_settings`);
    // this person: the company follow-up + his «تتبع أثناء العمل» + «حضور وانصراف» (reason = why not, for diagnostics)
    const elig = await trackingEligibility(db, a.id);
    // office areas so the phone can ring by itself when it leaves them, even with no internet
    const locs = (await db.query(`SELECT lat, lng, radius_m FROM work_locations WHERE active`)).rows;
    return ok({ enabled: elig.on, reason: elig.reason, intervalMinutes: s.tracking_interval_minutes,
      awayMarginM: s.away_margin_m ?? 0, offices: locs.map((l) => ({ lat: l.lat, lng: l.lng, radiusM: l.radius_m })) });
  });

  /** In-shift follow-up board for HR / owner / sales managers (their team only). */
  r.get('/tracking/live', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'attendance.read_all', 'attendance.read_team');
    const now = clock(); const l = local(now);
    await sweep(db, now);
    const ids = await readableIds(db, a, 'attendance');
    const cfg = await one(db, `SELECT tracking_enabled, tracking_stale_minutes FROM company_settings`);
    // one line per employee: the phone that is outside wins (any phone out = he is out); "last seen" = his latest phone
    const rows = await db.query(`
      SELECT e.id, e.full_name, e.code, (e.photo IS NOT NULL) AS has_photo, t.name AS team_name, a.check_in_at, a.check_out_at,
             ts.lat, ts.lng, ts.accuracy_m, ts.inside, ts.distance_m, ts.away_since, ts.away_minutes, ts.device_label,
             (SELECT max(z.last_ping_at) FROM tracking_state z WHERE z.employee_id = e.id AND z.work_date = $1) AS last_ping_at,
             (SELECT COALESCE(json_agg(json_build_object('label', z.device_label, 'inside', z.inside, 'distanceM', z.distance_m,
                       'lastPingAt', z.last_ping_at) ORDER BY z.last_ping_at DESC), '[]')
                FROM tracking_state z WHERE z.employee_id = e.id AND z.work_date = $1) AS devices
        FROM employees e
        LEFT JOIN teams t ON t.id = e.team_id
        JOIN attendance a ON a.employee_id = e.id AND a.work_date = $1
        LEFT JOIN LATERAL (SELECT * FROM tracking_state z WHERE z.employee_id = e.id AND z.work_date = $1
                            ORDER BY (z.inside IS FALSE) DESC, z.last_ping_at DESC LIMIT 1) ts ON true
       WHERE e.status = 'active' AND e.id <> $3 AND ($2::uuid[] IS NULL OR e.id = ANY($2::uuid[]))
       ORDER BY ts.inside NULLS FIRST, e.full_name`, [l.date, ids, a.id]);
    const live = rows.rows.map((x) => {
      const silent = x.last_ping_at ? Math.floor((now.getTime() - new Date(x.last_ping_at).getTime()) / 60000) : null;
      const awayNow = x.away_since ? Math.round((now.getTime() - new Date(x.away_since).getTime()) / 60000) : 0;
      return {
        devices: x.devices, outDevice: x.inside === false ? x.device_label : null,
        employeeId: x.id, fullName: x.full_name, code: x.code, hasPhoto: x.has_photo, teamName: x.team_name,
        checkIn: x.check_in_at, checkOut: x.check_out_at, lastPingAt: x.last_ping_at, silentMinutes: silent,
        stopped: !x.check_out_at && cfg.tracking_stale_minutes > 0 && (silent === null || silent >= cfg.tracking_stale_minutes),
        inside: x.inside, distanceM: x.distance_m, awayMinutesToday: x.away_minutes + awayNow,
        position: x.lat === null ? null : { lat: x.lat, lng: x.lng, accuracyM: x.accuracy_m },
      };
    });
    return ok({ date: l.date, trackingEnabled: cfg.tracking_enabled, live });
  });

  /** Today's path for one employee (privacy: only people who may read that employee's attendance). */
  r.get('/tracking/employee/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const ids = await readableIds(db, a, 'attendance');
    if (ids && !ids.includes(req.params.id)) throw notFound('Employee not found');
    const day = req.query.get('date') ?? local(clock()).date;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw invalid('date must be YYYY-MM-DD');
    const pts = await db.query(`
      SELECT at, lat, lng, accuracy_m, inside FROM tracking_pings
       WHERE employee_id = $1 AND (at AT TIME ZONE 'Africa/Cairo')::date = $2 ORDER BY at`, [req.params.id, day]);
    return ok({ date: day, points: pts.rows });
  });
};

