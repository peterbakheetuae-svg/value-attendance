import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { isUuid, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, type Actor } from '../auth/context.ts';
import { notify } from './notify.ts';

/**
 * Financial system, phase 1 — the office cashbox and the HR cashbox.
 *
 * Who sees what is decided here (never only in the app):
 *  - cash.office (المدير, owner): the office cashbox, approvals, and everything of the HR cashbox too.
 *  - cash.hr_view (HR, المدير, owner): the HR cashbox. HR never gets one byte about the office cashbox.
 *  - cash.hr_operate (HR, owner): HR collections / expenses / transfer requests and hand-overs.
 * Balances come from the cash_ledger view (the one source of truth). Nothing is deleted or edited afterwards;
 * corrections are reversals. Every step is in the audit log.
 */

export type Box = 'office' | 'hr';
const BOXES = ['office', 'hr'] as const;
const RECEIPT_KINDS = ['reservation', 'down_payment', 'installment', 'settlement', 'other'] as const;
const METHODS = ['cash', 'bank_transfer', 'cheque', 'card', 'wallet'] as const;
export const RECEIPT_KIND_AR: Record<string, string> = {
  reservation: 'مبلغ حجز', down_payment: 'مقدم وحدة', installment: 'قسط', settlement: 'تسوية', other: 'تحصيل آخر',
};

export const canOffice = (a: Actor) => has(a, 'cash.office');
export const canHrView = (a: Actor) => has(a, 'cash.hr_view') || has(a, 'cash.office');
export const canHrOperate = (a: Actor) => has(a, 'cash.hr_operate');
const canSee = (a: Actor, box: Box) => (box === 'office' ? canOffice(a) : canHrView(a));
const r2 = (n: number) => Math.round(n * 100) / 100;

function boxOf(b: Record<string, unknown>, field = 'cashbox'): Box {
  return oneOf(b, field, BOXES)! as Box;
}

function money(b: Record<string, unknown>, field = 'amount') {
  return num(b, field, { min: 0.01, max: 100_000_000 })!;
}

function when(b: Record<string, unknown>, field: string, now: Date): Date {
  const v = b[field];
  if (v === undefined || v === null || v === '') return now;
  const d = new Date(String(v));
  if (Number.isNaN(d.getTime())) throw invalid(`${field} is not a date`, { field });
  if (d.getTime() > now.getTime() + 5 * 60_000) throw invalid('The date cannot be in the future', { field });
  if (d.getTime() < now.getTime() - 400 * 86400_000) throw invalid('The date is too far in the past', { field });
  return d;
}

function attachment(b: Record<string, unknown>): Buffer | null {
  const v = b.attachment;
  if (v === undefined || v === null || v === '') return null;
  if (typeof v !== 'string') throw invalid('attachment must be base64', { field: 'attachment' });
  const buf = Buffer.from(v.replace(/^data:[^,]*,/, ''), 'base64');
  if (!buf.length || buf.length > 600_000) throw invalid('The attachment must be an image under 600 KB', { field: 'attachment' });
  return buf;
}

function clientRef(b: Record<string, unknown>): string | null {
  const v = b.clientRef;
  if (v === undefined || v === null || v === '') return null;
  if (typeof v !== 'string' || !isUuid(v)) throw invalid('clientRef must be a uuid', { field: 'clientRef' });
  return v;
}

/** Book balances (+ money moving between the boxes) for the boxes this person may see. */
export async function cashSummary(q: Q, a: Actor) {
  const bal = await q.query(`SELECT cashbox, COALESCE(sum(amount), 0) AS b FROM cash_ledger GROUP BY cashbox`);
  const get = (box: Box) => r2(Number(bal.rows.find((x) => x.cashbox === box)?.b ?? 0));
  const tr = await q.query(`SELECT direction, status, COALESCE(sum(COALESCE(amount_executed, amount_requested)), 0) AS s, count(*) AS n
                              FROM cash_transfers WHERE status IN ('requested','approved','executed') GROUP BY direction, status`);
  const pend = (dir: string, st: string[]) => tr.rows.filter((x) => x.direction === dir && st.includes(x.status))
    .reduce((s, x) => ({ amount: r2(s.amount + Number(x.s)), count: s.count + Number(x.n) }), { amount: 0, count: 0 });
  const out: Record<string, unknown> = { currency: 'EGP' };
  if (canHrView(a)) {
    const hr = get('hr');
    const pendingExp = await one(q, `SELECT COALESCE(sum(amount_egp),0) AS s, count(*) AS n FROM cash_expenses WHERE status = 'pending_approval'`);
    out.hr = {
      bookBalance: hr,
      // a negative book balance is money the office owes the HR cashbox, not cash that exists
      deficit: hr < 0 ? r2(-hr) : 0,
      incomingTransfers: pend('office_to_hr', ['requested', 'approved', 'executed']),
      outgoingTransfers: pend('hr_to_office', ['requested', 'executed']),
      expensesAwaitingApproval: { amount: r2(Number(pendingExp.s)), count: Number(pendingExp.n) },
    };
  }
  if (canOffice(a)) {
    const office = get('office');
    out.office = {
      bookBalance: office,
      incomingTransfers: pend('hr_to_office', ['requested', 'executed']),
      outgoingTransfers: pend('office_to_hr', ['requested', 'approved', 'executed']),
    };
    out.total = r2(office + get('hr'));
  }
  const s = await one(q, `SELECT expense_approval_threshold FROM company_settings LIMIT 1`);
  out.expenseApprovalThreshold = Number(s?.expense_approval_threshold ?? 1000);
  out.can = { office: canOffice(a), hrView: canHrView(a), hrOperate: canHrOperate(a), settings: has(a, 'cash.settings') };
  return out;
}

