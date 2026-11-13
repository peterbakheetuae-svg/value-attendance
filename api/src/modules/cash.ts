import { salesMoneyOverview } from './exclusive.ts';
import { ok, type Module } from '../ctx.ts';
import { local } from '../lib/time.ts';
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
const RECEIPT_KINDS = ['reservation', 'down_payment', 'installment', 'settlement', 'other', 'commission'] as const;
const METHODS = ['cash', 'bank_transfer', 'cheque', 'card', 'wallet'] as const;
export const RECEIPT_KIND_AR: Record<string, string> = {
  reservation: 'مبلغ حجز', down_payment: 'مقدم وحدة', installment: 'قسط', settlement: 'تسوية', other: 'تحصيل آخر',
  commission: 'عمولة مستلمة', injection: 'ضخ من المالك / المدير العام',
};

export const canOffice = (a: Actor) => has(a, 'cash.office');
export const canHrView = (a: Actor) => has(a, 'cash.hr_view') || has(a, 'cash.office');
export const canHrOperate = (a: Actor) => has(a, 'cash.hr_operate');
/** Recording money in / out of the HR cashbox (collections, expenses) is HR's desk only — never المدير / المالك. */
export const hrDesk = (a: Actor) => canHrOperate(a) && !canOffice(a);
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
  out.can = { office: canOffice(a), hrView: canHrView(a), hrOperate: canHrOperate(a), hrDesk: hrDesk(a), settings: has(a, 'cash.settings') };
  return out;
}

/**
 * The cashbox the office's way (see migration 041):
 *  المتاح = بنك + نقدي (خزنة المكتب + خزنة المحاسب); الدخل = عمولات / مبيعات / ضخ / أمانات; المصروفات = المرتبات + المصاريف بأنواعها.
 * The bank part of a box = its non-cash receipts − its bank-paid expenses. HR (المحاسب) sees his own box only.
 */
