import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { forbidden, invalid, notFound } from '../http/errors.ts';
import { bool, monthParam, num, obj, oneOf, reqStr, str, uuid, isUuid } from '../http/validate.ts';
import { assertCanRead, audit, authenticate, has, isInTeam, readableIds, requirePerm, type Actor } from '../auth/context.ts';
import { addMonths, local } from '../lib/time.ts';

const MEASURES = ['count', 'percent', 'amount_egp', 'score'] as const;

export type KpiState = 'not_evaluated' | 'in_progress' | 'completed' | 'below_target';

export function achievement(actual: number | null, target: number, higherIsBetter: boolean): number | null {
  if (actual === null) return null;
  if (higherIsBetter) return Math.round((actual / target) * 1000) / 10;
  if (actual === 0) return 100;
  return Math.round((target / actual) * 1000) / 10;
}

/** Per-KPI view + set totals. Missing data stays null — never zero. */
export function summarize(rows: any[]) {
  const items = rows.map((r) => {
    const ach = achievement(r.actual, r.target_snapshot, r.higher_is_better);
    const weighted = ach === null ? null : Math.round(Math.min(ach, 100) * r.weight_snapshot) / 100;
    let state: KpiState = r.state;
    if (r.state === 'completed' && ach !== null && ach < 100) state = 'below_target';
    return { id: r.id, kpiId: r.kpi_id, key: r.key, nameAr: r.name_ar, nameEn: r.name_en, measurementType: r.measurement_type,
      weight: r.weight_snapshot, target: r.target_snapshot, actual: r.actual, achievementPercent: ach,
      weightedScore: weighted, state, updatedAt: r.updated_at, enteredBy: r.entered_by_name ?? null };
  });
  const evaluated = items.filter((i) => i.weightedScore !== null);
  const status = !items.length ? 'no_kpis'
    : !evaluated.length ? 'not_evaluated'
    : items.every((i) => i.state === 'completed' || i.state === 'below_target') ? 'completed' : 'in_progress';
  const score = evaluated.length ? Math.round(evaluated.reduce((s, i) => s + (i.weightedScore as number), 0) * 100) / 100 : null;
  const evaluatedWeight = evaluated.reduce((s, i) => s + i.weight, 0);
  return { items, status, weightedScore: score, evaluatedWeight,
    belowTarget: status === 'completed' && score !== null && score < 100 };
}

/** The set that applies to an employee: own employee-scoped set, else their job title's set. */
async function activeSetFor(q: Q, employeeId: string) {
  return one(q, `
    SELECT s.* FROM kpi_sets s, employees e
     WHERE e.id = $1 AND s.active AND ((s.scope_type = 'employee' AND s.employee_id = e.id)
        OR (s.scope_type = 'job_title' AND s.job_title = e.job_title))
     ORDER BY (s.scope_type = 'employee') DESC LIMIT 1`, [employeeId]);
}

/** Snapshot the applicable set into result rows for a period (idempotent). Past snapshots are never touched. */
export async function ensurePeriod(q: Q, employeeId: string, period: string) {
  const exists = await one(q, `SELECT 1 FROM kpi_results WHERE employee_id = $1 AND period = $2 LIMIT 1`, [employeeId, period]);
  if (exists) return;
  const set = await activeSetFor(q, employeeId);
  if (!set) return;
  await q.query(`
    INSERT INTO kpi_results (employee_id, period, set_id, kpi_id, weight_snapshot, target_snapshot)
    SELECT $1, $2, i.set_id, i.kpi_id, i.weight, i.target FROM kpi_set_items i WHERE i.set_id = $3
    ON CONFLICT (employee_id, period, kpi_id) DO NOTHING`, [employeeId, period, set.id]);
}

export async function loadPeriod(q: Q, employeeId: string, period: string) {
  const rows = await q.query(`
    SELECT r.*, d.key, d.name_ar, d.name_en, d.measurement_type, d.higher_is_better, x.full_name AS entered_by_name
      FROM kpi_results r JOIN kpi_definitions d ON d.id = r.kpi_id LEFT JOIN employees x ON x.id = r.entered_by
     WHERE r.employee_id = $1 AND r.period = $2 ORDER BY r.weight_snapshot DESC, d.name_ar`, [employeeId, period]);
  return summarize(rows.rows);
}

async function canEnter(q: Q, a: Actor, employeeId: string) {
  if (employeeId === a.id) return false;
  if (has(a, 'kpi.enter_all')) return true;
  return has(a, 'kpi.enter_team') && await isInTeam(q, a.id, employeeId);
}