async function cashOfficers(q: Q, exceptId?: string) {
  const r = await q.query(`
    SELECT DISTINCT e.id FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
     WHERE rp.perm_key = 'cash.office' AND e.status = 'active' AND e.id <> COALESCE($1::uuid, '00000000-0000-0000-0000-000000000000')`,
    [exceptId ?? null]);
  return r.rows.map((x) => x.id as string);
}

async function hrOperators(q: Q, exceptId?: string) {
  const r = await q.query(`
    SELECT DISTINCT e.id FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
     WHERE rp.perm_key = 'cash.hr_operate' AND e.status = 'active' AND e.role_key <> 'owner'
       AND e.id <> COALESCE($1::uuid, '00000000-0000-0000-0000-000000000000')`, [exceptId ?? null]);
  return r.rows.map((x) => x.id as string);
}

const fmt = (n: number) => `${r2(n)} جنيه`;

export interface ReceiptInput {
  box: Box; recipientId: string; kind: string; amount: number; payerName: string; payerPhone: string; purpose: string;
  method: string; externalNo: string | null; notes: string; ref: string | null; att: Buffer | null; occurred: Date;
  saleId?: string | null; installmentId?: string | null;
}

/**
 * recipient 'hr' → HR physically got it → HR cashbox, recipient = HR person.
 * recipient 'manager' → the manager got it himself → office cashbox, recipient = that manager
 * (HR may type it in for him, but the money is recorded as the manager's, never as HR's).
 */
export function parseReceipt(b: Record<string, unknown>, a: Actor, now: Date): ReceiptInput {
  const recipient = oneOf(b, 'recipient', ['hr', 'manager'] as const)!;
  const kind = oneOf(b, 'kind', RECEIPT_KINDS)!;
  const amount = money(b);
  const payerName = str(b, 'payerName', { min: 2, max: 120 })!.trim();
  const payerPhone = (str(b, 'payerPhone', { optional: true, max: 30 }) ?? '').trim();
  const purpose = str(b, 'purpose', { min: 2, max: 300 })!.trim();
  const method = oneOf(b, 'paymentMethod', METHODS, true) ?? 'cash';
  const externalNo = (str(b, 'externalNo', { optional: true, max: 40 }) ?? '').trim() || null;
  const notes = str(b, 'notes', { optional: true, max: 1000 }) ?? '';
  const ref = clientRef(b);
  const att = attachment(b);
  const occurred = when(b, 'occurredAt', now);
  let box: Box, recipientId: string;
  if (recipient === 'hr') {
    if (!canHrOperate(a)) throw forbidden();
    box = 'hr';
    recipientId = typeof b.recipientId === 'string' && b.recipientId ? b.recipientId : a.id;
  } else {
    if (!canOffice(a) && !canHrOperate(a)) throw forbidden();
    box = 'office';
    recipientId = typeof b.recipientId === 'string' && b.recipientId ? b.recipientId : (canOffice(a) ? a.id : '');
    if (!recipientId) throw invalid('Choose the manager who received the money', { field: 'recipientId' });
  }
  if (!isUuid(recipientId)) throw invalid('recipientId is invalid', { field: 'recipientId' });
  const saleId = typeof b.saleId === 'string' && b.saleId ? b.saleId : null;
  const installmentId = typeof b.installmentId === 'string' && b.installmentId ? b.installmentId : null;
  return { box, recipientId, kind, amount, payerName, payerPhone, purpose, method, externalNo, notes, ref, att, occurred, saleId, installmentId };
}