export async function cashOverview(q: Q, a: Actor, from: string | null, to: string | null) {
  const office = canOffice(a);
  const boxes = office ? ['office', 'hr'] : ['hr'];
  const N = (v: unknown) => Number(v ?? 0);
  const bal = await q.query(`SELECT cashbox, COALESCE(sum(amount), 0) AS b FROM cash_ledger GROUP BY cashbox`);
  const bank = await q.query(`
    SELECT b.box,
      COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE cashbox = b.box AND status = 'posted' AND payment_method <> 'cash'), 0)
      - COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE cashbox = b.box AND status = 'posted' AND payment_method = 'bank'), 0)
      - COALESCE((SELECT sum(CASE direction WHEN 'bank_to_cash' THEN amount_egp ELSE -amount_egp END) FROM cash_bank_moves WHERE cashbox = b.box), 0) AS bank
      FROM (VALUES ('office'), ('hr')) b(box)`);
  const boxBal = (b: string) => r2(N(bal.rows.find((x) => x.cashbox === b)?.b));
  const boxBank = (b: string) => r2(N(bank.rows.find((x) => x.box === b)?.bank));
  const available: Record<string, unknown> = {
    hr: { total: boxBal('hr'), cash: r2(boxBal('hr') - boxBank('hr')), bank: boxBank('hr') },
  };
  if (office) {
    const officeCash = r2(boxBal('office') - boxBank('office')), hrCash = r2(boxBal('hr') - boxBank('hr'));
    Object.assign(available, {
      total: r2(boxBal('office') + boxBal('hr')), bank: r2(boxBank('office') + boxBank('hr')), cash: r2(officeCash + hrCash),
      office: { total: boxBal('office'), cash: officeCash, bank: boxBank('office') },
    });
  }
  if (office) {
    const held = await one(q, `SELECT
        COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r JOIN ex_units u ON u.id = r.ex_unit_id JOIN commission_projects p ON p.id = u.project_id
                   WHERE r.status = 'posted' AND p.kind = 'exclusive'), 0)
      - COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE status = 'posted' AND ex_kind IS NOT NULL), 0)
      - COALESCE((SELECT sum(amount_egp) FROM ex_commission_transfers), 0) AS s`);
    const trust = r2(N(held.s));
    Object.assign(available, { trust, afterTrust: r2(N(available.total) - trust) });
  }
  // the period (Cairo days)
  const vals: unknown[] = [boxes];
  const range = (col: string) => {
    const c: string[] = [];
    if (from) { vals.push(from); c.push(`${col} >= ($${vals.length}::date AT TIME ZONE 'Africa/Cairo')`); }
    if (to) { vals.push(to); c.push(`${col} < (($${vals.length}::date + 1) AT TIME ZONE 'Africa/Cairo')`); }
    return c.length ? ' AND ' + c.join(' AND ') : '';
  };
  vals.length = 1;
  const rcpt = await q.query(`
    SELECT r.kind, COALESCE(p.kind, '') AS project_kind, (r.ex_unit_id IS NOT NULL OR r.sale_id IS NOT NULL) AS unit, sum(r.amount_egp) AS s
      FROM cash_receipts r LEFT JOIN ex_units u ON u.id = r.ex_unit_id LEFT JOIN commission_projects p ON p.id = u.project_id
     WHERE r.status = 'posted' AND r.cashbox = ANY($1::text[]) ${range('r.occurred_at')}
     GROUP BY 1, 2, 3`, vals);
  const sumR = (f: (x: any) => boolean) => r2(rcpt.rows.filter(f).reduce((t, x) => t + N(x.s), 0));
  const isSale = (x: any) => ['reservation', 'down_payment', 'installment'].includes(x.kind);
  vals.length = 1;
  const exp = await q.query(`
    SELECT x.category, x.ex_kind, x.marketing_company_id IS NOT NULL AS mk, x.sale_id IS NOT NULL AS refund, x.owner_draw_id IS NOT NULL AS draw,
           x.fixed_expense_id IS NOT NULL AS fixed, sum(x.amount_egp) AS s, count(*)::int AS c
      FROM cash_expenses x WHERE x.status = 'posted' AND x.cashbox = ANY($1::text[]) ${range('COALESCE(x.approved_at, x.occurred_at)')}
     GROUP BY 1, 2, 3, 4, 5, 6`, vals);
  vals.length = 1;
  const pay = await q.query(`SELECT kind, sum(amount_egp) AS s FROM payouts WHERE status = 'received' AND kind <> 'fund' AND 'hr' = ANY($1::text[])
                               ${range('received_at')} GROUP BY kind`, vals);
  const payK = (k: string) => r2(N(pay.rows.find((x) => x.kind === k)?.s));
  const trustOut = r2(exp.rows.filter((x) => x.ex_kind).reduce((t, x) => t + N(x.s), 0));
  // a sold unit's refund (استرداد وحدة) gives the client his own money back: not a cost of the office
  const salesRefunds = r2(exp.rows.filter((x) => !x.ex_kind && x.refund).reduce((t, x) => t + N(x.s), 0));
  // مسحوبات الملاك: the owners' own money leaving, not a cost either
  const ownerDraws = r2(exp.rows.filter((x) => x.draw).reduce((t, x) => t + N(x.s), 0));
  const costsRows = exp.rows.filter((x) => !x.ex_kind && !x.refund && !x.draw);
  const byCat = new Map<string, { name: string; amount: number; count: number }>();
  for (const x of costsRows) {
    const name = x.mk ? 'شركة تسويق' : String(x.category).trim();
    const c = byCat.get(name) ?? { name, amount: 0, count: 0 };
    c.amount = r2(c.amount + N(x.s)); c.count += x.c; byCat.set(name, c);
  }
  const expensesTotal = r2([...byCat.values()].reduce((t, c) => t + c.amount, 0));
  // المصروفات الثابتة (إيجار، أوفيس بوي، نت...) apart from the rest
  const fixedTotal = r2(costsRows.filter((x) => x.fixed).reduce((t, x) => t + N(x.s), 0));
  const payroll = { salary: payK('salary'), commission: payK('commission'), advance: payK('advance'), workExpense: payK('work_expense') };
  const payrollTotal = r2(payroll.salary + payroll.commission + payroll.advance + payroll.workExpense);

  const out: Record<string, unknown> = {
    from, to, available,
    income: {
      sales: { total: sumR(isSale), reservation: sumR((x) => x.kind === 'reservation'), contract: sumR((x) => x.kind === 'down_payment'),
        installment: sumR((x) => x.kind === 'installment'), refunded: salesRefunds },
      injection: sumR((x) => x.kind === 'injection'),
      commissionReceived: sumR((x) => x.kind === 'commission'),
      other: sumR((x) => ['settlement', 'other'].includes(x.kind)),
    },
    expenses: { total: r2(expensesTotal + payrollTotal), payroll, payrollTotal, other: expensesTotal, fixed: fixedTotal, variable: r2(expensesTotal - fixedTotal), ownerDraws,
      byCategory: [...byCat.values()].sort((x, y) => y.amount - x.amount) },
  };
  if (office) {
    // الأمانات: the exclusive projects' money (in − refunds − paid to the owner − commission moved to the office)
    vals.length = 1;
    const tr = await one(q, `SELECT COALESCE(sum(amount_egp), 0) AS s FROM ex_commission_transfers WHERE $1::text[] IS NOT NULL ${range('created_at')}`, vals);
    const trustIn = sumR((x) => isSale(x) && x.project_kind === 'exclusive');
    const allTrust = await one(q, `SELECT
        COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r JOIN ex_units u ON u.id = r.ex_unit_id JOIN commission_projects p ON p.id = u.project_id
                   WHERE r.status = 'posted' AND p.kind = 'exclusive'), 0)
      - COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE status = 'posted' AND ex_kind IS NOT NULL), 0)
      - COALESCE((SELECT sum(amount_egp) FROM ex_commission_transfers), 0) AS s`);
    (out.income as any).trust = { in: trustIn, out: trustOut, commissionMoved: r2(N(tr.s)), balance: r2(N(allTrust.s)) };
    (out.income as any).commissions = r2((out.income as any).commissionReceived + N(tr.s));
    // the commission's split, as earned in the period (approved deals)
    vals.length = 1;
    // deals of the period: the contracted units (من المبيعات) + the commission requests filed without a unit (عمولة صفقة)
    const cm = await one(q, `SELECT COALESCE(sum(sales_amount), 0) AS s, COALESCE(sum(manager_amount), 0) AS m, COALESCE(sum(company_amount), 0) AS c,
        count(*)::int AS n FROM commission_requests WHERE status = 'approved' AND ex_unit_id IS NULL AND $1::text[] IS NOT NULL ${range('decided_at')}`, vals);
    vals.length = 1;
    const ux = await one(q, `SELECT COALESCE(sum(unit_price * sales_pct / 100), 0) AS s, COALESCE(sum(unit_price * manager_pct / 100), 0) AS m,
        COALESCE(sum(unit_price * mk_pct / 100), 0) AS k, COALESCE(sum(unit_price * total_pct / 100), 0) AS t, count(*)::int AS n
        FROM ex_units WHERE status = 'contracted' AND $1::text[] IS NOT NULL ${range('contracted_at')}`, vals);
    const sales = r2(N(cm.s) + N(ux.s)), manager = r2(N(cm.m) + N(ux.m)), marketing = r2(N(ux.k));
    const total = r2(N(cm.s) + N(cm.m) + N(cm.c) + N(ux.t));
    out.commissionSplit = { total, sales, manager, marketing, office: r2(total - sales - manager - marketing), deals: cm.n + ux.n };
    Object.assign(out, await salesMoneyOverview(q, from, to));
    const commissions = (out.income as any).commissions;
    out.result = { commissions, costs: (out.expenses as any).total, net: r2(commissions - (out.expenses as any).total) };
  }
  return out;
}

/** the company's owners: role owner, or anyone with a نسبة ملكية */
async function ownerIds(q: Q): Promise<string[]> {
  const r = await q.query(`SELECT e.id FROM employees e LEFT JOIN company_owners o ON o.employee_id = e.id
                            WHERE e.status = 'active' AND (e.role_key = 'owner' OR COALESCE(o.pct, 0) > 0)`);
  return r.rows.map((x) => x.id as string);
}