export const kpiModule: Module = (r, { db, clock }) => {
  const currentPeriod = () => local(clock()).date.slice(0, 7) + '-01';

  // ---------------------------------------------------------------- definitions
  r.get('/kpi/definitions', async (req) => {
    await authenticate(db, req);
    return ok({ definitions: (await db.query(`SELECT * FROM kpi_definitions ORDER BY active DESC, name_ar`)).rows });
  });
  r.post('/kpi/definitions', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'kpi.config');
    const b = obj(req.body);
    const d = await one(db, `INSERT INTO kpi_definitions (key, name_ar, name_en, measurement_type, higher_is_better, created_by)
      VALUES ($1,$2,$3,$4,$5,$6) RETURNING *`, [reqStr(b, 'key', { pattern: /^[a-z0-9_]{2,40}$/ }),
      reqStr(b, 'nameAr', { min: 2, max: 80 }), str(b, 'nameEn', { optional: true, max: 80 }) ?? '',
      oneOf(b, 'measurementType', MEASURES), bool(b, 'higherIsBetter') ?? true, a.id]);
    await audit(db, a.id, 'kpi.definition_create', 'kpi_definition', d.id, undefined, d);
    return ok({ definition: d }, 201);
  });
  r.patch('/kpi/definitions/:id', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'kpi.config');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const before = await one(db, `SELECT * FROM kpi_definitions WHERE id = $1`, [req.params.id]);
    if (!before) throw notFound();
    // measurement semantics of a used KPI are frozen; names and activity may change
    const d = await one(db, `UPDATE kpi_definitions SET name_ar = $2, name_en = $3, active = $4 WHERE id = $1 RETURNING *`,
      [before.id, str(b, 'nameAr', { optional: true, min: 2, max: 80 }) ?? before.name_ar,
       str(b, 'nameEn', { optional: true, max: 80 }) ?? before.name_en, bool(b, 'active') ?? before.active]);
    await audit(db, a.id, 'kpi.definition_update', 'kpi_definition', d.id, before, d);
    return ok({ definition: d });
  });

  // ---------------------------------------------------------------- sets (versioned)
  r.get('/kpi/sets', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'kpi.config', 'kpi.read_all', 'kpi.read_team');
    const includeRetired = req.query.get('includeRetired') === '1';
    const sets = await db.query(`
      SELECT s.*, e.full_name AS employee_name,
             json_agg(json_build_object('kpiId', i.kpi_id, 'nameAr', d.name_ar, 'nameEn', d.name_en,
               'measurementType', d.measurement_type, 'weight', i.weight, 'target', i.target) ORDER BY i.weight DESC) AS items
        FROM kpi_sets s JOIN kpi_set_items i ON i.set_id = s.id JOIN kpi_definitions d ON d.id = i.kpi_id
        LEFT JOIN employees e ON e.id = s.employee_id
       ${includeRetired ? '' : 'WHERE s.active'} GROUP BY s.id, e.full_name ORDER BY s.active DESC, s.name, s.version DESC`);
    return ok({ sets: sets.rows });
  });

  /**
   * Create a set, or a new version replacing the active set for the same scope.
   * Items + weights are validated together; the DB re-checks the 100 % rule at COMMIT.
   */
  r.post('/kpi/sets', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'kpi.config');
    const b = obj(req.body);
    const scopeType = oneOf(b, 'scopeType', ['job_title', 'employee'] as const)!;
    const jobTitle = scopeType === 'job_title' ? reqStr(b, 'jobTitle', { min: 2, max: 80 }) : null;
    const employeeId = scopeType === 'employee' ? uuid(b, 'employeeId')! : null;
    const name = reqStr(b, 'name', { min: 2, max: 80 });
    if (!Array.isArray(b.items) || !b.items.length || b.items.length > 20) throw invalid('items must list 1–20 KPIs', { field: 'items' });
    const items = b.items.map((it: any, i: number) => {
      const o = obj(it);
      return { kpiId: uuid(o, 'kpiId')!, weight: num(o, 'weight', { min: 0.01, max: 100 })!, target: num(o, 'target', { min: 0.01, max: 1e12 })!, i };
    });
    if (new Set(items.map((x: any) => x.kpiId)).size !== items.length) throw invalid('A KPI appears twice', { field: 'items' });
    const total = Math.round(items.reduce((s: number, x: any) => s + x.weight, 0) * 100) / 100;
    if (total !== 100) throw invalid(`Weights must total 100% (currently ${total}%)`, { field: 'items', total });
    const set = await db.tx(async (q) => {
      const defs = await q.query(`SELECT id FROM kpi_definitions WHERE id = ANY($1::uuid[]) AND active`, [items.map((x: any) => x.kpiId)]);
      if (defs.rowCount !== items.length) throw invalid('Every KPI must exist and be active', { field: 'items' });
      if (employeeId && !(await one(q, `SELECT 1 FROM employees WHERE id = $1`, [employeeId]))) throw invalid('Employee not found', { field: 'employeeId' });
      const prev = await one(q, `SELECT * FROM kpi_sets WHERE active AND scope_type = $1
                                   AND (job_title = $2 OR employee_id = $3) FOR UPDATE`, [scopeType, jobTitle, employeeId]);
      if (prev) await q.query(`UPDATE kpi_sets SET active = false, retired_at = now() WHERE id = $1`, [prev.id]);
      const s = await one(q, `INSERT INTO kpi_sets (name, scope_type, job_title, employee_id, version, created_by)
                              VALUES ($1,$2,$3,$4,$5,$6) RETURNING *`, [name, scopeType, jobTitle, employeeId, (prev?.version ?? 0) + 1, a.id]);
      for (const it of items) await q.query(`INSERT INTO kpi_set_items (set_id, kpi_id, weight, target) VALUES ($1,$2,$3,$4)`, [s.id, it.kpiId, it.weight, it.target]);
      await audit(q, a.id, prev ? 'kpi.set_new_version' : 'kpi.set_create', 'kpi_set', s.id, prev ? { previous: prev.id } : undefined, { name, scopeType, jobTitle, employeeId, items });
      return s;
    });
    return ok({ set }, 201);
  });

  r.post('/kpi/sets/:id/retire', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'kpi.config');
    if (!isUuid(req.params.id)) throw notFound();
    const s = await one(db, `UPDATE kpi_sets SET active = false, retired_at = now() WHERE id = $1 AND active RETURNING id`, [req.params.id]);
    if (!s) throw notFound();
    await audit(db, a.id, 'kpi.set_retire', 'kpi_set', s.id);
    return ok({ ok: true });
  });

  // ---------------------------------------------------------------- results
  r.get('/kpi/employees/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    await assertCanRead(db, a, req.params.id, 'kpi');
    const period = req.query.get('month') ? monthParam(req.query.get('month')) : currentPeriod();
    if (period <= currentPeriod()) await ensurePeriod(db, req.params.id, period);
    const cur = await loadPeriod(db, req.params.id, period);
    const prev = await loadPeriod(db, req.params.id, addMonths(period, -1));
    const trend: { period: string; weightedScore: number | null; status: string }[] = [];
    for (let i = 5; i >= 0; i--) {
      const p = addMonths(period, -i);
      const s = await loadPeriod(db, req.params.id, p);
      trend.push({ period: p, weightedScore: s.weightedScore, status: s.status });
    }
    return ok({ period, current: cur, previous: { period: addMonths(period, -1), weightedScore: prev.weightedScore, status: prev.status },
      change: cur.weightedScore !== null && prev.weightedScore !== null ? Math.round((cur.weightedScore - prev.weightedScore) * 100) / 100 : null,
      trend, canEnter: await canEnter(db, a, req.params.id) });
  });

  r.put('/kpi/results/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const state = oneOf(b, 'state', ['not_evaluated', 'in_progress', 'completed'] as const)!;
    const actual = state === 'not_evaluated' ? null : num(b, 'actual', { min: 0, max: 1e12 })!;
    await db.tx(async (q) => {
      const row = await one(q, `SELECT * FROM kpi_results WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!row) throw notFound();
      if (!(await canEnter(q, a, row.employee_id))) {
        if (row.employee_id === a.id) throw forbidden('You cannot enter your own KPI results');
        await assertCanRead(q, a, row.employee_id, 'kpi');
        throw forbidden();
      }
      await q.query(`UPDATE kpi_results SET actual = $2, state = $3, entered_by = $4, updated_at = now() WHERE id = $1`, [row.id, actual, state, a.id]);
      await audit(q, a.id, 'kpi.result_update', 'kpi_result', row.id, { actual: row.actual, state: row.state }, { actual, state });
    });
    return ok({ ok: true });
  });

  /** Team/company KPI overview for a month. */
  r.get('/kpi/overview', async (req) => {
    const a = await authenticate(db, req);
    requirePerm(a, 'kpi.read_all', 'kpi.read_team');
    const period = req.query.get('month') ? monthParam(req.query.get('month')) : currentPeriod();
    const ids = await readableIds(db, a, 'kpi');
    const emps = await db.query(`SELECT e.id, e.full_name, e.code, e.job_title, t.name AS team_name FROM employees e
       LEFT JOIN teams t ON t.id = e.team_id WHERE e.status = 'active' AND e.role_key IN ('sales_employee','sales_manager')
       AND ($1::uuid[] IS NULL OR e.id = ANY($1::uuid[])) AND e.id <> $2 ORDER BY e.full_name`, [ids, a.id]);
    const out = [];
    for (const e of emps.rows) {
      if (period <= currentPeriod()) await ensurePeriod(db, e.id, period);
      const s = await loadPeriod(db, e.id, period);
      out.push({ employee: e, status: s.status, weightedScore: s.weightedScore, belowTarget: s.belowTarget, kpiCount: s.items.length });
    }
    return ok({ period, employees: out });
  });
};