/** Writes one numbered receipt (inside the caller's transaction); the same form sent twice gives the same receipt. */
export async function recordReceipt(q: Q, a: Actor, x: ReceiptInput): Promise<{ id: string; duplicate: boolean }> {
  if (x.ref) {
    const dup = await one(q, `SELECT id FROM cash_receipts WHERE client_ref = $1`, [x.ref]);
    if (dup) return { id: dup.id, duplicate: true };
  }
  const perm = x.box === 'hr' ? 'cash.hr_operate' : 'cash.office';
  const ok2 = await one(q, `SELECT 1 FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
                             WHERE e.id = $1 AND e.status = 'active' AND rp.perm_key = $2`, [x.recipientId, perm]);
  if (!ok2) throw invalid(x.box === 'hr' ? 'The recipient must be from HR' : 'The recipient must be the manager or the owner', { field: 'recipientId' });
  if (x.externalNo && await one(q, `SELECT 1 FROM cash_receipts WHERE lower(trim(external_no)) = lower(trim($1))`, [x.externalNo])) {
    throw new AppError('conflict', 'This receipt number was already recorded', { reason: 'duplicate_receipt' });
  }
  const row = await one(q, `
    INSERT INTO cash_receipts (kind, amount_egp, cashbox, actual_recipient_id, payer_name, payer_phone, purpose, payment_method,
           external_no, client_ref, notes, attachment, occurred_at, recorded_by, sale_id, installment_id)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16) RETURNING id, ref_no`,
    [x.kind, x.amount, x.box, x.recipientId, x.payerName, x.payerPhone, x.purpose, x.method, x.externalNo, x.ref, x.notes, x.att,
      x.occurred, a.id, x.saleId ?? null, x.installmentId ?? null]);
  await audit(q, a.id, 'cash.receipt', 'cash_receipt', row.id, undefined,
    { kind: x.kind, amount: x.amount, cashbox: x.box, recipientId: x.recipientId, payerName: x.payerName, purpose: x.purpose,
      externalNo: x.externalNo, saleId: x.saleId ?? null, installmentId: x.installmentId ?? null });
  if (x.box === 'office' && x.recipientId !== a.id) {
    await notify(q, { to: x.recipientId, type: 'cash_receipt', title: `تحصيل باسمك: ${fmt(x.amount)}`,
      body: `${RECEIPT_KIND_AR[x.kind]} — ${x.payerName}`, entity: 'cash_receipt', entityId: row.id, dedupeKey: `cash:receipt:${row.id}` });
  }
  return { id: row.id, duplicate: false };
}

export function shapeReceipt(x: any) {
  return {
    id: x.id, refNo: Number(x.ref_no), receiptNo: `R-${String(x.ref_no).padStart(6, '0')}`, kind: x.kind, kindAr: RECEIPT_KIND_AR[x.kind],
    amount: Number(x.amount_egp), cashbox: x.cashbox, actualRecipientId: x.actual_recipient_id, actualRecipientName: x.recipient_name,
    payerName: x.payer_name, payerPhone: x.payer_phone, purpose: x.purpose, paymentMethod: x.payment_method, externalNo: x.external_no,
    saleId: x.sale_id, installmentId: x.installment_id, notes: x.notes, hasAttachment: x.has_attachment === true,
    occurredAt: x.occurred_at, recordedBy: x.recorded_by, recordedByName: x.recorded_by_name, status: x.status,
    reversedAt: x.reversed_at, reverseReason: x.reverse_reason, createdAt: x.created_at,
  };
}

function shapeExpense(x: any) {
  return {
    id: x.id, refNo: Number(x.ref_no), cashbox: x.cashbox, amount: Number(x.amount_egp), category: x.category, reason: x.reason,
    beneficiary: x.beneficiary, notes: x.notes, hasAttachment: x.has_attachment === true, occurredAt: x.occurred_at,
    recordedBy: x.recorded_by, recordedByName: x.recorded_by_name, status: x.status, approvedAt: x.approved_at,
    approvedByName: x.approved_by_name, rejectReason: x.reject_reason, reviewedAt: x.reviewed_at, reviewedByName: x.reviewed_by_name,
    reversedAt: x.reversed_at, reverseReason: x.reverse_reason, createdAt: x.created_at,
  };
}

function shapeTransfer(x: any, a: Actor) {
  const toHr = x.direction === 'office_to_hr';
  return {
    id: x.id, refNo: Number(x.ref_no), direction: x.direction, amountRequested: Number(x.amount_requested),
    amountExecuted: x.amount_executed == null ? null : Number(x.amount_executed), reason: x.reason, status: x.status,
    requestedByName: x.requested_by_name, requestedAt: x.requested_at, decidedByName: x.decided_by_name, decidedAt: x.decided_at,
    rejectReason: x.reject_reason, executedByName: x.executed_by_name, executedAt: x.executed_at,
    receivedByName: x.received_by_name, receivedAt: x.received_at,
    // what this person can do next
    can: {
      decide: toHr && x.status === 'requested' && canOffice(a),
      execute: (toHr && x.status === 'approved' && canOffice(a)) || (!toHr && x.status === 'requested' && canHrOperate(a)),
      receive: x.status === 'executed' && x.executed_by !== a.id && (toHr ? canHrOperate(a) : canOffice(a)),
      cancel: ['requested', 'approved'].includes(x.status) && x.requested_by === a.id,
    },
  };
}

