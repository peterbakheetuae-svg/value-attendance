import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { date, obj, oneOf, reqStr, str, time, uuid, isUuid } from '../http/validate.ts';
import { assertCanRead, audit, authenticate, has, readableIds, type Actor } from '../auth/context.ts';
import { daysBetween, isoDow, local, timeToMinutes } from '../lib/time.ts';
import { applyCorrection } from './attendance.ts';
import { holdersOf, notify } from './notify.ts';

export const REQUEST_TYPES = ['hourly_permission', 'short_leave', 'full_day_absence', 'emergency_permission', 'attendance_correction'] as const;
const ABSENCE_TYPES = ['annual', 'casual', 'sick', 'unpaid', 'mission'] as const;
const TYPE_AR: Record<string, string> = {
  hourly_permission: 'إذن ساعات', short_leave: 'انصراف مبكر', full_day_absence: 'غياب يوم كامل',
  emergency_permission: 'إذن طارئ', attendance_correction: 'تصحيح حضور',
};
const SHORT_LEAVE_MAX = 4 * 60;

/** Working days in a range for an employee (excludes their weekend and public holidays). */
async function workingDaysInRange(q: Q, employeeId: string, start: string, end: string): Promise<number> {
  const s = await one(q, `SELECT COALESCE(ws.weekend_days, d.weekend_days) AS wd FROM employees e
                           LEFT JOIN work_schedules ws ON ws.id = e.schedule_id
                           LEFT JOIN work_schedules d ON d.is_default WHERE e.id = $1`, [employeeId]);
  const hol = new Set((await q.query(`SELECT day FROM holidays WHERE day BETWEEN $1 AND $2`, [start, end])).rows.map((h) => h.day));
  let n = 0;
  for (let i = 0; i <= daysBetween(start, end); i++) {
    const d = new Date(Date.parse(start + 'T00:00:00Z') + i * 86400000).toISOString().slice(0, 10);
    if (!s.wd.includes(isoDow(d)) && !hol.has(d)) n++;
  }
  return n;
}

async function resolveManager(q: Q, employeeId: string): Promise<string | null> {
  const r = await one(q, `
    SELECT COALESCE(
      (SELECT m.id FROM employees m WHERE m.id = e.sales_manager_id AND m.status = 'active'),
      (SELECT m.id FROM teams t JOIN employees m ON m.id = t.manager_id
        WHERE t.id = e.team_id AND t.active AND m.status = 'active')) AS mid
      FROM employees e WHERE e.id = $1`, [employeeId]);
  return r?.mid && r.mid !== employeeId ? r.mid : null;
}

const SELECT = `
  SELECT r.*, e.full_name AS employee_name, e.code AS employee_code, m.full_name AS manager_name
    FROM requests r JOIN employees e ON e.id = r.employee_id LEFT JOIN employees m ON m.id = r.manager_id`;

async function loadActions(q: Q, id: string) {
  return (await q.query(`SELECT a.stage, a.action, a.comment, a.at, x.full_name AS actor_name, a.actor_id
                           FROM request_actions a JOIN employees x ON x.id = a.actor_id
                          WHERE a.request_id = $1 ORDER BY a.id`, [id])).rows;
}

/** What may this actor do with this request right now? Drives the UI and is re-checked server-side. */
function allowed(a: Actor, r: any) {
  const own = r.employee_id === a.id;
  return {
    cancel: own && (r.status === 'pending_manager' || r.status === 'pending_hr'),
    managerDecide: !own && r.status === 'pending_manager' && r.manager_id === a.id && has(a, 'request.approve_manager'),
    hrDecide: !own && r.status === 'pending_hr' && has(a, 'request.approve_hr'),
  };
}

