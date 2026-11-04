import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound, unprocessable } from '../http/errors.ts';
import { date, monthParam, num, obj, reqStr, time, uuid, isUuid } from '../http/validate.ts';
import { assertCanRead, audit, authenticate, has, readableIds, requirePerm } from '../auth/context.ts';
import { cairoInstant, local } from '../lib/time.ts';
import { computeMonth, metrics } from './attendance-calc.ts';
import { notify } from './notify.ts';

export function haversineM(lat1: number, lng1: number, lat2: number, lng2: number) {
  const R = 6371000, rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad, dLng = (lng2 - lng1) * rad;
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}

const MAX_ACCURACY_M = 200;

async function geofence(q: Q, body: Record<string, unknown>) {
  const s = await one(q, `SELECT gps_required FROM company_settings`);
  const lat = num(body, 'lat', { optional: true, min: -90, max: 90 });
  const lng = num(body, 'lng', { optional: true, min: -180, max: 180 });
  const acc = num(body, 'accuracyM', { optional: true, min: 0, max: 100000 });
  if (!s.gps_required) return { status: 'not_required' as const, lat: lat ?? null, lng: lng ?? null, acc: acc ?? null };
  const locs = (await q.query(`SELECT * FROM work_locations WHERE active`)).rows;
  if (!locs.length) throw unprocessable('GPS attendance is enabled but no office location is configured yet');
  if (lat === undefined || lng === undefined || acc === undefined) throw invalid('Location is required to record attendance', { field: 'lat' });
  if (acc > MAX_ACCURACY_M) throw unprocessable('Location signal is too weak. Move near a window and try again');
  const nearest = Math.min(...locs.map((l) => haversineM(lat, lng, l.lat, l.lng) - l.radius_m));
  if (nearest > 0) throw new AppError('unprocessable', 'You are outside the office area', { distanceOutsideM: Math.round(nearest) });
  return { status: 'inside' as const, lat, lng, acc };
}

async function scheduleFor(q: Q, employeeId: string) {
  return one(q, `
    SELECT ws.* FROM employees e
      JOIN work_schedules ws ON ws.id = COALESCE(e.schedule_id, (SELECT id FROM work_schedules WHERE is_default))
     WHERE e.id = $1`, [employeeId]);
}