export const RECEIPT_SELECT = `SELECT r.*, (r.attachment IS NOT NULL) AS has_attachment, rc.full_name AS recipient_name, rb.full_name AS recorded_by_name
  FROM cash_receipts r JOIN employees rc ON rc.id = r.actual_recipient_id JOIN employees rb ON rb.id = r.recorded_by`;
const EXPENSE_SELECT = `SELECT x.*, (x.attachment IS NOT NULL) AS has_attachment, rb.full_name AS recorded_by_name,
  ap.full_name AS approved_by_name, rv.full_name AS reviewed_by_name
  FROM cash_expenses x JOIN employees rb ON rb.id = x.recorded_by
  LEFT JOIN employees ap ON ap.id = x.approved_by LEFT JOIN employees rv ON rv.id = x.reviewed_by`;
const TRANSFER_SELECT = `SELECT t.*, rq.full_name AS requested_by_name, dc.full_name AS decided_by_name,
  ex.full_name AS executed_by_name, rc.full_name AS received_by_name
  FROM cash_transfers t JOIN employees rq ON rq.id = t.requested_by
  LEFT JOIN employees dc ON dc.id = t.decided_by LEFT JOIN employees ex ON ex.id = t.executed_by LEFT JOIN employees rc ON rc.id = t.received_by`;

