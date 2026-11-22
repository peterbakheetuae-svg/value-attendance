import { createHash } from 'node:crypto';
import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { isUuid, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, can, has, isOwner, type Actor } from '../auth/context.ts';
import { local } from '../lib/time.ts';
import { canOffice, cashOverview, ownerBalancesAt, ownerIds } from './cash.ts';

/**
 * تقفيل السنة المالية — a review / closing layer OVER the existing financial records (db/proposed/083).
 *
 * It is NOT a second ledger: every figure is read from the existing sources (cash_ledger, cashOverview, the receipts /
 * expenses / payouts / installments / advances / commissions / owners / custody tables) and nothing here writes to them.
 * What it keeps of its own: the checklist decisions, the issues and how they were resolved, documented reconciliations,
 * the approval, the frozen closing snapshot and the balances carried to the next year.
 *
 * Who does what (the existing permissions, enforced here — never only in the app):
 *  - cash.office (الخزنة الرئيسية): sees the closing and does the review (checklist, issues notes, reconciliations).
 *  - cash.approve: decides reconciliations / review-level exceptions (never his own).
 *  - the owner account: approves the closing, closes the year, reopens it, and the exception of a blocking issue.
 *  - the office's profit (finance.company_income) and the owners' accounts (cash.owner_funds) only to whom holds them.
 * Until 083 runs, the figures and reports are shown (read-only); every write answers 409 «module_not_installed».
 */

const r2 = (x: number) => Math.round(x * 100) / 100;
const N = (v: unknown) => Number(v ?? 0);
const ITEM_STATUSES = ['not_reviewed', 'reviewed', 'needs_attention', 'blocking', 'resolved', 'exception'] as const;
const DONE = new Set(['reviewed', 'resolved', 'exception']);
const REC_TYPES = ['treasury', 'bank', 'employee', 'partner', 'project', 'receivable', 'payable', 'asset', 'other'] as const;
const TZ = `'Africa/Cairo'`;
const at = (p: string) => `(${p}::date AT TIME ZONE ${TZ})`;

/** the checklist: [category, label, items[key, label, verify?]] — every item is mandatory for closing */
export const CHECKLIST: { key: string; label: string; items: { key: string; label: string; verify?: boolean }[] }[] = [
  { key: 'treasury', label: 'الخزنة', items: [
    { key: 'treasury.accounts', label: 'مراجعة كل الخزن (خزنة المكتب وخزنة المحاسب)' },
    { key: 'treasury.opening', label: 'التأكد من الأرصدة الافتتاحية' },
    { key: 'treasury.receipts', label: 'مراجعة المقبوضات' },
    { key: 'treasury.payments', label: 'مراجعة المدفوعات' },
    { key: 'treasury.transfers', label: 'مراجعة التحويلات بين الخزن' },
    { key: 'treasury.outstanding', label: 'مراجعة الحركات المعلّقة' },
    { key: 'treasury.office_count', label: 'جرد خزنة المكتب وتسجيل الرصيد الفعلي', verify: true },
    { key: 'treasury.hr_count', label: 'جرد خزنة المحاسب وتسجيل الرصيد الفعلي', verify: true },
    { key: 'treasury.final', label: 'تأكيد الأرصدة الختامية' },
  ] },
  { key: 'bank', label: 'البنك', items: [
    { key: 'bank.accounts', label: 'مراجعة الجزء البنكي من الخزن' },
    { key: 'bank.deposits', label: 'مراجعة الإيداعات (تحصيلات غير نقدية وإيداعات من الخزنة)' },
    { key: 'bank.withdrawals', label: 'مراجعة المسحوبات (مصروفات بنكية وسحب للخزنة)' },
    { key: 'bank.final', label: 'تأكيد أرصدة البنك الختامية مع كشف الحساب' },
  ] },
  { key: 'revenue', label: 'الإيرادات', items: [
    { key: 'revenue.transactions', label: 'مراجعة حركات الإيرادات' },
    { key: 'revenue.classification', label: 'مراجعة تصنيف الإيرادات' },
    { key: 'revenue.projects', label: 'مراجعة إيرادات المشاريع' },
    { key: 'revenue.commissions', label: 'مراجعة العمولات المستلمة' },
    { key: 'revenue.other', label: 'مراجعة الإيرادات الأخرى' },
    { key: 'revenue.cancelled', label: 'مراجعة الحركات المعكوسة' },
    { key: 'revenue.duplicates', label: 'مراجعة التكرار المحتمل' },
    { key: 'revenue.report', label: 'التأكد من تقرير الإيرادات السنوي' },
  ] },
  { key: 'expenses', label: 'المصروفات', items: [
    { key: 'expenses.transactions', label: 'مراجعة المصروفات' },
    { key: 'expenses.classification', label: 'مراجعة تصنيف المصروفات' },
    { key: 'expenses.operational', label: 'مراجعة المصروفات التشغيلية والثابتة' },
    { key: 'expenses.projects', label: 'مراجعة مصروفات المشاريع' },
    { key: 'expenses.employees', label: 'مراجعة مصروفات الموظفين' },
    { key: 'expenses.incomplete', label: 'مراجعة المصروفات اللي مستنية اعتماد' },
    { key: 'expenses.cancelled', label: 'مراجعة المصروفات المعكوسة' },
    { key: 'expenses.duplicates', label: 'مراجعة التكرار المحتمل' },
    { key: 'expenses.report', label: 'التأكد من تقرير المصروفات السنوي' },
  ] },
  { key: 'employees', label: 'ماليات الموظفين', items: [
    { key: 'employees.salaries', label: 'مراجعة المرتبات المصروفة' },
    { key: 'employees.advances', label: 'مراجعة السلف' },
    { key: 'employees.repayments', label: 'مراجعة أقساط السلف المخصومة' },
    { key: 'employees.adjustments', label: 'مراجعة الجزاءات والعلاوات' },
    { key: 'employees.commissions', label: 'مراجعة العمولات المستحقة' },
    { key: 'employees.commission_payments', label: 'مراجعة صرف العمولات' },
    { key: 'employees.balances', label: 'مراجعة الأرصدة المفتوحة للموظفين' },
    { key: 'employees.double_payments', label: 'مراجعة الصرف المكرر المحتمل' },
  ] },
  { key: 'obligations', label: 'المستحقات والالتزامات', items: [
    { key: 'obligations.receivables', label: 'مراجعة المستحق للشركة (الأقساط والعمولات)' },
    { key: 'obligations.payables', label: 'مراجعة المستحق على الشركة' },
    { key: 'obligations.overdue', label: 'مراجعة المتأخرات' },
    { key: 'obligations.partial', label: 'مراجعة المسدد جزئياً' },
    { key: 'obligations.carry_forward', label: 'مراجعة الأرصدة المرحّلة للسنة الجديدة' },
  ] },
  { key: 'projects', label: 'المشاريع', items: [
    { key: 'projects.receipts', label: 'مراجعة متحصلات المشاريع' },
    { key: 'projects.payments', label: 'مراجعة المدفوع للملاك والمرتجعات' },
    { key: 'projects.commissions', label: 'مراجعة عمولات المشاريع' },
    { key: 'projects.trust', label: 'مراجعة أموال الملاك (الأمانات)' },
    { key: 'projects.balances', label: 'مراجعة أرصدة المشاريع' },
  ] },
  { key: 'general', label: 'الحركات العامة', items: [
    { key: 'general.pending', label: 'مراجعة الحركات المعلّقة' },
    { key: 'general.approvals', label: 'مراجعة الحركات اللي محتاجة اعتماد' },
    { key: 'general.modified', label: 'مراجعة الحركات اللي اتعكست أو اتصححت أثناء المراجعة' },
    { key: 'general.inconsistencies', label: 'مراجعة أي تعارض لسه مفتوح' },
  ] },
  { key: 'partners', label: 'الشركاء', items: [
    { key: 'partners.opening', label: 'مراجعة أرصدة الشركاء الافتتاحية' },
    { key: 'partners.contributions', label: 'مراجعة ضخ الشركاء' },
    { key: 'partners.withdrawals', label: 'مراجعة مسحوبات الشركاء' },
    { key: 'partners.rules', label: 'التأكد من نسب الملكية المعتمدة' },
    { key: 'partners.balances', label: 'مراجعة أرصدة الشركاء الختامية' },
  ] },
  { key: 'profit', label: 'توزيع الأرباح', items: [
    { key: 'profit.result', label: 'مراجعة نتيجة السنة' },
    { key: 'profit.basis', label: 'التأكد من أساس التوزيع' },
    { key: 'profit.allocation', label: 'مراجعة نصيب كل شريك' },
    { key: 'profit.outstanding', label: 'مراجعة التوزيعات المتبقية' },
  ] },
  { key: 'assets', label: 'الأصول والعهد', items: [
    { key: 'assets.registry', label: 'مراجعة سجل الأجهزة والعهد' },
    { key: 'assets.assignments', label: 'مراجعة العهد المسلّمة' },
    { key: 'assets.returns', label: 'مراجعة العهد المرتجعة' },
    { key: 'assets.missing', label: 'مراجعة العهد المفقودة' },
  ] },
];
const ITEM = new Map(CHECKLIST.flatMap((c) => c.items.map((i) => [i.key, { ...i, category: c.key }] as const)));

/** what the existing system cannot support — shown as «غير متاح», never as zero */
export const LIMITATIONS = [
  'مفيش كشوف حساب بنك متسجلة في السيستم: رصيد البنك محسوب من الحركات، ومطابقته بالكشف بتتم يدوي (بند «تأكيد أرصدة البنك»).',
  'نتيجة السنة هي «صافي المكتب» بنظام الخزنة الحالي (العمولات − التكاليف) — أساس نقدي، مش قائمة دخل محاسبية بالاستحقاق.',
  'مفيش سجل أصول ثابتة بقيم شراء أو إهلاك: مراجعة الأصول على سجل الأجهزة والعهد، وقيم الأصول والإهلاك غير متاحة.',
  'نسب توزيع الأرباح هي نسب الملكية الحالية (company_owners) — مفيش تاريخ إصدارات للنسب، فالتقفيل بيحفظ النسبة وقت التقفيل.',
  'المرتبات المستحقة غير المصروفة بتتحسب شهر بشهر في صفحة المرتبات، ومش متاحة كرقم سنوي هنا.',
  'أموال الملاك (الأمانات) وعمولات المطورين المتبقية أرقام النهارده (مش يوم 31/12).',
];

function canonical(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(canonical);
  if (v && typeof v === 'object' && !(v instanceof Date)) {
    return Object.fromEntries(Object.keys(v as object).sort().map((k) => [k, canonical((v as any)[k])]));
  }
  return v;
}
export const hashOf = (v: unknown) => createHash('sha256').update(JSON.stringify(canonical(v))).digest('hex');

function yearParam(s: string): number {
  const y = Number(s);
  if (!/^\d{4}$/.test(s) || y < 2000 || y > 2100) throw notFound('Invalid year');
  return y;
}