/** the office cashbox split: its bank part and its cash part */
async function officeParts(q: Q) {
  const s = await one(q, `SELECT
      COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE cashbox = 'office' AND status = 'posted' AND payment_method <> 'cash'), 0)
    - COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE cashbox = 'office' AND status = 'posted' AND payment_method = 'bank'), 0)
    - COALESCE((SELECT sum(CASE direction WHEN 'bank_to_cash' THEN amount_egp ELSE -amount_egp END) FROM cash_bank_moves WHERE cashbox = 'office'), 0) AS bank,
      COALESCE((SELECT sum(amount) FROM cash_ledger WHERE cashbox = 'office'), 0) AS total`);
  const bank = r2(Number(s.bank));
  return { bank, cash: r2(Number(s.total) - bank) };
}

/**
 * Each owner's account (all months): what he injected + his share (نسبة الملكية) of the office's net profit
 * − what he already withdrew (approved) − what is waiting for approval = what he can still withdraw.
 */
export async function ownerAccounts(q: Q, a: Actor) {
  const ids = await ownerIds(q);
  const ov = await cashOverview(q, a, null, null);
  const net = Number((ov.result as any)?.net ?? 0);
  const rows = (await q.query(`SELECT e.id, COALESCE(o.pct, 0) AS pct,
      COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.kind = 'injection' AND r.status = 'posted' AND r.recorded_by = e.id), 0) AS injected,
      COALESCE((SELECT sum(x.amount_egp) FROM cash_expenses x WHERE x.owner_draw_id = e.id AND x.status = 'posted'), 0) AS drawn,
      COALESCE((SELECT sum(x.amount_egp) FROM cash_expenses x WHERE x.owner_draw_id = e.id AND x.status = 'pending_approval'), 0) AS pending
      FROM employees e LEFT JOIN company_owners o ON o.employee_id = e.id WHERE e.id = ANY($1::uuid[])`, [ids])).rows;
  const out: Record<string, { injected: number; profit: number; withdrawn: number; pending: number; balance: number }> = {};
  for (const x of rows) {
    const injected = r2(Number(x.injected)), profit = r2(net * Number(x.pct) / 100), withdrawn = r2(Number(x.drawn)), pending = r2(Number(x.pending));
    out[x.id] = { injected, profit, withdrawn, pending, balance: r2(injected + profit - withdrawn - pending) };
  }
  return out;
}

async function cashOfficers(q: Q, exceptId?: string) {
  const r = await q.query(`
    SELECT DISTINCT e.id FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
     WHERE rp.perm_key = 'cash.office' AND e.status = 'active' AND e.id <> COALESCE($1::uuid, '00000000-0000-0000-0000-000000000000')`,
    [exceptId ?? null]);
  return r.rows.map((x) => x.id as string);
}

export async function hrOperators(q: Q, exceptId?: string) {
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
  saleId?: string | null; installmentId?: string | null; projectId?: string | null;
}

/**
 * recipient 'hr' → HR physically got it → HR cashbox, recipient = HR person.
 * recipient 'manager' → the manager got it himself → office cashbox, recipient = that manager
 * (recorded by the manager / owner only — HR never collects into the office cashbox).
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
    if (!hrDesk(a)) throw forbidden('Only HR records collections into the HR cashbox');
    box = 'hr';
    recipientId = typeof b.recipientId === 'string' && b.recipientId ? b.recipientId : a.id;
  } else {
    // the office cashbox is the manager's / owner's own: HR never records a collection into it (and the manager
    // never records one into the HR cashbox — see above)
    if (!canOffice(a)) throw forbidden('Only the manager or the owner records collections into the office cashbox');
    box = 'office';
    recipientId = typeof b.recipientId === 'string' && b.recipientId ? b.recipientId : a.id;
    if (!recipientId) throw invalid('Choose the manager who received the money', { field: 'recipientId' });
  }
  if (!isUuid(recipientId)) throw invalid('recipientId is invalid', { field: 'recipientId' });
  const saleId = typeof b.saleId === 'string' && b.saleId ? b.saleId : null;
  const installmentId = typeof b.installmentId === 'string' && b.installmentId ? b.installmentId : null;
  const projectId = typeof b.projectId === 'string' && isUuid(b.projectId) ? b.projectId : null;
  return { box, recipientId, kind, amount, payerName, payerPhone, purpose, method, externalNo, notes, ref, att, occurred, saleId, installmentId, projectId };
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
           external_no, client_ref, notes, attachment, occurred_at, recorded_by, sale_id, installment_id, project_id)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17) RETURNING id, ref_no`,
    [x.kind, x.amount, x.box, x.recipientId, x.payerName, x.payerPhone, x.purpose, x.method, x.externalNo, x.ref, x.notes, x.att,
      x.occurred, a.id, x.saleId ?? null, x.installmentId ?? null, x.projectId ?? null]);
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
    paymentMethod: x.payment_method ?? 'cash', marketingCompanyId: x.marketing_company_id ?? null,
    fixedExpenseId: x.fixed_expense_id ?? null,
  };
}

/**
 * The two sides of a transfer: خزنة المكتب (المالك / المدير العام: cash.office) and خزنة المحاسب (the accountant: cash.hr_operate
 * without cash.office). Someone with both counts as the office side; he acts for the accountant's box only when the company has
 * no accountant at all.
 */
async function hasHrDesk(q: Q) {
  return !!(await one(q, `SELECT 1 FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
     WHERE e.status = 'active' AND rp.perm_key = 'cash.hr_operate'
       AND NOT EXISTS (SELECT 1 FROM role_permissions o WHERE o.role_key = rp.role_key AND o.perm_key = 'cash.office') LIMIT 1`));
}
const hrSideOf = (a: Actor, desk: boolean) => hrDesk(a) || (canHrOperate(a) && !desk);