/** Apply an approved correction; keeps originals forever. Used by HR direct edits and approved requests. */
export async function applyCorrection(q: Q, p: {
  employeeId: string; workDate: string; inHHMM: string; outHHMM: string | null; reason: string;
  requestedBy: string; approvedBy: string; requestId?: string;
}) {
  if (p.approvedBy === p.employeeId) throw forbidden('Nobody can correct their own attendance');
  const inAt = cairoInstant(p.workDate, p.inHHMM);
  const outAt = p.outHHMM ? cairoInstant(p.workDate, p.outHHMM) : null;
  if (outAt && outAt <= inAt) throw invalid('Check-out must be after check-in');
  const existing = await one(q, `SELECT * FROM attendance WHERE employee_id = $1 AND work_date = $2 FOR UPDATE`, [p.employeeId, p.workDate]);
  let attendanceId: string;
  if (existing) {
    await q.query(`UPDATE attendance SET check_in_at = $2, check_out_at = $3, corrected = true,
                     original_check_out_at = COALESCE(original_check_out_at, check_out_at) WHERE id = $1`,
      [existing.id, inAt, outAt]);
    attendanceId = existing.id;
  } else {
    const s = await scheduleFor(q, p.employeeId);
    const row = await one(q, `
      INSERT INTO attendance (employee_id, work_date, schedule_start, schedule_end, late_grace_minutes, early_grace_minutes,
        overtime_enabled, overtime_min_minutes, check_in_at, check_out_at, original_check_in_at, corrected, source)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$9,true,'correction') RETURNING id`,
      [p.employeeId, p.workDate, s.start_time, s.end_time, s.late_grace_minutes, s.early_grace_minutes,
       s.overtime_enabled, s.overtime_min_minutes, inAt, outAt]);
    attendanceId = row.id;
  }
  await q.query(`INSERT INTO attendance_corrections (attendance_id, employee_id, work_date, original_in, original_out,
                   corrected_in, corrected_out, reason, requested_by, approved_by, request_id)
                 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
    [attendanceId, p.employeeId, p.workDate, existing?.check_in_at ?? null, existing?.check_out_at ?? null,
     inAt, outAt, p.reason, p.requestedBy, p.approvedBy, p.requestId ?? null]);
  await audit(q, p.approvedBy, 'attendance.correct', 'attendance', attendanceId,
    existing ? { check_in_at: existing.check_in_at, check_out_at: existing.check_out_at } : null,
    { check_in_at: inAt, check_out_at: outAt, reason: p.reason, requestId: p.requestId ?? null });
  await notify(q, { to: p.employeeId, type: 'attendance_corrected', title: 'تم تعديل سجل حضورك',
    body: `${p.workDate}: ${p.reason}`, entity: 'attendance', entityId: attendanceId,
    dedupeKey: `att-corr:${attendanceId}:${inAt.toISOString()}:${outAt?.toISOString() ?? '-'}` });
  return attendanceId;
}

function shape(a: any, today: string) {
  return { id: a.id, workDate: a.work_date, checkIn: a.check_in_at, checkOut: a.check_out_at,
    corrected: a.corrected, source: a.source, geofence: a.geofence_status,
    schedule: { start: a.schedule_start, end: a.schedule_end }, ...metrics(a, today) };
}

const SELFIE_MIME = new Set(['image/jpeg', 'image/png', 'image/webp']);
function selfieFrom(b: Record<string, unknown>): { buf: Buffer; mime: string } | null {
  if (b.selfie === undefined || b.selfie === null) return null;
  if (typeof b.selfie !== 'string' || !/^[A-Za-z0-9+/=\s]+$/.test(b.selfie)) throw invalid('selfie must be base64', { field: 'selfie' });
  const mime = typeof b.selfieMime === 'string' ? b.selfieMime : 'image/jpeg';
  if (!SELFIE_MIME.has(mime)) throw invalid('selfie must be a JPEG, PNG or WebP image', { field: 'selfieMime' });
  const buf = Buffer.from(b.selfie, 'base64');
  if (!buf.length) throw invalid('selfie is empty', { field: 'selfie' });
  if (buf.length > 400_000) throw invalid('selfie is too large (max 400 KB)', { field: 'selfie' });
  return { buf, mime };
}

function breakShape(b: any, now: Date) {
  const end = b.ended_at ? new Date(b.ended_at) : now;
  const minutes = Math.max(0, Math.floor((end.getTime() - new Date(b.started_at).getTime()) / 60000));
  return { start: b.started_at, end: b.ended_at, minutes, allowedMinutes: b.allowed_minutes,
    onBreak: !b.ended_at, exceeded: minutes > b.allowed_minutes };
}

export const attendanceModule: Module = (r, { db, clock }) => {
  r.post('/attendance/check-in', async (req) => {
    const a = await authenticate(db, req);
    const now = clock(); const l = local(now);
    const b = obj(req.body ?? {});
    const row = await db.tx(async (q) => {
      // serialize per employee so two taps cannot both pass the duplicate check
      await q.query(`SELECT 1 FROM employees WHERE id = $1 FOR UPDATE`, [a.id]);
      const dup = await one(q, `SELECT id FROM attendance WHERE employee_id = $1 AND work_date = $2`, [a.id, l.date]);
      if (dup) throw conflict('You already checked in today');
      const g = await geofence(q, b);
      const s = await scheduleFor(q, a.id);
      const cfg = await one(q, `SELECT selfie_required, selfie_retention_days FROM company_settings`);
      const selfie = selfieFrom(b);
      if (cfg.selfie_required && !selfie) throw new AppError('unprocessable', 'A selfie is required to check in', { reason: 'selfie_required' });
      const inserted = await one(q, `
        INSERT INTO attendance (employee_id, work_date, schedule_start, schedule_end, late_grace_minutes, early_grace_minutes,
          overtime_enabled, overtime_min_minutes, check_in_at, check_in_lat, check_in_lng, check_in_accuracy_m,
          geofence_status, original_check_in_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$9) RETURNING *`,
        [a.id, l.date, s.start_time, s.end_time, s.late_grace_minutes, s.early_grace_minutes, s.overtime_enabled,
         s.overtime_min_minutes, now, g.lat, g.lng, g.acc, g.status]);
      if (selfie) {
        await q.query(`INSERT INTO attendance_selfies (attendance_id, employee_id, image, mime, taken_at) VALUES ($1,$2,$3,$4,$5)`,
          [inserted.id, a.id, selfie.buf, selfie.mime, now]);
      }
      // retention: old selfies are removed as part of normal use (no scheduler needed on the free plan)
      await q.query(`DELETE FROM attendance_selfies WHERE taken_at < $1::timestamptz - make_interval(days => $2)`, [now, cfg.selfie_retention_days]);
      await audit(q, a.id, 'attendance.check_in', 'attendance', inserted.id, undefined, { at: now, geofence: g.status, selfie: !!selfie });
      return inserted;
    });
    return ok({ attendance: shape(row, l.date) }, 201);
  });

  r.post('/attendance/check-out', async (req) => {
    const a = await authenticate(db, req);
    const now = clock(); const l = local(now);
    const b = obj(req.body ?? {});
    const row = await db.tx(async (q) => {
      const open = await one(q, `SELECT * FROM attendance WHERE employee_id = $1 AND work_date = $2 FOR UPDATE`, [a.id, l.date]);
      if (!open) throw conflict('You must check in first');
      if (open.check_out_at) throw conflict('You already checked out today');
      const onBreak = await one(q, `SELECT 1 FROM attendance_breaks WHERE attendance_id = $1 AND ended_at IS NULL`, [open.id]);
      if (onBreak) throw conflict('End your break before checking out');
      if (now <= new Date(open.check_in_at)) throw conflict('Check-out must be after check-in');
      const g = await geofence(q, b);
      const updated = await one(q, `UPDATE attendance SET check_out_at = $2, original_check_out_at = $2,
          check_out_lat = $3, check_out_lng = $4, check_out_accuracy_m = $5 WHERE id = $1 RETURNING *`,
        [open.id, now, g.lat, g.lng, g.acc]);
      await audit(q, a.id, 'attendance.check_out', 'attendance', open.id, undefined, { at: now });
      return updated;
    });
    return ok({ attendance: shape(row, l.date) });
  });

  r.post('/attendance/break-start', async (req) => {
    const a = await authenticate(db, req);
    const now = clock(); const l = local(now);
    const br = await db.tx(async (q) => {
      const att = await one(q, `SELECT * FROM attendance WHERE employee_id = $1 AND work_date = $2 FOR UPDATE`, [a.id, l.date]);
      if (!att) throw conflict('You must check in first');
      if (att.check_out_at) throw conflict('Your work day has ended');
      const prev = await one(q, `SELECT id FROM attendance_breaks WHERE attendance_id = $1`, [att.id]);
      if (prev) throw conflict('You already took your break today');
      const allowed = (await one(q, `SELECT break_minutes FROM company_settings`)).break_minutes;
      const row = await one(q, `INSERT INTO attendance_breaks (attendance_id, employee_id, started_at, allowed_minutes)
                                VALUES ($1,$2,$3,$4) RETURNING *`, [att.id, a.id, now, allowed]);
      await audit(q, a.id, 'attendance.break_start', 'attendance', att.id, undefined, { at: now });
      return row;
    });
    return ok({ break: breakShape(br, now) }, 201);
  });

  r.post('/attendance/break-end', async (req) => {
    const a = await authenticate(db, req);
    const now = clock(); const l = local(now);
    const br = await db.tx(async (q) => {
      const open = await one(q, `SELECT b.* FROM attendance_breaks b JOIN attendance t ON t.id = b.attendance_id
                                  WHERE t.employee_id = $1 AND t.work_date = $2 FOR UPDATE OF b`, [a.id, l.date]);
      if (!open) throw conflict('You have not started a break');
      if (open.ended_at) throw conflict('Your break has already ended');
      const row = await one(q, `UPDATE attendance_breaks SET ended_at = $2 WHERE id = $1 RETURNING *`, [open.id, now]);
      await audit(q, a.id, 'attendance.break_end', 'attendance', open.attendance_id, undefined, { at: now });
      return row;
    });
    return ok({ break: breakShape(br, now) });
  });

  r.get('/attendance/today', async (req) => {
    const a = await authenticate(db, req);
    const l = local(clock());
    const row = await one(db, `SELECT * FROM attendance WHERE employee_id = $1 AND work_date = $2`, [a.id, l.date]);
    const s = await scheduleFor(db, a.id);
    const holiday = await one(db, `SELECT name FROM holidays WHERE day = $1`, [l.date]);
    const settings = await one(db, `SELECT gps_required, break_minutes, selfie_required FROM company_settings`);
    const br = row ? await one(db, `SELECT * FROM attendance_breaks WHERE attendance_id = $1`, [row.id]) : undefined;
    return ok({ date: l.date, attendance: row ? shape(row, l.date) : null,
      break: br ? breakShape(br, clock()) : null, breakAllowedMinutes: settings.break_minutes,
      schedule: { start: s.start_time, end: s.end_time, lateGraceMinutes: s.late_grace_minutes, weekendDays: s.weekend_days },
      isWeekend: s.weekend_days.includes(l.isoDow), holiday: holiday?.name ?? null, gpsRequired: settings.gps_required,
      selfieRequired: settings.selfie_required });
  });

  /** Today's board for managers/HR/owner. */
  r.get('/attendance/board', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'attendance.read_all', 'attendance.read_team');
    const ids = await readableIds(db, a, 'attendance');
    const l = local(clock());
    const rows = await db.query(`
      SELECT at.*, e.id AS employee_id, e.full_name, e.code, e.job_title, t.name AS team_name
        FROM employees e LEFT JOIN teams t ON t.id = e.team_id
        LEFT JOIN attendance at ON at.employee_id = e.id AND at.work_date = $1
       WHERE e.status = 'active' AND ($2::uuid[] IS NULL OR e.id = ANY($2::uuid[]))
       ORDER BY e.full_name`, [l.date, ids]);
    const brs = await db.query(`SELECT b.* FROM attendance_breaks b JOIN attendance t ON t.id = b.attendance_id WHERE t.work_date = $1`, [l.date]);
    const brBy = new Map(brs.rows.map((b) => [b.attendance_id, b]));
    const board = rows.rows.map((x) => ({
      employeeId: x.employee_id, fullName: x.full_name, code: x.code, jobTitle: x.job_title, teamName: x.team_name,
      attendance: x.id ? shape(x, l.date) : null,
      break: x.id && brBy.has(x.id) ? breakShape(brBy.get(x.id), clock()) : null,
    }));
    return ok({ date: l.date, board });
  });

  r.get('/attendance/:id/selfie', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const row = await one(db, `SELECT employee_id, image, mime FROM attendance_selfies WHERE attendance_id = $1`, [req.params.id]);
    if (!row) throw notFound('No selfie (or it was deleted after the retention period)');
    if (row.employee_id !== a.id) await assertCanRead(db, a, row.employee_id, 'attendance');
    return { binary: row.image, contentType: row.mime };
  });

  /** Day-by-day detail for a date range (original JPH daily report): times, GPS points, break, selfie flag. */
  r.get('/attendance/range', async (req) => {
    const a = await authenticate(db, req);
    const employeeId = req.query.get('employeeId') ?? a.id;
    if (!isUuid(employeeId)) throw notFound();
    await assertCanRead(db, a, employeeId, 'attendance');
    const from = req.query.get('from') ?? '', to = req.query.get('to') ?? '';
    if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to) || to < from) throw invalid('from/to must be YYYY-MM-DD');
    const today = local(clock()).date;
    const rows = await db.query(`
      SELECT a.*, b.started_at AS break_start, b.ended_at AS break_end,
             EXISTS (SELECT 1 FROM attendance_selfies s WHERE s.attendance_id = a.id) AS has_selfie
        FROM attendance a LEFT JOIN attendance_breaks b ON b.attendance_id = a.id
       WHERE a.employee_id = $1 AND a.work_date BETWEEN $2 AND $3 ORDER BY a.work_date DESC LIMIT 400`, [employeeId, from, to]);
    return ok({ days: rows.rows.map((x) => ({
      ...shape(x, today), checkInLat: x.check_in_lat, checkInLng: x.check_in_lng, checkOutLat: x.check_out_lat, checkOutLng: x.check_out_lng,
      breakStart: x.break_start, breakEnd: x.break_end, hasSelfie: x.has_selfie,
    })) });
  });

  r.get('/attendance', async (req) => {
    const a = await authenticate(db, req);
    const employeeId = req.query.get('employeeId') ?? a.id;
    if (!isUuid(employeeId)) throw notFound();
    await assertCanRead(db, a, employeeId, 'attendance');
    const period = monthParam(req.query.get('month'));
    const today = local(clock()).date;
    return ok(await computeMonth(db, employeeId, period, today));
  });

  r.post('/attendance/corrections', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'attendance.correct');
    const b = obj(req.body);
    const employeeId = uuid(b, 'employeeId')!;
    if (employeeId === a.id) throw forbidden('Nobody can correct their own attendance');
    const workDate = date(b, 'workDate')!;
    if (workDate > local(clock()).date) throw invalid('Cannot correct a future day', { field: 'workDate' });
    const emp = await one(db, `SELECT id FROM employees WHERE id = $1`, [employeeId]);
    if (!emp) throw notFound('Employee not found');
    const id = await db.tx((q) => applyCorrection(q, {
      employeeId, workDate, inHHMM: time(b, 'checkIn')!, outHHMM: time(b, 'checkOut', true) ?? null,
      reason: reqStr(b, 'reason', { min: 3, max: 500 }), requestedBy: a.id, approvedBy: a.id,
    }));
    return ok({ attendanceId: id }, 201);
  });

  r.get('/attendance/:id/corrections', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const att = await one(db, `SELECT employee_id FROM attendance WHERE id = $1`, [req.params.id]);
    if (!att) throw notFound();
    await assertCanRead(db, a, att.employee_id, 'attendance');
    const rows = await db.query(`
      SELECT c.*, rq.full_name AS requested_by_name, ap.full_name AS approved_by_name
        FROM attendance_corrections c
        JOIN employees rq ON rq.id = c.requested_by JOIN employees ap ON ap.id = c.approved_by
       WHERE c.attendance_id = $1 ORDER BY c.at`, [req.params.id]);
    return ok({ corrections: rows.rows });
  });

  r.get('/attendance/issues', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'attendance.read_all', 'attendance.read_team');
    const ids = await readableIds(db, a, 'attendance');
    const today = local(clock()).date;
    const rows = await db.query(`
      SELECT e.id, e.full_name, e.code, count(*) FILTER (WHERE at.check_out_at IS NULL AND at.work_date < $1)::int AS missing_checkouts,
             count(*) FILTER (WHERE at.corrected)::int AS corrections
        FROM employees e JOIN attendance at ON at.employee_id = e.id
       WHERE at.work_date >= date_trunc('month', $1::date) AND e.status = 'active'
         AND ($2::uuid[] IS NULL OR e.id = ANY($2::uuid[]))
       GROUP BY e.id HAVING count(*) FILTER (WHERE at.check_out_at IS NULL AND at.work_date < $1) > 0
       ORDER BY missing_checkouts DESC`, [today, ids]);
    return ok({ issues: rows.rows });
  });
};

export { has };