/** every figure of the year, read from the existing sources (nothing written) */
export async function yearFigures(q: Q, a: Actor, y: number) {
  const s = `${y}-01-01`, e = `${y + 1}-01-01`, to = `${y}-12-31`;
  const ov: any = await cashOverview(q, a, s, to);
  delete ov.available; // today's balances — the year's are below

  // ------------------------------------------------ treasury: the two cashboxes from cash_ledger (the one source)
  const led = await q.query(`SELECT cashbox, type, (at < ${at('$1')}) AS before, COALESCE(sum(amount), 0) AS s, count(*)::int AS n
                               FROM cash_ledger WHERE at < ${at('$2')} GROUP BY 1, 2, 3`, [s, e]);
  const bank = await q.query(`
    SELECT b.box,
      COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE cashbox = b.box AND payment_method <> 'cash' AND status IN ('posted','reversed') AND occurred_at < ${at('$1')}), 0)
    - COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE cashbox = b.box AND payment_method <> 'cash' AND status = 'reversed' AND reversed_at < ${at('$1')}), 0)
    - COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE cashbox = b.box AND payment_method = 'bank' AND status IN ('posted','reversed') AND COALESCE(approved_at, occurred_at) < ${at('$1')}), 0)
    + COALESCE((SELECT sum(amount_egp) FROM cash_expenses WHERE cashbox = b.box AND payment_method = 'bank' AND status = 'reversed' AND reversed_at < ${at('$1')}), 0)
    - COALESCE((SELECT sum(CASE direction WHEN 'bank_to_cash' THEN amount_egp ELSE -amount_egp END) FROM cash_bank_moves WHERE cashbox = b.box AND created_at < ${at('$1')}), 0) AS bank
      FROM (VALUES ('office'), ('hr')) b(box)`, [e]);
  const moves = await q.query(`SELECT cashbox, direction, COALESCE(sum(amount_egp), 0) AS s, count(*)::int AS n FROM cash_bank_moves
                                WHERE created_at >= ${at('$1')} AND created_at < ${at('$2')} GROUP BY 1, 2`, [s, e]);
  const box = (b: string) => {
    const rows = led.rows.filter((x) => x.cashbox === b);
    const sum = (f: (t: string) => boolean, before = false) => r2(rows.filter((x) => x.before === before && f(x.type)).reduce((t, x) => t + N(x.s), 0));
    const opening = r2(rows.filter((x) => x.before).reduce((t, x) => t + N(x.s), 0));
    const receipts = sum((t) => t === 'receipt' || t === 'receipt_reversal');
    const payments = sum((t) => t === 'expense' || t === 'expense_reversal' || t.startsWith('payout_'));
    const transfersIn = sum((t) => t === 'transfer_in' || t === 'fund_in');
    const transfersOut = sum((t) => t === 'transfer_out' || t === 'fund_out');
    const adjustments = sum((t) => t === 'opening' || t === 'adjustment');
    const closing = r2(opening + receipts + payments + transfersIn + transfersOut + adjustments);
    const bk = r2(N(bank.rows.find((x) => x.box === b)?.bank));
    const mv = (d: string) => r2(N(moves.rows.find((x) => x.cashbox === b && x.direction === d)?.s));
    return { box: b, opening, receipts, payments, transfersIn, transfersOut, adjustments, closing, count: rows.filter((x) => !x.before).reduce((t, x) => t + x.n, 0),
      bankPart: bk, cashPart: r2(closing - bk), bankMoves: { toBank: mv('cash_to_bank'), toCash: mv('bank_to_cash') } };
  };
  const treasury = { office: box('office'), hr: box('hr') };

  // ------------------------------------------------ receivables at 31/12: installments still owed (receipts up to that day)
  const paidBy = (col: string) => `COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.${col} = i.id AND r.occurred_at < ${at('$1')}
                                     AND (r.status = 'posted' OR (r.status = 'reversed' AND r.reversed_at >= ${at('$1')}))), 0)`;
  const inst = await q.query(`
    WITH lines AS (
      SELECT 'sale' AS src, i.id, i.due_date, i.amount_egp, s.buyer_name AS party, p.name AS project, s.unit_no, ${paidBy('installment_id')} AS paid
        FROM sale_installments i JOIN unit_sales s ON s.id = i.sale_id JOIN commission_projects p ON p.id = s.project_id
       WHERE s.status = 'active' AND s.created_at < ${at('$1')}
      UNION ALL
      SELECT 'unit', i.id, i.due_date, i.amount_egp, u.client_name, p.name, u.unit_no, ${paidBy('ex_installment_id')}
        FROM ex_installments i JOIN ex_units u ON u.id = i.unit_id JOIN commission_projects p ON p.id = u.project_id
       WHERE u.status = 'contracted' AND COALESCE(u.contracted_at, u.created_at) < ${at('$1')})
    SELECT src, id, due_date, amount_egp, party, project, unit_no, paid, amount_egp - paid AS left FROM lines WHERE paid < amount_egp
     ORDER BY due_date`, [e]);
  const lines = inst.rows.map((x) => ({ source: x.src === 'sale' ? 'sale_installments' : 'ex_installments', id: x.id,
    dueDate: x.due_date instanceof Date ? x.due_date.toISOString().slice(0, 10) : String(x.due_date).slice(0, 10),
    amount: r2(N(x.amount_egp)), paid: r2(N(x.paid)), left: r2(N(x.left)), party: x.party, project: x.project, unitNo: x.unit_no }));
  const overdue = lines.filter((x) => x.dueDate <= to), future = lines.filter((x) => x.dueDate > to);
  const receivables = {
    installments: { total: r2(lines.reduce((t, x) => t + x.left, 0)), overdue: r2(overdue.reduce((t, x) => t + x.left, 0)), overdueCount: overdue.length,
      notDue: r2(future.reduce((t, x) => t + x.left, 0)), count: lines.length,
      partial: lines.filter((x) => x.paid > 0).length, lines: lines.sort((x, y) => y.left - x.left).slice(0, 300) },
    developerCommissions: ov.commissions ? { remaining: ov.commissions.remaining, asOf: 'today' } : null,
  };

  // ------------------------------------------------ employees: advances still to be deducted, commissions not paid at 31/12
  const adv = await q.query(`
    SELECT ar.employee_id, e.full_name, sum(GREATEST(ar.amount_egp - COALESCE(d.done, 0), 0)) AS left
      FROM advance_requests ar JOIN employees e ON e.id = ar.employee_id
      LEFT JOIN LATERAL (SELECT sum(x.amount_egp) AS done FROM advance_deductions x WHERE x.advance_id = ar.id AND x.status = 'active' AND x.period <= $1::date) d ON true
     WHERE ar.kind = 'advance' AND ar.status = 'confirmed' AND ar.period <= $1::date
       AND EXISTS (SELECT 1 FROM advance_deductions y WHERE y.advance_id = ar.id AND y.status = 'active')
     GROUP BY 1, 2 HAVING sum(GREATEST(ar.amount_egp - COALESCE(d.done, 0), 0)) > 0 ORDER BY 3 DESC`, [`${y}-12-01`]);
  const com = await q.query(`
    SELECT ce.employee_id, e.full_name, sum(ce.amount_egp) AS due, count(*)::int AS n
      FROM commission_entitlements ce JOIN employees e ON e.id = ce.employee_id
     WHERE ce.status = 'active' AND ce.period < $1::date
       AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.commission_entitlement_id = ce.id AND p.status = 'received' AND p.received_at < ${at('$1')})
     GROUP BY 1, 2 ORDER BY 3 DESC`, [e]);
  const adj = await q.query(`SELECT kind, COALESCE(sum(amount_egp), 0) AS s, count(*)::int AS n FROM salary_adjustments
                              WHERE status = 'approved' AND period >= $1::date AND period < $2::date GROUP BY kind`, [s, e]);
  const ded = await one(q, `SELECT COALESCE(sum(amount_egp), 0) AS s, count(*)::int AS n FROM advance_deductions WHERE status = 'active' AND period >= $1::date AND period < $2::date`, [s, e]);
  const pend = await one(q, `SELECT COALESCE(sum(amount_egp), 0) AS s, count(*)::int AS n FROM payouts WHERE kind <> 'fund' AND created_at < ${at('$1')}
                               AND (status = 'pending' OR (status = 'received' AND received_at >= ${at('$1')}))`, [e]);
  const employees = {
    paid: ov.expenses?.payroll ?? null,
    advancesOutstanding: { total: r2(adv.rows.reduce((t, x) => t + N(x.left), 0)), byEmployee: adv.rows.map((x) => ({ id: x.employee_id, name: x.full_name, amount: r2(N(x.left)) })) },
    advanceRepayments: { total: r2(N(ded?.s)), count: N(ded?.n) },
    adjustments: { deductions: r2(N(adj.rows.find((x) => x.kind === 'deduction')?.s)), bonuses: r2(N(adj.rows.find((x) => x.kind === 'bonus')?.s)) },
    commissionsUnpaid: { total: r2(com.rows.reduce((t, x) => t + N(x.due), 0)), byEmployee: com.rows.map((x) => ({ id: x.employee_id, name: x.full_name, amount: r2(N(x.due)), count: x.n })) },
    payoutsNotReceived: { total: r2(N(pend?.s)), count: N(pend?.n) },
    salariesUnpaid: { available: false },
  };
  const payables = {
    employeeCommissions: employees.commissionsUnpaid.total,
    payoutsNotReceived: employees.payoutsNotReceived.total,
    ownersTrust: can(a, 'exclusive.view_finance', 'cash.office') && ov.projectsBox ? { total: ov.projectsBox.total, asOf: 'today' } : null,
    salariesUnpaid: { available: false },
  };

  // ------------------------------------------------ partners: the owners' accounts exactly as ownerAccounts defines them
  // (cash.ts ownerBalancesAt): injected + نسبة الملكية × the office's net of every month so far − approved withdrawals,
  // read at the end of the previous year (opening) and at 31/12 (closing). The year's share = the difference (a loss too).
  let partners: any = { available: false, reason: 'permission' };
  let profit: any = { available: false, reason: ov.result ? 'no_rules' : 'permission' };
  if (can(a, 'cash.owner_funds', 'cash.office')) {
    const ids = await ownerIds(q);
    const endPrev = await ownerBalancesAt(q, a, ids, `${y - 1}-12-31`);
    const endYear = await ownerBalancesAt(q, a, ids, to);
    const carried = await carriedFrom(q, y);
    const net = ov.result ? N(ov.result.net) : null;
    const pctTotal = r2(endYear.owners.reduce((t, x) => t + x.pct, 0));
    const canAllocate = net !== null && pctTotal > 0 && pctTotal <= 100;
    const list = endYear.owners.map((x) => {
      const p0 = endPrev.owners.find((o) => o.id === x.id)!;
      const c = carried.get(`partner:${x.id}`);
      const withdrawals = r2(x.withdrawn - p0.withdrawn);
      const allocated = x.profit === null || p0.profit === null ? null : r2(x.profit - p0.profit);
      return { id: x.id, name: x.name, pct: x.pct, opening: p0.book, openingSource: c !== undefined ? 'closing' : 'history', carriedOpening: c ?? null,
        contributions: r2(x.injected - p0.injected), withdrawals, pendingWithdrawals: x.pending, allocated,
        // information only (never carried on its own: it is already inside the balance)
        outstandingDistribution: allocated === null ? null : r2(Math.max(allocated - withdrawals, 0)),
        closing: x.book, available: x.balance };
    });
    partners = { available: true, pctTotal, list, openingFromClosing: carried.size > 0, definition: 'ownerAccounts' };
    if (net !== null) {
      profit = { available: canAllocate, result: net, commissions: ov.result.commissions, costs: ov.result.costs,
        distributable: canAllocate ? net : null, basis: 'نسبة الملكية × صافي المكتب للسنة (بنفس حساب «حسابات الملاك»، والخسارة بتتوزع كمان)',
        retained: canAllocate ? r2(net * (100 - pctTotal) / 100) : null, pctTotal,
        reason: canAllocate ? null : (pctTotal === 0 ? 'no_rules' : pctTotal > 100 ? 'pct_over_100' : null),
        loss: net < 0 ? r2(-net) : 0,
        allocations: list.map((p) => ({ id: p.id, name: p.name, pct: p.pct, allocated: p.allocated, paid: p.withdrawals, outstanding: p.outstandingDistribution })) };
    }
  }

  // ------------------------------------------------ assets: the devices registry and the custody (العهد)
  const cust = await q.query(`SELECT asset_type,
      count(*) FILTER (WHERE assigned_on <= $2::date AND (returned_on IS NULL OR returned_on > $2::date) AND (status <> 'lost' OR closed_at >= ${at('$3')}))::int AS held,
      count(*) FILTER (WHERE assigned_on >= $1::date AND assigned_on <= $2::date)::int AS assigned,
      count(*) FILTER (WHERE status = 'returned' AND returned_on >= $1::date AND returned_on <= $2::date)::int AS returned,
      count(*) FILTER (WHERE status = 'lost' AND closed_at >= ${at('$1')} AND closed_at < ${at('$3')})::int AS lost
      FROM custody_items GROUP BY 1 ORDER BY 1`, [s, to, e]);
  const devs = await q.query(`SELECT asset_type, status, count(*)::int AS n,
      count(*) FILTER (WHERE created_at >= ${at('$1')} AND created_at < ${at('$2')})::int AS added FROM custody_assets WHERE created_at < ${at('$2')} GROUP BY 1, 2`, [s, e]);
  const assets = {
    custody: cust.rows.map((x) => ({ type: x.asset_type, held: x.held, assigned: x.assigned, returned: x.returned, lost: x.lost })),
    devices: devs.rows.map((x) => ({ type: x.asset_type, status: x.status, count: x.n, added: x.added })),
    values: { available: false }, depreciation: { available: false },
  };

  return {
    year: y, from: s, to,
    revenue: ov.income ?? null,
    expenses: ov.expenses ?? null,
    result: ov.result ?? null,
    commissionSplit: ov.commissionSplit ?? null,
    projects: { box: ov.projectsBox ?? null, commissions: ov.commissions ? { ...ov.commissions, units: undefined } : null },
    treasury, receivables, payables, employees, partners, profit, assets,
    cashFlow: { receipts: r2(treasury.office.receipts + treasury.hr.receipts), payments: r2(treasury.office.payments + treasury.hr.payments) },
  };
}

