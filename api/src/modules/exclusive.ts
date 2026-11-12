import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { local } from '../lib/time.ts';
import { date, isUuid, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';
import { canHrOperate, canOffice, hrDesk, hrOperators } from './cash.ts';
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
    SELECT u.*, p.name AS project_name, p.owner_name, p.kind AS project_kind, s.full_name AS sales_name, cb.full_name AS contracted_by_name,
           mk.name AS mk_name,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted'), 0) AS collected,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.payment_method <> 'cash'), 0) AS collected_bank,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.kind = 'reservation'), 0) AS deposit_paid,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.kind = 'down_payment'), 0) AS contract_paid,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.kind = 'installment'), 0) AS installments_paid,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_unit_id = u.id AND r.status = 'posted' AND r.kind IN ('reservation','down_payment')), 0) AS down_paid,
           COALESCE((SELECT sum(x.amount_egp) FROM cash_expenses x WHERE x.ex_unit_id = u.id AND x.ex_kind = 'refund' AND x.status = 'posted'), 0) AS refunded,
           COALESCE((SELECT sum(t.amount_egp) FROM ex_commission_transfers t WHERE t.unit_id = u.id), 0)
             + COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.commission_unit_id = u.id AND r.status = 'posted'), 0) AS commission_collected,
           COALESCE((SELECT sum(x.amount_egp) FROM ex_payments x WHERE x.unit_id = u.id AND x.status = 'pending'), 0) AS pending_money,
           (SELECT count(*) FROM ex_installments i WHERE i.unit_id = u.id)::int AS inst_total,
           (SELECT count(*) FROM ex_installments i WHERE i.unit_id = u.id AND i.amount_egp <=
              COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0))::int AS inst_paid,
           (SELECT min(i.due_date) FROM ex_installments i WHERE i.unit_id = u.id AND i.amount_egp >
              COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0)) AS next_due
      FROM ex_units u JOIN commission_projects p ON p.id = u.project_id JOIN employees s ON s.id = u.sales_id
      LEFT JOIN employees cb ON cb.id = u.contracted_by LEFT JOIN marketing_companies mk ON mk.id = u.mk_company_id
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
  const contracted = u.status === 'contracted';
  // the commission's split (of the unit's total commission): السيلز / مدير السيلز / شركة التسويق / المكتب
  const staff = contracted ? r2(price * (n(u.sales_pct) + n(u.manager_pct)) / 100) : 0;
  const marketing = contracted ? r2(price * n(u.mk_pct) / 100) : 0;
  const collected = r2(n(u.commission_collected));
  return { ...u, earned: r2(earned), upcoming: r2(upcoming), potential: r2(potential), completed, staff, marketing,
    commissionCollected: collected, receivable: r2(Math.max(earned - collected, 0)),
    office: contracted ? r2(price * Math.max(total - n(u.sales_pct) - n(u.manager_pct) - n(u.mk_pct), 0) / 100) : 0 };
}

function shapeUnit(u: any, a: Actor) {
  const status = u.completed ? 'completed' : u.status;
  const mine = u.sales_id === a.id;
  return {
    id: u.id, refNo: Number(u.ref_no), projectId: u.project_id, projectName: u.project_name, projectKind: u.project_kind, unitNo: u.unit_no,
    marketingCompanyId: u.mk_company_id, marketingCompanyName: u.mk_name, marketingPct: n(u.mk_pct),
    expectedContractDate: u.expected_contract_date ? String(u.expected_contract_date instanceof Date ? u.expected_contract_date.toISOString() : u.expected_contract_date).slice(0, 10) : null,
    clientName: u.client_name, clientPhone: u.client_phone, unitPrice: n(u.unit_price), depositAmount: n(u.deposit_amount),
    salesId: u.sales_id, salesName: u.sales_name, status, statusAr: STATUS_AR[status], notes: u.notes,
    ...(canSeeAll(a) ? { totalPct: n(u.total_pct), contractPct: n(u.contract_pct), managerPct: n(u.manager_pct) } : {}),
    salesPct: n(u.sales_pct),
    contract: u.payment_type ? {
      paymentType: u.payment_type, downPayment: n(u.down_payment), installmentsCount: u.installments_count, everyMonths: u.every_months,
      firstDueDate: u.first_due_date ? ds(u.first_due_date) : null, installmentPct: u.installment_pct == null ? null : n(u.installment_pct),
      note: u.contract_note, requestedAt: u.contract_requested_at, approvedAt: u.contracted_at, approvedByName: u.contracted_by_name,
      rejectReason: u.reject_reason,
    } : null,
    cancelReason: u.cancel_reason,
    money: { collected: r2(n(u.collected)), bank: r2(n(u.collected_bank)), cash: r2(n(u.collected) - n(u.collected_bank)),
      depositPaid: r2(n(u.deposit_paid)), downPaid: r2(n(u.down_paid)), refunded: r2(n(u.refunded)),
      remaining: r2(Math.max(n(u.unit_price) - n(u.collected), 0)), pending: r2(n(u.pending_money)) },
    installments: { total: u.inst_total, paid: u.inst_paid, nextDue: u.next_due ? ds(u.next_due) : null },
    // the commission figures are المالك / المدير العام's view
    // potential (محتملة) at the reservation → receivable (واجبة التحصيل) at the contract → collected (تم التحصيل)
    commission: canManage(a) ? { earned: u.earned, upcoming: u.upcoming, potential: u.potential, staff: u.staff,
      marketing: u.marketing, office: u.office, collected: u.commissionCollected, receivable: u.receivable } : undefined,
    myCommission: mine ? { amount: r2(n(u.unit_price) * n(u.sales_pct) / 100),
      state: u.status === 'contracted' ? 'earned' : u.status === 'cancelled' ? 'cancelled' : 'potential' } : undefined,
    createdAt: u.created_at,
    can: {
      collect: (hrDesk(a) || canOffice(a)) && u.project_kind === 'exclusive' && u.status === 'contracted' && u.payment_type === 'installments',
      receive: (hrDesk(a) || canOffice(a)) && n(u.pending_money) > 0,
      requestContract: (mine || canManage(a)) && u.status === 'reserved',
      collectCommission: canManage(a) && u.status === 'contracted' && u.receivable > 0,
      decideContract: canManage(a) && u.status === 'contract_pending' && !mine,
      requestCancel: (mine || canManage(a)) && ['reserving', 'reserved', 'contract_pending'].includes(u.status),
      decideCancel: canManage(a) && u.status === 'cancel_pending',
      // السيلز (or the management) edits the reservation / the contract's client details
      edit: (mine || canManage(a)) && ['reserving', 'reserved', 'contracted'].includes(u.status),
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
        potential: sum((u) => u.potential), staff: sum((u) => u.staff), marketing: sum((u) => u.marketing), office: sum((u) => u.office) },
      owner: { inTrust: trust, paid: ownerPaid, pendingPayout: r2(n(m.owner_pending)),
        due: r2(Math.max(trust - Math.max(earned - transferred, 0), 0)) },
      sales: sum((u) => (u.status === 'contracted' ? n(u.unit_price) : 0)),
    };
  }
  return { stats: out, units };
}

function shapePayment(x: any) {
  return { id: x.id, refNo: Number(x.ref_no), unitId: x.unit_id, kind: x.kind, kindAr: x.kind === 'reservation' ? 'عربون الحجز' : 'مقدم التعاقد',
    amount: n(x.amount_egp), method: x.payment_method, methodAr: x.payment_method === 'cash' ? 'نقدي' : 'بنك', at: x.created_at,
    unitNo: x.unit_no, clientName: x.client_name, projectName: x.project_name, salesName: x.sales_name };
}

