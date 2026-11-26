import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound, unprocessable } from '../http/errors.ts';
import { date, imageType, monthParam, num, obj, reqStr, time, uuid, isUuid } from '../http/validate.ts';
import { assertCanRead, audit, authenticate, can, has, notSettled, readableIds, requirePerm, type Actor } from '../auth/context.ts';
import { cairoInstant, local, actionTime } from '../lib/time.ts';
import { computeMonth, metrics } from './attendance-calc.ts';
import { notify } from './notify.ts';
import { effectiveSql } from '../auth/permission-admin.ts';
import type { Req } from '../http/router.ts';
import { devicePolicy, isBrowserRequest, punchRefusal, PUNCH_REFUSAL_AR, type PunchRefusal } from '../lib/client-platform.ts';
import { readFileBytes, storeFile, withFile } from '../lib/files.ts';

/**
 * G1: may THIS session record attendance / location? Decided from the server's own records — the employee's
 * «ربط الحساب بالجهاز», the device id the session was created with, and whether that device is approved for him —
 * read fresh on every step. A request header can only add a refusal (lib/client-platform.ts). null = allowed.
 */
export async function punchRefusalOf(q: Q, a: Actor, req: Req): Promise<PunchRefusal | null> {
  if (!a.sessionId) return 'device_not_approved'; // no session row behind the actor: nothing to check → refused
  const s = await one(q, `
    SELECT e.device_lock, s.device_id,
           EXISTS (SELECT 1 FROM employee_devices d
                    WHERE d.employee_id = s.employee_id AND d.device_id = s.device_id AND d.status = 'approved') AS approved
      FROM sessions s JOIN employees e ON e.id = s.employee_id
     WHERE s.id = $1 AND s.employee_id = $2`, [a.sessionId, a.id]);
  return punchRefusal(s ? { deviceLock: s.device_lock === true, deviceId: s.device_id ?? null, approved: s.approved === true } : null,
    isBrowserRequest(req.headers), devicePolicy());
}

/** refuses (403, audited) an attendance step from a session whose device may not record attendance */
export async function assertPunchClient(q: Q, a: Actor, req: Req, step: string) {
  const why = await punchRefusalOf(q, a, req);
  if (!why) return;
  await audit(q, a.id, 'attendance.device_refused', 'employee', a.id, undefined, { step, why, policy: devicePolicy() });
  throw new AppError('forbidden', PUNCH_REFUSAL_AR[why], { reason: 'device_not_authorized', why });
}

/**
 * The time of a check-in / check-out / «I'm back» — with an offline record's own time (`offlineAt`) trusted only when
 * the server has no sign the phone was online after it:
 *  - this session talked to the server after the claimed time (+5 min) but well before this record (−5 min) → the phone
 *    was online and did not send it: the claim is ignored and the server's time is used (audited);
 *  - a record of an earlier day → refused, HR is told (corrects it from the attendance log);
 *  - a record that reaches the server more than 5 minutes after its claimed time → HR is told (who, which step, the time
 *    claimed and the time it arrived), so a back-dated record is always seen.
 */
/**
 * Who is told about offline attendance records: the HR desk that corrects attendance — whoever holds both «تصحيح الحضور»
 * (attendance.correct) and the HR approval stage (request.approve_hr), by his position's grant or an individual one: HR,
 * the administrative officer, any position given both. The owner keeps not being told (as before); the person himself never.
 */
export async function hrAttendanceDesk(q: Q, exceptId: string): Promise<string[]> {
  const r = await q.query<{ id: string }>(`
    SELECT e.id FROM employees e
     WHERE e.status = 'active' AND ${notSettled('e')} AND e.id <> $1 AND e.role_key <> 'owner'
       AND ${effectiveSql('e', "'attendance.correct'")} AND ${effectiveSql('e', "'request.approve_hr'")}`, [exceptId]);
  return r.rows.map((x) => x.id);
}