/**
 * What a person may see of the figures — applied to every answer, the frozen snapshot of a closed year included (it was
 * taken with the owner's view): the office's profit needs finance.company_income, the owners' accounts cash.owner_funds,
 * the exclusive projects' money exclusive.view_finance, anything per employee employee.salary_read. Hidden = «غير متاح».
 */
export function redactFigures(f0: any, a: Actor) {
  if (!f0) return f0;
  const f = structuredClone(f0);
  const hidden = { available: false, reason: 'permission' };
  if (!can(a, 'finance.company_income', 'cash.office')) {
    f.result = null; f.commissionSplit = null;
    if (f.revenue) { delete f.revenue.commissions; delete f.revenue.commissionReceived; delete f.revenue.trust; }
    f.profit = { ...hidden };
  }
  if (!can(a, 'cash.owner_funds', 'cash.office')) {
    f.partners = { ...hidden };
    if (f.profit && f.profit.allocations) { delete f.profit.allocations; delete f.profit.retained; }
  }
  if (!can(a, 'exclusive.view_finance', 'cash.office')) {
    if (f.payables) f.payables.ownersTrust = null;
    if (f.projects) f.projects.box = null;
    if (f.revenue) delete f.revenue.trust;
  }
  if (!has(a, 'employee.salary_read')) {
    for (const k of ['advancesOutstanding', 'commissionsUnpaid']) {
      if (f.employees?.[k]) { f.employees[k].byEmployee = []; f.employees[k].byEmployeeHidden = true; }
    }
  }
  return f;
}
/**
 * The closing's own records carry owner-level detail too (a partner's reconciliation, a note on the office's profit, an
 * employee's payout). Each record belongs to an area; an area a person may not see shows its record without the detail
 * (no amount, no reason / note) — the stored record is never changed.
 */
type Area = 'partners' | 'profit' | 'employees' | 'projects' | null;
const AREA_ASK: Record<Exclude<Area, null>, string> = {
  partners: '«ضخ وسحب أموال الملاك»', profit: '«دخل وربح المكتب»', employees: '«عرض المرتبات»', projects: '«ماليات المشاريع الحصرية»',
};
export function mayArea(area: Area, a: Actor) {
  switch (area) {
    case 'partners': return can(a, 'cash.owner_funds', 'cash.office');
    case 'profit': return can(a, 'finance.company_income', 'cash.office');
    case 'employees': return has(a, 'employee.salary_read');
    case 'projects': return can(a, 'exclusive.view_finance', 'cash.office');
    default: return true;
  }
}
const PER_EMPLOYEE_SOURCES = new Set(['payouts', 'salary_adjustments', 'advance_requests', 'advance_deductions', 'commission_entitlements']);
const issueArea = (i: any): Area => (PER_EMPLOYEE_SOURCES.has(i.source) || i.category === 'employees' ? 'employees'
  : i.category === 'partners' ? 'partners' : i.category === 'profit' ? 'profit' : i.category === 'projects' ? 'projects' : null);
const recArea = (type: string): Area => (type === 'partner' ? 'partners' : type === 'employee' ? 'employees' : type === 'project' ? 'projects' : null);
const itemArea = (key: string): Area => {
  const c = key.split('.')[0];
  return c === 'partners' ? 'partners' : c === 'profit' ? 'profit' : c === 'employees' ? 'employees' : c === 'projects' ? 'projects' : null;
};
const hiddenText = (area: Exclude<Area, null>) => `(التفاصيل محتاجة صلاحية ${AREA_ASK[area]})`;
function redactIssue(i: any, a: Actor) {
  const area = issueArea(i);
  if (!area || mayArea(area, a)) return i;
  return { ...i, description: `ملاحظة ${hiddenText(area)}`, amount: null, sourceId: null, resolutionNote: i.resolutionNote ? hiddenText(area) : '', resolutionRef: null, redacted: true };
}
function redactRec(x: any, a: Actor) {
  const area = recArea(x.type);
  if (!area || mayArea(area, a)) return x;
  return { ...x, amount: null, reason: hiddenText(area), notes: '', sourceId: null, decisionNote: '', redacted: true };
}
function redactItem(i: any, a: Actor) {
  const area = itemArea(i.key);
  if (!area || mayArea(area, a)) return i;
  return { ...i, note: i.note ? hiddenText(area) : '', redacted: true };
}
/** the carried balances a person may see (partners: cash.owner_funds; per employee: employee.salary_read) */
export function visibleOpening(entityType: string, a: Actor) {
  if (entityType.startsWith('partner')) return can(a, 'cash.owner_funds', 'cash.office');
  if (entityType.startsWith('employee_')) return has(a, 'employee.salary_read');
  return true;
}
function redactState(st: any, a: Actor) {
  const out = { ...st, figures: redactFigures(st.figures, a) };
  if (Array.isArray(st.issues)) out.issues = st.issues.map((i: any) => redactIssue(i, a));
  if (Array.isArray(st.reconciliations)) out.reconciliations = st.reconciliations.map((x: any) => redactRec(x, a));
  if (Array.isArray(st.checklist)) out.checklist = st.checklist.map((c: any) => ({ ...c, items: (c.items ?? []).map((i: any) => redactItem(i, a)) }));
  if (Array.isArray(st.preview)) out.preview = st.preview.map((i: any) => redactIssue({ ...i, source: i.source }, a));
  if (st.snapshot) out.snapshot = { ...st.snapshot, openingBalances: (st.snapshot.openingBalances ?? []).filter((o: any) => visibleOpening(o.entityType, a)) };
  return out;
}

/** the balances a closed previous year carried to this one: `${entity_type}:${entity_id}` → carry_balance */
async function carriedFrom(q: Q, y: number): Promise<Map<string, number>> {
  if (!(await one(q, `SELECT to_regclass('public.fy_opening_balances') IS NOT NULL AS x`))?.x) return new Map();
  const r = await q.query(`SELECT entity_type, entity_id, carry_balance FROM fy_opening_balances WHERE to_year = $1 AND status = 'active'`, [y]);
  return new Map(r.rows.map((x) => [`${x.entity_type}:${x.entity_id}`, N(x.carry_balance)]));
}

type Det = { key: string; category: string; source: string; sourceId: string | null; description: string; amount: number | null; severity: 'info' | 'review' | 'blocking' };

