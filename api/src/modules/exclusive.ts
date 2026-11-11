import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { local } from '../lib/time.ts';
import { date, isUuid, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';
import { canHrOperate, canOffice, hrDesk } from './cash.ts';
import { holdersOf, notify } from './notify.ts';

/**
 * المشاريع الحصري — see db/migrations/040_exclusive_projects.sql for the rules.
 *  - السيلز: reserves a unit (حجز) and sends the contract terms (طلب تعاقد) / a cancel request.
 *  - المحاسب: records every payment (عربون / مقدم / قسط) into his cashbox — نقدي أو بنك — and pays back a
 *    cancelled reservation's deposit.
 *  - المالك / المدير العام: approves the contract and the cancel, moves the earned commission out of the owner's
 *    money (تحويل عمولة), and orders the owner's payouts (approved by the other owner, from the office cashbox).
 */
const r2 = (n: number) => Math.round(n * 100) / 100;
const n = (v: unknown) => Number(v ?? 0);
const ds = (v: unknown) => (v instanceof Date ? v.toISOString() : String(v ?? '')).slice(0, 10);
const SM_OF = `NULLIF(COALESCE(e.sales_manager_id, t.manager_id), e.id)`;
const METHODS = ['cash', 'bank_transfer', 'cheque', 'card', 'wallet'] as const;
const KIND_AR: Record<string, string> = { reservation: 'عربون حجز', down_payment: 'مقدم تعاقد', installment: 'قسط' };
const STATUS_AR: Record<string, string> = {
  reserving: 'مستني العربون', reserved: 'محجوز', contract_pending: 'مستني موافقة التعاقد', contracted: 'متعاقد',
  completed: 'مكتمل', cancel_pending: 'مستني موافقة الإلغاء', cancelled: 'ملغي',
};
const fmt = (v: number) => `${v.toLocaleString('en-US', { maximumFractionDigits: 2 })} جنيه`;

const canManage = (a: Actor) => canOffice(a);                       // المالك / المدير العام
const canReserve = (a: Actor) => has(a, 'exclusive.reserve') || canManage(a);
const canSeeAll = (a: Actor) => canManage(a) || canHrOperate(a);

function pct(b: Record<string, unknown>, k: string, def: number) {
  const v = num(b, k, { optional: true, min: 0, max: 100 });
  return v ?? def;
}

/** Every unit of the given projects with what was collected / refunded and how many installments are fully paid. */
async function loadUnits(q: Q, where: string, params: unknown[]) {
  const rows = await q.query(`
    SELECT u.*, p.name AS project_name, p.owner_name, s.full_name AS sales_name, cb.full_name AS contracted_by_name,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted'), 0) AS collected,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.payment_method <> 'cash'), 0) AS collected_bank,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.kind = 'reservation'), 0) AS deposit_paid,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.kind IN ('reservation','down_payment')), 0) AS down_paid,
           COALESCE((SELECT sum(x.amount_egp) FROM cash_expenses x WHERE x.ex_unit_id = u.id AND x.ex_kind = 'refund' AND x.status = 'posted'), 0) AS refunded,
           (SELECT count(*) FROM ex_installments i WHERE i.unit_id = u.id)::int AS inst_total,
           (SELECT count(*) FROM ex_installments i WHERE i.unit_id = u.id AND i.amount_egp <=
              COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0))::int AS inst_paid,
           (SELECT min(i.due_date) FROM ex_installments i WHERE i.unit_id = u.id AND i.amount_egp >
              COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0)) AS next_due
      FROM ex_units u JOIN commission_projects p ON p.id = u.project_id JOIN employees s ON s.id = u.sales_id
      LEFT JOIN employees cb ON cb.id = u.contracted_by
     WHERE ${where} ORDER BY u.created_at DESC`, params);
  return rows.rows.map(withCommission);
}

/** The office's commission on a unit: earned so far, still to come from installments, and potential (reserved only). */
function withCommission(u: any) {
  const price = n(u.unit_price), total = n(u.total_pct), contract = n(u.contract_pct);
  let earned = 0, upcoming = 0, potential = 0;
  if (u.status === 'contracted') {
    if (u.payment_type === 'cash') earned = price * total / 100;
    else {
      const instPart = Math.min(n(u.inst_paid) * n(u.installment_pct), Math.max(total - contract, 0));
      earned = price * (contract + instPart) / 100;
      upcoming = price * Math.max(total - contract - instPart, 0) / 100;
    }
  } else if (['reserving', 'reserved', 'contract_pending'].includes(u.status)) {
    potential = price * total / 100;
  }
  const completed = u.status === 'contracted' && n(u.collected) >= price;
  return { ...u, earned: r2(earned), upcoming: r2(upcoming), potential: r2(potential), completed,
    staff: u.status === 'contracted' ? r2(price * (n(u.sales_pct) + n(u.manager_pct)) / 100) : 0 };
}

function shapeUnit(u: any, a: Actor) {
  const status = u.completed ? 'completed' : u.status;
  const mine = u.sales_id === a.id;
  return {
    id: u.id, refNo: Number(u.ref_no), projectId: u.project_id, projectName: u.project_name, unitNo: u.unit_no,
    clientName: u.client_name, clientPhone: u.client_phone, unitPrice: n(u.unit_price), depositAmount: n(u.deposit_amount),
    salesId: u.sales_id, salesName: u.sales_name, status, statusAr: STATUS_AR[status], notes: u.notes,
    totalPct: n(u.total_pct), contractPct: n(u.contract_pct), salesPct: n(u.sales_pct), managerPct: n(u.manager_pct),
    contract: u.payment_type ? {
      paymentType: u.payment_type, downPayment: n(u.down_payment), installmentsCount: u.installments_count, everyMonths: u.every_months,
      firstDueDate: u.first_due_date ? ds(u.first_due_date) : null, installmentPct: u.installment_pct == null ? null : n(u.installment_pct),
      note: u.contract_note, requestedAt: u.contract_requested_at, approvedAt: u.contracted_at, approvedByName: u.contracted_by_name,
      rejectReason: u.reject_reason,
    } : null,
    cancelReason: u.cancel_reason,
    money: { collected: r2(n(u.collected)), bank: r2(n(u.collected_bank)), cash: r2(n(u.collected) - n(u.collected_bank)),
      depositPaid: r2(n(u.deposit_paid)), downPaid: r2(n(u.down_paid)), refunded: r2(n(u.refunded)),
      remaining: r2(Math.max(n(u.unit_price) - n(u.collected), 0)) },
    installments: { total: u.inst_total, paid: u.inst_paid, nextDue: u.next_due ? ds(u.next_due) : null },
    // the commission figures are المالك / المدير العام's view
    commission: canManage(a) ? { earned: u.earned, upcoming: u.upcoming, potential: u.potential, staff: u.staff } : undefined,
    createdAt: u.created_at,
    can: {
      collect: hrDesk(a) && ['reserving', 'reserved', 'contract_pending', 'contracted'].includes(u.status),
      requestContract: (mine || canManage(a)) && u.status === 'reserved',
      decideContract: canManage(a) && u.status === 'contract_pending' && !mine,
      requestCancel: (mine || canManage(a)) && ['reserving', 'reserved', 'contract_pending'].includes(u.status),
      decideCancel: canManage(a) && u.status === 'cancel_pending',
      refund: hrDesk(a) && u.status === 'cancelled' && n(u.collected) - n(u.refunded) > 0,
    },
  };
}

/** A project's totals: units by status, the owner's money, the office's commission. */
async function projectStats(q: Q, projectIds: string[]) {
  const units = projectIds.length ? await loadUnits(q, 'u.project_id = ANY($1::uuid[])', [projectIds]) : [];
  const moves = projectIds.length ? await q.query(`
    SELECT p.id,
      COALESCE((SELECT sum(t.amount_egp) FROM ex_commission_transfers t WHERE t.project_id = p.id), 0) AS transferred,
      COALESCE((SELECT sum(x.amount_egp) FROM cash_expenses x WHERE x.ex_project_id = p.id AND x.ex_kind = 'owner_payout' AND x.status = 'posted'), 0) AS owner_paid,
      COALESCE((SELECT sum(x.amount_egp) FROM cash_expenses x WHERE x.ex_project_id = p.id AND x.ex_kind = 'owner_payout' AND x.status = 'pending_approval'), 0) AS owner_pending
      FROM commission_projects p WHERE p.id = ANY($1::uuid[])`, [projectIds]) : { rows: [] as any[] };
  const out: Record<string, any> = {};
  for (const id of projectIds) {
    const us = units.filter((u) => u.project_id === id);
    const m = moves.rows.find((x: any) => x.id === id) ?? {};
    const sum = (f: (u: any) => number) => r2(us.reduce((a, u) => a + f(u), 0));
    const collected = sum((u) => n(u.collected)), refunded = sum((u) => n(u.refunded));
    const earned = sum((u) => u.earned), transferred = r2(n(m.transferred)), ownerPaid = r2(n(m.owner_paid));
    const trust = r2(collected - refunded - transferred - ownerPaid);
    out[id] = {
      units: {
        reserved: us.filter((u) => ['reserving', 'reserved', 'contract_pending'].includes(u.status)).length,
        contracted: us.filter((u) => u.status === 'contracted' && !u.completed).length,
        completed: us.filter((u) => u.completed).length,
        cancelled: us.filter((u) => u.status === 'cancelled').length,
        total: us.length,
      },
      collected, bank: sum((u) => n(u.collected_bank)), refunded,
      commission: { earned, transferred, pending: r2(Math.max(earned - transferred, 0)), upcoming: sum((u) => u.upcoming),
        potential: sum((u) => u.potential), staff: sum((u) => u.staff) },
      owner: { inTrust: trust, paid: ownerPaid, pendingPayout: r2(n(m.owner_pending)),
        due: r2(Math.max(trust - Math.max(earned - transferred, 0), 0)) },
      sales: sum((u) => (u.status === 'contracted' ? n(u.unit_price) : 0)),
    };
  }
  return { stats: out, units };
}

function shapeProject(p: any, stats?: any) {
  return {
    id: p.id, name: p.name, kind: p.kind, status: p.status, ownerName: p.owner_name, ownerPhone: p.owner_phone,
    totalPct: n(p.total_pct), contractPct: n(p.contract_pct), installmentPct: n(p.installment_pct),
    salesPct: n(p.sales_pct), managerPct: n(p.manager_pct), companyPct: n(p.company_pct), createdAt: p.created_at,
    stats,
  };
}

/** Installments: (price − down payment) split evenly; the last one takes the rounding. */
function schedule(price: number, down: number, count: number, every: number, first: string) {
  const rest = r2(price - down);
  const each = Math.floor((rest / count) * 100) / 100;
  const out: { seq: number; due: string; amount: number }[] = [];
  const [y, m, d] = first.split('-').map(Number);
  for (let i = 0; i < count; i++) {
    const dt = new Date(Date.UTC(y, m - 1 + i * every, 1));
    const last = new Date(Date.UTC(dt.getUTCFullYear(), dt.getUTCMonth() + 1, 0)).getUTCDate();
    dt.setUTCDate(Math.min(d, last));
    out.push({ seq: i + 1, due: dt.toISOString().slice(0, 10), amount: i === count - 1 ? r2(rest - each * (count - 1)) : each });
  }
  return out;
}

export const exclusiveModule: Module = (r, { db, clock }) => {
  const today = () => local(clock()).date;

  // ------------------------------------------------------------------ projects
  r.get('/exclusive/projects', async (req) => {
    const a = await authenticate(db, req);
    if (!canReserve(a) && !canSeeAll(a)) throw forbidden();
    const rows = await db.query(`SELECT * FROM commission_projects WHERE kind = 'exclusive'
                                  ${canManage(a) ? '' : `AND status = 'active'`} ORDER BY status = 'active' DESC, created_at DESC`);
    const st = canManage(a) ? (await projectStats(db, rows.rows.map((p) => p.id))).stats : {};
    return ok({ projects: rows.rows.map((p) => shapeProject(p, st[p.id])), canManage: canManage(a), canReserve: canReserve(a), canCollect: hrDesk(a) });
  });

  r.post('/exclusive/projects', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    const b = obj(req.body);
    const name = str(b, 'name', { min: 2, max: 120 })!.trim();
    const ownerName = str(b, 'ownerName', { min: 2, max: 120 })!.trim();
    const ownerPhone = (str(b, 'ownerPhone', { optional: true, max: 30 }) ?? '').trim();
    const total = pct(b, 'totalPct', 5), contract = pct(b, 'contractPct', 3), sales = pct(b, 'salesPct', 0.2),
      manager = pct(b, 'managerPct', 0.1), inst = pct(b, 'installmentPct', 0.5);
    if (contract > total) throw invalid('The contract share cannot be more than the total commission', { field: 'contractPct' });
    if (sales + manager > contract) throw invalid('The sales + manager shares come out of the contract share', { field: 'salesPct' });
    const p = await db.tx(async (q) => {
      if (await one(q, `SELECT 1 FROM commission_projects WHERE lower(trim(name)) = lower(trim($1))`, [name])) {
        throw invalid('A project with this name already exists', { field: 'name' });
      }
      const x = await one(q, `INSERT INTO commission_projects (name, total_pct, sales_pct, manager_pct, company_pct, created_by, kind,
          owner_name, owner_phone, contract_pct, installment_pct)
        VALUES ($1,$2,$3,$4,$5,$6,'exclusive',$7,$8,$9,$10) RETURNING *`,
        [name, total, sales, manager, r2(total - sales - manager), a.id, ownerName, ownerPhone, contract, inst]);
      await audit(q, a.id, 'exclusive.project.create', 'commission_project', x.id, undefined, x);
      return x;
    });
    return ok({ project: shapeProject(p) }, 201);
  });

  r.patch('/exclusive/projects/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const p = await db.tx(async (q) => {
      const o = await one(q, `SELECT * FROM commission_projects WHERE id = $1 AND kind = 'exclusive' FOR UPDATE`, [req.params.id]);
      if (!o) throw notFound();
      const total = pct(b, 'totalPct', n(o.total_pct)), contract = pct(b, 'contractPct', n(o.contract_pct)),
        sales = pct(b, 'salesPct', n(o.sales_pct)), manager = pct(b, 'managerPct', n(o.manager_pct)), inst = pct(b, 'installmentPct', n(o.installment_pct));
      if (contract > total || sales + manager > contract) throw invalid('Check the percentages', { field: 'contractPct' });
      const x = await one(q, `UPDATE commission_projects SET name = $2, owner_name = $3, owner_phone = $4, total_pct = $5, contract_pct = $6,
          sales_pct = $7, manager_pct = $8, company_pct = $9, installment_pct = $10, status = $11, updated_at = now() WHERE id = $1 RETURNING *`,
        [o.id, (str(b, 'name', { optional: true, min: 2, max: 120 }) ?? o.name).trim(), (str(b, 'ownerName', { optional: true, min: 2, max: 120 }) ?? o.owner_name).trim(),
          (str(b, 'ownerPhone', { optional: true, max: 30 }) ?? o.owner_phone).trim(), total, contract, sales, manager, r2(total - sales - manager), inst,
          oneOf(b, 'status', ['active', 'paused', 'closed'] as const, true) ?? o.status]);
      await audit(q, a.id, 'exclusive.project.update', 'commission_project', o.id, o, x);
      return x;
    });
    return ok({ project: shapeProject(p) });
  });

  /** One project: totals, its units and the owner's statement (كشف حساب المالك). */
  r.get('/exclusive/projects/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!canReserve(a) && !canSeeAll(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const p = await one(db, `SELECT * FROM commission_projects WHERE id = $1 AND kind = 'exclusive'`, [req.params.id]);
    if (!p) throw notFound();
    const { stats, units } = await projectStats(db, [p.id]);
    const visible = canSeeAll(a) ? units : units.filter((u) => u.sales_id === a.id);
    let statement: unknown[] | undefined;
    if (canManage(a)) {
      const st = await db.query(`
        SELECT * FROM (
          SELECT r.occurred_at AS at, 'in' AS dir, r.kind AS type, r.amount_egp AS amount, u.unit_no, r.payer_name AS who, r.payment_method AS method, r.ref_no
            FROM cash_receipts r JOIN ex_units u ON u.id = r.ex_unit_id WHERE u.project_id = $1 AND r.status = 'posted'
          UNION ALL
          SELECT COALESCE(x.approved_at, x.occurred_at), 'out', x.ex_kind, x.amount_egp, u.unit_no, x.beneficiary, NULL, x.ref_no
            FROM cash_expenses x LEFT JOIN ex_units u ON u.id = x.ex_unit_id
           WHERE (x.ex_project_id = $1 OR u.project_id = $1) AND x.status = 'posted'
          UNION ALL
          SELECT t.created_at, 'commission', 'commission_transfer', t.amount_egp, NULL, e.full_name, NULL, t.ref_no
            FROM ex_commission_transfers t JOIN employees e ON e.id = t.created_by WHERE t.project_id = $1
        ) s ORDER BY at DESC LIMIT 300`, [p.id]);
      const TYPE_AR: Record<string, string> = { ...KIND_AR, refund: 'رد عربون', owner_payout: 'صرف للمالك', commission_transfer: 'تحويل عمولة للمكتب' };
      statement = st.rows.map((x) => ({ at: x.at, dir: x.dir, type: x.type, typeAr: TYPE_AR[x.type] ?? x.type, amount: n(x.amount),
        unitNo: x.unit_no, who: x.who, method: x.method, refNo: Number(x.ref_no) }));
    }
    return ok({ project: shapeProject(p, canManage(a) ? stats[p.id] : undefined), units: visible.map((u) => shapeUnit(u, a)), statement,
      can: { manage: canManage(a), reserve: canReserve(a) && p.status === 'active', collect: hrDesk(a) } });
  });

  /** تحويل عمولة: the earned commission leaves the owner's money (up to what was earned and not yet moved). */
  r.post('/exclusive/projects/:id/commission-transfer', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const amount = num(b, 'amount', { min: 0.01, max: 100_000_000 })!;
    const note = (str(b, 'note', { optional: true, max: 500 }) ?? '').trim();
    const x = await db.tx(async (q) => {
      const p = await one(q, `SELECT id FROM commission_projects WHERE id = $1 AND kind = 'exclusive' FOR UPDATE`, [req.params.id]);
      if (!p) throw notFound();
      const st = (await projectStats(q, [p.id])).stats[p.id];
      if (amount > st.commission.pending + 0.001) throw invalid(`The commission waiting to move is ${fmt(st.commission.pending)}`, { field: 'amount', max: st.commission.pending });
      if (amount > st.owner.inTrust + 0.001) throw invalid(`Only ${fmt(st.owner.inTrust)} is held for this project`, { field: 'amount' });
      const t = await one(q, `INSERT INTO ex_commission_transfers (project_id, amount_egp, note, created_by, created_at) VALUES ($1,$2,$3,$4,$5) RETURNING *`, [p.id, amount, note, a.id, clock()]);
      await audit(q, a.id, 'exclusive.commission.transfer', 'commission_project', p.id, undefined, { amount, note });
      return t;
    });
    return ok({ transfer: { id: x.id, refNo: Number(x.ref_no), amount: n(x.amount_egp) } }, 201);
  });

  /** إذن صرف للمالك: from the office cashbox, approved by the other المالك / المدير العام. */
  r.post('/exclusive/projects/:id/owner-payout', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const amount = num(b, 'amount', { min: 0.01, max: 100_000_000 })!;
    const note = (str(b, 'note', { optional: true, max: 500 }) ?? '').trim();
    const x = await db.tx(async (q) => {
      const p = await one(q, `SELECT * FROM commission_projects WHERE id = $1 AND kind = 'exclusive' FOR UPDATE`, [req.params.id]);
      if (!p) throw notFound();
      const st = (await projectStats(q, [p.id])).stats[p.id];
      const free = r2(st.owner.due - st.owner.pendingPayout);
      if (amount > free + 0.001) throw invalid(`The owner's money available now is ${fmt(Math.max(free, 0))}`, { field: 'amount', max: free });
      const e = await one(q, `INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, notes, occurred_at, recorded_by, status, ex_project_id, ex_kind)
          VALUES ('office',$1,'صرف لمالك العقار',$2,$3,$4,$7,$5,'pending_approval',$6,'owner_payout') RETURNING id, ref_no`,
        [amount, `${p.name}${note ? ' — ' + note : ''}`, p.owner_name, note, a.id, p.id, clock()]);
      await audit(q, a.id, 'exclusive.owner_payout.request', 'cash_expense', e.id, undefined, { projectId: p.id, amount, note });
      for (const m of await holdersOf(q, 'cash.office', [a.id])) {
        await notify(q, { to: m, type: 'cash_expense_awaiting', title: `إذن صرف لمالك ${p.name}: ${fmt(amount)}`, body: `مستني موافقتك — ${p.owner_name}`,
          entity: 'cash_expense', entityId: e.id, dedupeKey: `cash:expense:${e.id}:awaiting` });
      }
      return e;
    });
    return ok({ expense: { id: x.id, refNo: Number(x.ref_no), status: 'pending_approval' } }, 201);
  });

  // ------------------------------------------------------------------ units
  r.get('/exclusive/units', async (req) => {
    const a = await authenticate(db, req);
    if (!canReserve(a) && !canSeeAll(a)) throw forbidden();
    const pid = req.query.get('projectId');
    const conds = ['true'], params: unknown[] = [];
    if (pid && isUuid(pid)) { params.push(pid); conds.push(`u.project_id = $${params.length}`); }
    if (!canSeeAll(a) || req.query.get('mine') === '1') { params.push(a.id); conds.push(`u.sales_id = $${params.length}`); }
    const units = await loadUnits(db, conds.join(' AND '), params);
    return ok({ units: units.map((u) => shapeUnit(u, a)) });
  });

  r.get('/exclusive/units/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const [u] = await loadUnits(db, 'u.id = $1', [req.params.id]);
    if (!u || (!canSeeAll(a) && u.sales_id !== a.id)) throw notFound();
    const inst = await db.query(`SELECT i.*, COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0) AS paid
                                   FROM ex_installments i WHERE i.unit_id = $1 ORDER BY i.seq`, [u.id]);
    const rc = await db.query(`SELECT r.id, r.ref_no, r.kind, r.amount_egp, r.payment_method, r.occurred_at, r.ex_installment_id, rb.full_name AS by_name
                                 FROM cash_receipts r JOIN employees rb ON rb.id = r.recorded_by WHERE r.ex_unit_id = $1 AND r.status = 'posted' ORDER BY r.occurred_at`, [u.id]);
    const t = today();
    return ok({
      unit: shapeUnit(u, a),
      installments: inst.rows.map((i) => ({ id: i.id, seq: i.seq, dueDate: ds(i.due_date), amount: n(i.amount_egp), paid: n(i.paid),
        left: r2(Math.max(n(i.amount_egp) - n(i.paid), 0)), status: n(i.paid) >= n(i.amount_egp) ? 'paid' : ds(i.due_date) < t ? 'overdue' : 'due' })),
      receipts: rc.rows.map((x) => ({ id: x.id, receiptNo: `R-${String(x.ref_no).padStart(6, '0')}`, kind: x.kind, kindAr: KIND_AR[x.kind] ?? x.kind,
        amount: n(x.amount_egp), method: x.payment_method, at: x.occurred_at, installmentId: x.ex_installment_id, byName: x.by_name })),
    });
  });

  /** حجز: the salesperson reserves a unit; it is reserved once the accountant records the deposit. */
  r.post('/exclusive/units', async (req) => {
    const a = await authenticate(db, req);
    if (!canReserve(a)) throw forbidden();
    const b = obj(req.body);
    const projectId = str(b, 'projectId', { min: 36, max: 36 })!;
    if (!isUuid(projectId)) throw invalid('Choose the project', { field: 'projectId' });
    const unitNo = str(b, 'unitNo', { min: 1, max: 60 })!.trim();
    const clientName = str(b, 'clientName', { min: 2, max: 120 })!.trim();
    const clientPhone = (str(b, 'clientPhone', { optional: true, max: 30 }) ?? '').trim();
    const price = num(b, 'unitPrice', { min: 1, max: 10_000_000_000 })!;
    const deposit = num(b, 'depositAmount', { min: 1, max: 10_000_000_000 })!;
    if (deposit > price) throw invalid('The deposit is more than the unit price', { field: 'depositAmount' });
    const notes = (str(b, 'notes', { optional: true, max: 1000 }) ?? '').trim();
    const salesId = canManage(a) && typeof b.salesId === 'string' && isUuid(b.salesId) ? b.salesId : a.id;
    const u = await db.tx(async (q) => {
      const p = await one(q, `SELECT * FROM commission_projects WHERE id = $1 AND kind = 'exclusive' FOR SHARE`, [projectId]);
      if (!p || p.status !== 'active') throw invalid('This project is not open for reservations', { field: 'projectId' });
      if (await one(q, `SELECT 1 FROM ex_units WHERE project_id = $1 AND lower(trim(unit_no)) = lower(trim($2)) AND status <> 'cancelled'`, [p.id, unitNo])) {
        throw conflict('This unit is already reserved / sold in this project');
      }
      const x = await one(q, `INSERT INTO ex_units (project_id, unit_no, client_name, client_phone, unit_price, deposit_amount, sales_id,
          total_pct, contract_pct, sales_pct, manager_pct, notes) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) RETURNING *`,
        [p.id, unitNo, clientName, clientPhone, price, deposit, salesId, p.total_pct, p.contract_pct, p.sales_pct, p.manager_pct, notes]);
      await audit(q, a.id, 'exclusive.unit.reserve', 'ex_unit', x.id, undefined, x);
      for (const m of await holdersOf(q, 'cash.hr_operate', [a.id])) {
        await notify(q, { to: m, type: 'exclusive_deposit', title: `عربون حجز مستني التسجيل: ${fmt(deposit)}`,
          body: `${p.name} — وحدة ${unitNo} — ${clientName}`, entity: 'ex_unit', entityId: x.id, dedupeKey: `ex:${x.id}:deposit` });
      }
      return x;
    });
    const [full] = await loadUnits(db, 'u.id = $1', [u.id]);
    return ok({ unit: shapeUnit(full, a) }, 201);
  });

  /** المحاسب records a payment (عربون / مقدم / قسط) into his cashbox — نقدي أو بنك. */
  r.post('/exclusive/units/:id/receipts', async (req) => {
    const a = await authenticate(db, req);
    if (!hrDesk(a)) throw forbidden('Payments are recorded by the accountant');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const kind = oneOf(b, 'kind', ['reservation', 'down_payment', 'installment'] as const)!;
    const amount = num(b, 'amount', { min: 0.01, max: 10_000_000_000 })!;
    const method = oneOf(b, 'paymentMethod', METHODS, true) ?? 'cash';
    const externalNo = (str(b, 'externalNo', { optional: true, max: 40 }) ?? '').trim() || null;
    const notes = (str(b, 'notes', { optional: true, max: 1000 }) ?? '').trim();
    const out = await db.tx(async (q) => {
      const u0 = await one(q, `SELECT * FROM ex_units WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!u0) throw notFound();
      const [u] = await loadUnits(q, 'u.id = $1', [u0.id]);
      const p = await one(q, `SELECT name FROM commission_projects WHERE id = $1`, [u.project_id]);
      let instId: string | null = null;
      if (kind === 'reservation') {
        if (!['reserving', 'reserved', 'contract_pending'].includes(u.status)) throw conflict('The reservation stage is over for this unit');
      } else if (kind === 'down_payment') {
        if (!['contract_pending', 'contracted'].includes(u.status)) throw conflict('Send the contract first');
        const due = r2(n(u.down_payment) - n(u.down_paid));
        if (amount > due + 0.001) throw invalid(`The down payment still due is ${fmt(Math.max(due, 0))}`, { field: 'amount', max: due });
      } else {
        if (u.status !== 'contracted' || u.payment_type !== 'installments') throw conflict('This unit has no installments');
        const iid = typeof b.installmentId === 'string' && isUuid(b.installmentId) ? b.installmentId : null;
        const i = iid ? await one(q, `SELECT i.*, COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0) AS paid
                                         FROM ex_installments i WHERE i.id = $1 AND i.unit_id = $2`, [iid, u.id])
          : await one(q, `SELECT i.*, COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0) AS paid
                            FROM ex_installments i WHERE i.unit_id = $1 AND i.amount_egp > COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0)
                           ORDER BY i.seq LIMIT 1`, [u.id]);
        if (!i) throw invalid('Choose the installment', { field: 'installmentId' });
        const left = r2(n(i.amount_egp) - n(i.paid));
        if (amount > left + 0.001) throw invalid(`What is left of installment ${i.seq} is ${fmt(left)}`, { field: 'amount', max: left });
        instId = i.id;
      }
      if (externalNo && await one(q, `SELECT 1 FROM cash_receipts WHERE lower(trim(external_no)) = lower(trim($1))`, [externalNo])) {
        throw conflict('This receipt number was already recorded');
      }
      const rc = await one(q, `INSERT INTO cash_receipts (kind, amount_egp, cashbox, actual_recipient_id, payer_name, payer_phone, purpose, payment_method,
          external_no, notes, occurred_at, recorded_by, ex_unit_id, ex_installment_id)
        VALUES ($1,$2,'hr',$3,$4,$5,$6,$7,$8,$9,$12,$3,$10,$11) RETURNING id, ref_no`,
        [kind, amount, a.id, u.client_name, u.client_phone, `${KIND_AR[kind]} — ${p.name} — وحدة ${u.unit_no}`, method, externalNo, notes, u.id, instId, clock()]);
      if (kind === 'reservation' && u.status === 'reserving') await q.query(`UPDATE ex_units SET status = 'reserved' WHERE id = $1`, [u.id]);
      await audit(q, a.id, 'exclusive.receipt', 'cash_receipt', rc.id, undefined, { unitId: u.id, kind, amount, method, installmentId: instId });
      await notify(q, { to: u.sales_id, type: 'exclusive_payment', title: `اتسجل ${KIND_AR[kind]}: ${fmt(amount)}`,
        body: `${p.name} — وحدة ${u.unit_no} — ${u.client_name}`, entity: 'ex_unit', entityId: u.id, dedupeKey: `ex:receipt:${rc.id}` });
      return rc;
    });
    return ok({ receipt: { id: out.id, receiptNo: `R-${String(out.ref_no).padStart(6, '0')}` } }, 201);
  });

  /** طلب تعاقد: the salesperson sends the contract terms; المالك / المدير العام approves. */
  r.post('/exclusive/units/:id/contract', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const type = oneOf(b, 'paymentType', ['cash', 'installments'] as const)!;
    const down = num(b, 'downPayment', { min: 0, max: 10_000_000_000 })!;
    const note = (str(b, 'note', { optional: true, max: 1000 }) ?? '').trim();
    await db.tx(async (q) => {
      const u = await one(q, `SELECT * FROM ex_units WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!u) throw notFound();
      if (u.sales_id !== a.id && !canManage(a)) throw forbidden();
      if (u.status !== 'reserved') throw conflict('The deposit has to be recorded first (the unit is not reserved yet)');
      const price = n(u.unit_price);
      if (down > price) throw invalid('The down payment is more than the price', { field: 'downPayment' });
      const p = await one(q, `SELECT * FROM commission_projects WHERE id = $1`, [u.project_id]);
      let count = null, every = null, first = null, instPct = null;
      if (type === 'installments') {
        count = num(b, 'installmentsCount', { min: 1, max: 240, int: true })!;
        every = num(b, 'everyMonths', { min: 1, max: 12, int: true })!;
        first = date(b, 'firstDueDate')!;
        instPct = num(b, 'installmentPct', { optional: true, min: 0, max: 100 }) ?? n(p.installment_pct);
        if (down >= price) throw invalid('Nothing is left for installments — choose cash', { field: 'downPayment' });
      } else if (Math.abs(down - price) > 0.001) {
        throw invalid('A cash sale pays the whole price', { field: 'downPayment' });
      }
      await q.query(`UPDATE ex_units SET status = 'contract_pending', payment_type = $2, down_payment = $3, installments_count = $4, every_months = $5,
          first_due_date = $6, installment_pct = $7, contract_note = $8, contract_requested_at = $9, reject_reason = NULL WHERE id = $1`,
        [u.id, type, down, count, every, first, instPct, note, clock()]);
      await audit(q, a.id, 'exclusive.contract.request', 'ex_unit', u.id, undefined, { type, down, count, every, first, instPct });
      for (const m of await holdersOf(q, 'cash.office', [u.sales_id])) {
        await notify(q, { to: m, type: 'exclusive_contract', title: `طلب تعاقد محتاج موافقتك: ${p.name} — وحدة ${u.unit_no}`,
          body: `${u.client_name} — ${type === 'cash' ? 'كاش' : `مقدم ${fmt(down)} + ${count} قسط`}`, entity: 'ex_unit', entityId: u.id,
          dedupeKey: `ex:${u.id}:contract:${Date.now()}` });
      }
    });
    const [full] = await loadUnits(db, 'u.id = $1', [req.params.id]);
    return ok({ unit: shapeUnit(full, a) });
  });

  r.post('/exclusive/units/:id/contract/decision', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const decision = oneOf(b, 'decision', ['approve', 'reject'] as const)!;
    const now = clock();
    await db.tx(async (q) => {
      const u = await one(q, `SELECT * FROM ex_units WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!u) throw notFound();
      if (u.status !== 'contract_pending') throw conflict('There is no contract waiting on this unit');
      if (u.sales_id === a.id) throw forbidden('You cannot approve your own contract');
      const p = await one(q, `SELECT * FROM commission_projects WHERE id = $1`, [u.project_id]);
      if (decision === 'reject') {
        const reason = str(b, 'reason', { min: 3, max: 500 })!;
        await q.query(`UPDATE ex_units SET status = 'reserved', reject_reason = $2 WHERE id = $1`, [u.id, reason]);
        await audit(q, a.id, 'exclusive.contract.reject', 'ex_unit', u.id, undefined, { reason });
        await notify(q, { to: u.sales_id, type: 'exclusive_contract_rejected', title: `اترفض طلب التعاقد: وحدة ${u.unit_no}`, body: reason,
          entity: 'ex_unit', entityId: u.id, dedupeKey: `ex:${u.id}:contract:rejected:${now.getTime()}` });
        return;
      }
      if (u.payment_type === 'installments') {
        for (const i of schedule(n(u.unit_price), n(u.down_payment), u.installments_count, u.every_months, ds(u.first_due_date))) {
          await q.query(`INSERT INTO ex_installments (unit_id, seq, due_date, amount_egp) VALUES ($1,$2,$3,$4)`, [u.id, i.seq, i.due, i.amount]);
        }
      }
      // the salesperson + his sales manager earn at the contract (cash or installments) — a normal commission
      const period = local(now).date.slice(0, 7) + '-01';
      const sm = await one(q, `SELECT m.id, m.status FROM employees e LEFT JOIN teams t ON t.id = e.team_id
                                 LEFT JOIN employees m ON m.id = ${SM_OF} WHERE e.id = $1`, [u.sales_id]);
      const smId = sm?.id && sm.status === 'active' ? sm.id : null;
      const price = n(u.unit_price), sp = n(u.sales_pct), mp = smId ? n(u.manager_pct) : 0;
      const cr = await one(q, `INSERT INTO commission_requests (project_id, employee_id, sales_manager_id, unit_no, price_per_m2, area_m2, unit_value,
          total_pct, sales_pct, manager_pct, company_pct, sales_amount, manager_amount, company_amount, note, status, period, decided_by, decided_at, ex_unit_id)
        VALUES ($1,$2,$3,$4,$5,1,$5,$6,$7,$8,$9,$10,$11,$12,$13,'approved',$14,$15,$16,$17) RETURNING *`,
        [u.project_id, u.sales_id, smId, u.unit_no, price, n(u.total_pct), sp, mp, r2(n(u.total_pct) - sp - mp), r2(price * sp / 100), r2(price * mp / 100),
          r2(price * (n(u.total_pct) - sp - mp) / 100), 'مشروع حصري', period, a.id, now, u.id]);
      if (n(cr.sales_amount) > 0) {
        await q.query(`INSERT INTO commission_entitlements (request_id, employee_id, role, amount_egp, period, included_at) VALUES ($1,$2,'sales',$3,$4,$5)`,
          [cr.id, u.sales_id, cr.sales_amount, period, now]);
      }
      if (smId && n(cr.manager_amount) > 0) {
        await q.query(`INSERT INTO commission_entitlements (request_id, employee_id, role, amount_egp, period, included_at) VALUES ($1,$2,'manager',$3,$4,$5)`,
          [cr.id, smId, cr.manager_amount, period, now]);
      }
      await q.query(`UPDATE ex_units SET status = 'contracted', contracted_by = $2, contracted_at = $3, commission_request_id = $4 WHERE id = $1`, [u.id, a.id, now, cr.id]);
      await audit(q, a.id, 'exclusive.contract.approve', 'ex_unit', u.id, undefined, { commissionRequestId: cr.id, period });
      await notify(q, { to: u.sales_id, type: 'exclusive_contract_approved', title: `اتوافق على التعاقد: وحدة ${u.unit_no} — عمولتك ${fmt(n(cr.sales_amount))}`,
        body: `${p.name} — هتنزل في مرتب ${period.slice(0, 7)}`, entity: 'ex_unit', entityId: u.id, dedupeKey: `ex:${u.id}:contract:approved` });
      for (const m of await holdersOf(q, 'cash.hr_operate')) {
        await notify(q, { to: m, type: 'exclusive_contract_approved', title: `تعاقد جديد: ${p.name} — وحدة ${u.unit_no}`,
          body: `حصّل المقدم من ${u.client_name}`, entity: 'ex_unit', entityId: u.id, dedupeKey: `ex:${u.id}:contract:approved:acc` });
      }
    });
    const [full] = await loadUnits(db, 'u.id = $1', [req.params.id]);
    return ok({ unit: shapeUnit(full, a) });
  });

  /** إلغاء الحجز: asked by the salesperson (or the management), approved by المالك / المدير العام. */
  r.post('/exclusive/units/:id/cancel', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const reason = str(obj(req.body), 'reason', { min: 3, max: 500 })!;
    await db.tx(async (q) => {
      const u = await one(q, `SELECT * FROM ex_units WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!u) throw notFound();
      if (u.sales_id !== a.id && !canManage(a)) throw forbidden();
      if (!['reserving', 'reserved', 'contract_pending'].includes(u.status)) throw conflict('Only a reservation can be cancelled');
      await q.query(`UPDATE ex_units SET status = 'cancel_pending', previous_status = status, cancel_reason = $2, cancel_requested_by = $3 WHERE id = $1`,
        [u.id, reason, a.id]);
      await audit(q, a.id, 'exclusive.cancel.request', 'ex_unit', u.id, undefined, { reason });
      for (const m of await holdersOf(q, 'cash.office', [a.id])) {
        await notify(q, { to: m, type: 'exclusive_cancel', title: `طلب إلغاء حجز: وحدة ${u.unit_no}`, body: `${u.client_name} — ${reason}`,
          entity: 'ex_unit', entityId: u.id, dedupeKey: `ex:${u.id}:cancel` });
      }
    });
    const [full] = await loadUnits(db, 'u.id = $1', [req.params.id]);
    return ok({ unit: shapeUnit(full, a) });
  });

  r.post('/exclusive/units/:id/cancel/decision', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const decision = oneOf(obj(req.body), 'decision', ['approve', 'reject'] as const)!;
    await db.tx(async (q) => {
      const u = await one(q, `SELECT * FROM ex_units WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!u) throw notFound();
      if (u.status !== 'cancel_pending') throw conflict('There is no cancel request on this unit');
      if (decision === 'reject') {
        await q.query(`UPDATE ex_units SET status = previous_status, cancel_reason = NULL WHERE id = $1`, [u.id]);
      } else {
        await q.query(`UPDATE ex_units SET status = 'cancelled', cancelled_by = $2, cancelled_at = now() WHERE id = $1`, [u.id, a.id]);
        const paid = await one(q, `SELECT COALESCE(sum(amount_egp), 0) AS s FROM cash_receipts WHERE ex_unit_id = $1 AND status = 'posted'`, [u.id]);
        if (n(paid.s) > 0) {
          for (const m of await holdersOf(q, 'cash.hr_operate')) {
            await notify(q, { to: m, type: 'exclusive_refund', title: `رجّع العربون: ${fmt(n(paid.s))}`, body: `وحدة ${u.unit_no} — ${u.client_name}`,
              entity: 'ex_unit', entityId: u.id, dedupeKey: `ex:${u.id}:refund` });
          }
        }
      }
      await audit(q, a.id, `exclusive.cancel.${decision}`, 'ex_unit', u.id);
      await notify(q, { to: u.sales_id, type: 'exclusive_cancel_decided', title: decision === 'approve' ? `اتلغى حجز وحدة ${u.unit_no}` : `اترفض إلغاء حجز وحدة ${u.unit_no}`,
        entity: 'ex_unit', entityId: u.id, dedupeKey: `ex:${u.id}:cancel:${decision}` });
    });
    const [full] = await loadUnits(db, 'u.id = $1', [req.params.id]);
    return ok({ unit: shapeUnit(full, a) });
  });

  /** رد العربون: the accountant gives a cancelled reservation's money back (from his cashbox). */
  r.post('/exclusive/units/:id/refund', async (req) => {
    const a = await authenticate(db, req);
    if (!hrDesk(a)) throw forbidden('The refund is paid by the accountant');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const amount = num(b, 'amount', { min: 0.01, max: 10_000_000_000 })!;
    const x = await db.tx(async (q) => {
      const u0 = await one(q, `SELECT id FROM ex_units WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!u0) throw notFound();
      const [u] = await loadUnits(q, 'u.id = $1', [u0.id]);
      if (u.status !== 'cancelled') throw conflict('Only a cancelled reservation is refunded');
      const left = r2(n(u.collected) - n(u.refunded));
      if (amount > left + 0.001) throw invalid(`What is left to give back is ${fmt(left)}`, { field: 'amount', max: left });
      const e = await one(q, `INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, notes, occurred_at, recorded_by, status, approved_by, approved_at, ex_unit_id, ex_project_id, ex_kind)
          VALUES ('hr',$1,'رد عربون حجز',$2,$3,$4,$8,$5,'posted',$5,$8,$6,$7,'refund') RETURNING id, ref_no`,
        [amount, `${u.project_name} — وحدة ${u.unit_no}`, u.client_name, (str(b, 'notes', { optional: true, max: 500 }) ?? '').trim(), a.id, u.id, u.project_id, clock()]);
      await audit(q, a.id, 'exclusive.refund', 'cash_expense', e.id, undefined, { unitId: u.id, amount });
      return e;
    });
    return ok({ expense: { id: x.id, refNo: Number(x.ref_no) } }, 201);
  });
};

/** For the owner's dashboard: every exclusive project's totals in one go. */
export async function exclusiveTotals(q: Q) {
  const ps = await q.query(`SELECT * FROM commission_projects WHERE kind = 'exclusive' ORDER BY created_at`);
  const { stats } = await projectStats(q, ps.rows.map((p) => p.id));
  return ps.rows.map((p) => ({ id: p.id, name: p.name, ownerName: p.owner_name, status: p.status, ...stats[p.id] }));
}
