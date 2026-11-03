import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { monthParam, num, obj, str, uuid, isUuid } from '../http/validate.ts';
import { assertCanRead, audit, authenticate, has, isInTeam, readableIds, type Actor } from '../auth/context.ts';
import { notify } from './notify.ts';

export const DIMENSIONS = ['discipline', 'attendance', 'communication', 'follow_up', 'teamwork',
  'sales_performance', 'initiative', 'professional_behavior'] as const;
const CAMEL: Record<string, string> = {
  discipline: 'discipline', attendance: 'attendance', communication: 'communication', follow_up: 'followUp',
  teamwork: 'teamwork', sales_performance: 'salesPerformance', initiative: 'initiative', professional_behavior: 'professionalBehavior',
};

/** Average of scored dimensions (1–5) as a percentage; null when nothing is scored. */
export function overall(e: any): number | null {
  const scored = DIMENSIONS.map((d) => e[d]).filter((v) => typeof v === 'number');
  if (!scored.length) return null;
  return Math.round((scored.reduce((s, v) => s + v, 0) / (scored.length * 5)) * 1000) / 10;
}

async function evaluatorKind(q: Q, a: Actor, employeeId: string): Promise<'manager' | 'hr' | 'owner'> {
  if (employeeId === a.id) throw forbidden('You cannot evaluate yourself');
  if (a.role === 'owner') return 'owner';
  if (has(a, 'evaluation.write_all')) return 'hr';
  if (has(a, 'evaluation.write_team') && await isInTeam(q, a.id, employeeId)) return 'manager';
  throw notFound('Employee not found');
}

function readBody(b: Record<string, unknown>) {
  const out: Record<string, unknown> = {};
  for (const d of DIMENSIONS) {
    const k = CAMEL[d];
    if (k in b) out[d] = b[k] === null ? null : num(b, k, { int: true, min: 1, max: 5 });
  }
  for (const [k, col] of [['feedback', 'feedback'], ['strengths', 'strengths'], ['improvements', 'improvements'], ['improvementPlan', 'improvement_plan']]) {
    if (k in b) out[col] = str(b, k, { optional: true, max: 4000 }) ?? '';
  }
  return out;
}

function shape(e: any) { return { ...e, overallPercent: overall(e) }; }

export const evaluationsModule: Module = (r, { db }) => {
  r.post('/evaluations', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const employeeId = uuid(b, 'employeeId')!;
    const period = monthParam(typeof b.month === 'string' ? b.month : null);
    const kind = await evaluatorKind(db, a, employeeId);
    const fields = readBody(b);
    const cols = Object.keys(fields);
    const e = await db.tx(async (q) => {
      const exists = await one(q, `SELECT id FROM evaluations WHERE employee_id = $1 AND period = $2 AND evaluator_kind = $3`, [employeeId, period, kind]);
      if (exists) throw conflict('An evaluation of this kind already exists for this month');
      const row = await one(q, `INSERT INTO evaluations (employee_id, evaluator_id, evaluator_kind, period ${cols.map((c) => ', ' + c).join('')})
        VALUES ($1,$2,$3,$4 ${cols.map((_, i) => `, $${i + 5}`).join('')}) RETURNING *`, [employeeId, a.id, kind, period, ...cols.map((c) => fields[c])]);
      await audit(q, a.id, 'evaluation.create', 'evaluation', row.id, undefined, { employeeId, period, kind });
      return row;
    });
    return ok({ evaluation: shape(e) }, 201);
  });

  r.patch('/evaluations/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const fields = readBody(obj(req.body));
    const cols = Object.keys(fields);
    if (!cols.length) throw invalid('Nothing to update');
    const e = await db.tx(async (q) => {
      const row = await one(q, `SELECT * FROM evaluations WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!row || row.evaluator_id !== a.id) throw notFound();
      if (row.status === 'published') throw conflict('Published evaluations cannot be edited');
      const upd = await one(q, `UPDATE evaluations SET ${cols.map((c, i) => `${c} = $${i + 2}`).join(', ')} WHERE id = $1 RETURNING *`,
        [row.id, ...cols.map((c) => fields[c])]);
      await audit(q, a.id, 'evaluation.update', 'evaluation', row.id);
      return upd;
    });
    return ok({ evaluation: shape(e) });
  });

  r.post('/evaluations/:id/publish', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const e = await db.tx(async (q) => {
      const row = await one(q, `SELECT * FROM evaluations WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!row || row.evaluator_id !== a.id) throw notFound();
      if (row.status === 'published') throw conflict('Already published');
      const missing = DIMENSIONS.filter((d) => row[d] === null);
      if (missing.length) throw invalid('All eight dimensions must be scored before publishing', { missing });
      const upd = await one(q, `UPDATE evaluations SET status = 'published', published_at = now() WHERE id = $1 RETURNING *`, [row.id]);
      await audit(q, a.id, 'evaluation.publish', 'evaluation', row.id);
      await notify(q, { to: row.employee_id, type: 'evaluation_published', title: 'تم نشر تقييم أدائك',
        body: String(row.period).slice(0, 7), entity: 'evaluation', entityId: row.id, dedupeKey: `eval:${row.id}:published` });
      return upd;
    });
    return ok({ evaluation: shape(e) });
  });

  r.delete('/evaluations/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const row = await one(db, `SELECT * FROM evaluations WHERE id = $1`, [req.params.id]);
    if (!row || row.evaluator_id !== a.id) throw notFound();
    if (row.status === 'published') throw conflict('Published evaluations are permanent');
    await db.tx(async (q) => {
      await q.query(`DELETE FROM evaluations WHERE id = $1`, [row.id]);
      await audit(q, a.id, 'evaluation.delete_draft', 'evaluation', row.id);
    });
    return ok({ ok: true });
  });

  r.get('/evaluations', async (req) => {
    const a = await authenticate(db, req);
    const vals: unknown[] = []; const where: string[] = [];
    const employeeId = req.query.get('employeeId');
    if (employeeId) {
      if (!isUuid(employeeId)) throw notFound();
      const scope = await assertCanRead(db, a, employeeId, 'evaluation');
      vals.push(employeeId); where.push(`v.employee_id = $${vals.length}`);
      // employees only ever see their own *published* evaluations
      if (scope === 'self') where.push(`v.status = 'published'`);
      else { vals.push(a.id); where.push(`(v.status = 'published' OR v.evaluator_id = $${vals.length})`); }
    } else {
      const ids = await readableIds(db, a, 'evaluation');
      vals.push(a.id);
      const me = vals.length;
      if (ids) { vals.push(ids); where.push(`(v.employee_id = ANY($${vals.length}::uuid[]) OR v.evaluator_id = $${me})`); }
      where.push(`(v.status = 'published' OR v.evaluator_id = $${me})`);
      where.push(`NOT (v.employee_id = $${me} AND v.status <> 'published')`);
    }
    const month = req.query.get('month');
    if (month) { vals.push(monthParam(month)); where.push(`v.period = $${vals.length}`); }
    const rows = await db.query(`
      SELECT v.*, e.full_name AS employee_name, x.full_name AS evaluator_name
        FROM evaluations v JOIN employees e ON e.id = v.employee_id JOIN employees x ON x.id = v.evaluator_id
       WHERE ${where.join(' AND ')} ORDER BY v.period DESC, v.created_at DESC LIMIT 300`, vals);
    return ok({ evaluations: rows.rows.map(shape) });
  });
};