function shapeProject(p: any, stats?: any, a?: Actor) {
  // the office's figures (its % / the owner) are المالك / المدير العام's; the sales team sees its own % only
  if (a && !canSeeAll(a)) {
    return { id: p.id, name: p.name, kind: p.kind, status: p.status, salesPct: n(p.sales_pct), createdAt: p.created_at };
  }
  return {
    id: p.id, name: p.name, kind: p.kind, status: p.status, ownerName: p.owner_name, ownerPhone: p.owner_phone,
    totalPct: n(p.total_pct), contractPct: n(p.contract_pct), installmentPct: n(p.installment_pct),
    salesPct: n(p.sales_pct), managerPct: n(p.manager_pct), companyPct: n(p.company_pct), marketingPct: n(p.marketing_pct),
    createdAt: p.created_at, stats,
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
    const kind = req.query.get('kind') ?? 'exclusive';
    const kindSql = kind === 'all' ? 'true' : kind === 'marketing' ? `kind = 'marketing'` : `kind = 'exclusive'`;
    const rows = await db.query(`SELECT * FROM commission_projects WHERE ${kindSql}
                                  ${canManage(a) ? '' : `AND status = 'active'`} ORDER BY status = 'active' DESC, created_at DESC`);
    const st = canManage(a) ? (await projectStats(db, rows.rows.map((p) => p.id))).stats : {};
    return ok({ projects: rows.rows.map((p) => shapeProject(p, st[p.id], a)), canManage: canManage(a), canReserve: canReserve(a), canCollect: hrDesk(a) });
  });

  r.post('/exclusive/projects', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    const b = obj(req.body);
    const name = str(b, 'name', { min: 2, max: 120 })!.trim();
    const ownerName = str(b, 'ownerName', { min: 2, max: 120 })!.trim();
    const ownerPhone = (str(b, 'ownerPhone', { optional: true, max: 30 }) ?? '').trim();
    const total = pct(b, 'totalPct', 5), contract = pct(b, 'contractPct', 3), sales = pct(b, 'salesPct', 0.2),
      manager = pct(b, 'managerPct', 0.1), inst = pct(b, 'installmentPct', 0.5), mkPct = pct(b, 'marketingPct', 0);
    if (mkPct > total - sales - manager) throw invalid('عمولة شركات التسويق أكبر من نصيب المكتب', { field: 'marketingPct' });
    if (contract > total) throw invalid('نسبة التعاقد مينفعش تكون أكبر من إجمالي العمولة', { field: 'contractPct' });
    if (sales + manager > contract) throw invalid('نسبة السيلز + المدير لازم تكون من ضمن نسبة التعاقد', { field: 'salesPct' });
    const p = await db.tx(async (q) => {
      if (await one(q, `SELECT 1 FROM commission_projects WHERE lower(trim(name)) = lower(trim($1))`, [name])) {
        throw invalid('فيه مشروع بنفس الاسم', { field: 'name' });
      }
      const x = await one(q, `INSERT INTO commission_projects (name, total_pct, sales_pct, manager_pct, company_pct, created_by, kind,
          owner_name, owner_phone, contract_pct, installment_pct, marketing_pct)
        VALUES ($1,$2,$3,$4,$5,$6,'exclusive',$7,$8,$9,$10,$11) RETURNING *`,
        [name, total, sales, manager, r2(total - sales - manager), a.id, ownerName, ownerPhone, contract, inst, mkPct]);
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
        sales = pct(b, 'salesPct', n(o.sales_pct)), manager = pct(b, 'managerPct', n(o.manager_pct)), inst = pct(b, 'installmentPct', n(o.installment_pct)),
        mkPct = pct(b, 'marketingPct', n(o.marketing_pct));
      if (contract > total || sales + manager > contract || mkPct > total - sales - manager) throw invalid('راجع النسب', { field: 'contractPct' });
      const x = await one(q, `UPDATE commission_projects SET name = $2, owner_name = $3, owner_phone = $4, total_pct = $5, contract_pct = $6,
          sales_pct = $7, manager_pct = $8, company_pct = $9, installment_pct = $10, status = $11, marketing_pct = $12, updated_at = now() WHERE id = $1 RETURNING *`,
        [o.id, (str(b, 'name', { optional: true, min: 2, max: 120 }) ?? o.name).trim(), (str(b, 'ownerName', { optional: true, min: 2, max: 120 }) ?? o.owner_name).trim(),
          (str(b, 'ownerPhone', { optional: true, max: 30 }) ?? o.owner_phone).trim(), total, contract, sales, manager, r2(total - sales - manager), inst,
          oneOf(b, 'status', ['active', 'paused', 'closed'] as const, true) ?? o.status, mkPct]);
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
    const p = await one(db, `SELECT * FROM commission_projects WHERE id = $1`, [req.params.id]);
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
    return ok({ project: shapeProject(p, canManage(a) ? stats[p.id] : undefined, a), units: visible.map((u) => shapeUnit(u, a)), statement,
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
      if (amount > st.commission.pending + 0.001) throw invalid(`العمولة اللي ممكن تتحوّل دلوقتي ${fmt(st.commission.pending)}`, { field: 'amount', max: st.commission.pending });
      if (amount > st.owner.inTrust + 0.001) throw invalid(`اللي في أمانة المشروع ${fmt(st.owner.inTrust)} بس`, { field: 'amount' });
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
      if (amount > free + 0.001) throw invalid(`المتاح للمالك دلوقتي ${fmt(Math.max(free, 0))}`, { field: 'amount', max: free });
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
    const stage = req.query.get('stage');
    if (stage === 'reservation') conds.push(`u.status IN ('reserving','reserved','contract_pending','cancel_pending','cancelled')`);
    if (stage === 'contract') conds.push(`u.status = 'contracted'`);
    const kind = req.query.get('kind');
    if (kind === 'exclusive' || kind === 'marketing') { params.push(kind); conds.push(`p.kind = $${params.length}`); }
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
      pendingPayments: (await db.query(`SELECT * FROM ex_payments WHERE unit_id = $1 AND status = 'pending' ORDER BY created_at`, [u.id])).rows.map(shapePayment),
    });
  });

  /**
   * Money the sales flow brings (عربون الحجز / باقي مقدم التعاقد of an exclusive unit) waits as a pending payment:
   * the accountant and المالك / المدير العام are told, and one of them presses «تم استلام المبلغ».
   */
  async function requestPayment(q: Q, a: Actor, u: any, projectName: string, kind: 'reservation' | 'down_payment', amount: number, method: string) {
    const x = await one(q, `INSERT INTO ex_payments (unit_id, kind, amount_egp, payment_method, requested_by, created_at) VALUES ($1,$2,$3,$4,$5,$6) RETURNING *`,
      [u.id, kind, amount, method, a.id, clock()]);
    await audit(q, a.id, 'exclusive.payment.request', 'ex_payment', x.id, undefined, { unitId: u.id, kind, amount, method });
    const to = new Set([...(await hrOperators(q)), ...(await holdersOf(q, 'cash.office', [a.id]))]);
    to.delete(a.id);
    const what = kind === 'reservation' ? 'حجز جديد' : 'تعاقد جديد';
    for (const m of to) {
      await notify(q, { to: m, type: 'exclusive_payment_pending', title: `${what} — اضغط «تم استلام المبلغ»: ${fmt(amount)}${method === 'cash' ? '' : ' (بنك)'}`,
        body: `${projectName} — وحدة ${u.unit_no} — ${u.client_name}`, entity: 'ex_unit', entityId: u.id, dedupeKey: `ex:payment:${x.id}` });
    }
    return x;
  }

  /**
   * تعاقد: the salesperson (or المالك / المدير العام) turns a reservation into a contract. The down payment (cash: the
   * whole price) of an exclusive unit goes into the cashbox, the installments are scheduled, the commission becomes
   * receivable; the staff commission is a request المالك / المدير العام approves (at once when he made the contract).
   */
  async function makeContract(q: Q, a: Actor, u: any, p: any, b: Record<string, unknown>) {
    if (u.sales_id !== a.id && !canManage(a)) throw forbidden();
    if (u.status === 'reserving') throw conflict('العربون لسه مستني تأكيد الاستلام من المحاسب / المدير');
    if (!['reserved', 'contract_pending'].includes(u.status)) throw conflict('الوحدة دي مش في مرحلة الحجز');
    const now = clock();
    const price = n(u.unit_price);
    const note = (str(b, 'note', { optional: true, max: 1000 }) ?? '').trim();
    const method = oneOf(b, 'paymentMethod', METHODS, true) ?? 'cash';
    let type: 'cash' | 'installments' = 'cash', down = 0, count = null, every = null, first = null, instPct: number | null = null;
    if (p.kind === 'exclusive') {
      type = oneOf(b, 'paymentType', ['cash', 'installments'] as const)!;
      down = num(b, 'downPayment', { min: 0, max: 10_000_000_000, optional: true }) ?? 0;
      if (down > price) throw invalid('المقدم أكبر من سعر الوحدة', { field: 'downPayment' });
      if (type === 'installments') {
        count = num(b, 'installmentsCount', { min: 1, max: 240, int: true })!;
        every = num(b, 'everyMonths', { min: 1, max: 12, int: true })!;
        first = date(b, 'firstDueDate')!;
        instPct = num(b, 'installmentPct', { optional: true, min: 0, max: 100 }) ?? n(p.installment_pct);
        if (down >= price) throw invalid('مفيش باقي للأقساط — اختار كاش', { field: 'downPayment' });
      } else {
        down = price; // كاش: the whole price
      }
      const depositPaid = n(u.deposit_amount); // the reservation's amount — fixed, it counts toward the down payment
      if (down < depositPaid) throw invalid(`المقدم لازم يكون أكبر من العربون (${fmt(depositPaid)})`, { field: 'downPayment' });
    }
    await q.query(`UPDATE ex_units SET status = 'contracted', payment_type = $2, down_payment = $3, installments_count = $4, every_months = $5,
        first_due_date = $6, installment_pct = $7, contract_note = $8, contract_requested_at = COALESCE(contract_requested_at, $9),
        contracted_by = $10, contracted_at = $9, reject_reason = NULL WHERE id = $1`,
      [u.id, type, down, count, every, first, instPct, note, now, a.id]);
    if (type === 'installments') {
      for (const i of schedule(price, down, count!, every!, first!)) {
        await q.query(`INSERT INTO ex_installments (unit_id, seq, due_date, amount_egp) VALUES ($1,$2,$3,$4)`, [u.id, i.seq, i.due, i.amount]);
      }
    }
    // the money of the contract (the deposit already in counts toward it)
    if (p.kind === 'exclusive') {
      const rest = r2(down - n(u.deposit_amount));
      if (rest > 0) await requestPayment(q, a, u, p.name, 'down_payment', rest, method);
    }
    // the staff commission (السيلز + مدير السيلز) — a normal commission request
    const live = await one(q, `SELECT * FROM commission_requests WHERE project_id = $1 AND lower(trim(unit_no)) = lower(trim($2))
                                  AND status IN ('pending','approved')`, [u.project_id, u.unit_no]);
    let crId = live?.id ?? null;
    if (!live) {
      const period = local(now).date.slice(0, 7) + '-01';
      const sm = await one(q, `SELECT m.id, m.status FROM employees e LEFT JOIN teams t ON t.id = e.team_id
                                 LEFT JOIN employees m ON m.id = ${SM_OF} WHERE e.id = $1`, [u.sales_id]);
      const smId = sm?.id && sm.status === 'active' ? sm.id : null;
      const sp = n(u.sales_pct), mp = smId ? n(u.manager_pct) : 0;
      const approveNow = a.id !== u.sales_id; // المالك / المدير العام made it: approved at once
      const cr = await one(q, `INSERT INTO commission_requests (project_id, employee_id, sales_manager_id, unit_no, price_per_m2, area_m2, unit_value,
          total_pct, sales_pct, manager_pct, company_pct, sales_amount, manager_amount, company_amount, note, status, period, decided_by, decided_at, ex_unit_id)
        VALUES ($1,$2,$3,$4,$5,1,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18) RETURNING *`,
        [u.project_id, u.sales_id, smId, u.unit_no, price, n(u.total_pct), sp, mp, r2(n(u.total_pct) - sp - mp), r2(price * sp / 100), r2(price * mp / 100),
          r2(price * (n(u.total_pct) - sp - mp) / 100), p.kind === 'exclusive' ? 'تعاقد مشروع حصري' : 'تعاقد مشروع تسويق',
          approveNow ? 'approved' : 'pending', approveNow ? period : null, approveNow ? a.id : null, approveNow ? now : null, u.id]);
      if (approveNow) {
        if (n(cr.sales_amount) > 0) {
          await q.query(`INSERT INTO commission_entitlements (request_id, employee_id, role, amount_egp, period, included_at) VALUES ($1,$2,'sales',$3,$4,$5)`,
            [cr.id, u.sales_id, cr.sales_amount, period, now]);
        }
        if (smId && n(cr.manager_amount) > 0) {
          await q.query(`INSERT INTO commission_entitlements (request_id, employee_id, role, amount_egp, period, included_at) VALUES ($1,$2,'manager',$3,$4,$5)`,
            [cr.id, smId, cr.manager_amount, period, now]);
        }
      } else {
        for (const m of await holdersOf(q, 'commission.approve', [u.sales_id])) {
          await notify(q, { to: m, type: 'commission_request', title: `عمولة تعاقد مستنية اعتمادك: وحدة ${u.unit_no}`,
            body: `${p.name} — ${u.client_name}`, entity: 'commission_request', entityId: cr.id, dedupeKey: `commission:${cr.id}:new` });
        }
      }
      crId = cr.id;
    }
    await q.query(`UPDATE ex_units SET commission_request_id = $2 WHERE id = $1`, [u.id, crId]);
    await audit(q, a.id, 'exclusive.contract', 'ex_unit', u.id, undefined, { type, down, count, every, first, instPct, commissionRequestId: crId });
    const commission = r2(price * n(u.total_pct) / 100);
    for (const m of await holdersOf(q, 'cash.office', [a.id])) {
      await notify(q, { to: m, type: 'exclusive_contract', title: `تعاقد: ${p.name} — وحدة ${u.unit_no}`,
        body: `${u.client_name} — عمولة واجبة التحصيل ${fmt(commission)}`, entity: 'ex_unit', entityId: u.id, dedupeKey: `ex:${u.id}:contracted` });
    }
  }

  /**
   * One unit / one client per project: the unit number is never taken twice; a contract (تعاقد جديد) for a client or
   * a unit that already has an open reservation is refused — that reservation is the one to turn into the contract.
   */
  async function noDuplicate(q: Q, projectId: string, x: { unitNo: string; clientName: string; clientPhone: string }, exceptId: string | null, contract: boolean) {
    const others = (await q.query(`SELECT id, unit_no, client_name, client_phone, status FROM ex_units
                                    WHERE project_id = $1 AND status <> 'cancelled' AND ($2::uuid IS NULL OR id <> $2)`, [projectId, exceptId])).rows;
    const digits = (v: string) => String(v ?? '').replace(/\D/g, '').slice(-10);
    const same = (a: string, b: string) => String(a ?? '').trim().toLowerCase() === String(b ?? '').trim().toLowerCase();
    if (others.some((o) => same(o.unit_no, x.unitNo))) {
      const o = others.find((o) => same(o.unit_no, x.unitNo))!;
      throw conflict(['contracted'].includes(o.status) ? 'الوحدة دي متعاقد عليها بالفعل في المشروع ده'
        : contract ? 'الوحدة دي عليها حجز — حوّل الحجز لتعاقد من صفحة الحجز' : 'الوحدة دي محجوزة بالفعل في المشروع ده');
    }
    if (!contract) return;
    const open = others.filter((o) => ['reserving', 'reserved', 'contract_pending', 'cancel_pending'].includes(o.status));
    const phone = digits(x.clientPhone);
    const hit = open.find((o) => same(o.client_name, x.clientName) || (phone.length >= 8 && digits(o.client_phone) === phone));
    if (hit) throw conflict(`العميل ده عليه حجز في المشروع ده (وحدة ${hit.unit_no}) — حوّل الحجز لتعاقد من صفحة الحجز`);
  }

  /**
   * حجز: the salesperson reserves a unit from «المبيعات». An exclusive unit's deposit goes into the cashbox at once;
   * a marketing unit holds no money of ours. With `contract` it is a direct contract (تعاقد جديد) in one go.
   * «مصدر العميل»: the office, or a marketing company paid by commission (the project's marketing %).
   */
  r.post('/exclusive/units', async (req) => {
    const a = await authenticate(db, req);
    if (!canReserve(a)) throw forbidden();
    const b = obj(req.body);
    const projectId = str(b, 'projectId', { min: 36, max: 36 })!;
    if (!isUuid(projectId)) throw invalid('اختار المشروع', { field: 'projectId' });
    const unitNo = str(b, 'unitNo', { min: 1, max: 60 })!.trim();
    const clientName = str(b, 'clientName', { min: 2, max: 120 })!.trim();
    const clientPhone = (str(b, 'clientPhone', { optional: true, max: 30 }) ?? '').trim();
    const price = num(b, 'unitPrice', { min: 1, max: 10_000_000_000 })!;
    const notes = (str(b, 'notes', { optional: true, max: 1000 }) ?? '').trim();
    const method = oneOf(b, 'paymentMethod', METHODS, true) ?? 'cash';
    const salesId = canManage(a) && typeof b.salesId === 'string' && isUuid(b.salesId) ? b.salesId : a.id;
    const mkId = typeof b.marketingCompanyId === 'string' && isUuid(b.marketingCompanyId) ? b.marketingCompanyId : null;
    const contract = b.contract && typeof b.contract === 'object' ? obj(b.contract) : null;
    // «التاريخ المتوقع للتعاقد»: the expected commission falls in that month
    const expected = contract ? null : date(b, 'expectedContractDate', true) ?? null;
    if (expected && expected < local(clock()).date) throw invalid('التاريخ المتوقع للتعاقد لازم يكون النهارده أو بعده', { field: 'expectedContractDate' });
    const u = await db.tx(async (q) => {
      const p = await one(q, `SELECT * FROM commission_projects WHERE id = $1 FOR SHARE`, [projectId]);
      if (!p || p.status !== 'active') throw invalid('المشروع ده مش بيستقبل حجوزات دلوقتي', { field: 'projectId' });
      const exclusive = p.kind === 'exclusive';
      const deposit = contract ? 0 : exclusive ? num(b, 'depositAmount', { min: 1, max: 10_000_000_000 }) ?? 0
        : num(b, 'depositAmount', { min: 0, max: 10_000_000_000, optional: true }) ?? 0;
      if (deposit > price) throw invalid('العربون أكبر من سعر الوحدة', { field: 'depositAmount' });
      await noDuplicate(q, p.id, { unitNo, clientName, clientPhone }, null, !!contract);
      let mkPct = 0;
      if (mkId) {
        const mk = await one(q, `SELECT * FROM marketing_companies WHERE id = $1 AND status = 'active' AND kind = 'commission'`, [mkId]);
        if (!mk) throw invalid('اختار شركة التسويق', { field: 'marketingCompanyId' });
        mkPct = n(p.marketing_pct) > 0 ? n(p.marketing_pct) : n(mk.default_pct);
        if (canManage(a)) mkPct = num(b, 'marketingPct', { optional: true, min: 0, max: 100 }) ?? mkPct;
        if (mkPct > n(p.company_pct) + 0.00001) throw invalid(`نسبة شركة التسويق أكبر من نصيب المكتب (${n(p.company_pct)}٪)`, { field: 'marketingPct' });
      }
      // a marketing project earns its whole commission at the contract (no staging on installments)
      const contractPct = exclusive ? p.contract_pct : p.total_pct;
      const x = await one(q, `INSERT INTO ex_units (project_id, unit_no, client_name, client_phone, unit_price, deposit_amount, sales_id,
          total_pct, contract_pct, sales_pct, manager_pct, notes, mk_company_id, mk_pct, status) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) RETURNING *`,
        [p.id, unitNo, clientName, clientPhone, price, deposit, salesId, p.total_pct, contractPct, p.sales_pct, p.manager_pct, notes, mkId, mkPct,
          exclusive && deposit > 0 && !contract ? 'reserving' : 'reserved']);
      if (expected) await q.query(`UPDATE ex_units SET expected_contract_date = $2 WHERE id = $1`, [x.id, expected]);
      await audit(q, a.id, 'exclusive.unit.reserve', 'ex_unit', x.id, undefined, x);
      // a direct contract: the deposit is part of its down payment (one pending payment for the whole of it)
      if (exclusive && deposit > 0 && !contract) await requestPayment(q, a, x, p.name, 'reservation', deposit, method);
      if (contract) await makeContract(q, a, x, p, { paymentMethod: method, ...contract });
      return x;
    });
    const [full] = await loadUnits(db, 'u.id = $1', [u.id]);
    return ok({ unit: shapeUnit(full, a) }, 201);
  });

  /** المحاسب records a payment (عربون / مقدم / قسط) into his cashbox — نقدي أو بنك. */
  r.post('/exclusive/units/:id/receipts', async (req) => {
    const a = await authenticate(db, req);
    if (!hrDesk(a) && !canOffice(a)) throw forbidden('تسجيل الفلوس من المحاسب أو المدير بس');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const box = hrDesk(a) ? 'hr' : 'office';
    const kind = oneOf(b, 'kind', ['reservation', 'down_payment', 'installment'] as const)!;
    let amount = num(b, 'amount', { min: 0.01, max: 10_000_000_000, optional: true }) ?? 0;
    const method = oneOf(b, 'paymentMethod', METHODS, true) ?? 'cash';
    const externalNo = (str(b, 'externalNo', { optional: true, max: 40 }) ?? '').trim() || null;
    const notes = (str(b, 'notes', { optional: true, max: 1000 }) ?? '').trim();
    const out = await db.tx(async (q) => {
      const u0 = await one(q, `SELECT * FROM ex_units WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!u0) throw notFound();
      const [u] = await loadUnits(q, 'u.id = $1', [u0.id]);
      const p = await one(q, `SELECT name FROM commission_projects WHERE id = $1`, [u.project_id]);
      let instId: string | null = null;
      if (kind !== 'installment' && !amount) throw invalid('اكتب المبلغ', { field: 'amount' });
      if (kind === 'reservation') {
        if (!['reserving', 'reserved', 'contract_pending'].includes(u.status)) throw conflict('الوحدة دي عدّت مرحلة الحجز');
      } else if (kind === 'down_payment') {
        if (!['contract_pending', 'contracted'].includes(u.status)) throw conflict('ابعت طلب التعاقد الأول');
        const due = r2(n(u.down_payment) - n(u.down_paid));
        if (amount > due + 0.001) throw invalid(`الباقي من المقدم ${fmt(Math.max(due, 0))}`, { field: 'amount', max: due });
      } else {
        if (u.status !== 'contracted' || u.payment_type !== 'installments') throw conflict('الوحدة دي مفيهاش أقساط');
        const iid = typeof b.installmentId === 'string' && isUuid(b.installmentId) ? b.installmentId : null;
        const i = iid ? await one(q, `SELECT i.*, COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0) AS paid
                                         FROM ex_installments i WHERE i.id = $1 AND i.unit_id = $2`, [iid, u.id])
          : await one(q, `SELECT i.*, COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0) AS paid
                            FROM ex_installments i WHERE i.unit_id = $1 AND i.amount_egp > COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.ex_installment_id = i.id AND r.status = 'posted'), 0)
                           ORDER BY i.seq LIMIT 1`, [u.id]);
        if (!i) throw invalid('اختار القسط', { field: 'installmentId' });
        const left = r2(n(i.amount_egp) - n(i.paid));
        if (!amount) amount = left; // «تم استلام القسط»: the installment's amount, nobody types it
        if (amount > left + 0.001) throw invalid(`الباقي من القسط ${i.seq} هو ${fmt(left)}`, { field: 'amount', max: left });
        instId = i.id;
      }
      if (externalNo && await one(q, `SELECT 1 FROM cash_receipts WHERE lower(trim(external_no)) = lower(trim($1))`, [externalNo])) {
        throw conflict('رقم الإيصال ده اتسجل قبل كده');
      }
      const rc = await one(q, `INSERT INTO cash_receipts (kind, amount_egp, cashbox, actual_recipient_id, payer_name, payer_phone, purpose, payment_method,
          external_no, notes, occurred_at, recorded_by, ex_unit_id, ex_installment_id)
        VALUES ($1,$2,$13,$3,$4,$5,$6,$7,$8,$9,$12,$3,$10,$11) RETURNING id, ref_no`,
        [kind, amount, a.id, u.client_name, u.client_phone, `${KIND_AR[kind]} — ${p.name} — وحدة ${u.unit_no}`, method, externalNo, notes, u.id, instId, clock(), box]);
      if (kind === 'reservation' && u.status === 'reserving') await q.query(`UPDATE ex_units SET status = 'reserved' WHERE id = $1`, [u.id]);
      await audit(q, a.id, 'exclusive.receipt', 'cash_receipt', rc.id, undefined, { unitId: u.id, kind, amount, method, installmentId: instId });
      await notify(q, { to: u.sales_id, type: 'exclusive_payment', title: `اتسجل ${KIND_AR[kind]}: ${fmt(amount)}`,
        body: `${p.name} — وحدة ${u.unit_no} — ${u.client_name}`, entity: 'ex_unit', entityId: u.id, dedupeKey: `ex:receipt:${rc.id}` });
      return rc;
    });
    return ok({ receipt: { id: out.id, receiptNo: `R-${String(out.ref_no).padStart(6, '0')}` } }, 201);
  });

  /**
   * تعديل: the salesperson (or the management) edits his reservation — unit, client, price, expected contract date,
   * client source, and the deposit while it still waits for «تم استلام المبلغ». After the contract only the client's
   * details and the notes (the money and the installments are fixed).
   */
  r.patch('/exclusive/units/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    await db.tx(async (q) => {
      const u = await one(q, `SELECT * FROM ex_units WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!u) throw notFound();
      if (u.sales_id !== a.id && !canManage(a)) throw forbidden();
      if (!['reserving', 'reserved', 'contracted'].includes(u.status)) throw conflict('الوحدة دي مش بتتعدّل دلوقتي');
      const p = await one(q, `SELECT * FROM commission_projects WHERE id = $1`, [u.project_id]);
      const clientName = (str(b, 'clientName', { optional: true, min: 2, max: 120 }) ?? u.client_name).trim();
      const clientPhone = (str(b, 'clientPhone', { optional: true, max: 30 }) ?? u.client_phone).trim();
      const notes = (str(b, 'notes', { optional: true, max: 1000 }) ?? u.notes).trim();
      const contracted = u.status === 'contracted';
      let unitNo = u.unit_no, price = n(u.unit_price), expected = u.expected_contract_date, mkId = u.mk_company_id, mkPct = n(u.mk_pct), deposit = n(u.deposit_amount);
      if (!contracted) {
        unitNo = (str(b, 'unitNo', { optional: true, min: 1, max: 60 }) ?? u.unit_no).trim();
        price = num(b, 'unitPrice', { optional: true, min: 1, max: 10_000_000_000 }) ?? price;
        if (b.expectedContractDate !== undefined) expected = date(b, 'expectedContractDate', true) ?? null;
        if (b.marketingCompanyId !== undefined) {
          mkId = typeof b.marketingCompanyId === 'string' && isUuid(b.marketingCompanyId) ? b.marketingCompanyId : null;
          mkPct = 0;
          if (mkId) {
            const mk = await one(q, `SELECT * FROM marketing_companies WHERE id = $1 AND status = 'active' AND kind = 'commission'`, [mkId]);
            if (!mk) throw invalid('اختار شركة التسويق', { field: 'marketingCompanyId' });
            mkPct = n(p.marketing_pct) > 0 ? n(p.marketing_pct) : n(mk.default_pct);
          }
        }
        if (b.depositAmount !== undefined && p.kind === 'exclusive') {
          const pend = await one(q, `SELECT * FROM ex_payments WHERE unit_id = $1 AND kind = 'reservation' AND status = 'pending' FOR UPDATE`, [u.id]);
          const d = num(b, 'depositAmount', { min: 1, max: 10_000_000_000 })!;
          if (d !== deposit) {
            if (!pend) throw conflict('العربون اتأكد استلامه — مايتغيرش');
            await q.query(`UPDATE ex_payments SET amount_egp = $2 WHERE id = $1`, [pend.id, d]);
            deposit = d;
          }
        }
        if (deposit > price) throw invalid('العربون أكبر من سعر الوحدة', { field: 'depositAmount' });
      }
      await noDuplicate(q, u.project_id, { unitNo, clientName, clientPhone }, u.id, false);
      await q.query(`UPDATE ex_units SET unit_no = $2, client_name = $3, client_phone = $4, unit_price = $5, deposit_amount = $6, notes = $7,
          expected_contract_date = $8, mk_company_id = $9, mk_pct = $10, contract_note = CASE WHEN $11::text IS NULL THEN contract_note ELSE $11 END
        WHERE id = $1`,
        [u.id, unitNo, clientName, clientPhone, price, deposit, notes, expected, mkId, mkPct,
          contracted ? (str(b, 'contractNote', { optional: true, max: 1000 }) ?? null) : null]);
      await audit(q, a.id, 'exclusive.unit.edit', 'ex_unit', u.id,
        { unitNo: u.unit_no, clientName: u.client_name, clientPhone: u.client_phone, price: n(u.unit_price), deposit: n(u.deposit_amount) },
        { unitNo, clientName, clientPhone, price, deposit });
    });
    const [full] = await loadUnits(db, 'u.id = $1', [req.params.id]);
    return ok({ unit: shapeUnit(full, a) });
  });

  /** تعاقد: the salesperson turns his reservation into a contract (see makeContract). */
  r.post('/exclusive/units/:id/contract', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    await db.tx(async (q) => {
      const u = await one(q, `SELECT * FROM ex_units WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!u) throw notFound();
      const p = await one(q, `SELECT * FROM commission_projects WHERE id = $1`, [u.project_id]);
      await makeContract(q, a, u, p, b);
    });
    const [full] = await loadUnits(db, 'u.id = $1', [req.params.id]);
    return ok({ unit: shapeUnit(full, a) });
  });

  /**
   * تم التحصيل: المالك / المدير العام marks a contracted unit's commission collected → it enters the commissions.
   * Exclusive: it moves out of the owner's money (up to what the unit earned). Marketing: the developer's payment
   * (نقدي في خزنة المكتب أو بنك).
   */
  r.post('/exclusive/units/:id/commission-collected', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const out = await db.tx(async (q) => {
      const u0 = await one(q, `SELECT id, project_id FROM ex_units WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!u0) throw notFound();
      const p = await one(q, `SELECT * FROM commission_projects WHERE id = $1 FOR UPDATE`, [u0.project_id]);
      const [u] = await loadUnits(q, 'u.id = $1', [u0.id]);
      if (u.status !== 'contracted') throw conflict('العمولة بتتحصّل بعد التعاقد');
      let amount = num(b, 'amount', { optional: true, min: 0.01, max: 10_000_000_000 }) ?? u.receivable;
      if (amount <= 0 || amount > u.receivable + 0.001) throw invalid(`العمولة الواجبة التحصيل ${fmt(u.receivable)}`, { field: 'amount', max: u.receivable });
      const note = (str(b, 'note', { optional: true, max: 500 }) ?? '').trim();
      if (p.kind === 'exclusive') {
        const st = (await projectStats(q, [p.id])).stats[p.id];
        // nobody types it: what the unit earned, as far as the owner's money holds
        if (b.amount === undefined) amount = r2(Math.min(amount, st.owner.inTrust));
        if (amount <= 0) throw invalid('أمانة المشروع فاضية — استنى تأكيد استلام الفلوس', { field: 'amount' });
        if (amount > st.owner.inTrust + 0.001) throw invalid(`اللي في أمانة المشروع ${fmt(st.owner.inTrust)} بس`, { field: 'amount' });
        const t = await one(q, `INSERT INTO ex_commission_transfers (project_id, unit_id, amount_egp, note, created_by, created_at) VALUES ($1,$2,$3,$4,$5,$6) RETURNING id, ref_no`,
          [p.id, u.id, amount, note || `وحدة ${u.unit_no}`, a.id, clock()]);
        await audit(q, a.id, 'exclusive.commission.collected', 'ex_unit', u.id, undefined, { amount, transferId: t.id });
        return t;
      }
      const method = oneOf(b, 'paymentMethod', METHODS, true) ?? 'bank_transfer';
      const rc = await one(q, `INSERT INTO cash_receipts (kind, amount_egp, cashbox, actual_recipient_id, payer_name, purpose, payment_method, notes,
          occurred_at, recorded_by, project_id, commission_unit_id)
        VALUES ('commission',$1,'office',$2,$3,$4,$5,$6,$7,$2,$8,$9) RETURNING id, ref_no`,
        [amount, a.id, p.name, `عمولة ${p.name} — وحدة ${u.unit_no}`, method, note, clock(), p.id, u.id]);
      await audit(q, a.id, 'exclusive.commission.collected', 'ex_unit', u.id, undefined, { amount, receiptId: rc.id, method });
      return rc;
    });
    const [full] = await loadUnits(db, 'u.id = $1', [req.params.id]);
    return ok({ unit: shapeUnit(full, a), refNo: Number(out.ref_no) }, 201);
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
      if (u.status !== 'contract_pending') throw conflict('مفيش طلب تعاقد مستني على الوحدة دي');
      if (u.sales_id === a.id) throw forbidden('مينفعش توافق على تعاقد إنت اللي طالبه');
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
      // the salesperson may already have filed this unit's commission (عمولة صفقة): keep that one, no second payout
      const live = await one(q, `SELECT * FROM commission_requests WHERE project_id = $1 AND lower(trim(unit_no)) = lower(trim($2))
                                    AND status IN ('pending','approved')`, [u.project_id, u.unit_no]);
      if (live) {
        await q.query(`UPDATE ex_units SET status = 'contracted', contracted_by = $2, contracted_at = $3, commission_request_id = $4 WHERE id = $1`, [u.id, a.id, now, live.id]);
        await audit(q, a.id, 'exclusive.contract.approve', 'ex_unit', u.id, undefined, { commissionRequestId: live.id, existing: true });
        await notify(q, { to: u.sales_id, type: 'exclusive_contract_approved', title: `اتوافق على التعاقد: وحدة ${u.unit_no}`,
          body: p.name, entity: 'ex_unit', entityId: u.id, dedupeKey: `ex:${u.id}:contract:approved` });
        return;
      }
      const cr = await one(q, `INSERT INTO commission_requests (project_id, employee_id, sales_manager_id, unit_no, price_per_m2, area_m2, unit_value,
          total_pct, sales_pct, manager_pct, company_pct, sales_amount, manager_amount, company_amount, note, status, period, decided_by, decided_at, ex_unit_id)
        VALUES ($1,$2,$3,$4,$5,1,$5,$6,$7,$8,$9,$10,$11,$12,$13,'approved',$14,$15,$16,$17) RETURNING *`,
        [u.project_id, u.sales_id, smId, u.unit_no, price, n(u.total_pct), sp, mp, r2(n(u.total_pct) - sp - mp), r2(price * sp / 100), r2(price * mp / 100),
          r2(price * (n(u.total_pct) - sp - mp) / 100), p.kind === 'exclusive' ? 'مشروع حصري' : 'تعاقد مشروع تسويق', period, a.id, now, u.id]);
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
      if (!['reserving', 'reserved', 'contract_pending'].includes(u.status)) throw conflict('الإلغاء للحجز بس');
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
      if (u.status !== 'cancel_pending') throw conflict('مفيش طلب إلغاء على الوحدة دي');
      if (decision === 'reject') {
        await q.query(`UPDATE ex_units SET status = previous_status, cancel_reason = NULL WHERE id = $1`, [u.id]);
      } else {
        await q.query(`UPDATE ex_units SET status = 'cancelled', cancelled_by = $2, cancelled_at = now() WHERE id = $1`, [u.id, a.id]);
        await q.query(`UPDATE ex_payments SET status = 'cancelled' WHERE unit_id = $1 AND status = 'pending'`, [u.id]);
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
    if (!hrDesk(a)) throw forbidden('رد العربون من المحاسب بس');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const amount = num(b, 'amount', { min: 0.01, max: 10_000_000_000 })!;
    const x = await db.tx(async (q) => {
      const u0 = await one(q, `SELECT id FROM ex_units WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!u0) throw notFound();
      const [u] = await loadUnits(q, 'u.id = $1', [u0.id]);
      if (u.status !== 'cancelled') throw conflict('رد العربون بيكون بعد موافقة الإلغاء');
      const left = r2(n(u.collected) - n(u.refunded));
      if (amount > left + 0.001) throw invalid(`الباقي للرد ${fmt(left)}`, { field: 'amount', max: left });
      const e = await one(q, `INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, notes, occurred_at, recorded_by, status, approved_by, approved_at, ex_unit_id, ex_project_id, ex_kind)
          VALUES ('hr',$1,'رد عربون حجز',$2,$3,$4,$8,$5,'posted',$5,$8,$6,$7,'refund') RETURNING id, ref_no`,
        [amount, `${u.project_name} — وحدة ${u.unit_no}`, u.client_name, (str(b, 'notes', { optional: true, max: 500 }) ?? '').trim(), a.id, u.id, u.project_id, clock()]);
      await audit(q, a.id, 'exclusive.refund', 'cash_expense', e.id, undefined, { unitId: u.id, amount });
      return e;
    });
    return ok({ expense: { id: x.id, refNo: Number(x.ref_no) } }, 201);
  });

  // ------------------------------------------------------------------ «تم استلام المبلغ»
  r.get('/exclusive/payments', async (req) => {
    const a = await authenticate(db, req);
    if (!hrDesk(a) && !canOffice(a) && !canReserve(a)) throw forbidden();
    const mine = hrDesk(a) || canOffice(a) ? '' : 'AND u.sales_id = $1';
    const rows = await db.query(`
      SELECT x.*, u.unit_no, u.client_name, u.client_phone, u.unit_price, p.name AS project_name, s.full_name AS sales_name
        FROM ex_payments x JOIN ex_units u ON u.id = x.unit_id JOIN commission_projects p ON p.id = u.project_id JOIN employees s ON s.id = u.sales_id
       WHERE x.status = 'pending' ${mine} ORDER BY x.created_at`, mine ? [a.id] : []);
    return ok({ payments: rows.rows.map(shapePayment), canReceive: hrDesk(a) || canOffice(a),
      into: hrDesk(a) ? 'خزنة المحاسب' : canOffice(a) ? 'خزنة المكتب' : null });
  });

  r.post('/exclusive/payments/:id/receive', async (req) => {
    const a = await authenticate(db, req);
    if (!hrDesk(a) && !canOffice(a)) throw forbidden('تأكيد الاستلام للمحاسب أو المالك / المدير العام');
    if (!isUuid(req.params.id)) throw notFound();
    const box = hrDesk(a) ? 'hr' : 'office';
    const out = await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM ex_payments WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x) throw notFound();
      if (x.status !== 'pending') throw conflict('المبلغ ده اتأكد استلامه قبل كده');
      const u = await one(q, `SELECT * FROM ex_units WHERE id = $1 FOR UPDATE`, [x.unit_id]);
      if (u.status === 'cancelled') throw conflict('الحجز ده اتلغى');
      const p = await one(q, `SELECT name FROM commission_projects WHERE id = $1`, [u.project_id]);
      const now = clock();
      const rc = await one(q, `INSERT INTO cash_receipts (kind, amount_egp, cashbox, actual_recipient_id, payer_name, payer_phone, purpose, payment_method,
          notes, occurred_at, recorded_by, ex_unit_id)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'',$9,$4,$10) RETURNING id, ref_no`,
        [x.kind, x.amount_egp, box, a.id, u.client_name, u.client_phone, `${KIND_AR[x.kind]} — ${p.name} — وحدة ${u.unit_no}`, x.payment_method, now, u.id]);
      await q.query(`UPDATE ex_payments SET status = 'received', received_by = $2, received_at = $3, receipt_id = $4 WHERE id = $1`, [x.id, a.id, now, rc.id]);
      if (x.kind === 'reservation' && u.status === 'reserving') await q.query(`UPDATE ex_units SET status = 'reserved' WHERE id = $1`, [u.id]);
      await audit(q, a.id, 'exclusive.payment.receive', 'ex_payment', x.id, undefined, { receiptId: rc.id, box, amount: n(x.amount_egp) });
      await notify(q, { to: u.sales_id, type: 'exclusive_payment', title: `اتأكد استلام ${KIND_AR[x.kind]}: ${fmt(n(x.amount_egp))}`,
        body: `${p.name} — وحدة ${u.unit_no}${x.kind === 'reservation' ? ' — تقدر تحوّل الحجز لتعاقد' : ''}`, entity: 'ex_unit', entityId: u.id,
        dedupeKey: `ex:payment:${x.id}:received` });
      return { unitId: u.id, ref: rc.ref_no };
    });
    const [full] = await loadUnits(db, 'u.id = $1', [out.unitId]);
    return ok({ unit: shapeUnit(full, a), receiptNo: `R-${String(out.ref).padStart(6, '0')}` });
  });

  // ------------------------------------------------------------------ الملاك (owners of the exclusive projects)
  r.get('/exclusive/owners', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    const ps = await db.query(`SELECT * FROM commission_projects WHERE kind = 'exclusive' ORDER BY created_at`);
    const { stats } = await projectStats(db, ps.rows.map((p) => p.id));
    const owners = new Map<string, any>();
    for (const p of ps.rows) {
      const key = `${String(p.owner_name).trim().toLowerCase()}|${String(p.owner_phone ?? '').replace(/\D/g, '')}`;
      const st = stats[p.id];
      const o = owners.get(key) ?? { name: p.owner_name, phone: p.owner_phone, projects: [], collected: 0, inTrust: 0, paid: 0, due: 0,
        commissionTransferred: 0, units: 0, sales: 0 };
      o.projects.push({ id: p.id, name: p.name, status: p.status, inTrust: st.owner.inTrust, paid: st.owner.paid, due: st.owner.due,
        collected: st.collected, units: st.units });
      o.collected = r2(o.collected + st.collected - st.refunded); o.inTrust = r2(o.inTrust + st.owner.inTrust);
      o.paid = r2(o.paid + st.owner.paid); o.due = r2(o.due + st.owner.due);
      o.commissionTransferred = r2(o.commissionTransferred + st.commission.transferred);
      o.units += st.units.total - st.units.cancelled; o.sales = r2(o.sales + st.sales);
      owners.set(key, o);
    }
    return ok({ owners: [...owners.values()].sort((x, y) => y.inTrust - x.inTrust) });
  });

  // ------------------------------------------------------------------ العملاء (every buyer: reservations + contracts)
  r.get('/exclusive/clients', async (req) => {
    const a = await authenticate(db, req);
    if (!canReserve(a) && !canSeeAll(a)) throw forbidden();
    const mine = canSeeAll(a) ? '' : `AND u.sales_id = $1`;
    const units = await loadUnits(db, `true ${mine}`, canSeeAll(a) ? [] : [a.id]);
    const legacy = canSeeAll(a) ? (await db.query(`
      SELECT s.id, s.buyer_name, s.buyer_phone, s.unit_no, s.total_price, s.status, s.created_at, p.name AS project_name, p.kind,
             COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.sale_id = s.id AND r.status = 'posted'), 0) AS paid
        FROM unit_sales s JOIN commission_projects p ON p.id = s.project_id WHERE s.status IN ('pending','active')`)).rows : [];
    const clients = new Map<string, any>();
    const put = (name: string, phone: string, unit: any) => {
      const digits = String(phone ?? '').replace(/\D/g, '');
      const key = digits.length >= 8 ? digits.slice(-10) : String(name).trim().toLowerCase();
      const c = clients.get(key) ?? { name, phone, units: [], total: 0, paid: 0, remaining: 0 };
      c.units.push(unit);
      if (unit.status !== 'cancelled') {
        c.total = r2(c.total + unit.price); c.paid = r2(c.paid + unit.paid);
        c.remaining = r2(c.remaining + Math.max(unit.price - unit.paid, 0));
      }
      if (!c.phone && phone) c.phone = phone;
      clients.set(key, c);
    };
    for (const u of units) {
      const status = u.completed ? 'completed' : u.status;
      put(u.client_name, u.client_phone, { id: u.id, source: 'unit', projectName: u.project_name, projectKind: u.project_kind, unitNo: u.unit_no,
        price: n(u.unit_price), paid: r2(n(u.collected) - n(u.refunded)), status, statusAr: STATUS_AR[status], salesName: u.sales_name, at: u.created_at });
    }
    for (const s of legacy) {
      put(s.buyer_name, s.buyer_phone, { id: s.id, source: 'sale', projectName: s.project_name, projectKind: s.kind, unitNo: s.unit_no,
        price: n(s.total_price), paid: n(s.paid), status: 'contracted', statusAr: 'متعاقد', at: s.created_at });
    }
    return ok({ clients: [...clients.values()].sort((x, y) => y.total - x.total) });
  });

  // ------------------------------------------------------------------ شركات التسويق
  const shapeMk = (m: any) => ({ id: m.id, name: m.name, kind: m.kind, kindAr: m.kind === 'fixed' ? 'راتب ثابت' : 'عمولة على المبيعات',
    defaultPct: n(m.default_pct), monthlyFee: n(m.monthly_fee), phone: m.phone, status: m.status });

  r.get('/marketing-companies', async (req) => {
    const a = await authenticate(db, req);
    if (!canReserve(a) && !canSeeAll(a)) throw forbidden();
    const rows = await db.query(`SELECT * FROM marketing_companies ${canManage(a) ? '' : `WHERE status = 'active'`} ORDER BY status, name`);
    let totals: Record<string, any> = {};
    if (canManage(a)) {
      const t = await db.query(`
        SELECT m.id,
          COALESCE((SELECT sum(u.unit_price * u.mk_pct / 100) FROM ex_units u WHERE u.mk_company_id = m.id AND u.status = 'contracted'), 0) AS earned,
          COALESCE((SELECT sum(x.amount_egp) FROM cash_expenses x WHERE x.marketing_company_id = m.id AND x.status = 'posted'), 0) AS paid,
          (SELECT count(*) FROM ex_units u WHERE u.mk_company_id = m.id AND u.status <> 'cancelled')::int AS units
          FROM marketing_companies m`);
      totals = Object.fromEntries(t.rows.map((x) => [x.id, { earned: r2(n(x.earned)), paid: r2(n(x.paid)), units: x.units,
        due: r2(Math.max(n(x.earned) - n(x.paid), 0)) }]));
    }
    return ok({ companies: rows.rows.map((m) => ({ ...shapeMk(m), totals: totals[m.id] })), canManage: canManage(a) });
  });

  r.post('/marketing-companies', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    const b = obj(req.body);
    const name = str(b, 'name', { min: 2, max: 120 })!.trim();
    const kind = oneOf(b, 'kind', ['fixed', 'commission'] as const)!;
    const m = await db.tx(async (q) => {
      if (await one(q, `SELECT 1 FROM marketing_companies WHERE lower(trim(name)) = lower(trim($1))`, [name])) throw conflict('فيه شركة بنفس الاسم');
      const x = await one(q, `INSERT INTO marketing_companies (name, kind, default_pct, monthly_fee, phone, created_by) VALUES ($1,$2,$3,$4,$5,$6) RETURNING *`,
        [name, kind, kind === 'commission' ? pct(b, 'defaultPct', 0) : 0, kind === 'fixed' ? (num(b, 'monthlyFee', { optional: true, min: 0, max: 100_000_000 }) ?? 0) : 0,
          (str(b, 'phone', { optional: true, max: 30 }) ?? '').trim(), a.id]);
      await audit(q, a.id, 'marketing_company.create', 'marketing_company', x.id, undefined, x);
      return x;
    });
    return ok({ company: shapeMk(m) }, 201);
  });

  r.patch('/marketing-companies/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const m = await db.tx(async (q) => {
      const o = await one(q, `SELECT * FROM marketing_companies WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!o) throw notFound();
      const x = await one(q, `UPDATE marketing_companies SET name = $2, default_pct = $3, monthly_fee = $4, phone = $5, status = $6 WHERE id = $1 RETURNING *`,
        [o.id, (str(b, 'name', { optional: true, min: 2, max: 120 }) ?? o.name).trim(), pct(b, 'defaultPct', n(o.default_pct)),
          num(b, 'monthlyFee', { optional: true, min: 0, max: 100_000_000 }) ?? n(o.monthly_fee), (str(b, 'phone', { optional: true, max: 30 }) ?? o.phone).trim(),
          oneOf(b, 'status', ['active', 'inactive'] as const, true) ?? o.status]);
      await audit(q, a.id, 'marketing_company.update', 'marketing_company', o.id, o, x);
      return x;
    });
    return ok({ company: shapeMk(m) });
  });
};