/** the closing rules: each problem found in the existing records (deterministic — the same data gives the same issues) */
async function detect(q: Q, y: number, f: any, items: Map<string, any>, recs: any[]): Promise<Det[]> {
  const s = `${y}-01-01`, e = `${y + 1}-01-01`;
  const out: Det[] = [];
  const add = (d: Det) => out.push(d);
  const pe = await q.query(`SELECT id, ref_no, amount_egp, category FROM cash_expenses WHERE status IN ('pending_approval','awaiting_otp') AND occurred_at >= ${at('$1')} AND occurred_at < ${at('$2')}`, [s, e]);
  for (const x of pe.rows) add({ key: `pending_expense:${x.id}`, category: 'incomplete', source: 'cash_expenses', sourceId: x.id, amount: r2(N(x.amount_egp)), severity: 'blocking',
    description: `مصروف رقم ${x.ref_no} (${x.category}) لسه مستني اعتماد — لازم يتعتمد أو يترفض قبل التقفيل` });
  const tr = await q.query(`SELECT id, ref_no, status, COALESCE(amount_executed, amount_requested) AS a FROM cash_transfers WHERE status IN ('requested','approved','executed')
                              AND requested_at < ${at('$1')}`, [e]);
  for (const x of tr.rows) add({ key: `open_transfer:${x.id}`, category: 'treasury', source: 'cash_transfers', sourceId: x.id, amount: r2(N(x.a)),
    severity: x.status === 'executed' ? 'blocking' : 'review',
    description: x.status === 'executed' ? `تحويل رقم ${x.ref_no} اتسلّم من خزنة ولسه متأكدش استلامه في التانية (فلوس في الطريق)` : `طلب تحويل رقم ${x.ref_no} لسه مفتوح` });
  const pp = await q.query(`SELECT p.id, p.kind, p.amount_egp, e.full_name FROM payouts p JOIN employees e ON e.id = p.employee_id
                             WHERE p.status = 'pending' AND p.created_at >= ${at('$1')} AND p.created_at < ${at('$2')}`, [s, e]);
  for (const x of pp.rows) add({ key: `pending_payout:${x.id}`, category: 'employees', source: 'payouts', sourceId: x.id, amount: r2(N(x.amount_egp)), severity: 'review',
    description: `صرف (${x.kind}) لـ ${x.full_name} لسه متأكدش استلامه` });
  const dr = await q.query(`SELECT array_agg(id ORDER BY ref_no) AS ids, array_agg(ref_no ORDER BY ref_no) AS refs, max(amount_egp) AS amt, count(*)::int AS n FROM cash_receipts
                             WHERE status = 'posted' AND occurred_at >= ${at('$1')} AND occurred_at < ${at('$2')}
                             GROUP BY kind, amount_egp, lower(trim(payer_name)), cashbox, (occurred_at AT TIME ZONE ${TZ})::date HAVING count(*) > 1`, [s, e]);
  for (const x of dr.rows) add({ key: `dup_receipt:${x.ids[0]}`, category: 'duplicate', source: 'cash_receipts', sourceId: x.ids[0], amount: r2(N(x.amt) * (x.n - 1)), severity: 'review',
    description: `تحصيلات ممكن تكون مكررة (نفس النوع والمبلغ والدافع واليوم): ${x.refs.join('، ')}` });
  const dx = await q.query(`SELECT array_agg(id ORDER BY ref_no) AS ids, array_agg(ref_no ORDER BY ref_no) AS refs, max(amount_egp) AS amt, count(*)::int AS n FROM cash_expenses
                             WHERE status = 'posted' AND occurred_at >= ${at('$1')} AND occurred_at < ${at('$2')}
                             GROUP BY cashbox, amount_egp, lower(trim(category)), lower(trim(COALESCE(beneficiary, ''))), (occurred_at AT TIME ZONE ${TZ})::date HAVING count(*) > 1`, [s, e]);
  for (const x of dx.rows) add({ key: `dup_expense:${x.ids[0]}`, category: 'duplicate', source: 'cash_expenses', sourceId: x.ids[0], amount: r2(N(x.amt) * (x.n - 1)), severity: 'review',
    description: `مصروفات ممكن تكون مكررة (نفس البند والمبلغ والمستفيد واليوم): ${x.refs.join('، ')}` });
  const dp = await q.query(`SELECT array_agg(p.id ORDER BY p.created_at) AS ids, max(p.amount_egp) AS amt, count(*)::int AS n, max(e.full_name) AS name, p.kind FROM payouts p
                             JOIN employees e ON e.id = p.employee_id
                             WHERE p.status = 'received' AND p.kind IN ('salary','commission') AND p.period >= $1::date AND p.period < $2::date
                             GROUP BY p.employee_id, p.kind, p.amount_egp, p.period, p.commission_entitlement_id HAVING count(*) > 1`, [s, e]);
  for (const x of dp.rows) add({ key: `dup_payout:${x.ids[0]}`, category: 'duplicate', source: 'payouts', sourceId: x.ids[0], amount: r2(N(x.amt) * (x.n - 1)), severity: 'review',
    description: `صرف ممكن يكون مكرر لـ ${x.name} (${x.kind}، نفس المبلغ ونفس الشهر) — ${x.n} مرات` });
  const pb = await q.query(`SELECT id, ref_no, status FROM payroll_batches WHERE status IN ('draft','returned','pending_approval') AND period >= $1::date AND period < $2::date`, [s, e]);
  for (const x of pb.rows) add({ key: `open_batch:${x.id}`, category: 'employees', source: 'payroll_batches', sourceId: x.id, amount: null, severity: 'review',
    description: `كشف مرتبات رقم ${x.ref_no} لسه مفتوح (${x.status})` });
  const sa = await q.query(`SELECT id, amount_egp FROM salary_adjustments WHERE status = 'pending' AND period >= $1::date AND period < $2::date`, [s, e]);
  for (const x of sa.rows) add({ key: `pending_adjustment:${x.id}`, category: 'employees', source: 'salary_adjustments', sourceId: x.id, amount: r2(N(x.amount_egp)), severity: 'review',
    description: 'جزاء / علاوة لسه مستنية قرار' });
  const ar = await q.query(`SELECT id, amount_egp FROM advance_requests WHERE status = 'pending' AND period >= $1::date AND period < $2::date`, [s, e]);
  for (const x of ar.rows) add({ key: `pending_advance:${x.id}`, category: 'employees', source: 'advance_requests', sourceId: x.id, amount: r2(N(x.amount_egp)), severity: 'review',
    description: 'طلب سلفة / مصاريف عمل لسه مستني قرار' });
  // the cashboxes at 31/12
  for (const b of ['office', 'hr'] as const) {
    const t = f.treasury[b];
    if (t.closing < 0) add({ key: `negative_box:${b}`, category: 'treasury', source: 'cash_ledger', sourceId: b, amount: t.closing, severity: b === 'office' ? 'blocking' : 'review',
      description: b === 'office' ? 'رصيد خزنة المكتب في آخر السنة بالسالب — تعارض لازم يتفسر' : 'خزنة المحاسب بالسالب في آخر السنة (فلوس مستحقة له على المكتب) — راجعها' });
    const it = items.get(`treasury.${b}_count`);
    if (it && it.verified_amount !== null && it.verified_amount !== undefined) {
      const diff = r2(N(it.verified_amount) - t.closing);
      const explained = r2(recs.filter((x) => x.status === 'approved' && x.rec_type === 'treasury' && x.source_id === b).reduce((s2, x) => s2 + N(x.amount), 0));
      if (Math.abs(diff) >= 0.01 && Math.abs(diff - explained) >= 0.01) {
        add({ key: `treasury_diff:${b}`, category: 'treasury', source: 'cash_ledger', sourceId: b, amount: r2(diff - explained), severity: 'blocking',
          description: `فرق جرد ${b === 'office' ? 'خزنة المكتب' : 'خزنة المحاسب'}: الفعلي ${N(it.verified_amount)} والسيستم ${t.closing}${explained ? ` (المتفسر بتسويات معتمدة ${explained})` : ''}` });
      }
    }
  }
  // the carry-forward from the previous closed year must still match the ledger
  const carried = await carriedFrom(q, y);
  for (const b of ['office', 'hr'] as const) {
    const c = carried.get(`cashbox:${b}`);
    if (c !== undefined && Math.abs(c - f.treasury[b].opening) >= 0.01) {
      add({ key: `opening_mismatch:${b}`, category: 'treasury', source: 'fy_opening_balances', sourceId: b, amount: r2(f.treasury[b].opening - c), severity: 'blocking',
        description: `الرصيد الافتتاحي لـ${b === 'office' ? 'خزنة المكتب' : 'خزنة المحاسب'} (${f.treasury[b].opening}) مختلف عن المرحّل من تقفيل السنة اللي فاتت (${c})` });
    }
  }
  if (f.partners.available) {
    for (const p of f.partners.list) {
      if (p.carriedOpening !== null && p.opening !== null && Math.abs(p.carriedOpening - p.opening) >= 0.01) {
        add({ key: `partner_opening_mismatch:${p.id}`, category: 'partners', source: 'fy_opening_balances', sourceId: p.id, amount: r2(p.opening - p.carriedOpening),
          severity: 'blocking', description: `رصيد أول السنة للشريك ${p.name} (${p.opening}) مختلف عن المرحّل من تقفيل السنة اللي فاتت (${p.carriedOpening})` });
      }
    }
    if (f.partners.pctTotal > 100) add({ key: 'partner_pct', category: 'partners', source: 'company_owners', sourceId: null, amount: null, severity: 'blocking',
      description: `مجموع نسب الملكية ${f.partners.pctTotal}% أكتر من 100%` });
    else if (f.partners.pctTotal === 0 && f.partners.list.length) add({ key: 'partner_pct', category: 'partners', source: 'company_owners', sourceId: null, amount: null, severity: 'info',
      description: 'مفيش نسب ملكية متسجلة — توزيع الأرباح مش هيتحسب' });
    else if (f.partners.pctTotal < 100 && f.partners.pctTotal > 0) add({ key: 'partner_pct', category: 'partners', source: 'company_owners', sourceId: null, amount: null, severity: 'info',
      description: `مجموع نسب الملكية ${f.partners.pctTotal}% — الباقي بيفضل محتجز في الشركة` });
    for (const p of f.partners.list) if (p.pendingWithdrawals > 0) add({ key: `partner_draw_pending:${p.id}`, category: 'partners', source: 'cash_expenses', sourceId: p.id,
      amount: p.pendingWithdrawals, severity: 'review', description: `مسحوبات للشريك ${p.name} لسه مستنية اعتماد` });
  }
  const lost = f.assets.custody.reduce((t: number, x: any) => t + x.lost, 0);
  if (lost > 0) add({ key: 'assets_lost', category: 'assets', source: 'custody_items', sourceId: null, amount: null, severity: 'review', description: `${lost} عهدة اتسجلت مفقودة خلال السنة` });
  return out;
}

