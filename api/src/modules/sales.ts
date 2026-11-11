import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { local } from '../lib/time.ts';
import { isUuid, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';
import { canHrOperate, canOffice, parseReceipt, recordReceipt, RECEIPT_SELECT, shapeReceipt } from './cash.ts';
import { createCommissionRequest, parseCommissionRequest } from './commissions.ts';
import { notify } from './notify.ts';

/**
 * Financial system, phase 2 — unit sales: reservation → down payment → installments.
 *  - A sale uses an existing project and the unit number as the commissions system writes it (the link key).
 *  - One live sale per unit (database index). The schedule is generated once and never edited.
 *  - Money is always a numbered receipt (cash.ts) tied to the sale and to one schedule line; a line can never be
 *    collected beyond what is left on it.
 *  - Cancelling (approved policy: full refund) stops the remaining lines; refunds are expenses linked to the sale.
 *  - A salesperson's sale waits for the management (sales.approve) before anything can be collected on it; HR / المدير
 *    record sales directly. The deal commission can be filed with the sale (for the chosen salesperson when HR / المدير).
 */

const FREQ_MONTHS: Record<string, number> = { monthly: 1, quarterly: 3, semiannual: 6, annual: 12 };
const cents = (n: number) => Math.round(n * 100);
const egp = (c: number) => c / 100;
const r2 = (n: number) => Math.round(n * 100) / 100;

const canView = (a: Actor) => has(a, 'sales.view');
const canManage = (a: Actor) => has(a, 'sales.manage');
const canApprove = (a: Actor) => has(a, 'sales.approve');

function dateParam(b: Record<string, unknown>, field: string, optional = false): string | null {
  const v = b[field];
  if ((v === undefined || v === null || v === '') && optional) return null;
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v) || Number.isNaN(Date.parse(v + 'T00:00:00Z'))) {
    throw invalid(`${field} must be a date (YYYY-MM-DD)`, { field });
  }
  return v;
}

function addMonths(iso: string, months: number): string {
  const [y, m, d] = iso.split('-').map(Number);
  const target = new Date(Date.UTC(y, m - 1 + months, 1));
  const last = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
  target.setUTCDate(Math.min(d, last)); // 31 Jan + 1 month → 28/29 Feb
  return target.toISOString().slice(0, 10);
}

/**
 * The schedule: down payment (seq 0) + installments whose total is exactly price − down payment;
 * any rounding difference goes to the last installment.
 */
export function buildSchedule(p: { total: number; down: number; downDue: string; frequency: string | null; count: number | null;
  installmentAmount: number | null; firstDue: string | null }) {
  const restC = cents(p.total) - cents(p.down);
  const lines: { seq: number; due: string; amount: number }[] = [{ seq: 0, due: p.downDue, amount: egp(cents(p.down)) }];
  if (restC <= 0) return lines;
  if (!p.frequency || !p.firstDue) throw invalid('Choose the installment frequency and the first due date', { field: 'frequency' });
  let count: number, eachC: number;
  if (p.installmentAmount && p.installmentAmount > 0) {
    eachC = cents(p.installmentAmount);
    count = Math.ceil(restC / eachC);
  } else if (p.count && p.count > 0) {
    count = p.count;
    eachC = Math.floor(restC / count);
  } else {
    throw invalid('Give the number of installments or the installment amount', { field: 'installmentsCount' });
  }
  if (count > 600) throw invalid('Too many installments', { field: 'installmentsCount' });
  const months = FREQ_MONTHS[p.frequency];
  let used = 0;
  for (let i = 1; i <= count; i++) {
    const amt = i === count ? restC - used : eachC;
    used += amt;
    lines.push({ seq: i, due: addMonths(p.firstDue, months * (i - 1)), amount: egp(amt) });
  }
  return lines;
}

/** Status of one schedule line on a given day. */
function lineStatus(saleStatus: string, amount: number, paid: number, due: string, today: string) {
  if (cents(paid) >= cents(amount)) return 'paid';
  if (saleStatus === 'cancelled') return 'cancelled';
  if (due < today) return 'overdue';
  if (paid > 0) return 'partial';
  if (due === today) return 'due';
  return 'not_due';
}