/** For the owner's dashboard: every exclusive project's totals in one go. */
/**
 * For the cashbox (المالك / المدير العام):
 *  خزنة المشاريع — the owners' money held, per exclusive project (حجز / تعاقد / أقساط in, paid to the owner, commission moved);
 *  العمولات — due (earned) / entered the commissions / still to collect;
 *  عمولات متوقعة — the reservations' commissions, in the month each is expected to become a contract.
 */
export async function salesMoneyOverview(q: Q) {
  const ps = await q.query(`SELECT * FROM commission_projects ORDER BY created_at`);
  const { stats, units } = await projectStats(q, ps.rows.map((p) => p.id));
  const projects = ps.rows.filter((p) => p.kind === 'exclusive').map((p) => {
    const us = units.filter((u) => u.project_id === p.id);
    const sum = (f: (u: any) => number) => r2(us.reduce((t, u) => t + f(u), 0));
    const st = stats[p.id];
    return { id: p.id, name: p.name, ownerName: p.owner_name, status: p.status,
      reservation: sum((u) => n(u.deposit_paid)), contract: sum((u) => n(u.contract_paid)), installments: sum((u) => n(u.installments_paid)),
      collected: st.collected, refunded: st.refunded, commissionMoved: st.commission.transferred, paidToOwner: st.owner.paid,
      pendingPayout: st.owner.pendingPayout, inTrust: st.owner.inTrust, ownerDue: st.owner.due, units: st.units };
  }).sort((a, b) => b.inTrust - a.inTrust);
  // العمولات: the units' + the commission requests filed without a unit (عمولة صفقة قديمة)
  const contracted = units.filter((u) => u.status === 'contracted');
  const legacy = await one(q, `SELECT
      COALESCE((SELECT sum(sales_amount + manager_amount + company_amount) FROM commission_requests WHERE status = 'approved' AND ex_unit_id IS NULL), 0) AS due,
      COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE kind = 'commission' AND status = 'posted' AND commission_unit_id IS NULL), 0) AS got`);
  const due = r2(contracted.reduce((t, u) => t + u.earned, 0) + n(legacy.due));
  const collected = r2(contracted.reduce((t, u) => t + u.commissionCollected, 0) + n(legacy.got));
  // every project (حصري + تسويق), the busiest first
  const byProject = ps.rows.map((p) => {
    const us = contracted.filter((u) => u.project_id === p.id);
    const d = r2(us.reduce((t, u) => t + u.earned, 0)), c = r2(us.reduce((t, u) => t + u.commissionCollected, 0));
    const expected = r2(units.filter((u) => u.project_id === p.id && ['reserving', 'reserved', 'contract_pending'].includes(u.status))
      .reduce((t, u) => t + u.potential, 0));
    return { id: p.id, name: p.name, kind: p.kind, status: p.status, due: d, collected: c, remaining: r2(Math.max(d - c, 0)),
      upcoming: r2(us.reduce((t, u) => t + u.upcoming, 0)), expected, units: us.length };
  }).sort((a, b) => b.remaining - a.remaining || b.due - a.due || b.expected - a.expected);
  // عمولات متوقعة: by the month the reservation is expected to become a contract
  const open = units.filter((u) => ['reserving', 'reserved', 'contract_pending'].includes(u.status));
  const months = new Map<string, { month: string; amount: number; units: any[] }>();
  for (const u of open) {
    const d = u.expected_contract_date ? String(u.expected_contract_date instanceof Date ? u.expected_contract_date.toISOString() : u.expected_contract_date).slice(0, 7) : '';
    const m = months.get(d) ?? { month: d, amount: 0, units: [] };
    m.amount = r2(m.amount + u.potential);
    m.units.push({ id: u.id, projectName: u.project_name, unitNo: u.unit_no, clientName: u.client_name, salesName: u.sales_name,
      amount: u.potential, expectedContractDate: d ? String(u.expected_contract_date instanceof Date ? u.expected_contract_date.toISOString() : u.expected_contract_date).slice(0, 10) : null });
    months.set(d, m);
  }
  const expected = [...months.values()].sort((a, b) => (a.month || '9999').localeCompare(b.month || '9999'));
  return {
    projectsBox: { total: r2(projects.reduce((t, p) => t + p.inTrust, 0)), projects },
    commissions: { due, collected, remaining: r2(Math.max(due - collected, 0)),
      upcoming: r2(contracted.reduce((t, u) => t + u.upcoming, 0)), byProject,
      units: contracted.map((u) => ({ id: u.id, projectId: u.project_id, projectName: u.project_name, projectKind: u.project_kind, unitNo: u.unit_no, clientName: u.client_name,
        salesName: u.sales_name, due: r2(u.earned), collected: r2(u.commissionCollected), remaining: r2(u.receivable), upcoming: r2(u.upcoming),
        contractedAt: u.contracted_at })).sort((x, y) => y.remaining - x.remaining),
      legacy: { due: r2(n(legacy.due)), collected: r2(n(legacy.got)) } },
    expectedCommissions: { total: r2(expected.reduce((t, m) => t + m.amount, 0)), months: expected },
  };
}

export async function exclusiveTotals(q: Q) {
  const ps = await q.query(`SELECT * FROM commission_projects WHERE kind = 'exclusive' ORDER BY created_at`);
  const { stats } = await projectStats(q, ps.rows.map((p) => p.id));
  return ps.rows.map((p) => ({ id: p.id, name: p.name, ownerName: p.owner_name, status: p.status, ...stats[p.id] }));
}
