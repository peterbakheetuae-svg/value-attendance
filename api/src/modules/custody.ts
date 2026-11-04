import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { date, obj, oneOf, reqStr, str, isUuid } from '../http/validate.ts';
import { audit, authenticate, has, isInTeam, type Actor } from '../auth/context.ts';
import { local } from '../lib/time.ts';
import { notify } from './notify.ts';

const TYPES = ['laptop', 'mobile', 'sim', 'keys', 'equipment', 'car', 'other'] as const;
const CONDITIONS = ['new', 'good', 'fair', 'damaged'] as const;
const TYPE_AR: Record<string, string> = { laptop: 'لابتوب', mobile: 'موبايل', sim: 'شريحة', keys: 'مفاتيح', equipment: 'معدات', car: 'عربية', other: 'أخرى' };

const COLS = `c.*, e.full_name AS employee_name, e.code AS employee_code, ab.full_name AS assigned_by_name, rb.full_name AS received_by_name`;
const FROM = `FROM custody_items c JOIN employees e ON e.id = c.employee_id JOIN employees ab ON ab.id = c.assigned_by
  LEFT JOIN employees rb ON rb.id = c.received_by`;

export const canManageCustody = (a: Actor) => has(a, 'custody.manage');

async function canReadCustody(q: Q, a: Actor, employeeId: string) {
  if (employeeId === a.id || has(a, 'custody.manage') || has(a, 'custody.read_all')) return true;
  return has(a, 'custody.read_team') && await isInTeam(q, a.id, employeeId);
}

/** Employee custody / company assets: assign, return, report lost — every step kept as history. */
export const custodyModule: Module = (r, { db, clock }) => {
  r.get('/employees/:id/custody', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id) || !(await canReadCustody(db, a, req.params.id))) throw notFound('Employee not found');
    const rows = await db.query(`SELECT ${COLS} ${FROM} WHERE c.employee_id = $1 ORDER BY (c.status = 'assigned') DESC, c.assigned_on DESC, c.created_at DESC`, [req.params.id]);
    return ok({ items: rows.rows, canManage: canManageCustody(a) });
  });

  r.get('/custody', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'custody.manage') && !has(a, 'custody.read_all')) throw forbidden();
    const status = req.query.get('status');
    const vals: unknown[] = []; const where: string[] = [];
    if (status) { if (!['assigned', 'returned', 'lost'].includes(status)) throw invalid('Bad status'); vals.push(status); where.push(`c.status = $1`); }
    const rows = await db.query(`SELECT ${COLS} ${FROM} ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
                                  ORDER BY c.created_at DESC LIMIT 500`, vals);
    return ok({ items: rows.rows, canManage: canManageCustody(a) });
  });

  r.post('/employees/:id/custody', async (req) => {
    const a = await authenticate(db, req);
    if (!canManageCustody(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const emp = await one(db, `SELECT id, status FROM employees WHERE id = $1`, [req.params.id]);
    if (!emp) throw notFound();
    if (emp.status !== 'active') throw invalid('The employee is not active');
    const b = obj(req.body);
    const item = await db.tx(async (q) => {
      const c = await one(q, `INSERT INTO custody_items (employee_id, asset_name, asset_type, description, serial_no, assigned_on, assigned_by, condition_out, notes)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *`, [emp.id, reqStr(b, 'assetName', { min: 2, max: 120 }), oneOf(b, 'assetType', TYPES),
        str(b, 'description', { optional: true, max: 1000 }) ?? '', str(b, 'serialNo', { optional: true, max: 120 }) || null,
        date(b, 'assignedOn', true) ?? local(clock()).date, a.id, oneOf(b, 'condition', CONDITIONS, true) ?? 'good',
        str(b, 'notes', { optional: true, max: 2000 }) ?? '']);
      await audit(q, a.id, 'custody.assign', 'custody', c.id, undefined, c);
      if (emp.id !== a.id) {
        await notify(q, { to: emp.id, type: 'custody_assigned', title: 'تم تسليمك عهدة جديدة',
          body: `${TYPE_AR[c.asset_type]}: ${c.asset_name}`, entity: 'custody', entityId: c.id, dedupeKey: `custody:${c.id}:assigned` });
      }
      return c;
    });
    return ok({ item }, 201);
  });

  r.patch('/custody/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!canManageCustody(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const out = await db.tx(async (q) => {
      const before = await one(q, `SELECT * FROM custody_items WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!before) throw notFound();
      if (before.status !== 'assigned') throw conflict('A closed custody record cannot be edited');
      const c = await one(q, `UPDATE custody_items SET asset_name = $2, description = $3, serial_no = $4, notes = $5 WHERE id = $1 RETURNING *`, [before.id,
        str(b, 'assetName', { optional: true, min: 2, max: 120 }) ?? before.asset_name, str(b, 'description', { optional: true, max: 1000 }) ?? before.description,
        'serialNo' in b ? (str(b, 'serialNo', { optional: true, max: 120 }) || null) : before.serial_no, str(b, 'notes', { optional: true, max: 2000 }) ?? before.notes]);
      await audit(q, a.id, 'custody.update', 'custody', c.id, before, c);
      return c;
    });
    return ok({ item: out });
  });

  /** Close a custody record: returned (with condition) or lost. Concurrent closes → one wins. */
  r.post('/custody/:id/close', async (req) => {
    const a = await authenticate(db, req);
    if (!canManageCustody(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const outcome = oneOf(b, 'outcome', ['returned', 'lost'] as const)!;
    const out = await db.tx(async (q) => {
      const before = await one(q, `SELECT * FROM custody_items WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!before) throw notFound();
      if (before.status !== 'assigned') throw conflict('This custody record is already closed');
      const on = date(b, 'returnedOn', true) ?? local(clock()).date;
      if (on < String(before.assigned_on instanceof Date ? before.assigned_on.toISOString().slice(0, 10) : before.assigned_on).slice(0, 10)) {
        throw invalid('Return date is before the assignment date', { field: 'returnedOn' });
      }
      const note = str(b, 'notes', { optional: true, max: 2000 });
      const c = await one(q, `UPDATE custody_items SET status = $2, returned_on = $3, condition_in = $4, received_by = $5, closed_at = now(),
          notes = CASE WHEN $6::text IS NULL OR $6 = '' THEN notes ELSE trim(notes || E'\n' || $6) END WHERE id = $1 RETURNING *`, [before.id, outcome,
        outcome === 'returned' ? on : null, outcome === 'returned' ? oneOf(b, 'condition', CONDITIONS)! : null, a.id, note ?? null]);
      await audit(q, a.id, outcome === 'returned' ? 'custody.return' : 'custody.lost', 'custody', c.id, before, c);
      return c;
    });
    return ok({ item: out });
  });
};