const SALE_SELECT = `SELECT s.*, p.name AS project_name, e.full_name AS created_by_name,
  (SELECT full_name FROM employees d WHERE d.id = s.decided_by) AS decided_by_name,
  cr.ref AS commission_ref, cr.status AS commission_status, cr.sales_amount AS commission_amount,
  (SELECT full_name FROM employees ce WHERE ce.id = cr.employee_id) AS commission_employee_name,
  COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.sale_id = s.id AND r.status = 'posted'), 0) AS collected,
  COALESCE((SELECT sum(x.amount_egp) FROM cash_expenses x WHERE x.sale_id = s.id AND x.status = 'posted'), 0) AS refunded
  FROM unit_sales s JOIN commission_projects p ON p.id = s.project_id JOIN employees e ON e.id = s.created_by
  LEFT JOIN commission_requests cr ON cr.id = s.commission_request_id`;

function shapeSale(s: any) {
  const collected = Number(s.collected), total = Number(s.total_price), down = Number(s.down_payment);
  const downPaid = Number(s.down_paid ?? 0);
  return {
    id: s.id, refNo: Number(s.ref_no), projectId: s.project_id, projectName: s.project_name, unitNo: s.unit_no,
    buyerName: s.buyer_name, buyerPhone: s.buyer_phone, buyerContact: s.buyer_contact,
    totalPrice: total, downPayment: down, downPaid: r2(downPaid), saleDate: String(s.sale_date).slice(0, 10),
    downPaymentDueDate: String(s.down_payment_due_date).slice(0, 10), frequency: s.frequency, installmentsCount: s.installments_count,
    firstDueDate: s.first_due_date ? String(s.first_due_date).slice(0, 10) : null, notes: s.notes,
    status: s.status,
    stage: ['cancelled', 'pending', 'rejected'].includes(s.status) ? s.status : collected >= total ? 'completed' : downPaid >= down ? 'installments' : 'reserved',
    paymentMethod: Number(s.installments_count) > 0 ? 'installments' : 'cash',
    collected: r2(collected), remaining: ['cancelled', 'rejected'].includes(s.status) ? 0 : r2(total - collected), refunded: r2(Number(s.refunded)),
    createdBy: s.created_by, decidedByName: s.decided_by_name ?? null, decidedAt: s.decided_at ?? null, rejectReason: s.reject_reason ?? null,
    commission: s.commission_request_id ? { id: s.commission_request_id, ref: Number(s.commission_ref), status: s.commission_status,
      amount: Number(s.commission_amount), employeeName: s.commission_employee_name } : null,
    refundDue: s.status === 'cancelled' ? r2(collected - Number(s.refunded)) : 0,
    createdByName: s.created_by_name, createdAt: s.created_at, cancelledAt: s.cancelled_at, cancelReason: s.cancel_reason,
  };
}

async function loadSale(q: Q, id: string, lock = false) {
  if (!isUuid(id)) throw notFound();
  const s = await one(q, `SELECT * FROM unit_sales WHERE id = $1${lock ? ' FOR UPDATE' : ''}`, [id]);
  if (!s) throw notFound();
  return s;
}