export const yearClosingModule: Module = (r, { db, clock }) => {
  let installedOk = false;
  const installed = async (q: Q) => installedOk || (installedOk = !!(await one(q, `SELECT to_regclass('public.fy_closings') IS NOT NULL AS x`))?.x);
  const needInstalled = async (q: Q) => {
    if (!(await installed(q))) throw new AppError('conflict', 'تقفيل السنة محتاج تشغيل migration 083 بعد موافقة المالك', { reason: 'module_not_installed' });
  };
  const view = (a: Actor) => { if (!canOffice(a)) throw forbidden(); };
  const decider = (a: Actor) => can(a, 'cash.approve', 'cash.office');
  const today = () => local(clock()).date;

  async function liveClosing(q: Q, y: number, lock = false) {
    return one(q, `SELECT * FROM fy_closings WHERE fiscal_year = $1 AND status IN ('in_review','approved','closed') ${lock ? 'FOR UPDATE' : ''}`, [y]);
  }
  /** a review write while approved takes the approval back (the approver must see the final state) */
  async function editable(q: Q, a: Actor, y: number) {
    await needInstalled(q);
    const c = await liveClosing(q, y, true);
    if (!c) throw conflict('ابدأ المراجعة الأول');
    if (c.status === 'closed') throw new AppError('conflict', 'السنة مقفولة — للقراءة فقط', { reason: 'year_closed' });
    if (c.status === 'approved') {
      await q.query(`UPDATE fy_closings SET status = 'in_review', approved_by = NULL, approved_at = NULL, approved_hash = NULL WHERE id = $1`, [c.id]);
      await audit(q, a.id, 'closing.approval_withdrawn', 'fy_closing', c.id, { status: 'approved' }, { status: 'in_review', why: 'review changed after approval' });
      c.status = 'in_review';
    }
    return c;
  }

  async function loadWork(q: Q, closingId: string) {
    const items = await q.query(`SELECT i.*, e.full_name AS reviewer FROM fy_review_items i JOIN employees e ON e.id = i.reviewed_by WHERE i.closing_id = $1`, [closingId]);
    const issues = await q.query(`SELECT i.*, d.full_name AS detected_by_name, rb.full_name AS resolved_by_name, xb.full_name AS exception_by_name FROM fy_issues i
                                    LEFT JOIN employees d ON d.id = i.detected_by LEFT JOIN employees rb ON rb.id = i.resolved_by LEFT JOIN employees xb ON xb.id = i.exception_by
                                   WHERE i.closing_id = $1 ORDER BY i.ref_no`, [closingId]);
    const recs = await q.query(`SELECT x.*, c.full_name AS created_by_name, d.full_name AS decided_by_name FROM fy_reconciliations x
                                  JOIN employees c ON c.id = x.created_by LEFT JOIN employees d ON d.id = x.decided_by WHERE x.closing_id = $1 ORDER BY x.ref_no`, [closingId]);
    return { items: new Map(items.rows.map((x) => [x.item_key, x])), issues: issues.rows, recs: recs.rows };
  }

  /** writes the issues the rules find: new → open; gone → resolved by the source (kept, never deleted) */
  async function syncIssues(q: Q, c: any, found: Det[], current: any[]) {
    let changed = 0;
    for (const d of found) {
      const r0 = await q.query(`
        INSERT INTO fy_issues (closing_id, issue_key, category, source_module, source_id, description, amount, severity)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
        ON CONFLICT (closing_id, issue_key) DO UPDATE SET description = EXCLUDED.description, amount = EXCLUDED.amount, severity = EXCLUDED.severity,
          status = CASE WHEN fy_issues.status = 'resolved' AND fy_issues.resolved_by IS NULL THEN 'open'
                        WHEN fy_issues.status = 'exception' AND fy_issues.amount IS DISTINCT FROM EXCLUDED.amount THEN 'open' ELSE fy_issues.status END,
          resolved_at = CASE WHEN fy_issues.status = 'resolved' AND fy_issues.resolved_by IS NULL THEN NULL ELSE fy_issues.resolved_at END,
          exception_by = CASE WHEN fy_issues.status = 'exception' AND fy_issues.amount IS DISTINCT FROM EXCLUDED.amount THEN NULL ELSE fy_issues.exception_by END,
          exception_at = CASE WHEN fy_issues.status = 'exception' AND fy_issues.amount IS DISTINCT FROM EXCLUDED.amount THEN NULL ELSE fy_issues.exception_at END
         WHERE fy_issues.detected_by IS NULL AND ((fy_issues.description, fy_issues.amount, fy_issues.severity) IS DISTINCT FROM (EXCLUDED.description, EXCLUDED.amount, EXCLUDED.severity)
            OR (fy_issues.status = 'resolved' AND fy_issues.resolved_by IS NULL))`,
        [c.id, d.key, d.category, d.source, d.sourceId, d.description, d.amount, d.severity]);
      changed += r0.rowCount ?? 0;
    }
    const keys = new Set(found.map((d) => d.key));
    for (const i of current) {
      if (i.detected_by === null && i.status !== 'resolved' && !keys.has(i.issue_key)) {
        await q.query(`UPDATE fy_issues SET status = 'resolved', resolved_at = now(), resolved_by = NULL,
                         resolution_note = CASE WHEN resolution_note = '' THEN 'اتحلت من مصدرها (الحركة اتكملت أو اتصححت في نظامها)' ELSE resolution_note END WHERE id = $1`, [i.id]);
        changed++;
      }
    }
    if (changed) await audit(q, null, 'closing.issues_detected', 'fy_closing', c.id, undefined, { changed, open: found.length });
    return changed;
  }

  function shape(c: any, f: any, w: { items: Map<string, any>; issues: any[]; recs: any[] }, a: Actor, y: number) {
    const checklist = CHECKLIST.map((cat) => ({ key: cat.key, label: cat.label, items: cat.items.map((i) => {
      const x = w.items.get(i.key);
      return { key: i.key, label: i.label, verify: !!i.verify, status: x?.status ?? 'not_reviewed', note: x?.note ?? '',
        verifiedAmount: x?.verified_amount == null ? null : N(x.verified_amount), reviewer: x?.reviewer ?? null, reviewedAt: x?.reviewed_at ?? null };
    }) }));
    const all = checklist.flatMap((c2) => c2.items);
    const done = all.filter((i) => DONE.has(i.status)).length;
    const issues = w.issues.map((i) => ({ id: i.id, refNo: Number(i.ref_no), key: i.issue_key, category: i.category, source: i.source_module, sourceId: i.source_id,
      description: i.description, amount: i.amount == null ? null : N(i.amount), severity: i.severity, blocking: i.severity === 'blocking', status: i.status,
      detectedBy: i.detected_by_name ?? 'السيستم', detectedAt: i.detected_at, resolutionNote: i.resolution_note, resolutionRef: i.resolution_ref,
      resolvedBy: i.resolved_by ? i.resolved_by_name : (i.status === 'resolved' ? 'السيستم' : null), resolvedAt: i.resolved_at,
      exceptionBy: i.exception_by_name ?? null, exceptionAt: i.exception_at }));
    const recs = w.recs.map((x) => ({ id: x.id, refNo: Number(x.ref_no), type: x.rec_type, source: x.source_module, sourceId: x.source_id, amount: N(x.amount),
      reason: x.reason, notes: x.notes, status: x.status, createdBy: x.created_by_name, createdAt: x.created_at, decidedBy: x.decided_by_name ?? null,
      decidedAt: x.decided_at, decisionNote: x.decision_note, canDecide: x.status === 'pending' && x.created_by !== a.id && decider(a) && c?.status !== 'closed' }));
    const open = issues.filter((i) => i.status === 'open');
    const last = [...w.items.values()].sort((p, q2) => +new Date(q2.reviewed_at) - +new Date(p.reviewed_at))[0];
    const blockers = closingBlockers(y, c, { all, open, recs }, f);
    let status = 'not_started';
    if (c) {
      if (c.status === 'closed') status = 'closed';
      else if (c.status === 'approved') status = 'approved';
      else if (all.some((i) => i.status === 'blocking' || i.status === 'needs_attention') || open.some((i) => i.blocking)) status = 'needs_attention';
      else status = blockers.length ? 'in_review' : 'ready_for_approval';
    }
    return {
      status, checklist, issues, reconciliations: recs, blockers,
      summary: { total: all.length, done, notReviewed: all.filter((i) => i.status === 'not_reviewed').length,
        attention: all.filter((i) => i.status === 'needs_attention').length, blockingItems: all.filter((i) => i.status === 'blocking').length,
        blockingIssues: open.filter((i) => i.blocking).length, reviewIssues: open.filter((i) => i.severity === 'review').length,
        pendingReconciliations: recs.filter((x) => x.status === 'pending').length,
        readinessPct: Math.round(done * 100 / all.length) },
      lastReview: last ? { by: last.reviewer, at: last.reviewed_at } : null,
    };
  }

  /** the hard closing blockers — the same rules decide approval and closing on the server */
  function closingBlockers(y: number, c: any, s: { all: any[]; open: any[]; recs: any[] }, f: any) {
    const b: { code: string; message: string }[] = [];
    if (!c) return [{ code: 'not_started', message: 'المراجعة لسه مبدأتش' }];
    if (today() <= `${y}-12-31`) b.push({ code: 'year_not_ended', message: `السنة ${y} لسه مخلصتش — التقفيل بعد 31/12` });
    const left = s.all.filter((i) => !DONE.has(i.status));
    if (left.length) b.push({ code: 'items_incomplete', message: `${left.length} بند في قائمة المراجعة لسه متراجعش أو عليه ملاحظة` });
    const bl = s.open.filter((i) => i.blocking);
    if (bl.length) b.push({ code: 'blocking_issues', message: `${bl.length} مشكلة مانعة للتقفيل لسه مفتوحة` });
    const rv = s.open.filter((i) => i.severity === 'review');
    if (rv.length) b.push({ code: 'review_issues', message: `${rv.length} ملاحظة محتاجة مراجعة (تتحل أو تتعتمد كاستثناء)` });
    const pr = s.recs.filter((x) => x.status === 'pending');
    if (pr.length) b.push({ code: 'pending_reconciliations', message: `${pr.length} تسوية مستنية اعتماد` });
    if (f?.revenue === null || f?.expenses === null) b.push({ code: 'figures_unavailable', message: 'أرقام السنة مش متاحة' });
    return b;
  }

  async function orderBlockers(q: Q, y: number) {
    const b: { code: string; message: string }[] = [];
    // the previous year's latest version: under review / approved, or reopened and not closed again → this year waits
    const prev = await one(q, `SELECT status FROM fy_closings WHERE fiscal_year = $1 ORDER BY version DESC LIMIT 1`, [y - 1]);
    if (prev && (prev.status === 'in_review' || prev.status === 'approved')) b.push({ code: 'previous_year_open', message: `مراجعة سنة ${y - 1} لسه مفتوحة — السنين بتتقفل بالترتيب` });
    if (prev?.status === 'reopened') b.push({ code: 'previous_year_reopened', message: `سنة ${y - 1} اتفتحت تاني ولسه متقفلتش — اقفلها الأول` });
    const next = await one(q, `SELECT 1 FROM fy_closings WHERE fiscal_year = $1 AND status IN ('approved','closed') LIMIT 1`, [y + 1]);
    if (next) b.push({ code: 'next_year_closed', message: `سنة ${y + 1} معتمدة أو مقفولة بالفعل` });
    return b;
  }

  async function state(q: Q, a: Actor, y: number, sync: boolean) {
    const isIn = await installed(q);
    const versions = isIn ? (await q.query(`SELECT c.id, c.version, c.status, c.started_at, c.approved_at, c.closed_at, c.reopened_at, c.reopen_reason, c.approval_notes,
        c.snapshot_hash, s.full_name AS started_by, ap.full_name AS approved_by, cl.full_name AS closed_by, ro.full_name AS reopened_by
        FROM fy_closings c JOIN employees s ON s.id = c.started_by LEFT JOIN employees ap ON ap.id = c.approved_by
        LEFT JOIN employees cl ON cl.id = c.closed_by LEFT JOIN employees ro ON ro.id = c.reopened_by
       WHERE c.fiscal_year = $1 ORDER BY c.version DESC`, [y])).rows : [];
    const c = isIn ? await liveClosing(q, y) : null;
    if (c?.status === 'closed') {
      const snap = c.snapshot;
      return { installed: isIn, closing: versions[0], versions, figures: snap.figures, ...snap.review, status: 'closed', blockers: [],
        snapshot: { hash: c.snapshot_hash, version: c.version, closedAt: c.closed_at, openingBalances: snap.openingBalances, approval: snap.approval } };
    }
    const f = await yearFigures(q, a, y);
    let w = { items: new Map<string, any>(), issues: [] as any[], recs: [] as any[] };
    if (c) {
      w = await loadWork(q, c.id);
      if (sync && await syncIssues(q, c, await detect(q, y, f, w.items, w.recs), w.issues)) w = await loadWork(q, c.id);
    }
    const sh = shape(c, f, w, a, y);
    if (c) sh.blockers.push(...await orderBlockers(q, y));
    if (c && sh.status === 'ready_for_approval' && sh.blockers.length) sh.status = 'in_review';
    // what would be found, even before a review starts (read-only preview)
    const preview = !c ? await detect(q, y, f, new Map(), []) : undefined;
    return { installed: isIn, closing: versions.find((v) => v.id === c?.id) ?? null, versions, figures: f, ...sh,
      preview: preview?.map((d) => ({ ...d, blocking: d.severity === 'blocking' })) };
  }

  const can4 = (a: Actor) => ({ review: canOffice(a), decide: decider(a), owner: isOwner(a),
    partners: can(a, 'cash.owner_funds', 'cash.office'), profit: can(a, 'finance.company_income', 'cash.office'), salaries: has(a, 'employee.salary_read') });

  // ------------------------------------------------------------------ read
  r.get('/closing/years', async (req) => {
    const a = await authenticate(db, req); view(a);
    const span = await one(db, `SELECT LEAST(
        (SELECT min(occurred_at) FROM cash_receipts), (SELECT min(occurred_at) FROM cash_expenses), (SELECT min(created_at) FROM payouts),
        (SELECT min(created_at) FROM cash_adjustments)) AS first`);
    const now = Number(today().slice(0, 4));
    const first = span?.first ? Number(local(new Date(span.first)).date.slice(0, 4)) : now;
    const isIn = await installed(db);
    const rows = isIn ? (await db.query(`SELECT DISTINCT ON (c.fiscal_year) c.fiscal_year, c.id, c.version, c.status, c.closed_at, c.started_at,
          ap.full_name AS approved_by, s.full_name AS started_by,
          c.snapshot->'figures'->'treasury' AS treasury, c.snapshot->'figures'->'receivables'->'installments'->'total' AS receivables,
          c.snapshot->'figures'->'payables' AS payables, c.snapshot->'figures'->'profit'->'available' AS profit_ok,
          (SELECT max(reviewed_at) FROM fy_review_items i WHERE i.closing_id = c.id) AS last_review
          FROM fy_closings c JOIN employees s ON s.id = c.started_by LEFT JOIN employees ap ON ap.id = c.approved_by
         ORDER BY c.fiscal_year, c.version DESC`)).rows : [];
    const years = [];
    for (let y = now; y >= Math.min(first, now); y--) {
      const c = rows.find((x) => x.fiscal_year === y);
      years.push({ year: y, from: `${y}-01-01`, to: `${y}-12-31`, status: c ? (c.status === 'reopened' ? 'reopened' : c.status) : 'not_started',
        version: c?.version ?? null, closedAt: c?.closed_at ?? null, approvedBy: c?.approved_by ?? null, startedBy: c?.started_by ?? null,
        lastReview: c?.last_review ?? null,
        closingTotals: c?.status === 'closed' ? {
          office: N(c.treasury?.office?.closing), hr: N(c.treasury?.hr?.closing), bank: r2(N(c.treasury?.office?.bankPart) + N(c.treasury?.hr?.bankPart)),
          receivables: N(c.receivables), payables: r2(N(c.payables?.employeeCommissions) + N(c.payables?.payoutsNotReceived)), profitAllocated: c.profit_ok === true } : null });
    }
    return ok({ installed: isIn, today: today(), years, can: can4(a), limitations: LIMITATIONS });
  });

  r.get('/closing/:year', async (req) => {
    const a = await authenticate(db, req); view(a);
    const y = yearParam(req.params.year);
    if (y > Number(today().slice(0, 4))) throw notFound('Invalid year');
    const st = await db.tx((q) => state(q, a, y, true));
    return ok({ year: y, currency: 'EGP', ...redactState(st, a), can: can4(a), limitations: LIMITATIONS });
  });

  /** the source records behind a figure (paged; no attachments, no phone numbers) */
  r.get('/closing/:year/transactions', async (req) => {
    const a = await authenticate(db, req); view(a);
    const y = yearParam(req.params.year);
    const kind = req.query.get('kind') ?? 'ledger';
    const offset = Math.max(0, Math.min(Number(req.query.get('offset') ?? 0) || 0, 100000));
    const box = req.query.get('cashbox');
    const vals: unknown[] = [`${y}-01-01`, `${y + 1}-01-01`];
    const boxSql = (col: string) => (box === 'office' || box === 'hr' ? (vals.push(box), ` AND ${col} = $${vals.length}`) : '');
    let sql: string;
    // each row's area: an owner's injection / withdrawal (partners), an exclusive project's money (projects), a payment to an
    // employee (employees) — shown without amount and label to whoever may not see that area
    const AREA_SQL = (r: string, x: string, p: string) => `CASE WHEN ${r}.kind = 'injection' OR ${x}.owner_draw_id IS NOT NULL THEN 'partners'
                                                              WHEN ${x}.ex_kind IS NOT NULL THEN 'projects'
                                                              WHEN ${p}.id IS NOT NULL AND ${p}.kind <> 'fund' THEN 'employees' END`;
    if (kind === 'ledger') {
      sql = `SELECT l.source, l.source_id AS id, l.ref_no, l.type, l.cashbox, l.amount, l.at, l.label, ${AREA_SQL('r', 'x', 'p')} AS area FROM cash_ledger l
               LEFT JOIN cash_receipts r ON l.source = 'cash_receipts' AND r.id = l.source_id
               LEFT JOIN cash_expenses x ON l.source = 'cash_expenses' AND x.id = l.source_id
               LEFT JOIN payouts p ON l.source = 'payouts' AND p.id = l.source_id
              WHERE l.at >= ${at('$1')} AND l.at < ${at('$2')}${boxSql('l.cashbox')} ORDER BY l.at, l.source, l.source_id, l.type, l.cashbox, l.amount`;
    } else if (kind === 'receipts') {
      sql = `SELECT 'cash_receipts' AS source, id, ref_no, kind AS type, cashbox, amount_egp AS amount, occurred_at AS at, purpose AS label, status, payment_method,
                    CASE WHEN kind = 'injection' THEN 'partners' END AS area FROM cash_receipts
              WHERE occurred_at >= ${at('$1')} AND occurred_at < ${at('$2')}${boxSql('cashbox')} ORDER BY occurred_at, id`;
    } else if (kind === 'expenses') {
      sql = `SELECT 'cash_expenses' AS source, id, ref_no, category AS type, cashbox, amount_egp AS amount, COALESCE(approved_at, occurred_at) AS at, reason AS label, status, payment_method,
                    CASE WHEN owner_draw_id IS NOT NULL THEN 'partners' WHEN ex_kind IS NOT NULL THEN 'projects' END AS area
               FROM cash_expenses WHERE occurred_at >= ${at('$1')} AND occurred_at < ${at('$2')}${boxSql('cashbox')} ORDER BY occurred_at, id`;
    } else if (kind === 'payouts') {
      // what each employee was paid: the same permission as his account page (/finance/employee-account)
      if (!has(a, 'employee.salary_read')) throw forbidden('صرف الموظفين محتاج صلاحية «عرض المرتبات»');
      sql = `SELECT 'payouts' AS source, p.id, NULL::bigint AS ref_no, p.kind AS type, 'hr' AS cashbox, p.amount_egp AS amount, COALESCE(p.received_at, p.created_at) AS at,
                    e.full_name AS label, p.status FROM payouts p JOIN employees e ON e.id = p.employee_id
              WHERE p.created_at >= ${at('$1')} AND p.created_at < ${at('$2')} ORDER BY p.created_at, p.id`;
    } else if (kind === 'transfers') {
      sql = `SELECT 'cash_transfers' AS source, id, ref_no, direction AS type, NULL AS cashbox, COALESCE(amount_executed, amount_requested) AS amount, requested_at AS at, reason AS label, status
               FROM cash_transfers WHERE requested_at >= ${at('$1')} AND requested_at < ${at('$2')} ORDER BY requested_at, id`;
    } else throw invalid('kind is invalid', { field: 'kind' });
    vals.push(offset);
    const rows = await db.query(`${sql} LIMIT 101 OFFSET $${vals.length}`, vals);
    return ok({ kind, offset, next: rows.rows.length > 100 ? offset + 100 : null,
      rows: rows.rows.slice(0, 100).map((x) => {
        const { area, ...row } = x;
        const out = { ...row, amount: N(x.amount), refNo: x.ref_no == null ? null : Number(x.ref_no) };
        return area && !mayArea(area as Area, a) ? { ...out, amount: null, label: hiddenText(area as Exclude<Area, null>), redacted: true } : out;
      }) });
  });

  r.get('/closing/:year/audit', async (req) => {
    const a = await authenticate(db, req); view(a);
    const y = yearParam(req.params.year);
    if (!(await installed(db))) return ok({ events: [] });
    const ev = await db.query(`SELECT l.id, l.at, l.action, l.entity_id, l.before, l.after, COALESCE(e.full_name, 'السيستم') AS by
        FROM audit_log l LEFT JOIN employees e ON e.id = l.actor_id
       WHERE l.entity = 'fy_closing' AND l.entity_id IN (SELECT id::text FROM fy_closings WHERE fiscal_year = $1) ORDER BY l.at DESC LIMIT 500`, [y]);
    // the area of each event: from the item key, or from the issue / reconciliation it is about (the log itself never changes)
    const ids = await db.query(`SELECT 'issue' AS k, i.id::text AS id, i.category, i.source_module AS source FROM fy_issues i JOIN fy_closings c ON c.id = i.closing_id WHERE c.fiscal_year = $1
                                UNION ALL
                                SELECT 'rec', x.id::text, x.rec_type, x.source_module FROM fy_reconciliations x JOIN fy_closings c ON c.id = x.closing_id WHERE c.fiscal_year = $1`, [y]);
    const areaOf = new Map<string, Area>(ids.rows.map((x) => [x.id, x.k === 'rec' ? recArea(x.category) : issueArea({ category: x.category, source: x.source })]));
    const events = ev.rows.map((e) => {
      const after = e.after ?? {};
      const area: Area = e.action === 'closing.item' ? itemArea(String(after.item ?? ''))
        : e.action.startsWith('closing.issue_') && e.action !== 'closing.issues_detected' ? (after.issue ? areaOf.get(after.issue) ?? (after.category ? issueArea({ category: after.category }) : null) : null)
        : e.action.startsWith('closing.reconciliation') ? (after.reconciliation ? areaOf.get(after.reconciliation) ?? (after.type ? recArea(after.type) : null) : null)
        : null;
      if (!area || mayArea(area, a)) return e;
      // what happened and to what stays visible; the amounts / notes / reasons do not
      const keep = Object.fromEntries(Object.entries(after).filter(([k]) => ['item', 'status', 'issue', 'reconciliation', 'action', 'decision', 'type', 'category', 'severity'].includes(k)));
      return { ...e, before: null, after: { ...keep, redacted: hiddenText(area) } };
    });
    return ok({ events });
  });

  r.get('/closing/:year/opening-balances', async (req) => {
    const a = await authenticate(db, req); view(a);
    const y = yearParam(req.params.year);
    if (!(await installed(db))) return ok({ carriedOut: [], carriedIn: [] });
    const sel = `SELECT o.*, c.version FROM fy_opening_balances o JOIN fy_closings c ON c.id = o.closing_id`;
    const out = await db.query(`${sel} WHERE o.from_year = $1 ORDER BY o.status, o.entity_type, o.label`, [y]);
    const inn = await db.query(`${sel} WHERE o.to_year = $1 ORDER BY o.status, o.entity_type, o.label`, [y]);
    const m = (x: any) => ({ id: x.id, closingId: x.closing_id, version: x.version, fromYear: x.from_year, toYear: x.to_year, entityType: x.entity_type,
      entityId: x.entity_id, label: x.label, sourceBalance: N(x.source_balance), carryBalance: N(x.carry_balance), classification: x.classification,
      status: x.status, createdAt: x.created_at });
    const vis = (x: any) => visibleOpening(x.entity_type, a);
    return ok({ carriedOut: out.rows.filter(vis).map(m), carriedIn: inn.rows.filter(vis).map(m) });
  });

  // ------------------------------------------------------------------ the review
  r.post('/closing/:year/start', async (req) => {
    const a = await authenticate(db, req); view(a);
    const y = yearParam(req.params.year);
    if (y > Number(today().slice(0, 4))) throw invalid('لا يمكن مراجعة سنة لسه مبدأتش');
    return db.tx(async (q) => {
      await needInstalled(q);
      await q.query(`SELECT pg_advisory_xact_lock(hashtext('fy_closing:' || $1::text))`, [y]);
      const live = await liveClosing(q, y);
      if (live) throw new AppError('conflict', live.status === 'closed' ? 'السنة مقفولة بالفعل' : 'المراجعة بدأت بالفعل', { reason: 'already_started' });
      const v = await one(q, `SELECT COALESCE(max(version), 0) + 1 AS v FROM fy_closings WHERE fiscal_year = $1`, [y]);
      const c = await one(q, `INSERT INTO fy_closings (fiscal_year, version, started_by) VALUES ($1, $2, $3) RETURNING id, version`, [y, v.v, a.id]);
      await audit(q, a.id, 'closing.start', 'fy_closing', c.id, undefined, { year: y, version: c.version });
      return ok({ closing: { id: c.id, version: c.version, status: 'in_review' } }, 201);
    });
  });

  /** one item, or several at once ({keys:[...]}, status reviewed only) */
  r.post('/closing/:year/items', async (req) => {
    const a = await authenticate(db, req); view(a);
    const y = yearParam(req.params.year);
    const b = obj(req.body);
    const status = oneOf(b, 'status', ITEM_STATUSES)!;
    const note = (str(b, 'note', { optional: true, max: 2000 }) ?? '').trim();
    const keys = Array.isArray(b.keys) ? b.keys : [b.key];
    if (!keys.length || keys.length > 100 || keys.some((k) => typeof k !== 'string' || !ITEM.has(k))) throw invalid('Unknown checklist item', { field: 'key' });
    if (keys.length > 1 && status !== 'reviewed') throw invalid('Several items at once can only be marked reviewed');
    const verified = num(b, 'verifiedAmount', { optional: true, min: -100_000_000, max: 100_000_000 });
    if (verified !== undefined && (keys.length > 1 || !ITEM.get(keys[0])!.verify)) throw invalid('This item takes no counted amount', { field: 'verifiedAmount' });
    if (['needs_attention', 'blocking', 'resolved', 'exception'].includes(status) && note.length < 5) throw invalid('اكتب ملاحظة (5 حروف على الأقل)', { field: 'note' });
    if (status === 'exception' && !isOwner(a)) throw forbidden('اعتماد بند كاستثناء للمالك بس');
    return db.tx(async (q) => {
      const c = await editable(q, a, y);
      for (const k of keys as string[]) {
        const it = ITEM.get(k)!;
        const before = await one(q, `SELECT status, note, verified_amount FROM fy_review_items WHERE closing_id = $1 AND item_key = $2`, [c.id, k]);
        let va = verified ?? (before?.verified_amount == null ? null : N(before.verified_amount));
        if (it.verify && DONE.has(status) && va === null) throw invalid('سجّل الرصيد الفعلي بعد الجرد الأول', { field: 'verifiedAmount' });
        if (it.verify && va !== null && status === 'reviewed') {
          // a counted balance that differs from the system's needs its reason written
          const f = await yearFigures(q, a, y);
          const sys = f.treasury[k === 'treasury.office_count' ? 'office' : 'hr'].closing;
          if (Math.abs(va - sys) >= 0.01 && note.length < 5) throw invalid('الرصيد الفعلي مختلف عن السيستم — اكتب سبب الفرق', { field: 'note' });
        }
        va = va === null ? null : r2(va);
        await q.query(`INSERT INTO fy_review_items (closing_id, item_key, status, note, verified_amount, reviewed_by) VALUES ($1,$2,$3,$4,$5,$6)
                       ON CONFLICT (closing_id, item_key) DO UPDATE SET status = EXCLUDED.status, note = EXCLUDED.note, verified_amount = EXCLUDED.verified_amount,
                         reviewed_by = EXCLUDED.reviewed_by, reviewed_at = now()`, [c.id, k, status, note, va, a.id]);
        await audit(q, a.id, 'closing.item', 'fy_closing', c.id, before ? { item: k, status: before.status, verifiedAmount: before.verified_amount } : { item: k, status: 'not_reviewed' },
          { item: k, status, note: note || undefined, verifiedAmount: va ?? undefined });
      }
      return ok({ saved: keys.length });
    });
  });

  /** an issue a reviewer found himself */
  r.post('/closing/:year/issues', async (req) => {
    const a = await authenticate(db, req); view(a);
    const y = yearParam(req.params.year);
    const b = obj(req.body);
    const category = oneOf(b, 'category', ['treasury', 'bank', 'revenue', 'expenses', 'employees', 'obligations', 'projects', 'partners', 'profit', 'assets', 'other'] as const)!;
    const severity = oneOf(b, 'severity', ['info', 'review', 'blocking'] as const)!;
    const description = str(b, 'description', { min: 5, max: 1000 })!.trim();
    const amount = num(b, 'amount', { optional: true, min: -100_000_000, max: 100_000_000 });
    const sourceId = (str(b, 'sourceId', { optional: true, max: 200 }) ?? '').trim() || null;
    const source = (str(b, 'source', { optional: true, max: 60 }) ?? 'manual').trim();
    return db.tx(async (q) => {
      const c = await editable(q, a, y);
      const x = await one(q, `INSERT INTO fy_issues (closing_id, issue_key, category, source_module, source_id, description, amount, severity, detected_by)
                              VALUES ($1, 'manual:' || gen_random_uuid(), $2, $3, $4, $5, $6, $7, $8) RETURNING id, ref_no`,
        [c.id, category, source, sourceId, description, amount ?? null, severity, a.id]);
      await audit(q, a.id, 'closing.issue_raised', 'fy_closing', c.id, undefined, { issue: x.id, category, severity, amount: amount ?? null });
      return ok({ issue: { id: x.id, refNo: Number(x.ref_no) } }, 201);
    });
  });

  /**
   * note: a resolution note / reference. resolve: only a reviewer's own issue, or one whose source no longer shows the
   * problem (then the system resolves it by itself). exception: approved with a reason — a review-level one by an approver
   * (not the one who raised it), a blocking one by the owner only.
   */
  r.post('/closing/issues/:id', async (req) => {
    const a = await authenticate(db, req); view(a);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const action = oneOf(b, 'action', ['note', 'resolve', 'exception', 'reopen'] as const)!;
    const note = (str(b, 'note', { optional: true, max: 2000 }) ?? '').trim();
    const ref = (str(b, 'ref', { optional: true, max: 200 }) ?? '').trim() || null;
    if (note.length < 5) throw invalid('اكتب ملاحظة (5 حروف على الأقل)', { field: 'note' });
    return db.tx(async (q) => {
      await needInstalled(q);
      const i = await one(q, `SELECT i.*, c.fiscal_year FROM fy_issues i JOIN fy_closings c ON c.id = i.closing_id WHERE i.id = $1 FOR UPDATE OF i`, [req.params.id]);
      if (!i) throw notFound();
      const c = await editable(q, a, i.fiscal_year);
      if (c.id !== i.closing_id) throw conflict('المشكلة دي من تقفيل قديم');
      const before = { status: i.status, resolutionNote: i.resolution_note };
      if (action === 'note') {
        await q.query(`UPDATE fy_issues SET resolution_note = $2, resolution_ref = COALESCE($3, resolution_ref) WHERE id = $1`, [i.id, note, ref]);
      } else if (action === 'resolve') {
        if (i.status !== 'open') throw conflict('المشكلة مش مفتوحة');
        if (i.detected_by === null) {
          throw new AppError('conflict', 'المشكلة دي بيكتشفها السيستم من الحركة نفسها: صحّح الحركة في نظامها (اعتماد / عكس / استلام) أو اطلب اعتمادها كاستثناء', { reason: 'fix_at_source' });
        }
        await q.query(`UPDATE fy_issues SET status = 'resolved', resolution_note = $2, resolution_ref = $3, resolved_by = $4, resolved_at = now() WHERE id = $1`, [i.id, note, ref, a.id]);
      } else if (action === 'exception') {
        if (i.status !== 'open') throw conflict('المشكلة مش مفتوحة');
        if (i.severity === 'blocking' ? !isOwner(a) : !decider(a)) throw forbidden(i.severity === 'blocking' ? 'استثناء مشكلة مانعة للمالك بس' : 'محتاج صلاحية الاعتماد');
        if (i.detected_by === a.id) throw forbidden('اللي سجّل المشكلة ميعتمدهاش كاستثناء');
        await q.query(`UPDATE fy_issues SET status = 'exception', resolution_note = $2, resolution_ref = COALESCE($3, resolution_ref), exception_by = $4, exception_at = now() WHERE id = $1`,
          [i.id, note, ref, a.id]);
      } else {
        if (i.status === 'open') throw conflict('المشكلة مفتوحة بالفعل');
        await q.query(`UPDATE fy_issues SET status = 'open', resolved_by = NULL, resolved_at = NULL, exception_by = NULL, exception_at = NULL,
                         resolution_note = $2 WHERE id = $1`, [i.id, note]);
      }
      await audit(q, a.id, `closing.issue_${action}`, 'fy_closing', i.closing_id, before, { issue: i.id, action, note, ref });
      return ok({ ok: true });
    });
  });

  r.post('/closing/:year/reconciliations', async (req) => {
    const a = await authenticate(db, req); view(a);
    const y = yearParam(req.params.year);
    const b = obj(req.body);
    const type = oneOf(b, 'type', REC_TYPES)!;
    const amount = num(b, 'amount', { min: -100_000_000, max: 100_000_000 })!;
    if (Math.abs(amount) < 0.01) throw invalid('المبلغ مينفعش يكون صفر', { field: 'amount' });
    const reason = str(b, 'reason', { min: 5, max: 500 })!.trim();
    const notes = (str(b, 'notes', { optional: true, max: 2000 }) ?? '').trim();
    const source = str(b, 'source', { min: 2, max: 60 })!.trim();
    const sourceId = (str(b, 'sourceId', { optional: true, max: 200 }) ?? '').trim() || null;
    if (type === 'treasury' && !['office', 'hr'].includes(sourceId ?? '')) throw invalid('تسوية الخزنة لازم تحدد الخزنة (office / hr)', { field: 'sourceId' });
    return db.tx(async (q) => {
      const c = await editable(q, a, y);
      const x = await one(q, `INSERT INTO fy_reconciliations (closing_id, rec_type, source_module, source_id, amount, reason, notes, created_by)
                              VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id, ref_no`, [c.id, type, source, sourceId, r2(amount), reason, notes, a.id]);
      await audit(q, a.id, 'closing.reconciliation', 'fy_closing', c.id, undefined, { reconciliation: x.id, type, source, sourceId, amount: r2(amount), reason });
      return ok({ reconciliation: { id: x.id, refNo: Number(x.ref_no) } }, 201);
    });
  });

  r.post('/closing/reconciliations/:id/decision', async (req) => {
    const a = await authenticate(db, req); view(a);
    if (!decider(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const decision = oneOf(b, 'decision', ['approve', 'reject'] as const)!;
    const note = (str(b, 'note', { optional: true, max: 2000 }) ?? '').trim();
    if (decision === 'reject' && note.length < 5) throw invalid('اكتب سبب الرفض', { field: 'note' });
    return db.tx(async (q) => {
      await needInstalled(q);
      const x = await one(q, `SELECT x.*, c.fiscal_year FROM fy_reconciliations x JOIN fy_closings c ON c.id = x.closing_id WHERE x.id = $1 FOR UPDATE OF x`, [req.params.id]);
      if (!x) throw notFound();
      if (x.created_by === a.id) throw forbidden('محدش يعتمد تسوية سجّلها بنفسه');
      if (x.status !== 'pending') throw conflict('التسوية اتقرر فيها بالفعل');
      const c = await editable(q, a, x.fiscal_year);
      if (c.id !== x.closing_id) throw conflict('التسوية دي من تقفيل قديم');
      await q.query(`UPDATE fy_reconciliations SET status = $2, decided_by = $3, decided_at = now(), decision_note = $4 WHERE id = $1`,
        [x.id, decision === 'approve' ? 'approved' : 'rejected', a.id, note]);
      await audit(q, a.id, 'closing.reconciliation_decision', 'fy_closing', x.closing_id, { status: 'pending' }, { reconciliation: x.id, decision, note });
      return ok({ ok: true });
    });
  });

  // ------------------------------------------------------------------ approval, closing, reopening (the owner)
  r.post('/closing/:year/approve', async (req) => {
    const a = await authenticate(db, req); view(a);
    if (!isOwner(a)) throw forbidden('اعتماد التقفيل للمالك بس');
    const y = yearParam(req.params.year);
    const b = obj(req.body ?? {});
    const notes = (str(b, 'notes', { optional: true, max: 2000 }) ?? '').trim();
    if (b.confirm !== true) throw invalid('الاعتماد لازم يكون صريح (confirm)', { field: 'confirm' });
    return db.tx(async (q) => {
      await needInstalled(q);
      await q.query(`SELECT pg_advisory_xact_lock(hashtext('fy_closing:' || $1::text))`, [y]);
      const c = await liveClosing(q, y, true);
      if (!c) throw conflict('ابدأ المراجعة الأول');
      if (c.status === 'closed') throw new AppError('conflict', 'السنة مقفولة بالفعل', { reason: 'year_closed' });
      const st = await state(q, a, y, true);
      if (st.blockers.length) throw new AppError('conflict', 'التقفيل مش جاهز للاعتماد', { reason: 'blocked', blockers: st.blockers });
      const h = hashOf(st.figures);
      await q.query(`UPDATE fy_closings SET status = 'approved', approved_by = $2, approved_at = now(), approval_notes = $3, approved_hash = $4 WHERE id = $1`, [c.id, a.id, notes, h]);
      await audit(q, a.id, 'closing.approve', 'fy_closing', c.id, { status: c.status }, { status: 'approved', figuresHash: h, notes: notes || undefined });
      return ok({ status: 'approved', figuresHash: h });
    });
  });

  r.post('/closing/:year/close', async (req) => {
    const a = await authenticate(db, req); view(a);
    if (!isOwner(a)) throw forbidden('تقفيل السنة للمالك بس');
    const y = yearParam(req.params.year);
    const b = obj(req.body ?? {});
    if (b.confirm !== `CLOSE ${y}`) throw invalid(`للتأكيد اكتب CLOSE ${y}`, { field: 'confirm' });
    return db.tx(async (q) => {
      await needInstalled(q);
      await q.query(`SELECT pg_advisory_xact_lock(hashtext('fy_closing:' || $1::text))`, [y]);
      const c = await liveClosing(q, y, true);
      if (!c) throw conflict('ابدأ المراجعة الأول');
      if (c.status === 'closed') throw new AppError('conflict', 'السنة مقفولة بالفعل', { reason: 'year_closed' });
      if (c.status !== 'approved') throw new AppError('conflict', 'التقفيل محتاج اعتماد الأول', { reason: 'not_approved' });
      // the rules run once more right now: anything that appeared since the approval blocks the closing too
      const st = await state(q, a, y, true);
      if (st.blockers.length) throw new AppError('conflict', 'في موانع للتقفيل', { reason: 'blocked', blockers: st.blockers });
      const f = st.figures;
      if (hashOf(f) !== c.approved_hash) {
        throw new AppError('conflict', 'الأرقام اتغيرت من وقت الاعتماد — راجعها واعتمد تاني', { reason: 'figures_changed' });
      }
      // carried to the next year: balances only (no transaction is created anywhere)
      const open: { type: string; id: string; label: string; source: number; carry: number; cls: string }[] = [];
      const push = (type: string, id: string, label: string, v: number | null | undefined, cls: string, keepZero = false) => {
        if (v !== null && v !== undefined && (keepZero || Math.abs(v) >= 0.01)) open.push({ type, id, label, source: r2(v), carry: r2(v), cls });
      };
      push('cashbox', 'office', 'خزنة المكتب', f.treasury.office.closing, 'treasury', true);
      push('cashbox', 'hr', 'خزنة المحاسب', f.treasury.hr.closing, 'treasury', true);
      push('bank', 'office', 'بنك خزنة المكتب', f.treasury.office.bankPart, 'bank');
      push('bank', 'hr', 'بنك خزنة المحاسب', f.treasury.hr.bankPart, 'bank');
      push('receivable', 'installments', 'أقساط مستحقة للشركة', f.receivables.installments.total, 'receivable');
      for (const x of f.employees.advancesOutstanding.byEmployee) push('employee_advance', x.id, `سلفة: ${x.name}`, x.amount, 'receivable');
      for (const x of f.employees.commissionsUnpaid.byEmployee) push('employee_commission', x.id, `عمولة مستحقة: ${x.name}`, x.amount, 'payable');
      if (f.partners.available) {
        for (const p of f.partners.list) {
          // the balance already holds his undistributed share — it is carried once, inside it
          if (p.closing !== null) push('partner', p.id, `شريك: ${p.name}`, p.closing, 'equity', true);
        }
      }
      const review = { checklist: st.checklist, issues: st.issues, reconciliations: st.reconciliations, summary: st.summary };
      const approval = { by: a.fullName, approvedAt: c.approved_at, notes: c.approval_notes, figuresHash: c.approved_hash };
      const snapshot = { schema: 1, year: y, closingId: c.id, version: c.version, figures: f, review, approval,
        openingBalances: open.map((o) => ({ entityType: o.type, entityId: o.id, label: o.label, sourceBalance: o.source, carryBalance: o.carry, classification: o.cls })),
        limitations: LIMITATIONS };
      const sh = hashOf(snapshot);
      await q.query(`UPDATE fy_closings SET status = 'closed', closed_by = $2, closed_at = now(), snapshot = $3, snapshot_hash = $4 WHERE id = $1`,
        [c.id, a.id, JSON.stringify(snapshot), sh]);
      for (const o of open) {
        await q.query(`INSERT INTO fy_opening_balances (closing_id, from_year, to_year, entity_type, entity_id, label, source_balance, carry_balance, classification)
                       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`, [c.id, y, y + 1, o.type, o.id, o.label, o.source, o.carry, o.cls]);
      }
      await audit(q, a.id, 'closing.close', 'fy_closing', c.id, { status: 'approved' }, { status: 'closed', snapshotHash: sh, openingBalances: open.length });
      return ok({ status: 'closed', snapshotHash: sh, openingBalances: open.length });
    });
  });

  r.post('/closing/:year/reopen', async (req) => {
    const a = await authenticate(db, req); view(a);
    if (!isOwner(a)) throw forbidden('فتح سنة مقفولة للمالك بس');
    const y = yearParam(req.params.year);
    const b = obj(req.body);
    const reason = str(b, 'reason', { min: 10, max: 2000 })!.trim();
    if (b.confirm !== `REOPEN ${y}`) throw invalid(`للتأكيد اكتب REOPEN ${y}`, { field: 'confirm' });
    return db.tx(async (q) => {
      await needInstalled(q);
      await q.query(`SELECT pg_advisory_xact_lock(hashtext('fy_closing:' || $1::text))`, [y]);
      const c = await liveClosing(q, y, true);
      if (!c || c.status !== 'closed') throw conflict('السنة دي مش مقفولة');
      const next = await one(q, `SELECT status FROM fy_closings WHERE fiscal_year = $1 AND status IN ('in_review','approved','closed')`, [y + 1]);
      if (next && next.status !== 'in_review') {
        throw new AppError('conflict', `سنة ${y + 1} معتمدة / مقفولة على الأرصدة المرحّلة من السنة دي — افتحها هي الأول`, { reason: 'next_year_closed' });
      }
      // the snapshot stays as it was (the trigger refuses anything else); this version is kept as «reopened»
      await q.query(`UPDATE fy_closings SET status = 'reopened', reopened_by = $2, reopened_at = now(), reopen_reason = $3 WHERE id = $1`, [c.id, a.id, reason]);
      const ob = await q.query(`UPDATE fy_opening_balances SET status = 'superseded' WHERE closing_id = $1 AND status = 'active' RETURNING entity_type, entity_id`, [c.id]);
      const impact = { openingBalancesSuperseded: ob.rowCount ?? 0, nextYearInReview: !!next };
      await audit(q, a.id, 'closing.reopen', 'fy_closing', c.id, { status: 'closed', snapshotHash: c.snapshot_hash }, { status: 'reopened', reason, impact });
      return ok({ status: 'reopened', impact });
    });
  });
};
