import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { local } from '../lib/time.ts';
import { isUuid, monthParam, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';
import { notify } from './notify.ts';

/**
 * إدارة عمولات المشاريع — projects with a commission split, "عمولة صفقة" requests by salespeople, approval by
 * the general manager (who picks the payroll month) and the payroll entitlements that follow.
 *
 * Who sees what is decided here, on the server — never only in the app:
 *  - commission.company_view (owner, المدير): company percentage, company earnings and profit.
 *  - commission.read_all (+ HR): every approved unit and every employee entitlement, without company figures.
 *  - commission.read_team (sales manager): projects + the units of his own team, without company figures.
 *  - anyone else: active projects (name + salesperson %) for the request form, and only his own requests.
 * All money is computed by PostgreSQL numeric (exact decimals), rounded to the piaster.
 */

const STATUS = ['active', 'paused', 'closed'] as const;
/** The salesperson's sales manager: his direct manager, else the manager of his sales team (never himself). */
const SM_OF = `NULLIF(COALESCE(e.sales_manager_id, t.manager_id), e.id)`;
const PCT_MAX = 100;

const canCompany = (a: Actor) => has(a, 'commission.company_view');
const canAll = (a: Actor) => has(a, 'commission.read_all');
const canTeam = (a: Actor) => has(a, 'commission.read_team');

function pct(b: Record<string, unknown>, k: string, optional = false) {
  const v = num(b, k, { min: 0, max: PCT_MAX, optional });
  if (v === undefined) return undefined;
  if (Math.abs(Math.round(v * 10000) - v * 10000) > 1e-6) {
    throw invalid('Use at most 4 decimals for a percentage', { field: k });
  }
  return v;
}

/** Project row for this person (company figures only for those allowed). */
function shapeProject(p: any, a: Actor, stats?: any) {
  const full = canAll(a) || canTeam(a) || has(a, 'commission.project_manage');
  const out: Record<string, unknown> = { id: p.id, name: p.name, status: p.status, salesPct: Number(p.sales_pct) };
  if (full) {
    out.totalPct = Number(p.total_pct);
    out.managerPct = Number(p.manager_pct);
    out.updatedAt = p.updated_at;
  }
  if (canCompany(a)) out.companyPct = Number(p.company_pct);
  if (stats) {
    out.units = Number(stats.units ?? 0);
    out.salesValue = Number(stats.sales_value ?? 0);
    out.salesCommission = Number(stats.sales_amount ?? 0);
    out.managerCommission = Number(stats.manager_amount ?? 0);
    // the total includes the company share — so only those who may see the company figures get it
    if (canCompany(a)) {
      out.companyCommission = Number(stats.company_amount ?? 0);
      out.totalCommission = Number(stats.sales_amount ?? 0) + Number(stats.manager_amount ?? 0) + Number(stats.company_amount ?? 0);
    }
  }
  return out;
}

/** A commission request for this person; company fields only with commission.company_view. */
function shapeRequest(r: any, a: Actor) {
  const out: Record<string, unknown> = {
    id: r.id, ref: Number(r.ref), projectId: r.project_id, projectName: r.project_name,
    employeeId: r.employee_id, employeeName: r.employee_name,
    salesManagerId: r.sales_manager_id, salesManagerName: r.sales_manager_name ?? null,
    unitNo: r.unit_no, pricePerM2: Number(r.price_per_m2), areaM2: Number(r.area_m2), unitValue: Number(r.unit_value),
    salesPct: Number(r.sales_pct), salesAmount: Number(r.sales_amount),
    status: r.status, period: r.period ? String(r.period).slice(0, 7) : null,
    note: r.note, createdAt: r.created_at, decidedAt: r.decided_at, decidedByName: r.decided_by_name ?? null,
    rejectReason: r.reject_reason, voidReason: r.void_reason, voidedAt: r.voided_at,
  };
  // the sales manager share is visible to the managers / payroll and to that sales manager himself
  if (canAll(a) || canTeam(a) || r.sales_manager_id === a.id) {
    out.managerPct = Number(r.manager_pct);
    out.managerAmount = Number(r.manager_amount);
  }
  if (canCompany(a)) {
    out.totalPct = Number(r.total_pct);
    out.companyPct = Number(r.company_pct);
    out.companyAmount = Number(r.company_amount);
    out.totalAmount = Number(r.sales_amount) + Number(r.manager_amount) + Number(r.company_amount);
  }
  if (r.payroll) out.payroll = r.payroll;
  return out;
}

const REQ_COLS = `cr.*, p.name AS project_name, e.full_name AS employee_name, sm.full_name AS sales_manager_name,
                  d.full_name AS decided_by_name`;
const REQ_FROM = `FROM commission_requests cr
  JOIN commission_projects p ON p.id = cr.project_id
  JOIN employees e ON e.id = cr.employee_id
  LEFT JOIN employees sm ON sm.id = cr.sales_manager_id
  LEFT JOIN employees d ON d.id = cr.decided_by`;

/** Payroll status of each entitlement of these requests (HR view / own view). */
async function attachPayroll(q: Q, rows: any[], a: Actor) {
  if (!rows.length) return rows;
  const ents = await q.query(`
    SELECT ce.*, e.full_name AS employee_name, po.id AS payout_id, po.status AS payout_status, po.received_at
      FROM commission_entitlements ce
      JOIN employees e ON e.id = ce.employee_id
      LEFT JOIN payouts po ON po.commission_entitlement_id = ce.id AND po.status <> 'cancelled'
     WHERE ce.request_id = ANY($1::uuid[])`, [rows.map((r) => r.id)]);
  const by = new Map<string, any[]>();
  for (const x of ents.rows) {
    if (!canAll(a) && x.employee_id !== a.id) continue; // own entitlements only
    const list = by.get(x.request_id) ?? [];
    list.push(shapeEntitlement(x));
    by.set(x.request_id, list);
  }
  for (const r of rows) r.payroll = by.get(r.id) ?? [];
  return rows;
}

function shapeEntitlement(x: any) {
  return {
    id: x.id, requestId: x.request_id, employeeId: x.employee_id, employeeName: x.employee_name, role: x.role,
    amount: Number(x.amount_egp), period: String(x.period).slice(0, 7), status: x.status,
    includedAt: x.included_at, payrollIncluded: x.status === 'active',
    payment: x.status !== 'active' ? 'cancelled' : !x.payout_id ? 'unpaid' : x.payout_status === 'received' ? 'paid' : 'handed',
    payoutId: x.payout_id ?? null, receivedAt: x.received_at ?? null,
    projectName: x.project_name, unitNo: x.unit_no, approvedAt: x.decided_at,
  };
}

/** A payroll month counts as finalized for an employee once his salary for it was handed over and received. */
async function monthClosed(q: Q, employeeId: string, period: string) {
  return !!(await one(q, `SELECT 1 FROM payouts WHERE employee_id = $1 AND period = $2 AND kind = 'salary' AND status = 'received'`,
    [employeeId, period]));
}

export interface CommissionRequestInput { projectId: string; unitNo: string; price: number; area: number; note: string; employeeId: string }

/**
 * The deal commission request. It is filed under the signed-in employee; HR / المدير (sales.manage) may file it for the
 * salesperson who made the deal. Any amount / percentage sent is ignored — they come from the project.
 */
export function parseCommissionRequest(b: Record<string, unknown>, a: Actor): CommissionRequestInput {
  const projectId = typeof b.projectId === 'string' ? b.projectId : '';
  if (!isUuid(projectId)) throw invalid('Choose the project', { field: 'projectId' });
  const unitNo = str(b, 'unitNo', { min: 1, max: 60 })!.trim();
  const price = num(b, 'pricePerM2', { min: 0.01, max: 10_000_000 })!;
  const area = num(b, 'areaM2', { min: 0.01, max: 1_000_000 })!;
  const note = str(b, 'note', { optional: true, max: 1000 }) ?? '';
  let employeeId = a.id;
  // anyone else's employeeId is ignored (the request is always his own), as before
  if (has(a, 'sales.manage') && typeof b.employeeId === 'string' && b.employeeId && b.employeeId !== a.id) {
    if (!isUuid(b.employeeId)) throw invalid('Choose the salesperson', { field: 'employeeId' });
    employeeId = b.employeeId;
  }
  return { projectId, unitNo, price, area, note, employeeId };
}

export async function createCommissionRequest(q: Q, a: Actor, x0: CommissionRequestInput): Promise<string> {
  const { projectId, unitNo, price, area, note, employeeId } = x0;
  const p = await one(q, `SELECT * FROM commission_projects WHERE id = $1 FOR SHARE`, [projectId]);
  if (!p) throw invalid('Choose the project', { field: 'projectId' });
  if (p.status !== 'active') throw new AppError('unprocessable', 'This project is not accepting deals now', { reason: 'project_inactive' });
  const dup = await one(q, `SELECT employee_id, status FROM commission_requests
                             WHERE project_id = $1 AND lower(trim(unit_no)) = lower(trim($2)) AND status IN ('pending','approved')`,
    [projectId, unitNo]);
  if (dup) {
    throw new AppError('conflict', 'This unit already has a commission request in this project',
      { reason: dup.status === 'pending' ? 'pending_exists' : 'unit_sold', what: 'طلب عمولة لنفس الوحدة' });
  }
  const me = await one(q, `SELECT e.full_name, e.status, ${SM_OF} AS sales_manager_id FROM employees e LEFT JOIN teams t ON t.id = e.team_id WHERE e.id = $1`, [employeeId]);
  if (!me || me.status !== 'active') throw invalid('Choose an active salesperson', { field: 'employeeId' });
  const x = await one(q, `
    INSERT INTO commission_requests (project_id, employee_id, sales_manager_id, unit_no, price_per_m2, area_m2, unit_value,
           total_pct, sales_pct, manager_pct, company_pct, sales_amount, manager_amount, company_amount, note)
    SELECT $1, $2, $3, $4, v.price, v.area, v.val, p.total_pct, p.sales_pct, p.manager_pct, p.company_pct,
           round(v.val * p.sales_pct / 100, 2), round(v.val * p.manager_pct / 100, 2), round(v.val * p.company_pct / 100, 2), $7
      FROM commission_projects p,
           LATERAL (SELECT $5::numeric AS price, $6::numeric AS area, round($5::numeric * $6::numeric, 2) AS val) v
     WHERE p.id = $1
    RETURNING id`, [projectId, employeeId, me.sales_manager_id ?? null, unitNo, String(price), String(area), note]);
  await audit(q, a.id, 'commission.request.create', 'commission_request', x.id, undefined,
    { projectId, unitNo, pricePerM2: price, areaM2: area, ...(employeeId !== a.id ? { employeeId, filedBy: a.id } : {}) });
  // ring the approvers (المدير / owner)
  const approvers = await q.query(`
    SELECT DISTINCT e.id FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
     WHERE rp.perm_key = 'commission.approve' AND e.status = 'active' AND e.id <> $1`, [employeeId]);
  for (const ap of approvers.rows) {
    await notify(q, { to: ap.id, type: 'commission_awaiting', title: `طلب عمولة صفقة من ${me.full_name}`,
      body: `${p.name} — وحدة ${unitNo}`, entity: 'commission_request', entityId: x.id, dedupeKey: `commission:${x.id}:awaiting` });
  }
  return x.id;
}

export const commissionsModule: Module = (r, { db, clock }) => {
  // ------------------------------------------------------------------ projects
  r.get('/commissions/projects', async (req) => {
    const a = await authenticate(db, req);
    const manage = has(a, 'commission.project_manage');
    const seeAll = manage || canAll(a) || canTeam(a);
    const vals: unknown[] = [];
    const where: string[] = [];
    if (!seeAll) where.push(`p.status = 'active'`);
    const st = req.query.get('status');
    if (st && (STATUS as readonly string[]).includes(st)) { vals.push(st); where.push(`p.status = $${vals.length}`); }
    const s = req.query.get('q');
    if (s) { vals.push(`%${s.trim().toLowerCase()}%`); where.push(`lower(p.name) LIKE $${vals.length}`); }
    // totals: everything for managers / HR, only own team's units for a sales manager, none for others
    let unitFilter = 'false';
    if (canAll(a) || manage) unitFilter = 'true';
    else if (canTeam(a)) { vals.push(a.id); unitFilter = `cr.sales_manager_id = $${vals.length}`; }
    const rows = await db.query(`
      SELECT p.*, s.units, s.sales_value, s.sales_amount, s.manager_amount, s.company_amount
        FROM commission_projects p
        LEFT JOIN LATERAL (
          SELECT count(*) AS units, sum(cr.unit_value) AS sales_value, sum(cr.sales_amount) AS sales_amount,
                 sum(cr.manager_amount) AS manager_amount, sum(cr.company_amount) AS company_amount
            FROM commission_requests cr WHERE cr.project_id = p.id AND cr.status = 'approved' AND (${unitFilter})) s ON true
       ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
       ORDER BY (p.status = 'active') DESC, p.name`, vals);
    return ok({
      currency: 'EGP',
      projects: rows.rows.map((p) => shapeProject(p, a, seeAll ? p : undefined)),
      can: { manage, companyView: canCompany(a), approve: has(a, 'commission.approve'), readAll: canAll(a), readTeam: canTeam(a) },
    });
  });

  function projectBody(b: Record<string, unknown>, partial: boolean) {
    const name = str(b, 'name', { min: 2, max: 120, optional: partial });
    const total = pct(b, 'totalPct', partial), sales = pct(b, 'salesPct', partial);
    const manager = pct(b, 'managerPct', partial), company = pct(b, 'companyPct', partial);
    const status = oneOf(b, 'status', STATUS, true);
    return { name, total, sales, manager, company, status };
  }

  /** sales + manager + company must equal the total, exactly (checked in numeric, not in floats). */
  async function checkSplit(q: Q, t: number, s: number, m: number, c: number) {
    if (!(t > 0)) throw invalid('The total commission must be more than 0', { field: 'totalPct' });
    const x = await one(q, `SELECT ($1::numeric + $2::numeric + $3::numeric) = $4::numeric AS eq,
                                   ($1::numeric + $2::numeric + $3::numeric) AS sum`, [String(s), String(m), String(c), String(t)]);
    if (!x.eq) {
      throw invalid(`Salesperson + sales manager + company = ${Number(x.sum)}% but the total is ${t}%`,
        { reason: 'split_mismatch', field: 'totalPct', sum: Number(x.sum), total: t });
    }
  }

  r.post('/commissions/projects', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'commission.project_manage')) throw forbidden();
    const b = projectBody(obj(req.body), false);
    const row = await db.tx(async (q) => {
      await checkSplit(q, b.total!, b.sales!, b.manager!, b.company!);
      if (await one(q, `SELECT 1 FROM commission_projects WHERE lower(trim(name)) = lower(trim($1))`, [b.name])) {
        throw conflict('A project with this name already exists');
      }
      const p = await one(q, `INSERT INTO commission_projects (name, total_pct, sales_pct, manager_pct, company_pct, status, created_by)
                              VALUES (trim($1),$2,$3,$4,$5,$6,$7) RETURNING *`,
        [b.name, String(b.total), String(b.sales), String(b.manager), String(b.company), b.status ?? 'active', a.id]);
      await audit(q, a.id, 'commission.project.create', 'commission_project', p.id, undefined,
        { name: p.name, totalPct: b.total, salesPct: b.sales, managerPct: b.manager, companyPct: b.company });
      return p;
    });
    return ok({ project: shapeProject(row, a) }, 201);
  });

  /** Editing the split changes only new requests — approved ones keep the percentages they were approved with. */
  r.patch('/commissions/projects/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'commission.project_manage')) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = projectBody(obj(req.body), true);
    const row = await db.tx(async (q) => {
      const old = await one(q, `SELECT * FROM commission_projects WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!old) throw notFound();
      const t = b.total ?? Number(old.total_pct), s = b.sales ?? Number(old.sales_pct);
      const m = b.manager ?? Number(old.manager_pct), c = b.company ?? Number(old.company_pct);
      await checkSplit(q, t, s, m, c);
      const name = b.name ?? old.name;
      if (await one(q, `SELECT 1 FROM commission_projects WHERE lower(trim(name)) = lower(trim($1)) AND id <> $2`, [name, old.id])) {
        throw conflict('A project with this name already exists');
      }
      const p = await one(q, `UPDATE commission_projects SET name = trim($2), total_pct = $3, sales_pct = $4, manager_pct = $5,
                                company_pct = $6, status = $7, updated_at = now() WHERE id = $1 RETURNING *`,
        [old.id, name, String(t), String(s), String(m), String(c), b.status ?? old.status]);
      await audit(q, a.id, 'commission.project.update', 'commission_project', old.id,
        { name: old.name, totalPct: Number(old.total_pct), salesPct: Number(old.sales_pct), managerPct: Number(old.manager_pct),
          companyPct: Number(old.company_pct), status: old.status },
        { name, totalPct: t, salesPct: s, managerPct: m, companyPct: c, status: b.status ?? old.status });
      return p;
    });
    return ok({ project: shapeProject(row, a) });
  });

  /** Project details + sold units (approved requests only — a pending one is never a sold unit). */
  r.get('/commissions/projects/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const p = await one(db, `SELECT * FROM commission_projects WHERE id = $1`, [req.params.id]);
    if (!p) throw notFound();
    const manage = has(a, 'commission.project_manage');
    if (!(manage || canAll(a) || canTeam(a)) && p.status !== 'active') throw notFound();
    const vals: unknown[] = [p.id];
    let scope = 'false';
    if (manage || canAll(a)) scope = 'true';
    else if (canTeam(a)) { vals.push(a.id); scope = `(cr.sales_manager_id = $2 OR cr.employee_id = $2)`; }
    else { vals.push(a.id); scope = `cr.employee_id = $2`; } // a salesperson sees only his own units
    const units = await db.query(`SELECT ${REQ_COLS} ${REQ_FROM}
       WHERE cr.project_id = $1 AND cr.status = 'approved' AND ${scope} ORDER BY cr.decided_at DESC`, vals);
    await attachPayroll(db, units.rows, a);
    const st = {
      units: units.rows.length,
      sales_value: units.rows.reduce((s, x) => s + Number(x.unit_value), 0),
      sales_amount: units.rows.reduce((s, x) => s + Number(x.sales_amount), 0),
      manager_amount: units.rows.reduce((s, x) => s + Number(x.manager_amount), 0),
      company_amount: units.rows.reduce((s, x) => s + Number(x.company_amount), 0),
    };
    const r2 = (n: number) => Math.round(n * 100) / 100;
    for (const k of Object.keys(st) as (keyof typeof st)[]) st[k] = r2(st[k]);
    return ok({ currency: 'EGP', project: shapeProject(p, a, st), units: units.rows.map((x) => shapeRequest(x, a)) });
  });

  // ------------------------------------------------------------------ requests (عمولة صفقة)
  r.post('/commissions/requests', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const input = parseCommissionRequest(b, a);
    const row = await db.tx(async (q) => {
      const id = await createCommissionRequest(q, a, input);
      return one(q, `SELECT ${REQ_COLS} ${REQ_FROM} WHERE cr.id = $1`, [id]);
    });
    return ok({ request: shapeRequest(row, a) }, 201);
  });

  /** scope=mine (default for everyone) | pending (approvers) | approved (HR / managers / own team) */
  r.get('/commissions/requests', async (req) => {
    const a = await authenticate(db, req);
    const scope = req.query.get('scope') ?? 'mine';
    const vals: unknown[] = [];
    const where: string[] = [];
    if (scope === 'pending') {
      if (!has(a, 'commission.approve')) throw forbidden();
      where.push(`cr.status = 'pending'`);
    } else if (scope === 'all') {
      if (canAll(a)) { /* every request */ } else if (canTeam(a)) {
        vals.push(a.id); where.push(`(cr.sales_manager_id = $${vals.length} OR cr.employee_id = $${vals.length})`);
      } else throw forbidden();
    } else {
      vals.push(a.id); where.push(`cr.employee_id = $${vals.length}`);
    }
    const st = req.query.get('status');
    if (st && ['pending', 'approved', 'rejected', 'voided'].includes(st)) { vals.push(st); where.push(`cr.status = $${vals.length}`); }
    const pid = req.query.get('projectId');
    if (pid && isUuid(pid)) { vals.push(pid); where.push(`cr.project_id = $${vals.length}`); }
    const rows = await db.query(`SELECT ${REQ_COLS} ${REQ_FROM} ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
                                 ORDER BY cr.created_at DESC LIMIT 500`, vals);
    await attachPayroll(db, rows.rows, a);
    return ok({ currency: 'EGP', requests: rows.rows.map((x) => shapeRequest(x, a)) });
  });

  /**
   * General manager decision. Approve = recompute every amount from the stored figures, freeze the snapshot,
   * pick the payroll month and create the payroll entitlements — all in one transaction, under a row lock,
   * so a double tap can never approve twice or pay twice.
   */
  r.post('/commissions/requests/:id/decision', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'commission.approve')) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const decision = oneOf(b, 'decision', ['approve', 'reject'] as const)!;
    const now = clock();
    const out = await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM commission_requests WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x) throw notFound();
      if (x.status !== 'pending') throw conflict('This request was already decided');
      if (x.employee_id === a.id) throw forbidden('You cannot approve your own commission');
      const p = await one(q, `SELECT name FROM commission_projects WHERE id = $1`, [x.project_id]);
      if (decision === 'reject') {
        const reason = str(b, 'reason', { min: 3, max: 500 })!;
        await q.query(`UPDATE commission_requests SET status = 'rejected', decided_by = $2, decided_at = $3, reject_reason = $4 WHERE id = $1`,
          [x.id, a.id, now, reason]);
        await audit(q, a.id, 'commission.request.reject', 'commission_request', x.id, undefined, { reason });
        await notify(q, { to: x.employee_id, type: 'commission_rejected', title: `اترفض طلب عمولة وحدة ${x.unit_no}`,
          body: `${p.name} — ${reason}`, entity: 'commission_request', entityId: x.id, dedupeKey: `commission:${x.id}:rejected` });
        return x.id;
      }
      const period = monthParam(typeof b.month === 'string' ? b.month : null);
      const cur = local(now).date.slice(0, 7) + '-01';
      const minP = await one(q, `SELECT ($1::date - interval '1 month')::date AS m, ($1::date + interval '12 months')::date AS mx`, [cur]);
      const pDate = new Date(period + 'T00:00:00Z'), minDate = new Date(String(minP.m).slice(0, 10) + 'T00:00:00Z');
      if (pDate < minDate || pDate > new Date(String(minP.mx).slice(0, 10) + 'T00:00:00Z')) {
        throw invalid('Pick a payroll month from last month up to a year ahead', { field: 'month' });
      }
      // the sales manager is the salesperson's direct manager now (he may have changed since the request)
      const emp = await one(q, `SELECT m.id AS sales_manager_id, m.status AS m_status FROM employees e
                                  LEFT JOIN teams t ON t.id = e.team_id
                                  LEFT JOIN employees m ON m.id = ${SM_OF} WHERE e.id = $1`, [x.employee_id]);
      const smId = emp?.sales_manager_id && emp.m_status === 'active' ? emp.sales_manager_id : null;
      for (const who of [x.employee_id, smId].filter(Boolean) as string[]) {
        if (await monthClosed(q, who, period)) {
          throw new AppError('unprocessable', 'This payroll month was already paid out — pick a later month',
            { reason: 'month_closed', field: 'month' });
        }
      }
      // recompute on the server from the frozen percentages (never from anything the app sent)
      const y = await one(q, `
        UPDATE commission_requests SET
               unit_value = round(price_per_m2 * area_m2, 2),
               sales_amount = round(round(price_per_m2 * area_m2, 2) * sales_pct / 100, 2),
               manager_amount = round(round(price_per_m2 * area_m2, 2) * manager_pct / 100, 2),
               company_amount = round(round(price_per_m2 * area_m2, 2) * company_pct / 100, 2),
               sales_manager_id = $2, status = 'approved', period = $3, decided_by = $4, decided_at = $5
         WHERE id = $1 RETURNING *`, [x.id, smId, period, a.id, now]);
      const ents: any[] = [];
      if (Number(y.sales_amount) > 0) {
        ents.push(await one(q, `INSERT INTO commission_entitlements (request_id, employee_id, role, amount_egp, period, included_at)
                                VALUES ($1,$2,'sales',$3,$4,$5) ON CONFLICT (request_id, role) DO NOTHING RETURNING *`,
          [y.id, y.employee_id, y.sales_amount, period, now]));
      }
      if (smId && Number(y.manager_amount) > 0) {
        ents.push(await one(q, `INSERT INTO commission_entitlements (request_id, employee_id, role, amount_egp, period, included_at)
                                VALUES ($1,$2,'manager',$3,$4,$5) ON CONFLICT (request_id, role) DO NOTHING RETURNING *`,
          [y.id, smId, y.manager_amount, period, now]));
      }
      await audit(q, a.id, 'commission.request.approve', 'commission_request', y.id, undefined, {
        period, unitValue: Number(y.unit_value), salesPct: Number(y.sales_pct), managerPct: Number(y.manager_pct),
        companyPct: Number(y.company_pct), salesAmount: Number(y.sales_amount), managerAmount: Number(y.manager_amount),
        companyAmount: Number(y.company_amount), salesManagerId: smId,
      });
      const monthAr = period.slice(0, 7);
      await notify(q, { to: y.employee_id, type: 'commission_approved', title: `اتوافق على عمولة وحدة ${y.unit_no}: ${Number(y.sales_amount)} جنيه`,
        body: `${p.name} — هتنزل في مرتب ${monthAr}`, entity: 'commission_request', entityId: y.id, dedupeKey: `commission:${y.id}:approved` });
      if (smId && Number(y.manager_amount) > 0) {
        await notify(q, { to: smId, type: 'commission_approved', title: `عمولة مدير مبيعات: ${Number(y.manager_amount)} جنيه`,
          body: `${p.name} — وحدة ${y.unit_no} — مرتب ${monthAr}`, entity: 'commission_request', entityId: y.id, dedupeKey: `commission:${y.id}:manager` });
      }
      return y.id;
    });
    const row = await one(db, `SELECT ${REQ_COLS} ${REQ_FROM} WHERE cr.id = $1`, [out]);
    await attachPayroll(db, [row], a);
    return ok({ request: shapeRequest(row, a) });
  });

  /** Owner-only correction of an approved deal (e.g. the sale fell through): the record stays, its unpaid entitlements stop. */
  r.post('/commissions/requests/:id/void', async (req) => {
    const a = await authenticate(db, req);
    if (a.role !== 'owner') throw forbidden('Only the owner can cancel an approved commission');
    if (!isUuid(req.params.id)) throw notFound();
    const reason = str(obj(req.body), 'reason', { min: 3, max: 500 })!;
    await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM commission_requests WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x) throw notFound();
      if (x.status !== 'approved') throw conflict('Only an approved commission can be cancelled');
      const paid = await one(q, `SELECT 1 FROM commission_entitlements ce JOIN payouts po ON po.commission_entitlement_id = ce.id
                                  WHERE ce.request_id = $1 AND po.status <> 'cancelled'`, [x.id]);
      if (paid) throw new AppError('conflict', 'This commission was already paid out — cancel the payout first', { reason: 'already_paid' });
      await q.query(`UPDATE commission_requests SET status = 'voided', voided_by = $2, voided_at = now(), void_reason = $3 WHERE id = $1`,
        [x.id, a.id, reason]);
      await q.query(`UPDATE commission_entitlements SET status = 'cancelled', cancelled_at = now() WHERE request_id = $1`, [x.id]);
      await audit(q, a.id, 'commission.request.void', 'commission_request', x.id, { status: 'approved' }, { status: 'voided', reason });
    });
    return ok({ ok: true });
  });

  // ------------------------------------------------------------------ payroll entitlements (HR)
  r.get('/commissions/entitlements', async (req) => {
    const a = await authenticate(db, req);
    const all = req.query.get('scope') === 'all';
    if (all && !canAll(a)) throw forbidden();
    const vals: unknown[] = [];
    const where: string[] = [];
    if (!all) { vals.push(a.id); where.push(`ce.employee_id = $${vals.length}`); }
    const m = req.query.get('month');
    if (m) { vals.push(monthParam(m)); where.push(`ce.period = $${vals.length}`); }
    const e = req.query.get('employeeId');
    if (all && e && isUuid(e)) { vals.push(e); where.push(`ce.employee_id = $${vals.length}`); }
    const rows = await db.query(`
      SELECT ce.*, e.full_name AS employee_name, p.name AS project_name, cr.unit_no, cr.decided_at,
             po.id AS payout_id, po.status AS payout_status, po.received_at
        FROM commission_entitlements ce
        JOIN employees e ON e.id = ce.employee_id
        JOIN commission_requests cr ON cr.id = ce.request_id
        JOIN commission_projects p ON p.id = cr.project_id
        LEFT JOIN payouts po ON po.commission_entitlement_id = ce.id AND po.status <> 'cancelled'
       ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
       ORDER BY ce.period DESC, e.full_name LIMIT 1000`, vals);
    const list = rows.rows.map(shapeEntitlement);
    const active = list.filter((x) => x.status === 'active');
    return ok({ currency: 'EGP', entitlements: list, totals: {
      amount: Math.round(active.reduce((s, x) => s + x.amount, 0) * 100) / 100,
      unpaid: Math.round(active.filter((x) => x.payment === 'unpaid').reduce((s, x) => s + x.amount, 0) * 100) / 100,
    } });
  });
};

/** Commissions of one employee for one payroll month (approved, not cancelled). */
export async function commissionsFor(q: Q, employeeId: string, period: string): Promise<number> {
  const r = await one(q, `SELECT COALESCE(sum(amount_egp), 0) AS s FROM commission_entitlements
                           WHERE employee_id = $1 AND period = $2 AND status = 'active'`, [employeeId, period]);
  return Number(r.s);
}