function shapeTransfer(x: any, a: Actor, desk: boolean) {
  const toHr = x.direction === 'office_to_hr';
  const hrSide = hrSideOf(a, desk), office = canOffice(a);
  // the viewer's own box: the office side sees it from خزنة المكتب, the accountant from his box
  const myBox = office ? 'office' : 'hr';
  const incoming = toHr ? myBox === 'hr' : myBox === 'office';
  return {
    id: x.id, refNo: Number(x.ref_no), direction: x.direction, amountRequested: Number(x.amount_requested),
    amountExecuted: x.amount_executed == null ? null : Number(x.amount_executed), reason: x.reason, status: x.status,
    requestedByName: x.requested_by_name, requestedAt: x.requested_at, decidedByName: x.decided_by_name, decidedAt: x.decided_at,
    rejectReason: x.reject_reason, executedByName: x.executed_by_name, executedAt: x.executed_at,
    receivedByName: x.received_by_name, receivedAt: x.received_at,
    // in = the money comes INTO the viewer's box (green), out = it leaves it (red)
    flow: incoming ? 'in' : 'out',
    // what this person can do next
    can: {
      decide: toHr && x.status === 'requested' && office && x.requested_by !== a.id,
      execute: (toHr && x.status === 'approved' && office) || (!toHr && x.status === 'requested' && (hrDesk(a) || (!desk && canHrOperate(a)))),
      // only the side the money goes TO confirms it, never the one who handed it over
      receive: x.status === 'executed' && x.executed_by !== a.id && (toHr ? hrSide && !(office && desk) : office),
      notReceived: x.status === 'executed' && x.executed_by !== a.id && (toHr ? hrSide && !(office && desk) : office),
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

  /** ضخ: المالك / المدير العام puts his own money in — نقدي في خزنة المكتب، في خزنة المحاسب، أو في البنك. */
  /** ضخ أموال: every injection + each owner's share (نسبة الملكية), what he injected and his part of the net profit. */
  r.get('/cash/injections', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden('صفحة الضخ للمالك / المدير العام بس');
    const ok1 = (d: string | null) => (d && /^\d{4}-\d{2}-\d{2}$/.test(d) ? d : null);
    const from = ok1(req.query.get('from')), to = ok1(req.query.get('to'));
    const vals: unknown[] = [];
    const range = (col: string) => {
      const c: string[] = [];
      if (from) { vals.push(from); c.push(`${col} >= ($${vals.length}::date AT TIME ZONE 'Africa/Cairo')`); }
      if (to) { vals.push(to); c.push(`${col} < (($${vals.length}::date + 1) AT TIME ZONE 'Africa/Cairo')`); }
      return c.length ? ' AND ' + c.join(' AND ') : '';
    };
    const rows = (await db.query(`
      SELECT r.id, r.ref_no, r.amount_egp, r.cashbox, r.payment_method, r.notes, r.purpose, r.occurred_at, r.status, r.recorded_by, e.full_name AS by_name
        FROM cash_receipts r JOIN employees e ON e.id = r.recorded_by
       WHERE r.kind = 'injection' ${range('r.occurred_at')} ORDER BY r.occurred_at DESC`, vals)).rows;
    const owners = (await db.query(`
      SELECT e.id, e.full_name, COALESCE(o.pct, 0) AS pct,
             COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.kind = 'injection' AND r.status = 'posted' AND r.recorded_by = e.id), 0) AS all_time
        FROM employees e LEFT JOIN company_owners o ON o.employee_id = e.id
       WHERE e.status = 'active' AND (e.role_key = 'owner' OR o.employee_id IS NOT NULL) ORDER BY o.pct DESC NULLS LAST, e.full_name`)).rows;
    const ov = await cashOverview(db, a, from, to);
    const net = Number((ov.result as any)?.net ?? 0);
    const posted = rows.filter((x) => x.status === 'posted');
    const acc = await ownerAccounts(db, a);
    vals.length = 0;
    const drawSql = `
      SELECT x.id, x.ref_no, x.amount_egp, x.payment_method, x.notes, x.status, x.occurred_at, x.owner_draw_id, x.recorded_by, x.reject_reason,
             e.full_name AS by_name, ap.full_name AS approved_by_name
        FROM cash_expenses x JOIN employees e ON e.id = x.owner_draw_id LEFT JOIN employees ap ON ap.id = x.approved_by
       WHERE x.owner_draw_id IS NOT NULL ${range('x.occurred_at')} ORDER BY x.occurred_at DESC`;
    const draws = (await db.query(drawSql, vals)).rows;
    return ok({
      from, to, net, commissions: (ov.result as any)?.commissions ?? 0, costs: (ov.result as any)?.costs ?? 0,
      total: r2(posted.reduce((t, x) => t + Number(x.amount_egp), 0)),
      owners: owners.map((o) => ({ id: o.id, name: o.full_name, pct: Number(o.pct),
        injected: r2(posted.filter((x) => x.recorded_by === o.id).reduce((t, x) => t + Number(x.amount_egp), 0)),
        injectedAllTime: r2(Number(o.all_time)), profit: r2(net * Number(o.pct) / 100),
        withdrawn: r2(draws.filter((x) => x.owner_draw_id === o.id && x.status === 'posted').reduce((t, x) => t + Number(x.amount_egp), 0)),
        account: acc[o.id] ?? null })),
      draws: draws.map((x) => ({ id: x.id, refNo: Number(x.ref_no), ownerId: x.owner_draw_id, ownerName: x.by_name, amount: Number(x.amount_egp),
        method: x.payment_method, note: x.notes, status: x.status, at: x.occurred_at, approvedByName: x.approved_by_name, rejectReason: x.reject_reason,
        canDecide: x.status === 'pending_approval' && x.recorded_by !== a.id && acc[a.id] !== undefined })),
      me: a.id,
      injections: rows.map((x) => ({ id: x.id, receiptNo: `R-${String(x.ref_no).padStart(6, '0')}`, amount: Number(x.amount_egp),
        target: x.payment_method !== 'cash' ? 'بنك' : x.cashbox === 'hr' ? 'خزنة المحاسب' : 'خزنة المكتب', note: x.notes, at: x.occurred_at,
        byName: x.by_name, status: x.status })),
    });
  });

  /** مسحوبات الملاك: he asks, another owner approves (/cash/expenses/:id/decision), the office cashbox pays. */
  r.post('/cash/owner-draws', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden();
    const b = obj(req.body);
    const amount = money(b);
    const method = oneOf(b, 'paymentMethod', ['cash', 'bank'] as const, true) ?? 'cash';
    const note = (str(b, 'note', { optional: true, max: 500 }) ?? '').trim();
    const ref = clientRef(b);
    const out = await db.tx(async (q) => {
      if (ref) {
        const dup = await one(q, `SELECT id FROM cash_expenses WHERE client_ref = $1`, [ref]);
        if (dup) return dup;
      }
      const owners = await ownerIds(q);
      if (!owners.includes(a.id)) throw forbidden('السحب للملاك بس');
      const others = owners.filter((x) => x !== a.id);
      if (!others.length) throw invalid('لازم مالك تاني يوافق على السحب — حدد نسب الملكية الأول', { field: 'amount' });
      const acc = (await ownerAccounts(q, a))[a.id];
      if (amount > acc.balance + 0.001) throw invalid(`رصيد حسابك ${fmt(Math.max(acc.balance, 0))} بس`, { field: 'amount', max: acc.balance });
      const box = await officeParts(q);
      const part = method === 'bank' ? box.bank : box.cash;
      if (amount > part + 0.001) throw invalid(`${method === 'bank' ? 'رصيد البنك' : 'النقدي في خزنة المكتب'} ${fmt(Math.max(part, 0))} بس`, { field: 'amount' });
      const x = await one(q, `
        INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, notes, client_ref, occurred_at, recorded_by, status, payment_method, owner_draw_id)
        VALUES ('office',$1,'مسحوبات الملاك',$2,$3,$4,$5,$6,$7,'pending_approval',$8,$7) RETURNING id`,
        [amount, `سحب أرباح — ${a.fullName}`, a.fullName || 'مالك', note, ref, clock(), a.id, method]);
      await audit(q, a.id, 'cash.owner_draw', 'cash_expense', x.id, undefined, { amount, method, note });
      for (const o of others) {
        await notify(q, { to: o, type: 'cash_expense_awaiting', title: `سحب أرباح محتاج موافقتك: ${fmt(amount)}`, body: `${a.fullName}${note ? ' — ' + note : ''}`,
          entity: 'cash_expense', entityId: x.id, dedupeKey: `cash:expense:${x.id}:awaiting` });
      }
      return x;
    });
    return ok({ draw: { id: out.id } }, 201);
  });

  /** نسبة الملكية of each owner (out of 100). */
  r.put('/cash/owners', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden();
    const b = obj(req.body);
    const list = Array.isArray(b.owners) ? b.owners : [];
    const parsed = list.map((x: any) => ({ id: String(x?.employeeId ?? ''), pct: Number(x?.pct) }));
    if (parsed.some((x) => !isUuid(x.id) || !Number.isFinite(x.pct) || x.pct < 0 || x.pct > 100)) throw invalid('راجع النسب', { field: 'owners' });
    if (parsed.reduce((t, x) => t + x.pct, 0) > 100.0001) throw invalid('مجموع النسب أكبر من 100٪', { field: 'owners' });
    await db.tx(async (q) => {
      for (const x of parsed) {
        if (!(await one(q, `SELECT 1 FROM employees WHERE id = $1`, [x.id]))) throw invalid('موظف مش موجود', { field: 'owners' });
        await q.query(`INSERT INTO company_owners (employee_id, pct, updated_by, updated_at) VALUES ($1,$2,$3,$4)
                        ON CONFLICT (employee_id) DO UPDATE SET pct = EXCLUDED.pct, updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at`,
          [x.id, x.pct, a.id, clock()]);
      }
      await audit(q, a.id, 'cash.owners', 'company_owners', a.id, undefined, { owners: parsed });
    });
    return ok({ ok: true });
  });

  r.post('/cash/injections', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden('الضخ للمالك / المدير العام بس');
    const b = obj(req.body);
    const target = oneOf(b, 'target', ['office', 'bank'] as const)! as 'office' | 'hr' | 'bank';
    const amount = money(b);
    const note = (str(b, 'note', { optional: true, max: 500 }) ?? '').trim();
    const ref = clientRef(b);
    const row = await db.tx(async (q) => {
      if (ref) {
        const dup = await one(q, `SELECT id FROM cash_receipts WHERE client_ref = $1`, [ref]);
        if (dup) return dup;
      }
      let recipient = a.id;
      if (target === 'hr') {
        const ops = await hrOperators(q);
        if (!ops.length) throw invalid('مفيش محاسب يستلم الفلوس', { field: 'target' });
        recipient = typeof b.recipientId === 'string' && ops.includes(b.recipientId) ? b.recipientId : ops[0];
      }
      const x = await one(q, `INSERT INTO cash_receipts (kind, amount_egp, cashbox, actual_recipient_id, payer_name, purpose, payment_method,
          client_ref, notes, occurred_at, recorded_by)
        VALUES ('injection',$1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id, ref_no`,
        [amount, target === 'hr' ? 'hr' : 'office', recipient, a.fullName || 'المالك / المدير العام',
          `ضخ من المالك / المدير العام — ${target === 'bank' ? 'بنك' : target === 'hr' ? 'خزنة المحاسب' : 'خزنة المكتب'}`,
          target === 'bank' ? 'bank_transfer' : 'cash', ref, note, clock(), a.id]);
      await audit(q, a.id, 'cash.injection', 'cash_receipt', x.id, undefined, { amount, target, note });
      if (target === 'hr') {
        await notify(q, { to: recipient, type: 'cash_receipt', title: `ضخ في خزنة المحاسب: ${fmt(amount)}`, body: note || 'من المالك / المدير العام',
          entity: 'cash_receipt', entityId: x.id, dedupeKey: `cash:receipt:${x.id}` });
      }
      return x;
    });
    return ok({ receipt: { id: row.id, receiptNo: `R-${String(row.ref_no).padStart(6, '0')}` } }, 201);
  });

  /** The cashbox read the office's way: what is available, where it came from and where it went. */
  r.get('/cash/overview', async (req) => {
    const a = await authenticate(db, req);
    if (!canHrView(a) && !canOffice(a)) throw forbidden();
    const from = req.query.get('from'), to = req.query.get('to');
    const ok1 = (d: string | null) => d && /^\d{4}-\d{2}-\d{2}$/.test(d) ? d : null;
    return ok(await cashOverview(db, a, ok1(from), ok1(to)));
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
    if (box === 'office' ? !canOffice(a) : !hrDesk(a)) throw forbidden('Only HR records HR cashbox expenses');
    const amount = money(b);
    const category = str(b, 'category', { min: 2, max: 80 })!.trim();
    const reason = str(b, 'reason', { min: 2, max: 500 })!.trim();
    const beneficiary = str(b, 'beneficiary', { min: 2, max: 120 })!.trim();
    const notes = str(b, 'notes', { optional: true, max: 1000 }) ?? '';
    const ref = clientRef(b);
    const att = attachment(b);
    const occurred = when(b, 'occurredAt', clock());
    const method = oneOf(b, 'paymentMethod', ['cash', 'bank'] as const, true) ?? 'cash';
    const mkId = typeof b.marketingCompanyId === 'string' && isUuid(b.marketingCompanyId) ? b.marketingCompanyId : null;
    const out = await db.tx(async (q) => {
      if (mkId && !(await one(q, `SELECT 1 FROM marketing_companies WHERE id = $1`, [mkId]))) throw invalid('اختار شركة التسويق', { field: 'marketingCompanyId' });
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
               status, approved_by, approved_at, payment_method, marketing_company_id)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) RETURNING id, ref_no`,
        [box, amount, category, reason, beneficiary, notes, att, ref, occurred, a.id,
          needsApproval ? 'pending_approval' : 'posted', needsApproval ? null : a.id, needsApproval ? null : clock(), method, mkId]);
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

  // ------------------------------------------------------------------ مصروفات ثابتة
  const canBox = (a: Actor, box: string) => (box === 'office' ? canOffice(a) : hrDesk(a) || canOffice(a));
  // a fixed expense belongs to no cashbox: whoever presses «صرف» pays it from his own (المحاسب ← خزنة المحاسب، المدير ← خزنة المكتب)
  const canFixed = (a: Actor) => hrDesk(a) || canOffice(a);
  const ownBox = (a: Actor): 'hr' | 'office' => (hrDesk(a) ? 'hr' : 'office');
  const shapeFixed = (f: any) => ({ id: f.id, name: f.name, category: f.category, amount: Number(f.amount_egp), beneficiary: f.beneficiary,
    cashbox: f.cashbox, paymentMethod: f.payment_method, notes: f.notes, active: f.active,
    paid: f.exp_id ? { expenseId: f.exp_id, cashbox: f.exp_box, status: f.exp_status, refNo: Number(f.exp_ref), hasAttachment: f.exp_att === true } : null });

  r.get('/cash/fixed-expenses', async (req) => {
    const a = await authenticate(db, req);
    if (!canFixed(a)) throw forbidden();
    const m = req.query.get('month');
    const period = m && /^\d{4}-\d{2}$/.test(m) ? `${m}-01` : local(clock()).date.slice(0, 7) + '-01';
    const rows = await db.query(`
      SELECT f.*, x.id AS exp_id, x.cashbox AS exp_box, x.status AS exp_status, x.ref_no AS exp_ref, (x.attachment IS NOT NULL) AS exp_att
        FROM fixed_expenses f
        LEFT JOIN LATERAL (SELECT * FROM cash_expenses e WHERE e.fixed_expense_id = f.id AND e.fixed_period = $1::date
                             AND e.status IN ('pending_approval','posted') ORDER BY e.created_at DESC LIMIT 1) x ON true
       ORDER BY f.active DESC, f.name`, [period]);
    return ok({ period, fixed: rows.rows.map(shapeFixed), payFrom: ownBox(a) });
  });

  function fixedBody(b: Record<string, unknown>, old?: any) {
    const box = (old?.cashbox ?? 'office') as 'office' | 'hr';
    return {
      name: (str(b, 'name', { optional: !!old, min: 2, max: 120 }) ?? old?.name ?? '').trim(),
      category: (str(b, 'category', { optional: !!old, min: 2, max: 80 }) ?? old?.category ?? '').trim(),
      amount: b.amount === undefined && old ? Number(old.amount_egp) : money(b),
      beneficiary: (str(b, 'beneficiary', { optional: !!old, min: 2, max: 120 }) ?? old?.beneficiary ?? '').trim(),
      box, method: oneOf(b, 'paymentMethod', ['cash', 'bank'] as const, true) ?? old?.payment_method ?? 'cash',
      notes: (str(b, 'notes', { optional: true, max: 1000 }) ?? old?.notes ?? '').trim(),
      active: typeof b.active === 'boolean' ? b.active : old?.active ?? true,
    };
  }

  r.post('/cash/fixed-expenses', async (req) => {
    const a = await authenticate(db, req);
    if (!canFixed(a)) throw forbidden();
    const f = fixedBody(obj(req.body));
    const x = await db.tx(async (q) => {
      const row = await one(q, `INSERT INTO fixed_expenses (name, category, amount_egp, beneficiary, cashbox, payment_method, notes, active, created_by)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *`, [f.name, f.category, f.amount, f.beneficiary, f.box, f.method, f.notes, f.active, a.id]);
      await audit(q, a.id, 'cash.fixed_expense.create', 'fixed_expense', row.id, undefined, row);
      return row;
    });
    return ok({ fixed: shapeFixed(x) }, 201);
  });

  r.patch('/cash/fixed-expenses/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const x = await db.tx(async (q) => {
      const o = await one(q, `SELECT * FROM fixed_expenses WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!o) throw notFound();
      const f = fixedBody(obj(req.body), o);
      if (!canFixed(a)) throw forbidden();
      const row = await one(q, `UPDATE fixed_expenses SET name = $2, category = $3, amount_egp = $4, beneficiary = $5, cashbox = $6, payment_method = $7,
          notes = $8, active = $9 WHERE id = $1 RETURNING *`, [o.id, f.name, f.category, f.amount, f.beneficiary, f.box, f.method, f.notes, f.active]);
      await audit(q, a.id, 'cash.fixed_expense.update', 'fixed_expense', o.id, o, row);
      return row;
    });
    return ok({ fixed: shapeFixed(x) });
  });

  /** «صرف»: this month's expense of a fixed one (once a month), recorded like any expense. */
  r.post('/cash/fixed-expenses/:id/pay', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const m = typeof b.month === 'string' && /^\d{4}-\d{2}$/.test(b.month) ? b.month : local(clock()).date.slice(0, 7);
    const period = `${m}-01`;
    const out = await db.tx(async (q) => {
      const f = await one(q, `SELECT * FROM fixed_expenses WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!f) throw notFound();
      if (!f.active) throw conflict('المصروف الثابت ده موقوف');
      if (!canFixed(a)) throw forbidden();
      const box = ownBox(a);
      if (await one(q, `SELECT 1 FROM cash_expenses WHERE fixed_expense_id = $1 AND fixed_period = $2 AND status IN ('pending_approval','posted')`, [f.id, period])) {
        throw conflict('المصروف ده اتصرف الشهر ده بالفعل');
      }
      const s = await one(q, `SELECT expense_approval_threshold FROM company_settings LIMIT 1`);
      const threshold = Number(s?.expense_approval_threshold ?? 1000);
      const amount = Number(f.amount_egp);
      const needsApproval = box === 'hr' && !canOffice(a) && amount > threshold;
      const monthAr = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'][Number(m.slice(5, 7)) - 1];
      const x = await one(q, `
        INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, notes, occurred_at, recorded_by, status, approved_by, approved_at,
               payment_method, fixed_expense_id, fixed_period)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) RETURNING id, ref_no`,
        [box, amount, f.category, `${f.name} — ${monthAr} ${m.slice(0, 4)}`, f.beneficiary, f.notes, clock(), a.id,
          needsApproval ? 'pending_approval' : 'posted', needsApproval ? null : a.id, needsApproval ? null : clock(), f.payment_method, f.id, period]);
      await audit(q, a.id, 'cash.fixed_expense.pay', 'cash_expense', x.id, undefined, { fixedExpenseId: f.id, period, amount, cashbox: box });
      if (needsApproval) {
        for (const o of await cashOfficers(q, a.id)) {
          await notify(q, { to: o, type: 'cash_expense_awaiting', title: `مصروف ثابت محتاج موافقتك: ${fmt(amount)}`, body: `${f.name} — ${f.beneficiary}`,
            entity: 'cash_expense', entityId: x.id, dedupeKey: `cash:expense:${x.id}:awaiting` });
        }
      }
      return x;
    });
    const full = await one(db, `${EXPENSE_SELECT} WHERE x.id = $1`, [out.id]);
    return ok({ expense: shapeExpense(full) }, 201);
  });

  /** The signed receipt's photo, added after the beneficiary signs (once). */
  r.post('/cash/expenses/:id/attachment', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const att = attachment(obj(req.body));
    if (!att) throw invalid('ارفع صورة الإيصال', { field: 'attachment' });
    await db.tx(async (q) => {
      const x = await one(q, `SELECT id, cashbox, recorded_by, attachment IS NOT NULL AS has FROM cash_expenses WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x) throw notFound();
      if (!canBox(a, x.cashbox)) throw forbidden();
      await q.query(`UPDATE cash_expenses SET attachment = $2 WHERE id = $1`, [x.id, att]);
      await audit(q, a.id, 'cash.expense.attachment', 'cash_expense', x.id, undefined, { replaced: x.has });
    });
    return ok({ ok: true });
  });

  r.get('/cash/expenses/:id/attachment', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const x = await one(db, `SELECT cashbox, attachment FROM cash_expenses WHERE id = $1`, [req.params.id]);
    if (!x || !x.attachment) throw notFound();
    if (!canSee(a, x.cashbox)) throw forbidden();
    return ok({ attachment: Buffer.from(x.attachment).toString('base64') });
  });

  // ------------------------------------------------------------------ نقل من البنك إلى خزنة المكتب
  r.get('/cash/bank-moves', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden();
    const rows = await db.query(`SELECT m.*, e.full_name AS by_name FROM cash_bank_moves m JOIN employees e ON e.id = m.created_by
                                  ORDER BY m.created_at DESC LIMIT 200`);
    return ok({ moves: rows.rows.map((m) => ({ id: m.id, refNo: Number(m.ref_no), cashbox: m.cashbox, direction: m.direction,
      amount: Number(m.amount_egp), note: m.note, at: m.created_at, byName: m.by_name })) });
  });

  /** بين البنك والنقدي في خزنة المكتب: نقل من البنك للخزنة، أو توريد كاش للبنك — the box's total stays the same. */
  r.post('/cash/bank-moves', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden('نقل الفلوس بين البنك والخزنة للمالك / المدير العام');
    const b = obj(req.body);
    const direction = oneOf(b, 'direction', ['bank_to_cash', 'cash_to_bank'] as const, true) ?? 'bank_to_cash';
    const amount = money(b);
    const note = (str(b, 'note', { optional: true, max: 500 }) ?? '').trim();
    const row = await db.tx(async (q) => {
      const s = await one(q, `SELECT
          COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE cashbox = 'office' AND status = 'posted' AND payment_method <> 'cash'), 0)
        - COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE cashbox = 'office' AND status = 'posted' AND payment_method = 'bank'), 0)
        - COALESCE((SELECT sum(CASE direction WHEN 'bank_to_cash' THEN amount_egp ELSE -amount_egp END) FROM cash_bank_moves WHERE cashbox = 'office'), 0) AS bank,
          COALESCE((SELECT sum(amount) FROM cash_ledger WHERE cashbox = 'office'), 0) AS total`);
      const bank = Number(s.bank), cash = Number(s.total) - bank;
      if (direction === 'bank_to_cash' && amount > bank + 0.001) throw invalid(`رصيد البنك ${fmt(bank)} بس`, { field: 'amount' });
      if (direction === 'cash_to_bank' && amount > cash + 0.001) throw invalid(`النقدي في خزنة المكتب ${fmt(Math.max(cash, 0))} بس`, { field: 'amount' });
      const x = await one(q, `INSERT INTO cash_bank_moves (cashbox, direction, amount_egp, note, created_by, created_at) VALUES ('office',$1,$2,$3,$4,$5)
                               RETURNING id, ref_no`, [direction, amount, note, a.id, clock()]);
      await audit(q, a.id, 'cash.bank_move', 'cash_bank_move', x.id, undefined, { direction, amount, note });
      return x;
    });
    return ok({ move: { id: row.id, refNo: Number(row.ref_no) } }, 201);
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
      if (x.owner_draw_id && !(await ownerIds(q)).includes(a.id)) throw forbidden('سحب الأرباح يوافق عليه مالك تاني');
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
    // طلب تحويل أموال للمحاسب: the accountant or المالك / المدير العام; طلب توريد: المالك / المدير العام
    if (direction === 'office_to_hr' ? !canHrOperate(a) && !canOffice(a) : !canOffice(a)) throw forbidden();
    const amount = money(b);
    const reason = str(b, 'reason', { min: 2, max: 500 })!.trim();
    const row = await db.tx(async (q) => {
      const desk = await hasHrDesk(q);
      // the office side sending money to the accountant: no approval of his own request — he hands it over next
      const selfApproved = direction === 'office_to_hr' && canOffice(a) && !hrDesk(a);
      if (direction === 'office_to_hr' && !canOffice(a) && !hrSideOf(a, desk)) throw forbidden();
      const x = await one(q, `INSERT INTO cash_transfers (direction, amount_requested, reason, requested_by, status, decided_by, decided_at)
                               VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
        [direction, amount, reason, a.id, selfApproved ? 'approved' : 'requested', selfApproved ? a.id : null, selfApproved ? clock() : null]);
      await audit(q, a.id, 'cash.transfer.request', 'cash_transfer', x.id, undefined, { direction, amount, reason });
      const to = selfApproved ? [] : direction === 'office_to_hr' ? await cashOfficers(q, a.id) : await hrOperators(q, a.id);
      for (const id of to) {
        await notify(q, { to: id, type: 'cash_transfer', title: direction === 'office_to_hr' ? `طلب تحويل من خزينة المكتب: ${fmt(amount)}` : `مطلوب تسليم ${fmt(amount)} لخزينة المكتب`,
          body: reason, entity: 'cash_transfer', entityId: x.id, dedupeKey: `cash:transfer:${x.id}:requested` });
      }
      return x;
    });
    const full = await one(db, `${TRANSFER_SELECT} WHERE t.id = $1`, [row.id]);
    return ok({ transfer: shapeTransfer(full, a, await hasHrDesk(db)) }, 201);
  });

  r.get('/cash/transfers', async (req) => {
    const a = await authenticate(db, req);
    if (!canHrView(a) && !canOffice(a)) throw forbidden();
    const vals: unknown[] = []; const where: string[] = [];
    const st = req.query.get('status');
    if (st === 'open') where.push(`t.status IN ('requested','approved','executed')`);
    else if (st) { vals.push(st); where.push(`t.status = $${vals.length}`); }
    const rows = await db.query(`${TRANSFER_SELECT} ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY t.requested_at DESC LIMIT 300`, vals);
    const desk = await hasHrDesk(db);
    return ok({ currency: 'EGP', transfers: rows.rows.map((x) => shapeTransfer(x, a, desk)) });
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
      if (x.requested_by === a.id) throw forbidden('مينفعش توافق على طلب انت عامله');
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
      const desk = await hasHrDesk(q);
      // office → المحاسب: the office hands it over · المحاسب → office (توريد): the accountant hands it over
      const mine = toHr ? canOffice(a) : hrDesk(a) || (!desk && canHrOperate(a));
      if (!mine) throw forbidden(toHr ? 'خزنة المكتب هي اللي بتسلّم الفلوس' : 'المحاسب هو اللي بيسلّم التوريد');
      if (x.status !== (toHr ? 'approved' : 'requested')) throw conflict('This transfer cannot be handed over now');
      const amount = num(b, 'amount', { optional: true, min: 0.01, max: 100_000_000 }) ?? Number(x.amount_requested);
      const from = toHr ? 'office' : 'hr';
      const bal = Number((await one(q, `SELECT COALESCE(sum(amount), 0) AS s FROM cash_ledger WHERE cashbox = $1`, [from])).s);
      if (amount > bal + 0.001) throw invalid(`${from === 'office' ? 'رصيد خزنة المكتب' : 'رصيد خزنة المحاسب'} ${fmt(Math.max(bal, 0))} بس`, { field: 'amount' });
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
      const desk = await hasHrDesk(q);
      // the money goes to the accountant → the accountant (not the manager) confirms; to the office → the office
      if (toHr ? !(hrSideOf(a, desk) && !(canOffice(a) && desk)) : !canOffice(a)) {
        throw forbidden(toHr ? 'المحاسب هو اللي يأكد إنه استلم' : 'خزنة المكتب هي اللي تأكد الاستلام');
      }
      if (x.status !== 'executed') throw conflict('Nothing was handed over yet');
      if (x.executed_by === a.id) throw forbidden('The person who handed the money over cannot confirm receiving it');
      await q.query(`UPDATE cash_transfers SET status = 'received', received_by = $2, received_at = now() WHERE id = $1`, [x.id, a.id]);
      await audit(q, a.id, 'cash.transfer.receive', 'cash_transfer', x.id, { status: 'executed' }, { status: 'received', amount: Number(x.amount_executed) });
      return { to: [x.executed_by], title: `تم استلام التحويل: ${fmt(Number(x.amount_executed))}` };
    });
    return ok({ ok: true });
  });

  /** «مستلمتش»: the receiving side says the money did not reach it — the transfer closes, no balance moved. */
  r.post('/cash/transfers/:id/not-received', async (req) => {
    const a = await authenticate(db, req);
    const reason = (str(obj(req.body), 'reason', { optional: true, max: 500 }) ?? '').trim();
    await transferStep(req.params.id, async (q, x) => {
      const toHr = x.direction === 'office_to_hr';
      const desk = await hasHrDesk(q);
      if (toHr ? !(hrSideOf(a, desk) && !(canOffice(a) && desk)) : !canOffice(a)) throw forbidden();
      if (x.status !== 'executed') throw conflict('Nothing was handed over yet');
      if (x.executed_by === a.id) throw forbidden();
      await q.query(`UPDATE cash_transfers SET status = 'cancelled', reject_reason = $2 WHERE id = $1`, [x.id, `مستلمتش${reason ? ' — ' + reason : ''}`]);
      await audit(q, a.id, 'cash.transfer.not_received', 'cash_transfer', x.id, { status: 'executed' }, { status: 'cancelled', reason });
      return { to: [x.executed_by], title: `التحويل ما اتستلمش: ${fmt(Number(x.amount_executed))}` };
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
