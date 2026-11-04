import { ok, type Module } from '../ctx.ts';
import { one } from '../db.ts';
import { conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { date, isUuid, num, obj, oneOf, reqStr, str } from '../http/validate.ts';
import { audit, authenticate, has, readableIds, requirePerm } from '../auth/context.ts';
import { daysBetween, local } from '../lib/time.ts';
import { holdersOf, notify } from './notify.ts';
import { randomUUID } from 'node:crypto';
import { signedMediaPath, verifyMedia } from '../lib/media.ts';

/**
 * Endpoints behind the original JPH pages (advances / work expenses, holiday periods,
 * admin-sent notifications, own profile with bank details).
 */
export const legacyModule: Module = (r, { db, clock }) => {
  // ------------------------------------------------------------------ advances (سلفة / مصاريف عمل)
  const ADV = `SELECT x.*, e.full_name AS employee_name, e.code AS employee_code, d.full_name AS decided_by_name
                 FROM advance_requests x JOIN employees e ON e.id = x.employee_id LEFT JOIN employees d ON d.id = x.decided_by`;
  const canDecideAdvances = (a: any) => has(a, 'finance.approve');

  r.get('/advances', async (req) => {
    const a = await authenticate(db, req);
    const all = req.query.get('scope') !== 'mine' && (has(a, 'finance.read') || has(a, 'request.approve_hr'));
    const rows = await db.query(`${ADV} ${all ? '' : 'WHERE x.employee_id = $1'} ORDER BY x.created_at DESC LIMIT 500`, all ? [] : [a.id]);
    return ok({ advances: rows.rows.map((x) => ({ ...x, attachment: undefined, has_attachment: x.attachment !== null })),
      canDecide: canDecideAdvances(a) });
  });

  r.post('/advances', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const kind = oneOf(b, 'kind', ['advance', 'work_expense'] as const)!;
    const amount = num(b, 'amount', { min: 1, max: 1_000_000 })!;
    const period = date(b, 'period')!;
    if (!period.endsWith('-01')) throw invalid('period must be the first day of a month', { field: 'period' });
    const note = str(b, 'note', { optional: true, max: 1000 }) ?? '';
    const employeeId = typeof b.employeeId === 'string' && b.employeeId ? b.employeeId : a.id;
    if (!isUuid(employeeId)) throw invalid('employeeId is invalid', { field: 'employeeId' });
    const onBehalf = employeeId !== a.id;
    // HR / finance may record one for someone else; finance approvers confirm it on the spot
    if (onBehalf && !has(a, 'finance.manage') && !has(a, 'employee.manage')) throw forbidden();
    if (!(await one(db, `SELECT 1 FROM employees WHERE id = $1 AND status = 'active'`, [employeeId]))) throw notFound('Employee not found');
    let attachment: Buffer | null = null;
    if (typeof b.attachment === 'string' && b.attachment.length) {
      const raw = b.attachment.replace(/^data:[^;]+;base64,/, '');
      attachment = Buffer.from(raw, 'base64');
      if (attachment.length > 600_000) throw invalid('Attachment is too large', { field: 'attachment' });
    }
    const confirmNow = onBehalf && canDecideAdvances(a);
    const row = await db.tx(async (q) => {
      const x = await one(q, `INSERT INTO advance_requests (employee_id, kind, period, amount_egp, note, attachment, status, created_by, decided_by, decided_at)
                              VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id, status`,
        [employeeId, kind, period, amount, note, attachment, confirmNow ? 'confirmed' : 'pending', a.id,
         confirmNow ? a.id : null, confirmNow ? clock() : null]);
      await audit(q, a.id, 'advance.create', 'advance', x.id, undefined, { employeeId, kind, period, amount, status: x.status });
      if (!confirmNow) {
        for (const to of await holdersOf(q, 'finance.approve', [employeeId])) {
          await notify(q, { to, type: 'advance_awaiting', title: kind === 'advance' ? 'طلب سلفة جديد' : 'طلب مصاريف عمل جديد',
            body: `${amount} جنيه`, entity: 'advance', entityId: x.id, dedupeKey: `adv:${x.id}:awaiting` });
        }
      }
      return x;
    });
    return ok({ advance: row }, 201);
  });

  r.post('/advances/:id/decision', async (req) => {
    const a = await authenticate(db, req);
    if (!canDecideAdvances(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const decision = oneOf(obj(req.body), 'decision', ['confirm', 'reject'] as const)!;
    const out = await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM advance_requests WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x) throw notFound();
      if (x.employee_id === a.id) throw forbidden('You cannot decide on your own request');
      if (x.status !== 'pending') throw conflict('This request is already closed');
      const status = decision === 'confirm' ? 'confirmed' : 'rejected';
      await q.query(`UPDATE advance_requests SET status = $2, decided_by = $3, decided_at = now() WHERE id = $1`, [x.id, status, a.id]);
      await audit(q, a.id, `advance.${decision}`, 'advance', x.id, { status: x.status }, { status });
      await notify(q, { to: x.employee_id, type: `advance_${status}`, title: status === 'confirmed' ? 'تم تأكيد طلبك المالي' : 'تم رفض طلبك المالي',
        body: `${x.amount_egp} جنيه`, entity: 'advance', entityId: x.id, dedupeKey: `adv:${x.id}:${status}` });
      return status;
    });
    return ok({ status: out });
  });

  r.post('/advances/:id/cancel', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM advance_requests WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x || (x.employee_id !== a.id && x.created_by !== a.id && !canDecideAdvances(a))) throw notFound();
      if (x.status !== 'pending') throw conflict('This request can no longer be cancelled');
      await q.query(`UPDATE advance_requests SET status = 'cancelled', decided_at = now() WHERE id = $1`, [x.id]);
      await audit(q, a.id, 'advance.cancel', 'advance', x.id);
    });
    return ok({ ok: true });
  });

  r.get('/advances/:id/attachment', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const x = await one(db, `SELECT employee_id, attachment FROM advance_requests WHERE id = $1`, [req.params.id]);
    if (!x || !x.attachment) throw notFound();
    if (x.employee_id !== a.id && !has(a, 'finance.read') && !has(a, 'request.approve_hr')) throw notFound();
    return { binary: x.attachment, contentType: 'image/jpeg' };
  });

  // ------------------------------------------------------------------ holiday periods
  r.get('/holiday-periods', async (req) => {
    await authenticate(db, req);
    const rows = await db.query(`
      SELECT group_id AS id, min(day) AS from_date, max(day) AS to_date, min(holiday_type) AS holiday_type,
             min(description) AS description, min(name) AS name, count(*)::int AS days
        FROM holidays GROUP BY group_id ORDER BY min(day) DESC`);
    return ok({ periods: rows.rows });
  });

  const savePeriod = async (actorId: string, groupId: string, b: Record<string, unknown>, replace: boolean) => {
    const from = date(b, 'fromDate')!, to = date(b, 'toDate')!;
    if (to < from) throw invalid('The end date must be on or after the start date', { field: 'toDate' });
    if (daysBetween(from, to) > 60) throw invalid('A holiday period cannot exceed 60 days', { field: 'toDate' });
    const type = str(b, 'holidayType', { optional: true, max: 60 }) ?? 'عطلة رسمية';
    const description = str(b, 'description', { optional: true, max: 300 }) ?? '';
    const name = description || type;
    await db.tx(async (q) => {
      if (replace) await q.query(`DELETE FROM holidays WHERE group_id = $1`, [groupId]);
      for (let i = 0; i <= daysBetween(from, to); i++) {
        const d = new Date(Date.parse(from + 'T00:00:00Z') + i * 86400000).toISOString().slice(0, 10);
        const clash = await one(q, `SELECT 1 FROM holidays WHERE day = $1`, [d]);
        if (clash) throw conflict(`${d} is already a holiday`);
        await q.query(`INSERT INTO holidays (day, name, group_id, holiday_type, description) VALUES ($1,$2,$3,$4,$5)`,
          [d, name, groupId, type, description]);
      }
      await audit(q, actorId, replace ? 'holiday.update' : 'holiday.create', 'holiday', groupId, undefined, { from, to, type, description });
    });
  };

  r.post('/holiday-periods', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'attendance.config');
    const id = randomUUID();
    await savePeriod(a.id, id, obj(req.body), false);
    return ok({ id }, 201);
  });
  r.put('/holiday-periods/:id', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'attendance.config');
    if (!isUuid(req.params.id)) throw notFound();
    if (!(await one(db, `SELECT 1 FROM holidays WHERE group_id = $1`, [req.params.id]))) throw notFound();
    await savePeriod(a.id, req.params.id, obj(req.body), true);
    return ok({ id: req.params.id });
  });
  r.delete('/holiday-periods/:id', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'attendance.config');
    if (!isUuid(req.params.id)) throw notFound();
    const n = await db.query(`DELETE FROM holidays WHERE group_id = $1`, [req.params.id]);
    if (!n.rowCount) throw notFound();
    await audit(db, a.id, 'holiday.delete', 'holiday', req.params.id);
    return ok({ ok: true });
  });

  // ------------------------------------------------------------------ admin-sent notifications
  r.post('/notifications/send', async (req) => {
    const a = await authenticate(db, req);
    const canAll = has(a, 'employee.manage') || has(a, 'attendance.read_all') || has(a, 'notification.send');
    const canTeam = has(a, 'employee.read_team');
    if (!canAll && !canTeam) throw forbidden();
    const b = obj(req.body);
    const title = reqStr(b, 'title', { min: 2, max: 150 });
    const body = reqStr(b, 'content', { min: 1, max: 2000 });
    const category = str(b, 'category', { optional: true, max: 60 }) ?? 'عام';
    const list = Array.isArray(b.recipientIds) ? b.recipientIds.filter((x): x is string => typeof x === 'string' && isUuid(x)) : [];
    if (!list.length || list.length > 500) throw invalid('Choose 1–500 recipients', { field: 'recipientIds' });
    const allowed = canAll ? null : await readableIds(db, a, 'employee');
    const targets = allowed ? list.filter((x) => allowed.includes(x)) : list;
    if (!targets.length) throw forbidden();
    const batch = `msg:${randomUUID()}`;
    await db.tx(async (q) => {
      for (const to of targets) {
        await q.query(`INSERT INTO notifications (recipient_id, type, title, body, dedupe_key, sender_id, category)
                       SELECT $1, 'message', $2, $3, $4, $5, $6 WHERE EXISTS (SELECT 1 FROM employees WHERE id = $1 AND status = 'active')`,
          [to, title, body, batch, a.id, category]);
      }
      await audit(q, a.id, 'notification.send', 'notification', null, undefined, { batch, count: targets.length, title });
    });
    return ok({ sent: targets.length }, 201);
  });

  r.get('/notifications/sent', async (req) => {
    const a = await authenticate(db, req);
    const rows = await db.query(`
      SELECT n.dedupe_key AS batch, min(n.title) AS title, min(n.body) AS body, min(n.category) AS category, min(n.created_at) AS created_at,
             count(*)::int AS recipients, count(n.read_at)::int AS read,
             string_agg(e.full_name, '، ' ORDER BY e.full_name) AS recipient_names
        FROM notifications n JOIN employees e ON e.id = n.recipient_id
       WHERE n.sender_id = $1 GROUP BY n.dedupe_key ORDER BY min(n.created_at) DESC LIMIT 200`, [a.id]);
    return ok({ sent: rows.rows });
  });

  r.delete('/notifications/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const n = await db.query(`DELETE FROM notifications WHERE id = $1 AND recipient_id = $2`, [req.params.id, a.id]);
    if (!n.rowCount) throw notFound();
    return ok({ ok: true });
  });
  r.delete('/notifications', async (req) => {
    const a = await authenticate(db, req);
    await db.query(`DELETE FROM notifications WHERE recipient_id = $1`, [a.id]);
    return ok({ ok: true });
  });

  // ------------------------------------------------------------------ signed media (no auth header needed)
  r.get('/media/:kind/:id', async (req) => {
    const { kind, id } = req.params;
    if (!isUuid(id) || !['photo', 'selfie', 'advance'].includes(kind)) throw notFound();
    if (!(await verifyMedia(db, kind, id, req.query.get('exp'), req.query.get('sig'), clock()))) throw notFound();
    const row = kind === 'photo' ? await one(db, `SELECT photo AS data, photo_mime AS mime FROM employees WHERE id = $1`, [id])
      : kind === 'selfie' ? await one(db, `SELECT image AS data, mime FROM attendance_selfies WHERE attendance_id = $1`, [id])
      : await one(db, `SELECT attachment AS data, 'image/jpeg' AS mime FROM advance_requests WHERE id = $1`, [id]);
    if (!row?.data) throw notFound();
    return { binary: row.data, contentType: row.mime ?? 'image/jpeg' };
  });

  /** Signed links for photos of employees the caller may see (and selfies of attendance days they may read). */
  r.post('/media/links', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const now = clock();
    const out: Record<string, string> = {};
    const photoIds = Array.isArray(b.photos) ? b.photos.filter((x): x is string => typeof x === 'string' && isUuid(x)).slice(0, 500) : [];
    if (photoIds.length) {
      const rows = await db.query(`SELECT id FROM employees WHERE id = ANY($1::uuid[]) AND photo IS NOT NULL`, [photoIds]);
      for (const x of rows.rows) out[`photo:${x.id}`] = await signedMediaPath(db, 'photo', x.id, now);
    }
    const selfieIds = Array.isArray(b.selfies) ? b.selfies.filter((x): x is string => typeof x === 'string' && isUuid(x)).slice(0, 500) : [];
    if (selfieIds.length) {
      const ids = await readableIds(db, a, 'attendance');
      const rows = await db.query(`SELECT attendance_id, employee_id FROM attendance_selfies WHERE attendance_id = ANY($1::uuid[])`, [selfieIds]);
      for (const x of rows.rows) if (!ids || ids.includes(x.employee_id)) out[`selfie:${x.attendance_id}`] = await signedMediaPath(db, 'selfie', x.attendance_id, now);
    }
    return ok({ links: out });
  });

  // ------------------------------------------------------------------ own profile (contact + bank)
  r.patch('/me/profile', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const before = await one(db, `SELECT email, phone, bank_name, account_holder, iban, account_number FROM employees WHERE id = $1`, [a.id]);
    const f = {
      email: b.email === undefined ? before.email : (str(b, 'email', { optional: true, pattern: /^[^\s@]+@[^\s@]+\.[^\s@]+$/, max: 160 }) ?? null),
      phone: b.phone === undefined ? before.phone : (str(b, 'phone', { optional: true, pattern: /^\+?[0-9]{8,15}$/ }) ?? null),
      bank_name: b.bankName === undefined ? before.bank_name : (str(b, 'bankName', { optional: true, max: 120 }) ?? null),
      account_holder: b.accountHolder === undefined ? before.account_holder : (str(b, 'accountHolder', { optional: true, max: 120 }) ?? null),
      iban: b.iban === undefined ? before.iban : (str(b, 'iban', { optional: true, max: 40 }) ?? null),
      account_number: b.accountNumber === undefined ? before.account_number : (str(b, 'accountNumber', { optional: true, max: 40 }) ?? null),
    };
    await db.tx(async (q) => {
      await q.query(`UPDATE employees SET email=$2, phone=$3, bank_name=$4, account_holder=$5, iban=$6, account_number=$7, updated_at = now() WHERE id = $1`,
        [a.id, f.email, f.phone, f.bank_name, f.account_holder, f.iban, f.account_number]);
      await audit(q, a.id, 'employee.self_update', 'employee', a.id, before, f);
    });
    return ok({ ok: true });
  });

  r.get('/me/profile', async (req) => {
    const a = await authenticate(db, req);
    const e = await one(db, `
      SELECT e.id, e.code, e.full_name, e.email, e.phone, e.job_title, e.role_key, r.name_ar AS role_name_ar, r.name_en AS role_name_en,
             e.status, e.joining_date, e.created_at, e.updated_at, e.bank_name, e.account_holder, e.iban, e.account_number, e.notes,
             (e.photo IS NOT NULL) AS has_photo, t.name AS team_name, m.full_name AS manager_name, d.name_ar AS department_name,
             ws.name AS schedule_name, ws.start_time, ws.end_time, ws.weekend_days
        FROM employees e JOIN roles r ON r.key = e.role_key
        LEFT JOIN teams t ON t.id = e.team_id LEFT JOIN employees m ON m.id = COALESCE(e.sales_manager_id, t.manager_id)
        LEFT JOIN departments d ON d.id = e.department_id
        LEFT JOIN work_schedules ws ON ws.id = COALESCE(e.schedule_id, (SELECT id FROM work_schedules WHERE is_default))
       WHERE e.id = $1`, [a.id]);
    const s = await one(db, `SELECT company_name_ar, company_name_en FROM company_settings`);
    const today = local(clock()).date;
    return ok({ profile: e, company: s, today });
  });
};