export async function trustedTime(q: Q, a: Actor, body: Record<string, unknown>, now: Date, step: string) {
  const t = actionTime(body, now);
  if (!t.offline) return t;
  // an offline record belongs to today: a day already over is corrected by HR (who is told), never by the phone's clock —
  // otherwise yesterday's absence could be turned into a full day by two back-dated records
  if (local(t.at).date !== local(now).date) {
    for (const id of await hrAttendanceDesk(q, a.id)) {
      await notify(q, { to: id, type: 'offline_attendance', title: `${step} من غير نت ليوم فات — ${a.fullName}`,
        body: `متسجل بتاريخ ${local(t.at).date} ووصل النهارده — اترفض، صححه من سجل الحضور لو صحيح`,
        entity: 'employee', entityId: a.id, dedupeKey: `offline_old:${a.id}:${step}:${local(t.at).date}` });
    }
    await audit(q, a.id, 'attendance.offline_old_refused', 'employee', a.id, undefined, { step, claimed: t.at.toISOString() });
    throw new AppError('conflict', 'An offline record from an earlier day is not accepted — HR corrects it', { reason: 'offline_other_day' });
  }
  const seen = a.prevSeenAt ? a.prevSeenAt.getTime() : null;
  if (seen !== null && seen > t.at.getTime() + 5 * 60_000 && seen < now.getTime() - 5 * 60_000) {
    await audit(q, a.id, 'attendance.offline_time_refused', 'employee', a.id, undefined,
      { step, claimed: t.at.toISOString(), seenOnline: a.prevSeenAt!.toISOString(), used: now.toISOString() });
    return { at: now, offline: false, overridden: true };
  }
  return t;
}

