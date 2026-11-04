import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { conflict, invalid, notFound } from '../http/errors.ts';
import { isUuid, num, obj } from '../http/validate.ts';
import { authenticate, readableIds, requirePerm } from '../auth/context.ts';
import { local, timeToMinutes } from '../lib/time.ts';
import { haversineM } from './attendance.ts';
import { holdersOf, notify } from './notify.ts';

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

const SWEEP_EVERY_MS = 5 * 60 * 1000;

/**
 * Reminders and alerts without a scheduler (free hosting has none): this runs at most every
 * 5 minutes, triggered by normal traffic — tracking pings during shifts and managers opening boards.
 */
export async function sweep(q: Q, now: Date) {
  const claimed = await one(q, `
    UPDATE company_settings SET last_sweep_at = $1
     WHERE last_sweep_at IS NULL OR last_sweep_at < $1::timestamptz - make_interval(secs => $2)
     RETURNING checkin_reminder_minutes, tracking_enabled, tracking_stale_minutes`, [now, SWEEP_EVERY_MS / 1000]);
  if (!claimed) return;
  const l = local(now);
  if (await one(q, `SELECT 1 FROM holidays WHERE day = $1`, [l.date])) return;
  const rows = await q.query(`
    SELECT e.id, e.full_name, ws.start_time, ws.end_time, ws.weekend_days,
           a.id AS att_id, a.check_out_at,
           EXISTS (SELECT 1 FROM requests r WHERE r.employee_id = e.id AND r.status = 'approved'
                     AND r.type = 'full_day_absence' AND r.start_date <= $1 AND r.end_date >= $1) AS on_leave,
           EXISTS (SELECT 1 FROM attendance_breaks b WHERE b.attendance_id = a.id AND b.ended_at IS NULL) AS on_break,
           ts.last_ping_at
      FROM employees e
      JOIN work_schedules ws ON ws.id = COALESCE(e.schedule_id, (SELECT id FROM work_schedules WHERE is_default))
      LEFT JOIN attendance a ON a.employee_id = e.id AND a.work_date = $1
      LEFT JOIN tracking_state ts ON ts.employee_id = e.id AND ts.work_date = $1
     WHERE e.status = 'active' AND e.role_key <> 'owner' AND e.joining_date <= $1`, [l.date]);
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
    if (claimed.tracking_enabled && stale > 0 && r.att_id && !r.check_out_at) {
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
    const now = clock(); const l = local(now);
    const cfg = await one(db, `SELECT tracking_enabled, tracking_interval_minutes, away_margin_m FROM company_settings`);
    if (!cfg.tracking_enabled) return ok({ tracking: false });
    const att = await one(db, `SELECT id, check_out_at FROM attendance WHERE employee_id = $1 AND work_date = $2`, [a.id, l.date]);
    if (!att || att.check_out_at) throw conflict('Tracking runs only between check-in and check-out');
    const locs = (await db.query(`SELECT * FROM work_locations WHERE active`)).rows;
    const outside = locs.length ? Math.min(...locs.map((x) => haversineM(lat, lng, x.lat, x.lng) - x.radius_m)) : null;
    // poor GPS fixes never count as "left the office"
    const inside = outside === null ? null : (acc !== null && acc > 200) ? null : outside <= cfg.away_margin_m;
    await db.tx(async (q) => {
      const prev = await one(q, `SELECT * FROM tracking_state WHERE employee_id = $1 FOR UPDATE`, [a.id]);
      const sameDay = prev && prev.work_date === l.date;
      let awaySince: Date | null = sameDay && prev.away_since ? new Date(prev.away_since) : null;
      let awayMinutes = sameDay ? prev.away_minutes : 0;
      const wasInside = sameDay ? prev.inside : true;
      if (inside === false && wasInside !== false) {
        awaySince = now;
        await tellWatchers(q, a.id, 'left_office', `${a.fullName} خرج برة المكتب`, `على بُعد ${Math.round(outside!)} متر من المكتب.`,
          `left_office:${a.id}:${now.getTime()}`);
      } else if (inside === true && wasInside === false && awaySince) {
        const mins = Math.max(0, Math.round((now.getTime() - awaySince.getTime()) / 60000));
        awayMinutes += mins; awaySince = null;
        await tellWatchers(q, a.id, 'back_in_office', `${a.fullName} رجع المكتب`, `كان برة ${mins} دقيقة.`,
          `back_in_office:${a.id}:${now.getTime()}`);
      }
      await q.query(`
        INSERT INTO tracking_state (employee_id, work_date, last_ping_at, lat, lng, accuracy_m, inside, distance_m, away_since, away_minutes)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
        ON CONFLICT (employee_id) DO UPDATE SET work_date = EXCLUDED.work_date, last_ping_at = EXCLUDED.last_ping_at,
          lat = EXCLUDED.lat, lng = EXCLUDED.lng, accuracy_m = EXCLUDED.accuracy_m,
          inside = COALESCE(EXCLUDED.inside, tracking_state.inside), distance_m = EXCLUDED.distance_m,
          away_since = EXCLUDED.away_since, away_minutes = EXCLUDED.away_minutes`,
        [a.id, l.date, now, lat, lng, acc, inside ?? (sameDay ? prev.inside : null), outside === null ? null : Math.max(0, Math.round(outside)), awaySince, awayMinutes]);
      await q.query(`INSERT INTO tracking_pings (employee_id, at, lat, lng, accuracy_m, inside) VALUES ($1,$2,$3,$4,$5,$6)`, [a.id, now, lat, lng, acc, inside]);
      await q.query(`DELETE FROM tracking_pings WHERE at < $1::timestamptz - interval '14 days'`, [now]);
    });
    await sweep(db, now);
    return ok({ tracking: true, inside, intervalMinutes: cfg.tracking_interval_minutes });
  });

  /** Tracking settings the app needs (any signed-in user). */
  r.get('/tracking/config', async (req) => {
    await authenticate(db, req);
    const s = await one(db, `SELECT tracking_enabled, tracking_interval_minutes FROM company_settings`);
    return ok({ enabled: s.tracking_enabled, intervalMinutes: s.tracking_interval_minutes });
  });

  /** In-shift follow-up board for HR / owner / sales managers (their team only). */
  r.get('/tracking/live', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'attendance.read_all', 'attendance.read_team');
    const now = clock(); const l = local(now);
    await sweep(db, now);
    const ids = await readableIds(db, a, 'attendance');
    const cfg = await one(db, `SELECT tracking_enabled, tracking_stale_minutes FROM company_settings`);
    const rows = await db.query(`
      SELECT e.id, e.full_name, e.code, (e.photo IS NOT NULL) AS has_photo, t.name AS team_name, a.check_in_at, a.check_out_at,
             ts.last_ping_at, ts.lat, ts.lng, ts.accuracy_m, ts.inside, ts.distance_m, ts.away_since, ts.away_minutes
        FROM employees e
        LEFT JOIN teams t ON t.id = e.team_id
        JOIN attendance a ON a.employee_id = e.id AND a.work_date = $1
        LEFT JOIN tracking_state ts ON ts.employee_id = e.id AND ts.work_date = $1
       WHERE e.status = 'active' AND e.id <> $3 AND ($2::uuid[] IS NULL OR e.id = ANY($2::uuid[]))
       ORDER BY ts.inside NULLS FIRST, e.full_name`, [l.date, ids, a.id]);
    const live = rows.rows.map((x) => {
      const silent = x.last_ping_at ? Math.floor((now.getTime() - new Date(x.last_ping_at).getTime()) / 60000) : null;
      const awayNow = x.away_since ? Math.round((now.getTime() - new Date(x.away_since).getTime()) / 60000) : 0;
      return {
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