export const requestsModule: Module = (r, { db, clock }) => {
  r.post('/requests', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    // HR may record a request for an employee (original JPH "submit by manager"): it is approved on entry.
    const forId = typeof b.employeeId === 'string' && b.employeeId && b.employeeId !== a.id ? b.employeeId : null;
    if (forId) {
      if (!has(a, 'request.approve_hr')) throw forbidden('Only HR can record a request for another employee');
      if (!isUuid(forId) || !(await one(db, `SELECT 1 FROM employees WHERE id = $1 AND status = 'active'`, [forId]))) throw notFound('Employee not found');
    }
    const subjectId = forId ?? a.id;
    const type = oneOf(b, 'type', REQUEST_TYPES)!;
    const reason = reqStr(b, 'reason', { min: 3, max: 1000 });
    const attachmentId = uuid(b, 'attachmentId', true) ?? null;
    const today = local(clock()).date;
    const settings = await one(db, `SELECT request_backdate_days FROM company_settings`);
    const oldest = new Date(Date.parse(today + 'T00:00:00Z') - settings.request_backdate_days * 86400000).toISOString().slice(0, 10);
    const f: Record<string, unknown> = {};

    if (type === 'hourly_permission' || type === 'short_leave' || type === 'emergency_permission') {
      f.day = date(b, 'day'); f.from_time = time(b, 'fromTime'); f.to_time = time(b, 'toTime');
      const dur = timeToMinutes(f.to_time as string) - timeToMinutes(f.from_time as string);
      if (dur <= 0) throw invalid('End time must be after start time', { field: 'toTime' });
      if (type === 'short_leave' && dur > SHORT_LEAVE_MAX) throw invalid('Short leave cannot exceed 4 hours', { field: 'toTime' });
      f.duration_minutes = dur;
      if ((f.day as string) < oldest) throw invalid(`Requests cannot be older than ${settings.request_backdate_days} days`, { field: 'day' });
    } else if (type === 'full_day_absence') {
      f.start_date = date(b, 'startDate'); f.end_date = date(b, 'endDate');
      f.absence_type = oneOf(b, 'absenceType', ABSENCE_TYPES);
      if ((f.end_date as string) < (f.start_date as string)) throw invalid('End date must be on or after start date', { field: 'endDate' });
      if (daysBetween(f.start_date as string, f.end_date as string) > 60) throw invalid('An absence request cannot exceed 60 days', { field: 'endDate' });
      if ((f.start_date as string) < oldest) throw invalid(`Requests cannot be older than ${settings.request_backdate_days} days`, { field: 'startDate' });
      f.days_count = await workingDaysInRange(db, subjectId, f.start_date as string, f.end_date as string);
      if (!f.days_count) throw invalid('The selected range has no working days', { field: 'startDate' });
    } else {
      f.correction_date = date(b, 'correctionDate'); f.correction_in = time(b, 'correctionIn');
      f.correction_out = time(b, 'correctionOut', true) ?? null;
      if (f.correction_out && timeToMinutes(f.correction_out as string) <= timeToMinutes(f.correction_in as string)) {
        throw invalid('Check-out must be after check-in', { field: 'correctionOut' });
      }
      if ((f.correction_date as string) > today) throw invalid('Cannot correct a future day', { field: 'correctionDate' });
      if ((f.correction_date as string) < oldest) throw invalid(`Requests cannot be older than ${settings.request_backdate_days} days`, { field: 'correctionDate' });
    }
    if (attachmentId) {
      const doc = await one(db, `SELECT employee_id FROM employee_documents WHERE id = $1`, [attachmentId]);
      if (!doc || doc.employee_id !== subjectId) throw invalid('Attachment not found', { field: 'attachmentId' });
    }

    if (forId) {
      const row = await db.tx(async (q) => {
        await q.query(`SELECT 1 FROM employees WHERE id = $1 FOR UPDATE`, [forId]);
        if (type === 'full_day_absence') {
          const overlap = await one(q, `SELECT 1 FROM requests WHERE employee_id = $1 AND type = 'full_day_absence'
              AND status = 'approved' AND start_date <= $3 AND end_date >= $2`, [forId, f.start_date, f.end_date]);
          if (overlap) throw conflict('These dates overlap an approved absence');
        }
        const cols = Object.keys(f);
        const x = await one(q, `
          INSERT INTO requests (employee_id, type, reason, attachment_id, route, manager_id, status, decided_at ${cols.map((c) => ', ' + c).join('')})
          VALUES ($1,$2,$3,$4,'hr_only',NULL,'approved',now() ${cols.map((_, i) => `, $${i + 5}`).join('')}) RETURNING *`,
          [forId, type, reason, attachmentId, ...cols.map((c) => f[c])]);
        await q.query(`INSERT INTO request_actions (request_id, actor_id, stage, action, comment) VALUES ($1,$2,'hr','submit','سجّلته الموارد البشرية'),($1,$2,'hr','approve',NULL)`, [x.id, a.id]);
        if (type === 'attendance_correction') {
          await applyCorrection(q, { employeeId: forId, workDate: x.correction_date, inHHMM: x.correction_in.slice(0, 5),
            outHHMM: x.correction_out ? x.correction_out.slice(0, 5) : null, reason, requestedBy: a.id, approvedBy: a.id, requestId: x.id });
        }
        await audit(q, a.id, 'request.record_for_employee', 'request', x.id, undefined, { type, employeeId: forId });
        await notify(q, { to: forId, type: 'request_approved', title: `سجّلت الإدارة لك طلب ${TYPE_AR[type]}`, body: reason,
          entity: 'request', entityId: x.id, dedupeKey: `req:${x.id}:approved` });
        return x;
      });
      return ok({ request: row }, 201);
    }

    const created = await db.tx(async (q) => {
      await q.query(`SELECT 1 FROM employees WHERE id = $1 FOR UPDATE`, [a.id]);
      // one pending request per overlapping day and type
      const dup = await one(q, `
        SELECT 1 FROM requests WHERE employee_id = $1 AND type = $2 AND status IN ('pending_manager','pending_hr')
           AND ( (day IS NOT NULL AND day = $3::date)
              OR (start_date IS NOT NULL AND start_date <= $5::date AND end_date >= $4::date)
              OR (correction_date IS NOT NULL AND correction_date = $6::date))`,
        [a.id, type, f.day ?? null, f.start_date ?? null, f.end_date ?? null, f.correction_date ?? null]);
      if (dup) throw conflict('You already have a pending request like this');
      if (type === 'full_day_absence') {
        const overlap = await one(q, `SELECT 1 FROM requests WHERE employee_id = $1 AND type = 'full_day_absence'
            AND status = 'approved' AND start_date <= $3 AND end_date >= $2`, [a.id, f.start_date, f.end_date]);
        if (overlap) throw conflict('These dates overlap an approved absence');
      }
      const managerId = await resolveManager(q, a.id);
      const route = managerId ? 'manager_then_hr' : 'hr_only';
      const status = managerId ? 'pending_manager' : 'pending_hr';
      const cols = Object.keys(f);
      const row = await one(q, `
        INSERT INTO requests (employee_id, type, reason, attachment_id, route, manager_id, status ${cols.map((c) => ', ' + c).join('')})
        VALUES ($1,$2,$3,$4,$5,$6,$7 ${cols.map((_, i) => `, $${i + 8}`).join('')}) RETURNING *`,
        [a.id, type, reason, attachmentId, route, managerId, status, ...cols.map((c) => f[c])]);
      await q.query(`INSERT INTO request_actions (request_id, actor_id, stage, action) VALUES ($1,$2,'employee','submit')`, [row.id, a.id]);
      await audit(q, a.id, 'request.submit', 'request', row.id, undefined, { type, route });
      const recipients = managerId ? [managerId] : await holdersOf(q, 'request.approve_hr', [a.id]);
      for (const to of recipients) {
        await notify(q, { to, type: 'request_awaiting', title: `طلب ${TYPE_AR[type]} بانتظار موافقتك`,
          body: `${a.fullName}: ${reason}`, entity: 'request', entityId: row.id, dedupeKey: `req:${row.id}:awaiting:${status}` });
      }
      await notify(q, { to: a.id, type: 'request_submitted', title: `تم إرسال طلب ${TYPE_AR[type]}`,
        entity: 'request', entityId: row.id, dedupeKey: `req:${row.id}:submitted` });
      return row;
    });
    return ok({ request: created }, 201);
  });

  r.get('/requests', async (req) => {
    const a = await authenticate(db, req);
    const vals: unknown[] = []; const where: string[] = [];
    const mine = req.query.get('scope') === 'mine';
    const ids = mine ? [a.id] : await readableIds(db, a, 'request');
    if (ids) { vals.push(ids); where.push(`r.employee_id = ANY($${vals.length}::uuid[])`); }
    const status = req.query.get('status');
    if (status === 'pending') where.push(`r.status IN ('pending_manager','pending_hr')`);
    else if (status) { vals.push(status); where.push(`r.status = $${vals.length}`); }
    const type = req.query.get('type');
    if (type) { vals.push(type); where.push(`r.type = $${vals.length}`); }
    const emp = req.query.get('employeeId');
    if (emp) { if (!isUuid(emp)) throw notFound(); vals.push(emp); where.push(`r.employee_id = $${vals.length}`); }
    if (req.query.get('awaitingMe') === '1') {
      const conds = [];
      if (has(a, 'request.approve_manager')) { vals.push(a.id); conds.push(`(r.status = 'pending_manager' AND r.manager_id = $${vals.length})`); }
      if (has(a, 'request.approve_hr')) conds.push(`r.status = 'pending_hr'`);
      vals.push(a.id);
      where.push(conds.length ? `(${conds.join(' OR ')}) AND r.employee_id <> $${vals.length}` : 'false');
    }
    const rows = await db.query(`${SELECT} ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
      ORDER BY r.created_at DESC LIMIT 300`, vals);
    return ok({ requests: rows.rows.map((x) => ({ ...x, can: allowed(a, x) })) });
  });

  r.get('/requests/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const row = await one(db, `${SELECT} WHERE r.id = $1`, [req.params.id]);
    if (!row) throw notFound();
    // the snapshotted manager keeps access to a request routed to them
    if (row.manager_id !== a.id) await assertCanRead(db, a, row.employee_id, 'request');
    return ok({ request: { ...row, can: allowed(a, row) }, actions: await loadActions(db, row.id) });
  });

  r.post('/requests/:id/cancel', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    await db.tx(async (q) => {
      const row = await one(q, `SELECT * FROM requests WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!row || row.employee_id !== a.id) throw notFound();
      if (!allowed(a, row).cancel) throw conflict('This request can no longer be cancelled');
      await q.query(`UPDATE requests SET status = 'cancelled', decided_at = now() WHERE id = $1`, [row.id]);
      await q.query(`INSERT INTO request_actions (request_id, actor_id, stage, action) VALUES ($1,$2,'employee','cancel')`, [row.id, a.id]);
      await audit(q, a.id, 'request.cancel', 'request', row.id);
    });
    return ok({ ok: true });
  });

  r.post('/requests/:id/decision', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const decision = oneOf(b, 'decision', ['approve', 'reject'] as const)!;
    const comment = str(b, 'comment', { optional: true, max: 1000 }) ?? null;
    if (decision === 'reject' && (!comment || comment.length < 3)) throw invalid('A rejection reason is required', { field: 'comment' });

    const result = await db.tx(async (q) => {
      const row = await one(q, `SELECT r.*, e.full_name AS employee_name FROM requests r JOIN employees e ON e.id = r.employee_id
                                  WHERE r.id = $1 FOR UPDATE OF r`, [req.params.id]);
      if (!row) throw notFound();
      if (row.employee_id === a.id) throw forbidden('You cannot decide on your own request');
      const can = allowed(a, row);
      let stage: 'manager' | 'hr';
      if (can.managerDecide) stage = 'manager';
      else if (can.hrDecide) stage = 'hr';
      else {
        // hide requests the actor cannot see at all; otherwise explain the stage problem
        if (row.manager_id !== a.id) await assertCanRead(q, a, row.employee_id, 'request');
        if (['approved', 'rejected', 'cancelled'].includes(row.status)) throw conflict('This request is already closed');
        throw forbidden(row.status === 'pending_manager'
          ? 'This request is waiting for the assigned sales manager'
          : 'This request is waiting for HR approval');
      }
      let next: string;
      if (decision === 'reject') next = 'rejected';
      else next = stage === 'manager' ? 'pending_hr' : 'approved';
      await q.query(`UPDATE requests SET status = $2, decided_at = CASE WHEN $2 IN ('approved','rejected') THEN now() END WHERE id = $1`, [row.id, next]);
      await q.query(`INSERT INTO request_actions (request_id, actor_id, stage, action, comment) VALUES ($1,$2,$3,$4,$5)`,
        [row.id, a.id, stage, decision, comment]);
      await audit(q, a.id, `request.${stage}_${decision}`, 'request', row.id, { status: row.status }, { status: next, comment });

      const label = TYPE_AR[row.type];
      if (next === 'pending_hr') {
        for (const to of await holdersOf(q, 'request.approve_hr', [row.employee_id])) {
          await notify(q, { to, type: 'request_awaiting', title: `طلب ${label} بانتظار موافقة الموارد البشرية`,
            body: `${row.employee_name} — وافق المدير`, entity: 'request', entityId: row.id, dedupeKey: `req:${row.id}:awaiting:pending_hr` });
        }
        await notify(q, { to: row.employee_id, type: 'request_progress', title: `وافق مديرك على طلب ${label}`,
          body: 'الطلب الآن عند الموارد البشرية', entity: 'request', entityId: row.id, dedupeKey: `req:${row.id}:manager_approved` });
      } else if (next === 'approved') {
        if (row.type === 'attendance_correction') {
          await applyCorrection(q, {
            employeeId: row.employee_id, workDate: row.correction_date, inHHMM: row.correction_in.slice(0, 5),
            outHHMM: row.correction_out ? row.correction_out.slice(0, 5) : null, reason: row.reason,
            requestedBy: row.employee_id, approvedBy: a.id, requestId: row.id,
          });
        }
        await notify(q, { to: row.employee_id, type: 'request_approved', title: `تمت الموافقة على طلب ${label}`,
          entity: 'request', entityId: row.id, dedupeKey: `req:${row.id}:approved` });
      } else {
        await notify(q, { to: row.employee_id, type: 'request_rejected', title: `تم رفض طلب ${label}`,
          body: comment ?? '', entity: 'request', entityId: row.id, dedupeKey: `req:${row.id}:rejected` });
      }
      return next;
    });
    return ok({ status: result });
  });

  // ---------------------------------------------------------------- leave balances
  r.get('/leave-balances/:employeeId', async (req) => {
    const a = await authenticate(db, req);
    const id = req.params.employeeId;
    if (!isUuid(id)) throw notFound();
    if (id !== a.id && !has(a, 'leave.manage_balances')) await assertCanRead(db, a, id, 'request');
    const year = Number(req.query.get('year') ?? local(clock()).date.slice(0, 4));
    const bal = await one(db, `SELECT * FROM leave_balances WHERE employee_id = $1 AND year = $2`, [id, year]);
    const used = await db.query(`SELECT absence_type, COALESCE(sum(days_count),0)::int AS days FROM requests
        WHERE employee_id = $1 AND type = 'full_day_absence' AND status = 'approved'
          AND extract(year FROM start_date) = $2 GROUP BY absence_type`, [id, year]);
    const u = Object.fromEntries(used.rows.map((x) => [x.absence_type, x.days]));
    return ok({ year, entitled: bal ?? null, used: u,
      remaining: bal ? { annual: bal.annual_days - (u.annual ?? 0), casual: bal.casual_days - (u.casual ?? 0) } : null });
  });

  r.put('/leave-balances/:employeeId', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'leave.manage_balances')) throw forbidden();
    const id = req.params.employeeId;
    if (!isUuid(id)) throw notFound();
    if (id === a.id) throw forbidden('You cannot change your own leave balance');
    const b = obj(req.body);
    const year = Number(b.year);
    if (!Number.isInteger(year) || year < 2000 || year > 2100) throw invalid('year is invalid', { field: 'year' });
    const vals = ['annualDays', 'casualDays', 'sickDays'].map((k) => {
      const v = b[k];
      if (typeof v !== 'number' || v < 0 || v > 365) throw invalid(`${k} must be 0–365`, { field: k });
      return v;
    });
    await db.tx(async (q) => {
      const before = await one(q, `SELECT * FROM leave_balances WHERE employee_id = $1 AND year = $2`, [id, year]);
      await q.query(`INSERT INTO leave_balances (employee_id, year, annual_days, casual_days, sick_days, updated_by)
                     VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (employee_id, year) DO UPDATE SET
                     annual_days = EXCLUDED.annual_days, casual_days = EXCLUDED.casual_days, sick_days = EXCLUDED.sick_days,
                     updated_by = EXCLUDED.updated_by, updated_at = now()`, [id, year, ...vals, a.id]);
      await audit(q, a.id, 'leave_balance.set', 'employee', id, before ?? null, { year, annual: vals[0], casual: vals[1], sick: vals[2] });
    });
    return ok({ ok: true });
  });
};