/** an offline record that arrived late: HR is told (once per record) */
export async function tellHrLateOffline(q: Q, a: Actor, step: string, at: Date, now: Date, entityId: string) {
  const lateMin = Math.round((now.getTime() - at.getTime()) / 60_000);
  if (lateMin < 5) return;
  const hhmm = (d: Date) => { const m = local(d).minutes; return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`; };
  for (const id of await hrAttendanceDesk(q, a.id)) {
    await notify(q, { to: id, type: 'offline_attendance', title: `${step} من غير نت — ${a.fullName}`,
      body: `متسجل بتوقيت ${hhmm(at)} ووصل للسيستم ${hhmm(now)} (بعد ${lateMin} دقيقة) — راجعه لو محتاج`,
      entity: 'employee', entityId: a.id, dedupeKey: `offline_att:${entityId}:${step}` });
  }
}

export function haversineM(lat1: number, lng1: number, lat2: number, lng2: number) {
  const R = 6371000, rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad, dLng = (lng2 - lng1) * rad;
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}

const MAX_ACCURACY_M = 200;

export async function geofence(q: Q, body: Record<string, unknown>, opts: { enforce?: boolean } = {}) {
  const s = await one(q, `SELECT gps_required FROM company_settings`);
  const lat = num(body, 'lat', { optional: true, min: -90, max: 90 });
  const lng = num(body, 'lng', { optional: true, min: -180, max: 180 });
  const acc = num(body, 'accuracyM', { optional: true, min: 0, max: 100000 });
  if (!s.gps_required) return { status: 'not_required' as const, lat: lat ?? null, lng: lng ?? null, acc: acc ?? null };
  const locs = (await q.query(`SELECT * FROM work_locations WHERE active`)).rows;
  // no office saved yet, or a step that only records the place (check-out): never blocks
  if (!locs.length || opts.enforce === false) return { status: 'not_required' as const, lat: lat ?? null, lng: lng ?? null, acc: acc ?? null };
  if (lat === undefined || lng === undefined || acc === undefined) throw invalid('Location is required to record attendance', { field: 'lat' });
  // the phone itself says the location comes from a fake-location app (Android «mock location»)
  if (body.mocked === true) throw new AppError('unprocessable', 'The location comes from a fake-location app — turn it off and try again', { reason: 'mock_location' });
  if (acc > MAX_ACCURACY_M) throw unprocessable('Location signal is too weak. Move near a window and try again');
  const nearest = Math.min(...locs.map((l) => haversineM(lat, lng, l.lat, l.lng) - l.radius_m));
  if (nearest > 0) throw new AppError('unprocessable', 'You are outside the office area', { distanceOutsideM: Math.round(nearest) });
  return { status: 'inside' as const, lat, lng, acc };
}

export async function scheduleFor(q: Q, employeeId: string) {
  return one(q, `
    SELECT ws.*, COALESCE(e.work_start, ws.start_time) AS start_time, COALESCE(e.work_end, ws.end_time) AS end_time,
           e.attendance_exempt, e.selfie_required AS emp_selfie_required
      FROM employees e
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
    checkInOffline: a.check_in_offline === true, checkOutOffline: a.check_out_offline === true,
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
  // the real content decides (a mislabelled file is stored with what it really is; anything not a photo is refused)
  const real = imageType(buf);
  if (!real) throw invalid('selfie must be a JPEG, PNG or WebP image', { field: 'selfie' });
  return { buf, mime: real };
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
    await assertPunchClient(db, a, req, 'حضور');
    const b = obj(req.body ?? {});
    const { at: now, offline } = await trustedTime(db, a, b, clock(), 'حضور'); const l = local(now);
    const selfie = selfieFrom(b);
    // R2 (091): the selfie is written and verified BEFORE the transaction — inside it, the employee row lock below
    // (FOR UPDATE) would block the file record's own foreign-key check on that employee (FOR KEY SHARE) and the check-in
    // would wait forever. The refusals that do not depend on the race are checked first so nothing is stored for them.
    let fileId: string | null = null;
    if (selfie) {
      if (await one(db, `SELECT id FROM attendance WHERE employee_id = $1 AND work_date = $2`, [a.id, l.date])) throw conflict('You already checked in today');
      const s0 = await scheduleFor(db, a.id);
      if (!s0.attendance_exempt) {
        fileId = await storeFile(db, { category: 'attendance_selfie', bytes: selfie.buf, mime: selfie.mime, name: 'selfie', createdBy: a.id });
      }
    }
    const row = await db.tx(async (q) => {
      // serialize per employee so two taps cannot both pass the duplicate check
      await q.query(`SELECT 1 FROM employees WHERE id = $1 FOR UPDATE`, [a.id]);
      const dup = await one(q, `SELECT id FROM attendance WHERE employee_id = $1 AND work_date = $2`, [a.id, l.date]);
      if (dup) throw conflict('You already checked in today');
      const s = await scheduleFor(q, a.id);
      if (s.attendance_exempt) throw new AppError('unprocessable', 'This account does not use check-in / check-out', { reason: 'attendance_exempt' });
      const g = await geofence(q, b);
      const cfg = await one(q, `SELECT selfie_required, selfie_retention_days FROM company_settings`);
      if (s.emp_selfie_required && !selfie) throw new AppError('unprocessable', 'A selfie is required to check in', { reason: 'selfie_required' });
      const inserted = await one(q, `
        INSERT INTO attendance (employee_id, work_date, schedule_start, schedule_end, late_grace_minutes, early_grace_minutes,
          overtime_enabled, overtime_min_minutes, check_in_at, check_in_lat, check_in_lng, check_in_accuracy_m,
          geofence_status, original_check_in_at, check_in_offline)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$9,$14) RETURNING *`,
        [a.id, l.date, s.start_time, s.end_time, s.late_grace_minutes, s.early_grace_minutes, s.overtime_enabled,
         s.overtime_min_minutes, now, g.lat, g.lng, g.acc, g.status, offline]);
      if (selfie) {
        await q.query(...withFile(`INSERT INTO attendance_selfies (attendance_id, employee_id, image, mime, taken_at) VALUES ($1,$2,$3,$4,$5)`,
          [inserted.id, a.id, selfie.buf, selfie.mime, now], 'image', fileId));
      }
      // retention: old selfies are removed as part of normal use (no scheduler needed on the free plan)
      await q.query(`DELETE FROM attendance_selfies WHERE taken_at < $1::timestamptz - make_interval(days => $2)`, [clock(), cfg.selfie_retention_days]);
      await audit(q, a.id, 'attendance.check_in', 'attendance', inserted.id, undefined, { at: now, geofence: g.status, selfie: !!selfie, offline });
      if (offline) await tellHrLateOffline(q, a, 'حضور', now, clock(), inserted.id);
      return inserted;
    });
    // the account open on other phones too: they ring like a call so each is opened and followed
    const { ringOtherPhonesAtCheckIn } = await import('./tracking.ts');
    await ringOtherPhonesAtCheckIn(db, a.id, a.sessionId, l.date, now);
    return ok({ attendance: shape(row, l.date) }, 201);
  });

  r.post('/attendance/check-out', async (req) => {
    const a = await authenticate(db, req);
    await assertPunchClient(db, a, req, 'انصراف');
    const b = obj(req.body ?? {});
    const { at: now, offline } = await trustedTime(db, a, b, clock(), 'انصراف'); const l = local(now);
    const row = await db.tx(async (q) => {
      const open = await one(q, `SELECT * FROM attendance WHERE employee_id = $1 AND work_date = $2 FOR UPDATE`, [a.id, l.date]);
      if (!open) throw conflict('You must check in first');
      if (open.check_out_at) throw conflict('You already checked out today');
      const onBreak = await one(q, `SELECT 1 FROM attendance_breaks WHERE attendance_id = $1 AND ended_at IS NULL`, [open.id]);
      if (onBreak) throw conflict('End your break before checking out');
      if (now <= new Date(open.check_in_at)) throw conflict('Check-out must be after check-in');
      const g = await geofence(q, b, { enforce: false }); // check-out records the place; only check-in is tied to the office
      const updated = await one(q, `UPDATE attendance SET check_out_at = $2, original_check_out_at = $2,
          check_out_lat = $3, check_out_lng = $4, check_out_accuracy_m = $5, check_out_offline = $6 WHERE id = $1 RETURNING *`,
        [open.id, now, g.lat, g.lng, g.acc, offline]);
      await audit(q, a.id, 'attendance.check_out', 'attendance', open.id, undefined, { at: now, offline });
      // an open unauthorized-exit incident ends at the check-out (capped at the scheduled shift end)
      await (await import('./exit-incidents.ts')).closeIncident(q, a.id, now, 'checked_out');
      if (offline) await tellHrLateOffline(q, a, 'انصراف', now, clock(), open.id);
      return updated;
    });
    return ok({ attendance: shape(row, l.date) });
  });

  r.post('/attendance/break-start', async (req) => {
    await authenticate(db, req);
    // the break was replaced by hourly permission / external visit (POST /outings); old breaks stay in history
    throw new AppError('conflict', 'The break has been replaced by hourly permission / external visit', { reason: 'break_removed' });
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
      selfieRequired: s.emp_selfie_required === true, attendanceExempt: s.attendance_exempt === true,
      // the absence threshold (proposed 094): whether registering today's absence is open yet — information only
      absenceThreshold: await (await import('./presence.ts')).absenceWindow(db, a.id, clock()) });
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
       WHERE e.status = 'active' AND NOT e.attendance_exempt AND ${notSettled('e')} AND ($2::uuid[] IS NULL OR e.id = ANY($2::uuid[]))
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
    const row = await one(db, `SELECT * FROM attendance_selfies WHERE attendance_id = $1`, [req.params.id]);
    if (!row) throw notFound('No selfie (or it was deleted after the retention period)');
    if (row.employee_id !== a.id) await assertCanRead(db, a, row.employee_id, 'attendance');
    return { binary: await readFileBytes(db, row.image, row.image_file_id), contentType: row.mime };
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
             EXISTS (SELECT 1 FROM attendance_selfies s WHERE s.attendance_id = a.id) AS has_selfie,
             (SELECT e.full_name FROM attendance_corrections c JOIN employees e ON e.id = c.approved_by
               WHERE c.attendance_id = a.id ORDER BY c.at DESC LIMIT 1) AS corrected_by_name
        FROM attendance a LEFT JOIN attendance_breaks b ON b.attendance_id = a.id
       WHERE a.employee_id = $1 AND a.work_date BETWEEN $2 AND $3 ORDER BY a.work_date DESC LIMIT 400`, [employeeId, from, to]);
    // permissions / visits of each day (approved ones; an extension replaces its parent)
    const outs = await db.query(`
      SELECT o.work_date, o.kind, COALESCE(o.starts_at, o.requested_at) AS from_at, o.expected_return_at, o.returned_at, o.status
        FROM outing_requests o
       WHERE o.employee_id = $1 AND o.work_date BETWEEN $2 AND $3 AND o.status = 'approved'
       ORDER BY COALESCE(o.starts_at, o.requested_at)`, [employeeId, from, to]);
    const outBy = new Map<string, any[]>();
    for (const o of outs.rows) {
      const k = String(o.work_date);
      if (!outBy.has(k)) outBy.set(k, []);
      outBy.get(k)!.push({ kind: o.kind, from: o.from_at, expectedReturn: o.expected_return_at, returnedAt: o.returned_at });
    }
    const seeLoc = employeeId === a.id || can(a, 'attendance.view_location', ['attendance.read_all', 'attendance.read_team']);
    return ok({ days: rows.rows.map((x) => ({
      // where he checked in / out: his own, or with «عرض مواقع الموظفين»
      ...shape(x, today), ...(seeLoc ? { checkInLat: x.check_in_lat, checkInLng: x.check_in_lng, checkOutLat: x.check_out_lat, checkOutLng: x.check_out_lng }
        : { checkInLat: null, checkInLng: null, checkOutLat: null, checkOutLng: null }),
      breakStart: x.break_start, breakEnd: x.break_end, hasSelfie: x.has_selfie, outings: outBy.get(String(x.work_date)) ?? [],
      correctedByName: x.corrected_by_name ?? null,
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
    // only an employee in his reading scope (all / own teams)
    if (!isUuid(employeeId)) throw notFound();
    await assertCanRead(db, a, employeeId, 'attendance');
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
       WHERE at.work_date >= date_trunc('month', $1::date) AND e.status = 'active' AND ${notSettled('e')}
         AND ($2::uuid[] IS NULL OR e.id = ANY($2::uuid[]))
       GROUP BY e.id HAVING count(*) FILTER (WHERE at.check_out_at IS NULL AND at.work_date < $1) > 0
       ORDER BY missing_checkouts DESC`, [today, ids]);
    return ok({ issues: rows.rows });
  });
};

export { has };