export const salesModule: Module = (r, { db, clock }) => {
  const today = () => local(clock()).date;

  // ------------------------------------------------------------------ العملاء (built from the sales — no separate list to keep)
  /** One client = one buyer: the same mobile number (or, without one, the same name). */
  const clientKey = (name: string, phone: string) => {
    const d = String(phone ?? '').replace(/\D/g, '');
    return d.length >= 7 ? `p:${d.slice(-10)}` : `n:${String(name ?? '').trim().toLowerCase()}`;
  };

  async function clientSales(q: Q) {
    return (await q.query(`
      ${SALE_SELECT} WHERE s.status IN ('active','pending','cancelled') ORDER BY s.sale_date, s.created_at`)).rows;
  }

  async function clientLines(q: Q, saleIds: string[]) {
    if (!saleIds.length) return [];
    return (await q.query(`
      SELECT i.id, i.sale_id, i.seq, i.due_date, i.amount_egp,
             COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.installment_id = i.id AND r.status = 'posted'), 0) AS paid
        FROM sale_installments i WHERE i.sale_id = ANY($1::uuid[]) ORDER BY i.due_date, i.seq`, [saleIds])).rows;
  }

  r.get('/sales/clients', async (req) => {
    const a = await authenticate(db, req);
    if (!canView(a)) throw forbidden();
    const q = (req.query.get('q') ?? '').trim().toLowerCase();
    const t = today();
    const sales = await clientSales(db);
    const lines = await clientLines(db, sales.filter((x) => x.status === 'active').map((x) => x.id));
    const overdueBySale = new Map<string, number>();
    for (const l of lines) {
      const due = String(l.due_date).slice(0, 10), left = Number(l.amount_egp) - Number(l.paid);
      if (due < t && left > 0.009) overdueBySale.set(l.sale_id, (overdueBySale.get(l.sale_id) ?? 0) + left);
    }
    const by = new Map<string, any>();
    for (const x of sales) {
      const sh = shapeSale(x);
      const k = clientKey(x.buyer_name, x.buyer_phone);
      const c = by.get(k) ?? { key: k, name: sh.buyerName, phone: sh.buyerPhone, units: [] as string[], salesCount: 0,
        total: 0, collected: 0, remaining: 0, overdue: 0, installments: false, lastSale: '' };
      c.salesCount++;
      c.units.push(`${sh.projectName} — ${sh.unitNo}${x.status === 'cancelled' ? ' (ملغي)' : x.status === 'pending' ? ' (مستنية اعتماد)' : ''}`);
      if (x.status === 'active') {
        c.total += sh.totalPrice; c.collected += sh.collected; c.remaining += sh.remaining;
        c.overdue += overdueBySale.get(x.id) ?? 0;
        if (Number(x.installments_count) > 0) c.installments = true;
      }
      if (!c.phone && sh.buyerPhone) c.phone = sh.buyerPhone;
      c.lastSale = sh.saleDate > c.lastSale ? sh.saleDate : c.lastSale;
      by.set(k, c);
    }
    let list = [...by.values()].map((c) => ({ ...c, total: r2(c.total), collected: r2(c.collected), remaining: r2(c.remaining),
      overdue: r2(c.overdue), paymentMethod: c.installments ? 'installments' : 'cash' }));
    if (q) list = list.filter((c) => c.name.toLowerCase().includes(q) || String(c.phone).includes(q) || c.units.some((u: string) => u.toLowerCase().includes(q)));
    list.sort((x, y) => (y.overdue - x.overdue) || (y.remaining - x.remaining) || x.name.localeCompare(y.name, 'ar'));
    return ok({ currency: 'EGP', clients: list });
  });

  /**
   * One client: number of installments (all / paid / left), amounts (paid / left / total) and the full schedule of
   * every unit he bought, each line with what was collected on it in the cashbox.
   */
  r.get('/sales/clients/detail', async (req) => {
    const a = await authenticate(db, req);
    if (!canView(a)) throw forbidden();
    const key = req.query.get('key') ?? '';
    const t = today();
    const sales = (await clientSales(db)).filter((x) => clientKey(x.buyer_name, x.buyer_phone) === key);
    if (!sales.length) throw notFound('Client not found');
    const active = sales.filter((x) => x.status === 'active');
    const lines = await clientLines(db, active.map((x) => x.id));
    const saleBy = new Map(active.map((x) => [x.id, shapeSale(x)]));
    const schedule = lines.map((l) => {
      const sh = saleBy.get(l.sale_id)!;
      const amount = Number(l.amount_egp), paid = Number(l.paid), due = String(l.due_date).slice(0, 10);
      return { id: l.id, saleId: l.sale_id, unit: `${sh.projectName} — ${sh.unitNo}`, seq: l.seq, dueDate: due, amount, paid: r2(paid),
        remaining: r2(Math.max(0, amount - paid)), status: lineStatus('active', amount, paid, due, t) };
    }).filter((l) => l.amount > 0);
    const inst = schedule.filter((l) => l.seq > 0);
    const shaped = sales.map(shapeSale);
    const total = r2(active.reduce((s, x) => s + Number(x.total_price), 0));
    const collected = r2([...saleBy.values()].reduce((s, x) => s + x.collected, 0));
    return ok({ currency: 'EGP', client: { key, name: shaped[0].buyerName, phone: shaped.find((x) => x.buyerPhone)?.buyerPhone ?? '' },
      counts: { installments: inst.length, paid: inst.filter((l) => l.status === 'paid').length,
        remaining: inst.filter((l) => l.status !== 'paid').length, overdue: inst.filter((l) => l.status === 'overdue').length },
      amounts: { paid: collected, remaining: r2(Math.max(0, total - collected)), total },
      sales: shaped, schedule });
  });

  /**
   * تحصيل من الخزنة مربوط بالعميل: the amount goes automatically to the sale's open schedule lines, oldest first
   * (down payment / reservation → line 0 only; installment → the installments). One numbered receipt per line.
   */
  r.post('/sales/:id/collect-auto', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    const b = obj(req.body);
    const out = await db.tx(async (q) => {
      const s = await loadSale(q, req.params.id, true);
      if (s.status !== 'active') throw conflict('This sale is not active');
      const reqKind = b.kind === 'reservation' || b.kind === 'down_payment' ? b.kind : 'installment';
      const p = await one(q, `SELECT name FROM commission_projects WHERE id = $1`, [s.project_id]);
      const base = parseReceipt({ ...b, kind: reqKind, payerName: b.payerName || s.buyer_name, payerPhone: b.payerPhone ?? s.buyer_phone,
        purpose: b.purpose || `${p.name} — وحدة ${s.unit_no}` }, a, clock());
      if (base.ref) {
        const dup = await one(q, `SELECT id FROM cash_receipts WHERE client_ref = $1`, [base.ref]);
        if (dup) return { ids: [dup.id], duplicate: true };
      }
      const open = (await q.query(`
        SELECT i.*, COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.installment_id = i.id AND r.status = 'posted'), 0) AS paid
          FROM sale_installments i WHERE i.sale_id = $1 AND ${reqKind === 'installment' ? 'i.seq > 0' : 'i.seq = 0'}
         ORDER BY i.due_date, i.seq`, [s.id])).rows
        .map((l) => ({ ...l, left: cents(Number(l.amount_egp)) - cents(Number(l.paid)) })).filter((l) => l.left > 0);
      const leftAll = open.reduce((t, l) => t + l.left, 0);
      let rest = cents(base.amount);
      if (rest > leftAll) {
        throw new AppError('unprocessable', `Only ${egp(leftAll)} is left to collect here`, { reason: 'over_collect', remaining: egp(leftAll) });
      }
      const ids: string[] = [];
      for (const l of open) {
        if (rest <= 0) break;
        const take = Math.min(rest, l.left);
        rest -= take;
        const lineKind = l.seq === 0 ? reqKind : 'installment';
        const rec = await recordReceipt(q, a, { ...base, kind: lineKind, amount: egp(take), ref: ids.length ? null : base.ref,
          externalNo: ids.length ? null : base.externalNo,
          purpose: `${p.name} — وحدة ${s.unit_no} — ${l.seq === 0 ? (lineKind === 'reservation' ? 'حجز' : 'مقدم') : `قسط ${l.seq}`}`,
          saleId: s.id, installmentId: l.id });
        ids.push(rec.id);
      }
      return { ids, duplicate: false };
    });
    return ok({ receiptIds: out.ids, duplicate: out.duplicate, ...(await saleDetails(db, req.params.id, a)) }, out.duplicate ? 200 : 201);
  });

  r.post('/sales', async (req) => {
    const a = await authenticate(db, req);
    const direct = canManage(a); // HR / المدير: the sale is live at once; anyone else's waits for approval
    const b = obj(req.body);
    const projectId = typeof b.projectId === 'string' ? b.projectId : '';
    if (!isUuid(projectId)) throw invalid('Choose the project', { field: 'projectId' });
    const unitNo = str(b, 'unitNo', { min: 1, max: 60 })!.trim();
    const buyerName = str(b, 'buyerName', { min: 2, max: 120 })!.trim();
    const buyerPhone = (str(b, 'buyerPhone', { optional: true, max: 30 }) ?? '').trim();
    const buyerContact = (str(b, 'buyerContact', { optional: true, max: 300 }) ?? '').trim();
    const total = num(b, 'totalPrice', { min: 1, max: 10_000_000_000 })!;
    const down = num(b, 'downPayment', { min: 0, max: 10_000_000_000 })!;
    if (cents(down) > cents(total)) throw invalid('The down payment is more than the price', { field: 'downPayment' });
    const saleDate = dateParam(b, 'saleDate')!;
    const downDue = dateParam(b, 'downPaymentDueDate')!;
    const frequency = oneOf(b, 'frequency', ['monthly', 'quarterly', 'semiannual', 'annual'] as const, true) ?? null;
    const count = num(b, 'installmentsCount', { optional: true, int: true, min: 1, max: 600 }) ?? null;
    const instAmount = num(b, 'installmentAmount', { optional: true, min: 1, max: 10_000_000_000 }) ?? null;
    const firstDue = dateParam(b, 'firstDueDate', true);
    const notes = str(b, 'notes', { optional: true, max: 1000 }) ?? '';
    const lines = buildSchedule({ total, down, downDue, frequency, count, installmentAmount: instAmount, firstDue });
    const commission = b.withCommission === true ? parseCommissionRequest({ ...b, projectId, unitNo, note: b.commissionNote ?? '' }, a) : null;
    const id = await db.tx(async (q) => {
      const p = await one(q, `SELECT id, status FROM commission_projects WHERE id = $1 AND kind = 'marketing'`, [projectId]);
      if (!p) throw invalid('Choose the project', { field: 'projectId' });
      const live = await one(q, `SELECT ref_no FROM unit_sales WHERE project_id = $1 AND lower(trim(unit_no)) = lower(trim($2)) AND status IN ('active','pending')`,
        [projectId, unitNo]);
      if (live) throw new AppError('conflict', 'This unit already has an active sale', { reason: 'unit_has_buyer', refNo: Number(live.ref_no) });
      const s = await one(q, `
        INSERT INTO unit_sales (project_id, unit_no, buyer_name, buyer_phone, buyer_contact, total_price, down_payment, sale_date,
               down_payment_due_date, frequency, installments_count, first_due_date, notes, created_by, status, commission_request_id)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16) RETURNING id`,
        [projectId, unitNo, buyerName, buyerPhone, buyerContact, total, down, saleDate, downDue,
          lines.length > 1 ? frequency : null, lines.length - 1, lines.length > 1 ? firstDue : null, notes, a.id,
          direct ? 'active' : 'pending', commission ? await createCommissionRequest(q, a, commission) : null]);
      for (const l of lines) {
        await q.query(`INSERT INTO sale_installments (sale_id, seq, due_date, amount_egp) VALUES ($1,$2,$3,$4)`, [s.id, l.seq, l.due, l.amount]);
      }
      await audit(q, a.id, 'sales.create', 'unit_sale', s.id, undefined,
        { projectId, unitNo, buyerName, total, down, frequency, installments: lines.length - 1, status: direct ? 'active' : 'pending' });
      if (!direct) {
        const approvers = await q.query(`
          SELECT DISTINCT e.id FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
           WHERE rp.perm_key = 'sales.approve' AND e.status = 'active' AND e.id <> $1`, [a.id]);
        for (const ap of approvers.rows) {
          await notify(q, { to: ap.id, type: 'sale_awaiting', title: `بيعة جديدة من ${a.fullName} مستنية الاعتماد`,
            body: `وحدة ${unitNo} — ${buyerName}`, entity: 'unit_sale', entityId: s.id, dedupeKey: `sale:${s.id}:awaiting` });
        }
      }
      return s.id;
    });
    return ok(await saleDetails(db, id, a), 201);
  });

  async function saleDetails(q: Q, id: string, a: Actor) {
    const s = await one(q, `${SALE_SELECT} WHERE s.id = $1`, [id]);
    if (!s) throw notFound();
    const lines = await q.query(`
      SELECT i.*, COALESCE(sum(r.amount_egp) FILTER (WHERE r.status = 'posted'), 0) AS paid
        FROM sale_installments i LEFT JOIN cash_receipts r ON r.installment_id = i.id
       WHERE i.sale_id = $1 GROUP BY i.id ORDER BY i.seq`, [id]);
    s.down_paid = Number(lines.rows.find((x) => x.seq === 0)?.paid ?? 0);
    const t = today();
    const receipts = await q.query(`${RECEIPT_SELECT} WHERE r.sale_id = $1 ORDER BY r.occurred_at`, [id]);
    const refunds = await q.query(`SELECT id, ref_no, amount_egp, cashbox, occurred_at, reason, status FROM cash_expenses WHERE sale_id = $1 ORDER BY occurred_at`, [id]);
    return {
      currency: 'EGP',
      sale: shapeSale(s),
      schedule: lines.rows.map((l) => {
        const amount = Number(l.amount_egp), paid = Number(l.paid);
        return { id: l.id, seq: l.seq, kind: l.seq === 0 ? 'down_payment' : 'installment', dueDate: String(l.due_date).slice(0, 10),
          amount, paid: r2(paid), remaining: r2(Math.max(0, amount - paid)), status: lineStatus(s.status, amount, paid, String(l.due_date).slice(0, 10), t) };
      }),
      receipts: receipts.rows.map(shapeReceipt),
      refunds: refunds.rows.map((x) => ({ id: x.id, refNo: Number(x.ref_no), amount: Number(x.amount_egp), cashbox: x.cashbox,
        at: x.occurred_at, reason: x.reason, status: x.status })),
      can: { collect: canManage(a) && s.status === 'active', cancel: has(a, 'sales.cancel') && s.status === 'active',
        decide: canApprove(a) && s.status === 'pending' && s.created_by !== a.id,
        refund: s.status === 'cancelled' && (canOffice(a) || canHrOperate(a)) && has(a, 'sales.cancel') },
    };
  }

  r.get('/sales/:id', async (req) => {
    const a = await authenticate(db, req);
    const s = await loadSale(db, req.params.id);
    if (!canView(a) && s.created_by !== a.id) throw forbidden(); // the salesperson sees his own submissions
    return ok(await saleDetails(db, req.params.id, a));
  });

  r.get('/sales', async (req) => {
    const a = await authenticate(db, req);
    const vals: unknown[] = []; const where: string[] = [];
    if (!canView(a) || req.query.get('mine') === '1') { vals.push(a.id); where.push(`s.created_by = $${vals.length}`); }
    const s = req.query.get('q');
    if (s) { vals.push(`%${s.trim().toLowerCase()}%`); where.push(`(lower(s.buyer_name) LIKE $${vals.length} OR lower(s.unit_no) LIKE $${vals.length} OR s.buyer_phone LIKE $${vals.length})`); }
    const pid = req.query.get('projectId');
    if (pid && isUuid(pid)) { vals.push(pid); where.push(`s.project_id = $${vals.length}`); }
    const st = req.query.get('status');
    if (st && ['pending', 'active', 'rejected', 'cancelled'].includes(st)) { vals.push(st); where.push(`s.status = $${vals.length}`); }
    const rows = await db.query(`
      ${SALE_SELECT.replace('FROM unit_sales s', `, COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r JOIN sale_installments i ON i.id = r.installment_id
          WHERE i.sale_id = s.id AND i.seq = 0 AND r.status = 'posted'), 0) AS down_paid FROM unit_sales s`)}
      ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY s.created_at DESC LIMIT 500`, vals);
    return ok({ currency: 'EGP', sales: rows.rows.map(shapeSale),
      can: { manage: canManage(a), approve: canApprove(a), view: canView(a) } });
  });

  /** Management decision on a salesperson's sale: approve (collections can start) or reject (with a reason). */
  r.post('/sales/:id/decision', async (req) => {
    const a = await authenticate(db, req);
    if (!canApprove(a)) throw forbidden();
    const b = obj(req.body);
    const decision = oneOf(b, 'decision', ['approve', 'reject'] as const)!;
    const reason = decision === 'reject' ? str(b, 'reason', { min: 3, max: 500 })! : null;
    await db.tx(async (q) => {
      const s = await loadSale(q, req.params.id, true);
      if (s.status !== 'pending') throw conflict('This sale was already decided');
      if (s.created_by === a.id) throw forbidden('You cannot approve your own sale');
      await q.query(`UPDATE unit_sales SET status = $2, decided_by = $3, decided_at = now(), reject_reason = $4 WHERE id = $1`,
        [s.id, decision === 'approve' ? 'active' : 'rejected', a.id, reason]);
      // a rejected sale takes its waiting commission request with it
      if (decision === 'reject' && s.commission_request_id) {
        const c = await one(q, `UPDATE commission_requests SET status = 'rejected', decided_by = $2, decided_at = now(), reject_reason = $3
                                 WHERE id = $1 AND status = 'pending' AND employee_id <> $2 RETURNING id, employee_id`, [s.commission_request_id, a.id, `البيعة اترفضت: ${reason}`]);
        if (c) await audit(q, a.id, 'commission.request.reject', 'commission_request', c.id, undefined, { reason: 'sale rejected' });
      }
      await audit(q, a.id, `sales.${decision}`, 'unit_sale', s.id, { status: 'pending' }, { status: decision === 'approve' ? 'active' : 'rejected', reason });
      await notify(q, { to: s.created_by, type: decision === 'approve' ? 'sale_approved' : 'sale_rejected',
        title: decision === 'approve' ? `اتعتمدت بيعة وحدة ${s.unit_no}` : `اترفضت بيعة وحدة ${s.unit_no}`,
        body: decision === 'approve' ? s.buyer_name : `${reason}`, entity: 'unit_sale', entityId: s.id, dedupeKey: `sale:${s.id}:${decision}` });
    });
    return ok(await saleDetails(db, req.params.id, a));
  });

  /**
   * الأقساط المستحقة: every open schedule line with its paid / remaining amount and status.
   * Filters: from / to (due date), projectId, unit, buyer, status, overdue=1, today=1.
   */
  r.get('/sales/installments/due', async (req) => {
    const a = await authenticate(db, req);
    if (!canView(a)) throw forbidden();
    const t = today();
    const vals: unknown[] = []; const where: string[] = [];
    const from = req.query.get('from'), to = req.query.get('to');
    if (req.query.get('today') === '1') { vals.push(t); where.push(`i.due_date = $${vals.length}`); }
    if (from && /^\d{4}-\d{2}-\d{2}$/.test(from)) { vals.push(from); where.push(`i.due_date >= $${vals.length}`); }
    if (to && /^\d{4}-\d{2}-\d{2}$/.test(to)) { vals.push(to); where.push(`i.due_date <= $${vals.length}`); }
    const pid = req.query.get('projectId');
    if (pid && isUuid(pid)) { vals.push(pid); where.push(`s.project_id = $${vals.length}`); }
    const unit = req.query.get('unit');
    if (unit) { vals.push(`%${unit.trim().toLowerCase()}%`); where.push(`lower(s.unit_no) LIKE $${vals.length}`); }
    const buyer = req.query.get('buyer');
    if (buyer) { vals.push(`%${buyer.trim().toLowerCase()}%`); where.push(`lower(s.buyer_name) LIKE $${vals.length}`); }
    if (req.query.get('includeCancelled') !== '1') where.push(`s.status = 'active'`);
    const rows = await db.query(`
      SELECT i.id, i.seq, i.due_date, i.amount_egp, s.id AS sale_id, s.unit_no, s.buyer_name, s.buyer_phone, s.status AS sale_status,
             s.total_price, p.name AS project_name,
             COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.installment_id = i.id AND r.status = 'posted'), 0) AS paid,
             COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.sale_id = s.id AND r.status = 'posted'), 0) AS sale_collected
        FROM sale_installments i JOIN unit_sales s ON s.id = i.sale_id JOIN commission_projects p ON p.id = s.project_id
       ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
       ORDER BY i.due_date, s.buyer_name LIMIT 2000`, vals);
    let list = rows.rows.map((x) => {
      const amount = Number(x.amount_egp), paid = Number(x.paid), due = String(x.due_date).slice(0, 10);
      return { id: x.id, saleId: x.sale_id, seq: x.seq, kind: x.seq === 0 ? 'down_payment' : 'installment', projectName: x.project_name,
        unitNo: x.unit_no, buyerName: x.buyer_name, buyerPhone: x.buyer_phone, dueDate: due, amount, paid: r2(paid),
        remaining: r2(Math.max(0, amount - paid)), saleRemaining: x.sale_status === 'cancelled' ? 0 : r2(Number(x.total_price) - Number(x.sale_collected)),
        status: lineStatus(x.sale_status, amount, paid, due, t) };
    });
    const st = req.query.get('status');
    if (req.query.get('overdue') === '1') list = list.filter((x) => x.status === 'overdue');
    else if (st) list = list.filter((x) => x.status === st);
    else if (req.query.get('all') !== '1') list = list.filter((x) => x.status !== 'paid');
    const sum = (k: 'amount' | 'paid' | 'remaining') => r2(list.reduce((s, x) => s + x[k], 0));
    return ok({ currency: 'EGP', today: t, installments: list,
      totals: { amount: sum('amount'), paid: sum('paid'), remaining: sum('remaining'), overdue: r2(list.filter((x) => x.status === 'overdue').reduce((s, x) => s + x.remaining, 0)) } });
  });

  /** Collect money on one schedule line (reservation / down payment on line 0, installment on the others); partial is fine. */
  r.post('/sales/:id/collect', async (req) => {
    const a = await authenticate(db, req);
    if (!canManage(a)) throw forbidden();
    const b = obj(req.body);
    const lineId = typeof b.installmentId === 'string' ? b.installmentId : '';
    if (!isUuid(lineId)) throw invalid('Choose the installment', { field: 'installmentId' });
    const res = await db.tx(async (q) => {
      const s = await loadSale(q, req.params.id, true);
      if (s.status !== 'active') throw conflict('This sale was cancelled');
      const line = await one(q, `SELECT * FROM sale_installments WHERE id = $1 AND sale_id = $2`, [lineId, s.id]);
      if (!line) throw invalid('Choose an installment of this sale', { field: 'installmentId' });
      const kind = line.seq === 0 ? (b.kind === 'reservation' ? 'reservation' : 'down_payment') : 'installment';
      const p = await one(q, `SELECT name FROM commission_projects WHERE id = $1`, [s.project_id]);
      const input = parseReceipt({ ...b, kind, payerName: b.payerName ?? s.buyer_name, payerPhone: b.payerPhone ?? s.buyer_phone,
        purpose: `${p.name} — وحدة ${s.unit_no} — ${line.seq === 0 ? (kind === 'reservation' ? 'حجز' : 'مقدم') : `قسط ${line.seq}`}` }, a, clock());
      if (input.ref) {
        const dup = await one(q, `SELECT id FROM cash_receipts WHERE client_ref = $1`, [input.ref]);
        if (dup) return { id: dup.id, duplicate: true };
      }
      const paid = await one(q, `SELECT COALESCE(sum(amount_egp), 0) AS s FROM cash_receipts WHERE installment_id = $1 AND status = 'posted'`, [line.id]);
      const left = cents(Number(line.amount_egp)) - cents(Number(paid.s));
      if (cents(input.amount) > left) {
        throw new AppError('unprocessable', `Only ${egp(Math.max(0, left))} is left on this installment`, { reason: 'over_collect', remaining: egp(Math.max(0, left)) });
      }
      return recordReceipt(q, a, { ...input, saleId: s.id, installmentId: line.id });
    });
    const receipt = await one(db, `${RECEIPT_SELECT} WHERE r.id = $1`, [res.id]);
    return ok({ receipt: shapeReceipt(receipt), duplicate: res.duplicate, ...(await saleDetails(db, req.params.id, a)) }, res.duplicate ? 200 : 201);
  });

  /** Cancel a sale (approved policy: full refund). Collections stay recorded; the remaining lines stop. */
  r.post('/sales/:id/cancel', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'sales.cancel')) throw forbidden();
    const reason = str(obj(req.body), 'reason', { min: 3, max: 500 })!;
    await db.tx(async (q) => {
      const s = await loadSale(q, req.params.id, true);
      if (s.status !== 'active') throw conflict('Already cancelled');
      await q.query(`UPDATE unit_sales SET status = 'cancelled', cancelled_by = $2, cancelled_at = now(), cancel_reason = $3 WHERE id = $1`, [s.id, a.id, reason]);
      const c = await one(q, `SELECT COALESCE(sum(amount_egp),0) AS s FROM cash_receipts WHERE sale_id = $1 AND status = 'posted'`, [s.id]);
      await audit(q, a.id, 'sales.cancel', 'unit_sale', s.id, { status: 'active' }, { status: 'cancelled', reason, refundDue: Number(c.s) });
    });
    return ok(await saleDetails(db, req.params.id, a));
  });

  /** Pay back (part of) what was collected on a cancelled sale — a posted expense linked to the sale. */
  r.post('/sales/:id/refund', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'sales.cancel')) throw forbidden();
    const b = obj(req.body);
    const box = oneOf(b, 'cashbox', ['office', 'hr'] as const)!;
    if (box === 'office' ? !canOffice(a) : !canHrOperate(a)) throw forbidden();
    const amount = num(b, 'amount', { min: 0.01, max: 10_000_000_000 })!;
    const note = str(b, 'reason', { optional: true, max: 500 }) ?? '';
    await db.tx(async (q) => {
      const s = await loadSale(q, req.params.id, true);
      if (s.status !== 'cancelled') throw conflict('Cancel the sale first');
      const c = await one(q, `SELECT
          COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE sale_id = $1 AND status = 'posted'),0) AS col,
          COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE sale_id = $1 AND status = 'posted'),0) AS ref`, [s.id]);
      const left = cents(Number(c.col)) - cents(Number(c.ref));
      if (cents(amount) > left) throw new AppError('unprocessable', `Only ${egp(left)} is left to refund`, { reason: 'over_refund', remaining: egp(left) });
      const x = await one(q, `
        INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, notes, occurred_at, recorded_by, status, approved_by, approved_at, sale_id)
        VALUES ($1,$2,'استرداد وحدة',$3,$4,$5,now(),$6,'posted',$6,now(),$7) RETURNING id`,
        [box, amount, `استرداد بيع وحدة ${s.unit_no}`, s.buyer_name, note, a.id, s.id]);
      await audit(q, a.id, 'sales.refund', 'unit_sale', s.id, undefined, { amount, cashbox: box, expenseId: x.id });
    });
    return ok(await saleDetails(db, req.params.id, a));
  });
};