export const cashModule: Module = (r, { db, clock }) => {
  // ------------------------------------------------------------------ overview / ledger
  r.get('/cash/summary', async (req) => {
    const a = await authenticate(db, req);
    if (!canHrView(a) && !canOffice(a)) throw forbidden();
    return ok(await cashSummary(db, a));
  });

  r.get('/cash/ledger', async (req) => {
    const a = await authenticate(db, req);
    const box = (req.query.get('cashbox') ?? 'hr') as Box;
    if (!BOXES.includes(box) || !canSee(a, box)) throw forbidden();
    const vals: unknown[] = [box];
    const where = ['l.cashbox = $1'];
    const from = req.query.get('from'), to = req.query.get('to');
    if (from && /^\d{4}-\d{2}-\d{2}$/.test(from)) { vals.push(from); where.push(`l.at >= ($${vals.length}::date AT TIME ZONE 'Africa/Cairo')`); }
    if (to && /^\d{4}-\d{2}-\d{2}$/.test(to)) { vals.push(to); where.push(`l.at < (($${vals.length}::date + 1) AT TIME ZONE 'Africa/Cairo')`); }
    const rows = await db.query(`SELECT l.*, e.full_name AS by_name FROM cash_ledger l LEFT JOIN employees e ON e.id = l.by_id
                                 WHERE ${where.join(' AND ')} ORDER BY l.at DESC LIMIT 1000`, vals);
    const totalIn = rows.rows.filter((x) => Number(x.amount) > 0).reduce((s, x) => s + Number(x.amount), 0);
    const totalOut = rows.rows.filter((x) => Number(x.amount) < 0).reduce((s, x) => s - Number(x.amount), 0);
    return ok({
      currency: 'EGP', cashbox: box, totals: { in: r2(totalIn), out: r2(totalOut) },
      entries: rows.rows.map((x) => ({
        amount: Number(x.amount), at: x.at, type: x.type, refNo: x.ref_no == null ? null : Number(x.ref_no),
        sourceId: x.source_id, source: x.source, label: x.label, byName: x.by_name,
      })),
    });
  });

  // ------------------------------------------------------------------ opening balance / cash count
  r.post('/cash/adjustments', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'cash.settings')) throw forbidden();
    const b = obj(req.body);
    const box = boxOf(b);
    const kind = oneOf(b, 'kind', ['opening', 'adjustment'] as const)!;
    const amount = num(b, 'amount', { min: -100_000_000, max: 100_000_000 })!;
    if (amount === 0) throw invalid('The amount cannot be 0', { field: 'amount' });
    const reason = str(b, 'reason', { min: 3, max: 500 })!;
    const counted = num(b, 'countedCash', { optional: true, min: -100_000_000, max: 100_000_000 });
    const row = await db.tx(async (q) => {
      if (kind === 'opening' && await one(q, `SELECT 1 FROM cash_adjustments WHERE cashbox = $1 AND kind = 'opening'`, [box])) {
        throw conflict('The opening balance was already recorded — record an adjustment instead');
      }
      const x = await one(q, `INSERT INTO cash_adjustments (cashbox, kind, amount_egp, counted_cash, reason, created_by)
                              VALUES ($1,$2,$3,$4,$5,$6) RETURNING *`, [box, kind, amount, counted ?? null, reason, a.id]);
      await audit(q, a.id, `cash.${kind}`, 'cash_adjustment', x.id, undefined, { cashbox: box, amount, countedCash: counted ?? null, reason });
      return x;
    });
    return ok({ adjustment: { id: row.id, refNo: Number(row.ref_no), cashbox: box, kind, amount } }, 201);
  });

  r.patch('/cash/settings', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'cash.settings')) throw forbidden();
    const t = num(obj(req.body), 'expenseApprovalThreshold', { min: 0, max: 100_000_000 })!;
    await db.tx(async (q) => {
      const before = await one(q, `SELECT expense_approval_threshold FROM company_settings LIMIT 1`);
      await q.query(`UPDATE company_settings SET expense_approval_threshold = $1`, [t]);
      await audit(q, a.id, 'cash.settings', 'company_settings', null,
        { expenseApprovalThreshold: Number(before?.expense_approval_threshold) }, { expenseApprovalThreshold: t });
    });
    return ok({ expenseApprovalThreshold: t });
  });

  // ------------------------------------------------------------------ collections (receipts)
  /**
   * recipient 'hr' → HR physically got it → HR cashbox, recipient = HR person.
   * recipient 'manager' → the manager got it himself → office cashbox, recipient = that manager
   * (HR may type it in for him, but the money is recorded as the manager's, never as HR's).
   */
  r.post('/cash/receipts', async (req) => {
    const a = await authenticate(db, req);
    const input = parseReceipt(obj(req.body), a, clock());
    if (input.saleId || input.installmentId) throw invalid('Collect sale payments from the sale page', { field: 'saleId' });
    const row = await db.tx((q) => recordReceipt(q, a, input));
    const full = await one(db, `${RECEIPT_SELECT} WHERE r.id = $1`, [row.id]);
    return ok({ receipt: shapeReceipt(full), duplicate: row.duplicate }, row.duplicate ? 200 : 201);
  });

  r.get('/cash/receipts', async (req) => {
    const a = await authenticate(db, req);
    const vals: unknown[] = []; const where: string[] = [];
    const boxes: Box[] = BOXES.filter((x) => canSee(a, x));
    // HR may see the office receipts it typed in for the manager, nothing else of the office box
    if (!boxes.length && !canHrOperate(a)) throw forbidden();
    vals.push(boxes, a.id);
    where.push(`(r.cashbox = ANY($1::text[]) OR r.recorded_by = $2)`);
    const k = req.query.get('kind');
    if (k && (RECEIPT_KINDS as readonly string[]).includes(k)) { vals.push(k); where.push(`r.kind = $${vals.length}`); }
    const s = req.query.get('q');
    if (s) { vals.push(`%${s.trim().toLowerCase()}%`); where.push(`(lower(r.payer_name) LIKE $${vals.length} OR lower(r.purpose) LIKE $${vals.length} OR r.ref_no::text LIKE $${vals.length})`); }
    const rows = await db.query(`${RECEIPT_SELECT} WHERE ${where.join(' AND ')} ORDER BY r.occurred_at DESC LIMIT 500`, vals);
    return ok({ currency: 'EGP', receipts: rows.rows.map(shapeReceipt) });
  });

  r.post('/cash/receipts/:id/reverse', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden('Only the manager or the owner can reverse a receipt');
    if (!isUuid(req.params.id)) throw notFound();
    const reason = str(obj(req.body), 'reason', { min: 3, max: 500 })!;
    await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM cash_receipts WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x) throw notFound();
      if (x.status !== 'posted') throw conflict('Already reversed');
      await q.query(`UPDATE cash_receipts SET status = 'reversed', reversed_by = $2, reversed_at = now(), reverse_reason = $3 WHERE id = $1`,
        [x.id, a.id, reason]);
      await audit(q, a.id, 'cash.receipt.reverse', 'cash_receipt', x.id, { status: 'posted', amount: Number(x.amount_egp) }, { status: 'reversed', reason });
    });
    return ok({ ok: true });
  });

  // ------------------------------------------------------------------ expenses
  r.post('/cash/expenses', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const box = boxOf(b);
    if (box === 'office' ? !canOffice(a) : !canHrOperate(a)) throw forbidden();
    const amount = money(b);
    const category = str(b, 'category', { min: 2, max: 80 })!.trim();
    const reason = str(b, 'reason', { min: 2, max: 500 })!.trim();
    const beneficiary = str(b, 'beneficiary', { min: 2, max: 120 })!.trim();
    const notes = str(b, 'notes', { optional: true, max: 1000 }) ?? '';
    const ref = clientRef(b);
    const att = attachment(b);
    const occurred = when(b, 'occurredAt', clock());
    const out = await db.tx(async (q) => {
      if (ref) {
        const dup = await one(q, `SELECT id FROM cash_expenses WHERE client_ref = $1`, [ref]);
        if (dup) return { id: dup.id, duplicate: true };
      }
      const s = await one(q, `SELECT expense_approval_threshold FROM company_settings LIMIT 1`);
      const threshold = Number(s?.expense_approval_threshold ?? 1000);
      // HR records directly; above the threshold the manager approves first. Office expenses are the manager's own.
      const needsApproval = box === 'hr' && !canOffice(a) && amount > threshold;
      const x = await one(q, `
        INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, notes, attachment, client_ref, occurred_at, recorded_by,
               status, approved_by, approved_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING id, ref_no`,
        [box, amount, category, reason, beneficiary, notes, att, ref, occurred, a.id,
          needsApproval ? 'pending_approval' : 'posted', needsApproval ? null : a.id, needsApproval ? null : clock()]);
      await audit(q, a.id, 'cash.expense', 'cash_expense', x.id, undefined,
        { cashbox: box, amount, category, reason, beneficiary, status: needsApproval ? 'pending_approval' : 'posted', threshold });
      if (needsApproval) {
        for (const m of await cashOfficers(q, a.id)) {
          await notify(q, { to: m, type: 'cash_expense_awaiting', title: `مصروف محتاج موافقتك: ${fmt(amount)}`,
            body: `${category} — ${beneficiary}`, entity: 'cash_expense', entityId: x.id, dedupeKey: `cash:expense:${x.id}:awaiting` });
        }
      }
      return { id: x.id, duplicate: false };
    });
    const full = await one(db, `${EXPENSE_SELECT} WHERE x.id = $1`, [out.id]);
    return ok({ expense: shapeExpense(full), duplicate: out.duplicate }, out.duplicate ? 200 : 201);
  });

  r.get('/cash/expenses', async (req) => {
    const a = await authenticate(db, req);
    const boxes: Box[] = BOXES.filter((x) => canSee(a, x));
    if (!boxes.length) throw forbidden();
    const vals: unknown[] = [boxes]; const where = ['x.cashbox = ANY($1::text[])'];
    const st = req.query.get('status');
    if (st && ['pending_approval', 'posted', 'rejected', 'reversed'].includes(st)) { vals.push(st); where.push(`x.status = $${vals.length}`); }
    if (req.query.get('unreviewed') === '1') where.push(`x.reviewed_at IS NULL AND x.status = 'posted'`);
    const rows = await db.query(`${EXPENSE_SELECT} WHERE ${where.join(' AND ')} ORDER BY x.occurred_at DESC LIMIT 500`, vals);
    return ok({ currency: 'EGP', expenses: rows.rows.map(shapeExpense) });
  });

  async function expenseStep(id: string, a: Actor, fn: (q: Q, x: any) => Promise<void>) {
    if (!isUuid(id)) throw notFound();
    await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM cash_expenses WHERE id = $1 FOR UPDATE`, [id]);
      if (!x) throw notFound();
      if (!canSee(a, x.cashbox)) throw forbidden();
      await fn(q, x);
    });
  }

  r.post('/cash/expenses/:id/decision', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden();
    const b = obj(req.body);
    const decision = oneOf(b, 'decision', ['approve', 'reject'] as const)!;
    const reason = decision === 'reject' ? str(b, 'reason', { min: 3, max: 500 })! : null;
    await expenseStep(req.params.id, a, async (q, x) => {
      if (x.status !== 'pending_approval') throw conflict('This expense is not waiting for approval');
      if (x.recorded_by === a.id) throw forbidden('You cannot approve your own expense');
      if (decision === 'approve') {
        await q.query(`UPDATE cash_expenses SET status = 'posted', approved_by = $2, approved_at = now(), reviewed_by = $2, reviewed_at = now() WHERE id = $1`, [x.id, a.id]);
      } else {
        await q.query(`UPDATE cash_expenses SET status = 'rejected', approved_by = $2, approved_at = now(), reject_reason = $3 WHERE id = $1`, [x.id, a.id, reason]);
      }
      await audit(q, a.id, `cash.expense.${decision}`, 'cash_expense', x.id, { status: x.status }, { status: decision === 'approve' ? 'posted' : 'rejected', reason });
      await notify(q, { to: x.recorded_by, type: 'cash_expense_decided', title: decision === 'approve' ? `اتوافق على المصروف: ${fmt(Number(x.amount_egp))}` : 'اترفض المصروف',
        body: `${x.category}${reason ? ' — ' + reason : ''}`, entity: 'cash_expense', entityId: x.id, dedupeKey: `cash:expense:${x.id}:decided` });
    });
    return ok({ ok: true });
  });

  /** The manager / owner marks an expense as looked at (review after payment). */
  r.post('/cash/expenses/:id/review', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden();
    await expenseStep(req.params.id, a, async (q, x) => {
      if (x.reviewed_at) return;
      await q.query(`UPDATE cash_expenses SET reviewed_by = $2, reviewed_at = now() WHERE id = $1`, [x.id, a.id]);
      await audit(q, a.id, 'cash.expense.review', 'cash_expense', x.id, undefined, { reviewed: true });
    });
    return ok({ ok: true });
  });

  r.post('/cash/expenses/:id/reverse', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden('Only the manager or the owner can reverse an expense');
    const reason = str(obj(req.body), 'reason', { min: 3, max: 500 })!;
    await expenseStep(req.params.id, a, async (q, x) => {
      if (x.status !== 'posted') throw conflict('Only a posted expense can be reversed');
      await q.query(`UPDATE cash_expenses SET status = 'reversed', reversed_by = $2, reversed_at = now(), reverse_reason = $3 WHERE id = $1`, [x.id, a.id, reason]);
      await audit(q, a.id, 'cash.expense.reverse', 'cash_expense', x.id, { status: 'posted', amount: Number(x.amount_egp) }, { status: 'reversed', reason });
    });
    return ok({ ok: true });
  });

  r.get('/cash/attachment/:kind/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id) || !['receipt', 'expense'].includes(req.params.kind)) throw notFound();
    const t = req.params.kind === 'receipt' ? 'cash_receipts' : 'cash_expenses';
    const x = await one(db, `SELECT cashbox, recorded_by, attachment FROM ${t} WHERE id = $1`, [req.params.id]);
    if (!x || !x.attachment) throw notFound();
    if (!canSee(a, x.cashbox) && x.recorded_by !== a.id) throw forbidden();
    return ok({ attachment: Buffer.from(x.attachment).toString('base64') });
  });

  // ------------------------------------------------------------------ transfers between the two cashboxes
  /**
   * office → HR: HR asks, the manager approves, the manager hands it over, HR confirms receipt.
   * HR → office: the manager asks, HR hands it over (records the amount actually given), the manager confirms.
   * The two balances move only on the receipt confirmation, together, in one transaction (the ledger view).
   */
  r.post('/cash/transfers', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const direction = oneOf(b, 'direction', ['office_to_hr', 'hr_to_office'] as const)!;
    if (direction === 'office_to_hr' ? !canHrOperate(a) : !canOffice(a)) throw forbidden();
    const amount = money(b);
    const reason = str(b, 'reason', { min: 2, max: 500 })!.trim();
    const row = await db.tx(async (q) => {
      const x = await one(q, `INSERT INTO cash_transfers (direction, amount_requested, reason, requested_by) VALUES ($1,$2,$3,$4) RETURNING id`,
        [direction, amount, reason, a.id]);
      await audit(q, a.id, 'cash.transfer.request', 'cash_transfer', x.id, undefined, { direction, amount, reason });
      const to = direction === 'office_to_hr' ? await cashOfficers(q, a.id) : await hrOperators(q, a.id);
      for (const id of to) {
        await notify(q, { to: id, type: 'cash_transfer', title: direction === 'office_to_hr' ? `طلب تحويل من خزينة المكتب: ${fmt(amount)}` : `مطلوب تسليم ${fmt(amount)} لخزينة المكتب`,
          body: reason, entity: 'cash_transfer', entityId: x.id, dedupeKey: `cash:transfer:${x.id}:requested` });
      }
      return x;
    });
    const full = await one(db, `${TRANSFER_SELECT} WHERE t.id = $1`, [row.id]);
    return ok({ transfer: shapeTransfer(full, a) }, 201);
  });

  r.get('/cash/transfers', async (req) => {
    const a = await authenticate(db, req);
    if (!canHrView(a) && !canOffice(a)) throw forbidden();
    const vals: unknown[] = []; const where: string[] = [];
    const st = req.query.get('status');
    if (st === 'open') where.push(`t.status IN ('requested','approved','executed')`);
    else if (st) { vals.push(st); where.push(`t.status = $${vals.length}`); }
    const rows = await db.query(`${TRANSFER_SELECT} ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY t.requested_at DESC LIMIT 300`, vals);
    return ok({ currency: 'EGP', transfers: rows.rows.map((x) => shapeTransfer(x, a)) });
  });

  async function transferStep(id: string, fn: (q: Q, x: any) => Promise<{ to: string[]; title: string } | void>) {
    if (!isUuid(id)) throw notFound();
    await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM cash_transfers WHERE id = $1 FOR UPDATE`, [id]);
      if (!x) throw notFound();
      const n = await fn(q, x);
      if (n) {
        for (const to of n.to) {
          await notify(q, { to, type: 'cash_transfer', title: n.title, body: x.reason, entity: 'cash_transfer', entityId: x.id,
            dedupeKey: `cash:transfer:${x.id}:${n.title}:${to}` });
        }
      }
    });
  }

  r.post('/cash/transfers/:id/decision', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden();
    const b = obj(req.body);
    const decision = oneOf(b, 'decision', ['approve', 'reject'] as const)!;
    const reason = decision === 'reject' ? str(b, 'reason', { min: 3, max: 500 })! : null;
    await transferStep(req.params.id, async (q, x) => {
      if (x.direction !== 'office_to_hr' || x.status !== 'requested') throw conflict('This transfer is not waiting for approval');
      await q.query(`UPDATE cash_transfers SET status = $2, decided_by = $3, decided_at = now(), reject_reason = $4 WHERE id = $1`,
        [x.id, decision === 'approve' ? 'approved' : 'rejected', a.id, reason]);
      await audit(q, a.id, `cash.transfer.${decision}`, 'cash_transfer', x.id, { status: x.status }, { status: decision === 'approve' ? 'approved' : 'rejected', reason });
      return { to: [x.requested_by], title: decision === 'approve' ? `اتوافق على التحويل: ${fmt(Number(x.amount_requested))}` : 'اترفض طلب التحويل' };
    });
    return ok({ ok: true });
  });

  /** The cash is handed over: the amount actually given is recorded (it may differ from the request). */
  r.post('/cash/transfers/:id/execute', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    await transferStep(req.params.id, async (q, x) => {
      const toHr = x.direction === 'office_to_hr';
      if (toHr ? !(x.status === 'approved' && canOffice(a)) : !(x.status === 'requested' && canHrOperate(a))) {
        if (toHr ? !canOffice(a) : !canHrOperate(a)) throw forbidden();
        throw conflict('This transfer cannot be handed over now');
      }
      const amount = num(b, 'amount', { optional: true, min: 0.01, max: 100_000_000 }) ?? Number(x.amount_requested);
      await q.query(`UPDATE cash_transfers SET status = 'executed', executed_by = $2, executed_at = now(), amount_executed = $3 WHERE id = $1`,
        [x.id, a.id, amount]);
      await audit(q, a.id, 'cash.transfer.execute', 'cash_transfer', x.id, { status: x.status }, { status: 'executed', amount });
      const to = toHr ? await hrOperators(q, a.id) : (x.requested_by !== a.id ? [x.requested_by] : await cashOfficers(q, a.id));
      return { to, title: `اتسلّم ${fmt(amount)} — أكّد الاستلام` };
    });
    return ok({ ok: true });
  });

  /** Receipt confirmation by the other side: only now both balances move (one transaction). */
  r.post('/cash/transfers/:id/receive', async (req) => {
    const a = await authenticate(db, req);
    await transferStep(req.params.id, async (q, x) => {
      const toHr = x.direction === 'office_to_hr';
      if (toHr ? !canHrOperate(a) : !canOffice(a)) throw forbidden();
      if (x.status !== 'executed') throw conflict('Nothing was handed over yet');
      if (x.executed_by === a.id) throw forbidden('The person who handed the money over cannot confirm receiving it');
      await q.query(`UPDATE cash_transfers SET status = 'received', received_by = $2, received_at = now() WHERE id = $1`, [x.id, a.id]);
      await audit(q, a.id, 'cash.transfer.receive', 'cash_transfer', x.id, { status: 'executed' }, { status: 'received', amount: Number(x.amount_executed) });
      return { to: [x.executed_by], title: `تم استلام التحويل: ${fmt(Number(x.amount_executed))}` };
    });
    return ok({ ok: true });
  });

  r.post('/cash/transfers/:id/cancel', async (req) => {
    const a = await authenticate(db, req);
    await transferStep(req.params.id, async (q, x) => {
      if (x.requested_by !== a.id) throw forbidden();
      if (!['requested', 'approved'].includes(x.status)) throw conflict('This transfer can no longer be cancelled');
      await q.query(`UPDATE cash_transfers SET status = 'cancelled' WHERE id = $1`, [x.id]);
      await audit(q, a.id, 'cash.transfer.cancel', 'cash_transfer', x.id, { status: x.status }, { status: 'cancelled' });
    });
    return ok({ ok: true });
  });
};
