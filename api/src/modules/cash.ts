import { salesMoneyOverview } from './exclusive.ts';
import { ok, type Module } from '../ctx.ts';
import { local } from '../lib/time.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { imageAttachment, isUuid, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, type Actor, can, notSettled } from '../auth/context.ts';
import { notify } from './notify.ts';
import { companyForPayment, companyOtpInstalled, tellCompany } from './company-payouts.ts';
import { checkClassification, classificationInstalled } from './expense-classes.ts';
import { onBrokerageReceiptReversed } from './brokerage.ts';
import { computePayrollMany, loadRules } from './payroll-calc.ts';
import { readFileBytes, storeAttachment, withFile } from '../lib/files.ts';

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
  return imageAttachment(v, 'attachment', 600_000, 'The attachment must be an image under 600 KB');
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
    // F3: the HR cashbox's own expenses only — an office withdrawal / owner payout waiting for approval is never counted here
    const pendingExp = await one(q, `SELECT COALESCE(sum(amount_egp),0) AS s, count(*) AS n FROM cash_expenses WHERE status = 'pending_approval' AND cashbox = 'hr'`);
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
  out.can = { office: canOffice(a), hrView: canHrView(a), hrOperate: canHrOperate(a), hrDesk: hrDesk(a), settings: has(a, 'cash.settings'),
    // each financial action on its own permission (the endpoints check the same)
    approve: can(a, 'cash.approve', 'cash.office'), reverse: can(a, 'cash.reverse', 'cash.office'),
    bankView: canOffice(a) && can(a, 'cash.bank_view', 'cash.office'), bankTransfer: canOffice(a) && can(a, 'cash.bank_transfer', 'cash.office'),
    ownerFunds: can(a, 'cash.owner_funds', 'cash.office'),
    print: can(a, 'cash.receipt_print', null), attachmentView: canAttachmentView(a), attachmentUpload: canAttachmentUpload(a) };
  return out;
}

/**
 * F5 — how much of the cashbox-paid advances was ACTUALLY recovered, and when (Cairo dates). Amount-based:
 *  - deducted: each month's advance deductions (hand-set advance_deductions, or the whole advance in its own month when it
 *    has none — the payroll's own rule), only for advances paid through the cashbox (a received payout linked to the
 *    request). Every (advance, month) deduction is counted once — it is a row, not a salary status.
 *  - recoverable that month = the deduction, less what the salary could not absorb: when deductions are larger than the
 *    salary part (salaryShortfall) the part not absorbed stays a receivable. Shared pro rata with the month's other
 *    advances (e.g. one handed over outside the cashbox).
 *  - recovered as the salary is actually received: each received salary payment recovers its share of the month's salary
 *    part (two payments of half → two halves; a pending / disputed / cancelled payment recovers nothing). A month with no
 *    salary to hand over (deductions ate it all) recovers what the salary absorbed once that month is over.
 * outstanding = paid − recovered, per advance month (never below 0; never more recovered than deducted).
 */
export async function advanceRecoveries(q: Q, today: string) {
  const ded = (await q.query(`
    SELECT d.employee_id, to_char(d.period, 'YYYY-MM-DD') AS period, sum(d.amount_egp) AS amount
      FROM (SELECT x.advance_id, x.employee_id, x.period, x.amount_egp FROM advance_deductions x WHERE x.status = 'active'
            UNION ALL
            SELECT ar.id, ar.employee_id, ar.period, ar.amount_egp FROM advance_requests ar
             WHERE ar.kind = 'advance' AND ar.status = 'confirmed'
               AND NOT EXISTS (SELECT 1 FROM advance_deductions y WHERE y.advance_id = ar.id AND y.status = 'active')) d
     WHERE EXISTS (SELECT 1 FROM payouts pa WHERE pa.advance_id = d.advance_id AND pa.kind = 'advance' AND pa.status = 'received')
     GROUP BY 1, 2`)).rows;
  const events: { date: string; amount: number; employeeId: string; period: string }[] = [];
  const perMonth: { employeeId: string; period: string; deducted: number; recoverable: number; recovered: number }[] = [];
  if (!ded.length) return { events, perMonth };
  const rules = await loadRules(q);
  const byPeriod = new Map<string, any[]>();
  for (const d of ded) (byPeriod.get(d.period) ?? byPeriod.set(d.period, []).get(d.period)!).push(d);
  for (const [period, list] of byPeriod) {
    const ids = list.map((d) => d.employee_id as string);
    const pays = await computePayrollMany(q, ids, period, today, rules);
    const sal = (await q.query(`SELECT employee_id, amount_egp, received_at FROM payouts
                                 WHERE employee_id = ANY($1::uuid[]) AND period = $2 AND kind = 'salary' AND status = 'received'
                                 ORDER BY received_at, id`, [ids, period])).rows;
    const monthOver = (() => { const [y, m] = period.split('-').map(Number); return `${m === 12 ? y + 1 : y}-${String(m === 12 ? 1 : m + 1).padStart(2, '0')}-01` <= today; })();
    const lastDay = (() => { const [y, m] = period.split('-').map(Number); return new Date(Date.UTC(y, m, 0)).toISOString().slice(0, 10); })();
    for (const d of list) {
      const p: any = pays.get(d.employee_id);
      const deducted = r2(Number(d.amount));
      if (!p || p.net == null) { perMonth.push({ employeeId: d.employee_id, period, deducted, recoverable: 0, recovered: 0 }); continue; }
      const allAdv = Number(p.advances) || 0, salaryDue = Number(p.salaryDue);
      // what the month's salary absorbed of ALL its advance deductions, then this (cashbox-paid) share of it
      const absorbed = Math.max(0, Math.min(allAdv, allAdv + Math.min(0, salaryDue)));
      const recoverable = r2(allAdv > 0 ? Math.min(deducted, deducted * absorbed / allAdv) : 0);
      let recovered = 0;
      if (salaryDue > 0.009) {
        let cum = 0;
        for (const x of sal.filter((y) => y.employee_id === d.employee_id)) {
          const before = cum;
          cum = Math.min(salaryDue, cum + Number(x.amount_egp));
          const amt = r2(recoverable * (cum - before) / salaryDue);
          if (amt > 0) { events.push({ date: local(new Date(x.received_at)).date, amount: amt, employeeId: d.employee_id, period }); recovered = r2(recovered + amt); }
        }
        // rounding: a fully received salary recovers exactly the recoverable amount
        if (cum + 0.009 >= salaryDue && Math.abs(recovered - recoverable) > 0 && events.length) {
          events[events.length - 1].amount = r2(events[events.length - 1].amount + recoverable - recovered); recovered = recoverable;
        }
      } else if (monthOver && recoverable > 0) {
        events.push({ date: lastDay, amount: recoverable, employeeId: d.employee_id, period }); recovered = recoverable;
      }
      perMonth.push({ employeeId: d.employee_id, period, deducted, recoverable, recovered });
    }
  }
  return { events, perMonth };
}

/**
 * The office's result month by month (Cairo months), the ONE definition shared by the cashbox overview, the owners'
 * accounts, the injections page and the year closing:
 *   commissions = commission receipts + exclusive commission moved to the office
 *   cashCosts   = the office's own expenses (not trust money, unit refunds or owner withdrawals) + every payout received
 *   F5: an advance paid to an employee is money he owes back (a receivable), not a cost: it leaves the costs when paid and
 *       comes back as a cost only as it is ACTUALLY recovered from his salary — amount by amount (advanceRecoveries below),
 *       never because a salary simply exists. Only advances paid through the cashbox against an approved advance request
 *       count this way; any other «سلفة» payout stays a cost.
 *   costs = cashCosts − advancesPaid + advancesRecovered · net = commissions − costs
 */
export async function profitParts(q: Q, from: string | null, to: string | null, today = local(new Date()).date) {
  const vals: unknown[] = [];
  const range = (col: string) => {
    const c: string[] = [];
    if (from) { vals.push(from); c.push(`${col} >= ($${vals.length}::date AT TIME ZONE 'Africa/Cairo')`); }
    if (to) { vals.push(to); c.push(`${col} < (($${vals.length}::date + 1) AT TIME ZONE 'Africa/Cairo')`); }
    return c.length ? ' AND ' + c.join(' AND ') : '';
  };
  const M = (col: string) => `date_trunc('month', ${col} AT TIME ZONE 'Africa/Cairo')::date`;
  const sql = `
    WITH parts AS (
      SELECT ${M('occurred_at')} AS m, amount_egp AS commissions, 0::numeric AS costs, 0::numeric AS adv_paid, 0::numeric AS adv_rec
        FROM cash_receipts WHERE status = 'posted' AND kind = 'commission' ${range('occurred_at')}
      UNION ALL
      SELECT ${M('created_at')}, amount_egp, 0, 0, 0 FROM ex_commission_transfers WHERE true ${range('created_at')}
      UNION ALL
      SELECT ${M('COALESCE(approved_at, occurred_at)')}, 0, amount_egp, 0, 0 FROM cash_expenses
       WHERE status = 'posted' AND ex_kind IS NULL AND sale_id IS NULL AND owner_draw_id IS NULL ${range('COALESCE(approved_at, occurred_at)')}
      UNION ALL
      SELECT ${M('received_at')}, 0, amount_egp, 0, 0 FROM payouts WHERE status = 'received' AND kind <> 'fund' ${range('received_at')}
      UNION ALL
      SELECT ${M('p.received_at')}, 0, 0, p.amount_egp, 0 FROM payouts p JOIN advance_requests ar ON ar.id = p.advance_id AND ar.kind = 'advance'
       WHERE p.status = 'received' AND p.kind = 'advance' ${range('p.received_at')}
    )
    SELECT to_char(m, 'YYYY-MM-DD') AS month, sum(commissions) AS commissions, sum(costs) AS cash_costs, sum(adv_paid) AS adv_paid, sum(adv_rec) AS adv_rec
      FROM parts GROUP BY m ORDER BY m`;
  const raw = (await q.query(sql, vals)).rows;
  // F5: what was actually recovered of the advances, per Cairo month of the recovery, inside the range
  const rec = new Map<string, number>();
  for (const e of (await advanceRecoveries(q, today)).events) {
    if ((from && e.date < from) || (to && e.date > to)) continue;
    const m = e.date.slice(0, 7) + '-01';
    rec.set(m, r2((rec.get(m) ?? 0) + e.amount));
  }
  for (const m of rec.keys()) if (!raw.some((x) => x.month === m)) raw.push({ month: m, commissions: 0, cash_costs: 0, adv_paid: 0, adv_rec: 0 });
  raw.sort((x, y) => String(x.month).localeCompare(String(y.month)));
  const rows = raw.map((x) => {
    const commissions = r2(Number(x.commissions)), cashCosts = r2(Number(x.cash_costs));
    const advancesPaid = r2(Number(x.adv_paid)), advancesRecovered = r2(rec.get(x.month) ?? 0);
    const costs = r2(cashCosts - advancesPaid + advancesRecovered);
    return { month: x.month as string, commissions, cashCosts, advancesPaid, advancesRecovered, costs, net: r2(commissions - costs) };
  });
  const sum = (k: 'commissions' | 'cashCosts' | 'advancesPaid' | 'advancesRecovered' | 'costs' | 'net') => r2(rows.reduce((t, x) => t + x[k], 0));
  return { months: rows, total: { commissions: sum('commissions'), cashCosts: sum('cashCosts'), advancesPaid: sum('advancesPaid'),
    advancesRecovered: sum('advancesRecovered'), costs: sum('costs'), net: sum('net') } };
}

/** F6: ownership-share history (migration 085) — until it runs, today's نسبة الملكية applies to every month (as before). */
export async function ownerShareHistoryInstalled(q: Q) {
  return !!(await one(q, `SELECT to_regclass('public.company_owner_shares') IS NOT NULL AS ok`))?.ok;
}

/** Each owner's share for every month: the latest share in force on that month's first day (history), else today's. */
async function ownerProfits(q: Q, ids: string[], months: { month: string; net: number }[]) {
  const out = new Map<string, number>();
  const hist = await ownerShareHistoryInstalled(q)
    ? (await q.query(`SELECT employee_id, pct, to_char(effective_from, 'YYYY-MM-DD') AS f FROM company_owner_shares
                       WHERE employee_id = ANY($1::uuid[]) ORDER BY effective_from, created_at`, [ids])).rows : null;
  const cur = new Map((await q.query(`SELECT employee_id, pct FROM company_owners WHERE employee_id = ANY($1::uuid[])`, [ids])).rows
    .map((x) => [x.employee_id as string, Number(x.pct)]));
  for (const id of ids) {
    const mine = hist?.filter((h) => h.employee_id === id) ?? [];
    let total = 0;
    for (const m of months) {
      let pct = cur.get(id) ?? 0;
      if (hist) {
        const inForce = mine.filter((h) => h.f <= m.month).pop();
        pct = inForce ? Number(inForce.pct) : 0; // no share recorded yet for that month → none
      }
      total += m.net * pct / 100;
    }
    out.set(id, r2(total));
  }
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
    // the office's result: the one definition (profitParts) — cash costs with advances as receivables (F5)
    const pr = (await profitParts(q, from, to)).total;
    // the employees' advances still to recover (paid through the cashbox − actually recovered), up to the range's end
    const upTo = from ? (await profitParts(q, null, to)).total : pr;
    out.result = { commissions: pr.commissions, costs: pr.costs, net: pr.net, cashCosts: pr.cashCosts,
      advancesPaid: pr.advancesPaid, advancesRecovered: pr.advancesRecovered,
      advancesOutstanding: r2(Math.max(0, upTo.advancesPaid - upTo.advancesRecovered)) };
    // the owners' trust is the exclusive projects' money; the office's commission income / split / net its own permission
    // resale / rental commissions (087): collected = office revenue already in the boxes; receivable = agreed, not yet paid
    if (await one(q, `SELECT to_regclass('public.brokerage_deals') IS NOT NULL AS ok`).then((x) => x?.ok)) {
      const bk = await one(q, `SELECT count(*)::int AS n,
          COALESCE(sum(d.total_commission_egp), 0) AS agreed,
          COALESCE(sum((SELECT COALESCE(sum(r.amount_egp), 0) FROM cash_receipts r WHERE r.brokerage_deal_id = d.id AND r.status = 'posted')), 0) AS collected
        FROM brokerage_deals d WHERE d.status IN ('approved', 'collected')`);
      out.brokerage = { deals: bk.n, agreed: r2(N(bk.agreed)), collected: r2(N(bk.collected)), receivable: r2(N(bk.agreed) - N(bk.collected)) };
    }
    if (!can(a, 'exclusive.view_finance', 'cash.office')) delete (out.income as any).trust;
    if (!can(a, 'finance.company_income', 'cash.office')) { delete (out.income as any).commissions; delete out.commissionSplit; delete out.result; }
  }
  return out;
}

/** the company's owners: role owner, or anyone with a نسبة ملكية */
export async function ownerIds(q: Q): Promise<string[]> {
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
 * Each owner's account up to a day (null = until now — what ownerAccounts shows): what he injected + his share (نسبة
 * الملكية) of the office's net profit of every month up to that day − what he withdrew (approved); `pending` = withdrawals
 * waiting for approval (the balance he can still withdraw subtracts them). The one definition — the year closing reads it too.
 * `net` is null when this person may not see the office's profit (finance.company_income).
 */
export async function ownerBalancesAt(q: Q, a: Actor, ids: string[], to: string | null) {
  const ov = await cashOverview(q, a, null, to);
  const net = (ov.result as any)?.net == null ? null : Number((ov.result as any).net);
  // F6: each month's net × the share in force that month (history), summed — not today's share × the whole net
  const profits = net === null ? null : await ownerProfits(q, ids, (await profitParts(q, null, to)).months);
  const before = to ? ` AND %s < (($2::date + 1) AT TIME ZONE 'Africa/Cairo')` : '';
  const cut = (col: string) => before.replace('%s', col);
  const rows = (await q.query(`SELECT e.id, e.full_name, COALESCE(o.pct, 0) AS pct,
      COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.kind = 'injection' AND r.status = 'posted' AND r.recorded_by = e.id${cut('r.occurred_at')}), 0) AS injected,
      COALESCE((SELECT sum(x.amount_egp) FROM cash_expenses x WHERE x.owner_draw_id = e.id AND x.status = 'posted'${cut('COALESCE(x.approved_at, x.occurred_at)')}), 0) AS drawn,
      COALESCE((SELECT sum(x.amount_egp) FROM cash_expenses x WHERE x.owner_draw_id = e.id AND x.status = 'pending_approval'${cut('x.occurred_at')}), 0) AS pending
      FROM employees e LEFT JOIN company_owners o ON o.employee_id = e.id WHERE e.id = ANY($1::uuid[]) ORDER BY COALESCE(o.pct, 0) DESC, e.full_name`,
    to ? [ids, to] : [ids])).rows;
  return {
    net,
    owners: rows.map((x) => {
      const injected = r2(Number(x.injected)), withdrawn = r2(Number(x.drawn)), pending = r2(Number(x.pending)), pct = Number(x.pct);
      const profit = net === null || !profits ? null : profits.get(x.id as string) ?? 0;
      return { id: x.id as string, name: x.full_name as string, pct, injected, profit, withdrawn, pending,
        book: profit === null ? null : r2(injected + profit - withdrawn), balance: profit === null ? null : r2(injected + profit - withdrawn - pending) };
    }),
  };
}

/**
 * Each owner's account (all months): what he injected + his share (نسبة الملكية) of the office's net profit
 * − what he already withdrew (approved) − what is waiting for approval = what he can still withdraw.
 */
export async function ownerAccounts(q: Q, a: Actor) {
  // F6: today's owners + anyone who held a share in a past month (his profit of those months stays his)
  const ids = [...new Set([...(await ownerIds(q)), ...(await ownerShareHistoryInstalled(q)
    ? (await q.query(`SELECT DISTINCT s.employee_id FROM company_owner_shares s JOIN employees e ON e.id = s.employee_id
                       WHERE s.pct > 0 AND e.status = 'active'`)).rows.map((x) => x.employee_id as string) : [])])];
  const { owners } = await ownerBalancesAt(q, a, ids, null);
  const out: Record<string, { injected: number; profit: number; withdrawn: number; pending: number; balance: number }> = {};
  for (const x of owners) {
    // without the office's profit in view it counts as 0 here (as it always did)
    const profit = x.profit ?? 0;
    out[x.id] = { injected: x.injected, profit, withdrawn: x.withdrawn, pending: x.pending, balance: r2(x.injected + profit - x.withdrawn - x.pending) };
  }
  return out;
}

async function cashOfficers(q: Q, exceptId?: string) {
  const r = await q.query(`
    SELECT DISTINCT e.id FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
     WHERE rp.perm_key = 'cash.office' AND e.status = 'active' AND ${notSettled('e')} AND e.id <> COALESCE($1::uuid, '00000000-0000-0000-0000-000000000000')`,
    [exceptId ?? null]);
  return r.rows.map((x) => x.id as string);
}

export async function hrOperators(q: Q, exceptId?: string) {
  const r = await q.query(`
    SELECT DISTINCT e.id FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
     WHERE rp.perm_key = 'cash.hr_operate' AND e.status = 'active' AND ${notSettled('e')} AND e.role_key <> 'owner'
       AND e.id <> COALESCE($1::uuid, '00000000-0000-0000-0000-000000000000')`, [exceptId ?? null]);
  return r.rows.map((x) => x.id as string);
}

const fmt = (n: number) => `${r2(n)} جنيه`;

export interface ReceiptInput {
  box: Box; recipientId: string; kind: string; amount: number; payerName: string; payerPhone: string; purpose: string;
  method: string; externalNo: string | null; notes: string; ref: string | null; att: Buffer | null; occurred: Date;
  saleId?: string | null; installmentId?: string | null; projectId?: string | null;
  /** a resale / rental commission (087): the deal and the side that paid it — only ever set by the brokerage module */
  brokerageDealId?: string | null; brokerageSide?: 'owner' | 'client' | null;
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
  if (att && !canAttachmentUpload(a)) throw forbidden('رفع صورة الإيصال محتاج صلاحية «رفع صور الإيصالات»');
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

/**
 * The retry of a form (same `clientRef`) gives back what the first send recorded — only to the person who sent it, and
 * only for the same operation on the same target (`same` checks the stored row: sale, installment, unit, cashbox, kind,
 * amount, …). Anything else presenting that reference — another user, another sale / box / operation, another amount —
 * gets a plain 409 `client_ref_reused` and nothing of the original row.
 * Concurrent identical sends are serialised on the reference (transaction-scoped advisory lock, no schema change): the
 * second one waits for the first to commit and then finds its row, instead of failing on UNIQUE(client_ref).
 */
export async function priorByClientRef(q: Q, table: 'cash_receipts' | 'cash_expenses', ref: string, actorId: string,
  same: (row: any) => boolean): Promise<{ id: string; ref_no: unknown } | null> {
  await q.query(`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, [`client_ref:${ref}`]);
  const dup = await one(q, `SELECT * FROM ${table} WHERE client_ref = $1`, [ref]);
  if (!dup) return null;
  if (dup.recorded_by !== actorId || !same(dup)) throw new AppError('conflict', 'رقم الطلب ده اتسجل لحركة تانية', { reason: 'client_ref_reused' });
  return { id: dup.id, ref_no: dup.ref_no };
}
/** the same amount, to the piaster */
export const sameAmount = (stored: unknown, sent: number) => Math.round(Number(stored) * 100) === Math.round(Number(sent) * 100);

/** Writes one numbered receipt (inside the caller's transaction); the same form sent twice gives the same receipt. */
export async function recordReceipt(q: Q, a: Actor, x: ReceiptInput): Promise<{ id: string; duplicate: boolean }> {
  if (x.ref) {
    const dup = await priorByClientRef(q, 'cash_receipts', x.ref, a.id, (r) => r.kind === x.kind && r.cashbox === x.box
      && r.actual_recipient_id === x.recipientId && sameAmount(r.amount_egp, x.amount) && r.ex_unit_id == null
      && (r.sale_id ?? null) === (x.saleId ?? null) && (r.installment_id ?? null) === (x.installmentId ?? null)
      && (r.project_id ?? null) === (x.projectId ?? null)
      && (r.brokerage_deal_id ?? null) === (x.brokerageDealId ?? null) && (r.brokerage_side ?? null) === (x.brokerageSide ?? null));
    if (dup) return { id: dup.id, duplicate: true };
  }
  const perm = x.box === 'hr' ? 'cash.hr_operate' : 'cash.office';
  const ok2 = await one(q, `SELECT 1 FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
                             WHERE e.id = $1 AND e.status = 'active' AND ${notSettled('e')} AND rp.perm_key = $2`, [x.recipientId, perm]);
  if (!ok2) throw invalid(x.box === 'hr' ? 'The recipient must be from HR' : 'The recipient must be the manager or the owner', { field: 'recipientId' });
  if (x.externalNo && await one(q, `SELECT 1 FROM cash_receipts WHERE lower(trim(external_no)) = lower(trim($1))`, [x.externalNo])) {
    throw new AppError('conflict', 'This receipt number was already recorded', { reason: 'duplicate_receipt' });
  }
  // the two brokerage columns exist only after 087 and are written only for a brokerage commission
  const deal = x.brokerageDealId ? `, brokerage_deal_id, brokerage_side` : '';
  const row = await one(q, `
    INSERT INTO cash_receipts (kind, amount_egp, cashbox, actual_recipient_id, payer_name, payer_phone, purpose, payment_method,
           external_no, client_ref, notes, attachment, occurred_at, recorded_by, sale_id, installment_id, project_id${deal})
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17${deal ? ',$18,$19' : ''}) RETURNING id, ref_no`,
    [x.kind, x.amount, x.box, x.recipientId, x.payerName, x.payerPhone, x.purpose, x.method, x.externalNo, x.ref, x.notes, x.att,
      x.occurred, a.id, x.saleId ?? null, x.installmentId ?? null, x.projectId ?? null,
      ...(deal ? [x.brokerageDealId, x.brokerageSide] : [])]);
  await audit(q, a.id, 'cash.receipt', 'cash_receipt', row.id, undefined,
    { kind: x.kind, amount: x.amount, cashbox: x.box, recipientId: x.recipientId, payerName: x.payerName, purpose: x.purpose,
      externalNo: x.externalNo, saleId: x.saleId ?? null, installmentId: x.installmentId ?? null });
  if (x.box === 'office' && x.recipientId !== a.id) {
    await notify(q, { to: x.recipientId, type: 'cash_receipt', title: `تحصيل باسمك: ${fmt(x.amount)}`,
      body: `${RECEIPT_KIND_AR[x.kind]} — ${x.payerName}`, entity: 'cash_receipt', entityId: row.id, dedupeKey: `cash:receipt:${row.id}` });
  }
  return { id: row.id, duplicate: false };
}

/** the signed receipts' photos and the printed receipt: permissions of their own (open before 066, as today) */
export const canAttachmentView = (a: Actor) => can(a, 'cash.attachment_view', null);
export const canAttachmentUpload = (a: Actor) => can(a, 'cash.attachment_upload', null);

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
    beneficiary: x.beneficiary, notes: x.notes, hasAttachment: x.has_attachment === true || !!x.attachment_file_id, occurredAt: x.occurred_at,
    recordedBy: x.recorded_by, recordedByName: x.recorded_by_name, status: x.status, approvedAt: x.approved_at,
    approvedByName: x.approved_by_name, rejectReason: x.reject_reason, reviewedAt: x.reviewed_at, reviewedByName: x.reviewed_by_name,
    reversedAt: x.reversed_at, reverseReason: x.reverse_reason, createdAt: x.created_at,
    paymentMethod: x.payment_method ?? 'cash', marketingCompanyId: x.marketing_company_id ?? null,
    fixedExpenseId: x.fixed_expense_id ?? null,
    // classification (086): metadata only — null = «غير مصنف»
    expenseGroupId: x.expense_group_id ?? null, expenseCategoryId: x.expense_category_id ?? null,
    expenseGroupName: x.expense_group_name ?? null, expenseCategoryName: x.expense_category_name ?? null,
  };
}

/**
 * The two sides of a transfer: خزنة المكتب (المالك / المدير العام: cash.office) and خزنة المحاسب (the accountant: cash.hr_operate
 * without cash.office). Someone with both counts as the office side; he acts for the accountant's box only when the company has
 * no accountant at all.
 */
async function hasHrDesk(q: Q) {
  return !!(await one(q, `SELECT 1 FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
     WHERE e.status = 'active' AND ${notSettled('e')} AND rp.perm_key = 'cash.hr_operate'
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
    receivedByName: x.received_by_name, receivedAt: x.received_at, hasAttachment: x.has_attachment === true,
    // in = the money comes INTO the viewer's box (green), out = it leaves it (red)
    flow: incoming ? 'in' : 'out',
    // what this person can do next
    can: {
      decide: toHr && x.status === 'requested' && office && can(a, 'cash.approve', 'cash.office') && x.requested_by !== a.id,
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
const EXPENSE_SELECT_BASE = `SELECT x.*, (x.attachment IS NOT NULL) AS has_attachment, rb.full_name AS recorded_by_name,
  ap.full_name AS approved_by_name, rv.full_name AS reviewed_by_name
  FROM cash_expenses x JOIN employees rb ON rb.id = x.recorded_by
  LEFT JOIN employees ap ON ap.id = x.approved_by LEFT JOIN employees rv ON rv.id = x.reviewed_by`;
/** with the group / category names once 086 runs (before it, exactly the old select) */
const EXPENSE_SELECT_CLS = EXPENSE_SELECT_BASE.replace(' FROM cash_expenses x ', `, eg.name AS expense_group_name, ec.name AS expense_category_name
  FROM cash_expenses x LEFT JOIN expense_groups eg ON eg.id = x.expense_group_id LEFT JOIN expense_categories ec ON ec.id = x.expense_category_id `);
async function expenseSelect(q: Q) { return (await classificationInstalled(q)) ? EXPENSE_SELECT_CLS : EXPENSE_SELECT_BASE; }
// R3: list screens never show the photo itself (only has_attachment), so the list queries read every column except the
// image. The column list comes from the table itself (once per process), so a column added by a later migration is
// still listed; the single-record reads (and the attachment routes) are unchanged.
const listCols = new Map<string, Promise<string>>();
function colsWithoutAttachment(q: Q, table: 'cash_receipts' | 'cash_expenses', alias: string): Promise<string> {
  const key = `${table}|${alias}`;
  let p = listCols.get(key);
  if (!p) {
    p = q.query(`SELECT string_agg($2 || '.' || quote_ident(attname), ', ' ORDER BY attnum) AS cols FROM pg_attribute
                  WHERE attrelid = $1::regclass AND attnum > 0 AND NOT attisdropped AND attname <> 'attachment'`, [table, alias])
      .then((r) => { const c = r.rows[0]?.cols; if (!c) throw new Error(`no columns for ${table}`); return c as string; });
    p.catch(() => listCols.delete(key));
    listCols.set(key, p);
  }
  return p;
}
export async function receiptListSelect(q: Q) {
  return RECEIPT_SELECT.replace('SELECT r.*,', `SELECT ${await colsWithoutAttachment(q, 'cash_receipts', 'r')},`);
}
async function expenseListSelect(q: Q) {
  // the 086-aware select (group / category names once 086 runs), without the photo column
  return (await expenseSelect(q)).replace('SELECT x.*,', `SELECT ${await colsWithoutAttachment(q, 'cash_expenses', 'x')},`);
}
const TRANSFER_SELECT = `SELECT t.*, rq.full_name AS requested_by_name, dc.full_name AS decided_by_name,
  ex.full_name AS executed_by_name, rc.full_name AS received_by_name,
  EXISTS (SELECT 1 FROM cash_attachments ca WHERE ca.entity = 'transfer' AND ca.entity_id = t.id) AS has_attachment
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
    if (!can(a, 'cash.owner_funds', 'cash.office')) throw forbidden('صفحة الضخ للمالك / المدير العام بس');
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
    // F6: the period's profit share with the share in force each month
    const periodProfit = (ov.result as any) ? await ownerProfits(db, owners.map((o) => o.id as string), (await profitParts(db, from, to)).months) : new Map<string, number>();
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
        injectedAllTime: r2(Number(o.all_time)), profit: periodProfit.get(o.id) ?? 0,
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
    if (!can(a, 'cash.owner_funds', 'cash.office')) throw forbidden();
    const b = obj(req.body);
    const amount = money(b);
    const method = oneOf(b, 'paymentMethod', ['cash', 'bank'] as const, true) ?? 'cash';
    const note = (str(b, 'note', { optional: true, max: 500 }) ?? '').trim();
    const ref = clientRef(b);
    const out = await db.tx(async (q) => {
      if (ref) {
        const dup = await priorByClientRef(q, 'cash_expenses', ref, a.id, (r) => r.owner_draw_id === a.id && r.cashbox === 'office'
          && r.payment_method === method && sameAmount(r.amount_egp, amount));
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
    if (!can(a, 'cash.owner_funds', 'cash.office')) throw forbidden();
    const b = obj(req.body);
    const list = Array.isArray(b.owners) ? b.owners : [];
    const parsed = list.map((x: any) => ({ id: String(x?.employeeId ?? ''), pct: Number(x?.pct) }));
    if (parsed.some((x) => !isUuid(x.id) || !Number.isFinite(x.pct) || x.pct < 0 || x.pct > 100)) throw invalid('راجع النسب', { field: 'owners' });
    if (parsed.reduce((t, x) => t + x.pct, 0) > 100.0001) throw invalid('مجموع النسب أكبر من 100٪', { field: 'owners' });
    await db.tx(async (q) => {
      const history = await ownerShareHistoryInstalled(q);
      for (const x of parsed) {
        if (!(await one(q, `SELECT 1 FROM employees WHERE id = $1`, [x.id]))) throw invalid('موظف مش موجود', { field: 'owners' });
        const before = await one(q, `SELECT pct FROM company_owners WHERE employee_id = $1`, [x.id]);
        await q.query(`INSERT INTO company_owners (employee_id, pct, updated_by, updated_at) VALUES ($1,$2,$3,$4)
                        ON CONFLICT (employee_id) DO UPDATE SET pct = EXCLUDED.pct, updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at`,
          [x.id, x.pct, a.id, clock()]);
        // F6: a changed share applies from this month on; earlier months keep the share they had (history, never edited)
        if (history && (!before || Number(before.pct) !== x.pct)) {
          await q.query(`INSERT INTO company_owner_shares (employee_id, pct, effective_from, created_by, created_at) VALUES ($1,$2,$3,$4,$5)
                          ON CONFLICT (employee_id, effective_from) DO UPDATE SET pct = EXCLUDED.pct, created_by = EXCLUDED.created_by, created_at = EXCLUDED.created_at`,
            [x.id, x.pct, local(clock()).date.slice(0, 7) + '-01', a.id, clock()]);
        }
      }
      await audit(q, a.id, 'cash.owners', 'company_owners', a.id, undefined, { owners: parsed });
    });
    return ok({ ok: true });
  });

  r.post('/cash/injections', async (req) => {
    const a = await authenticate(db, req);
    if (!can(a, 'cash.owner_funds', 'cash.office')) throw forbidden('الضخ للمالك / المدير العام بس');
    const b = obj(req.body);
    const target = oneOf(b, 'target', ['office', 'bank'] as const)! as 'office' | 'hr' | 'bank';
    const amount = money(b);
    const note = (str(b, 'note', { optional: true, max: 500 }) ?? '').trim();
    const ref = clientRef(b);
    const row = await db.tx(async (q) => {
      if (ref) {
        const dup = await priorByClientRef(q, 'cash_receipts', ref, a.id, (r) => r.kind === 'injection'
          && r.cashbox === (target === 'hr' ? 'hr' : 'office') && r.payment_method === (target === 'bank' ? 'bank_transfer' : 'cash')
          && sameAmount(r.amount_egp, amount));
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
    const q0 = req.query.get('cashbox') ?? 'hr';
    // «الكل»: both boxes together (only for whoever sees both)
    const all = q0 === 'all';
    if (all ? !(canSee(a, 'office') && canSee(a, 'hr')) : !BOXES.includes(q0 as Box) || !canSee(a, q0 as Box)) throw forbidden();
    const box = q0 as Box;
    const vals: unknown[] = all ? [['office', 'hr']] : [[box]];
    const where = ['l.cashbox = ANY($1::text[])'];
    const from = req.query.get('from'), to = req.query.get('to');
    if (from && /^\d{4}-\d{2}-\d{2}$/.test(from)) { vals.push(from); where.push(`l.at >= ($${vals.length}::date AT TIME ZONE 'Africa/Cairo')`); }
    if (to && /^\d{4}-\d{2}-\d{2}$/.test(to)) { vals.push(to); where.push(`l.at < (($${vals.length}::date + 1) AT TIME ZONE 'Africa/Cairo')`); }
    const rows = await db.query(`SELECT l.*, e.full_name AS by_name, pe.full_name AS to_name, p.kind AS payout_kind, p.period AS payout_period,
          t.direction AS transfer_direction, ex.full_name AS executed_by_name, rc.full_name AS received_by_name,
          (ca.entity_id IS NOT NULL) AS has_attachment
        FROM cash_ledger l LEFT JOIN employees e ON e.id = l.by_id
        LEFT JOIN payouts p ON l.source = 'payouts' AND p.id = l.source_id LEFT JOIN employees pe ON pe.id = p.employee_id
        LEFT JOIN cash_transfers t ON l.source = 'cash_transfers' AND t.id = l.source_id
        LEFT JOIN employees ex ON ex.id = t.executed_by LEFT JOIN employees rc ON rc.id = t.received_by
        LEFT JOIN cash_attachments ca ON ca.entity = CASE l.source WHEN 'payouts' THEN 'payout' WHEN 'cash_transfers' THEN 'transfer' END
                                     AND ca.entity_id = l.source_id
       WHERE ${where.join(' AND ')} ORDER BY l.at DESC LIMIT 1000`, vals);
    const totalIn = rows.rows.filter((x) => Number(x.amount) > 0).reduce((s, x) => s + Number(x.amount), 0);
    const totalOut = rows.rows.filter((x) => Number(x.amount) < 0).reduce((s, x) => s - Number(x.amount), 0);
    return ok({
      currency: 'EGP', cashbox: all ? 'all' : box, totals: { in: r2(totalIn), out: r2(totalOut) },
      entries: rows.rows.map((x) => ({
        amount: Number(x.amount), at: x.at, type: x.type, refNo: x.ref_no == null ? null : Number(x.ref_no),
        sourceId: x.source_id, source: x.source, label: x.label, byName: x.by_name, cashbox: x.cashbox,
        // صرف سلفة / قبض …: who got it
        toName: x.to_name ?? null, payoutKind: x.payout_kind ?? null, period: x.payout_period ?? null,
        direction: x.transfer_direction ?? null, executedByName: x.executed_by_name ?? null, receivedByName: x.received_by_name ?? null,
        hasAttachment: x.has_attachment === true,
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
    const rows = await db.query(`${await receiptListSelect(db)} WHERE ${where.join(' AND ')} ORDER BY r.occurred_at DESC, r.id LIMIT 500`, vals);
    return ok({ currency: 'EGP', receipts: rows.rows.map(shapeReceipt) });
  });

  r.post('/cash/receipts/:id/reverse', async (req) => {
    const a = await authenticate(db, req);
    if (!can(a, 'cash.reverse', 'cash.office')) throw forbidden('Only the manager or the owner can reverse a receipt');
    if (!isUuid(req.params.id)) throw notFound();
    const reason = str(obj(req.body), 'reason', { min: 3, max: 500 })!;
    await db.tx(async (q) => {
      const x = await one(q, `SELECT * FROM cash_receipts WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x) throw notFound();
      if (!canSee(a, x.cashbox)) throw notFound(); // only a receipt of a box he may see
      if (x.status !== 'posted') throw conflict('Already reversed');
      await q.query(`UPDATE cash_receipts SET status = 'reversed', reversed_by = $2, reversed_at = now(), reverse_reason = $3 WHERE id = $1`,
        [x.id, a.id, reason]);
      // a resale / rental commission (087): re-open the deal and cancel its entitlements — or refuse if a share was paid
      if (x.brokerage_deal_id) await onBrokerageReceiptReversed(q, x, a);
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
    const attFile = await storeAttachment(db, 'expense_attachment', att, 'receipt', a.id);
    if (att && !canAttachmentUpload(a)) throw forbidden('رفع صورة الإيصال محتاج صلاحية «رفع صور الإيصالات»');
    const occurred = when(b, 'occurredAt', clock());
    const method = oneOf(b, 'paymentMethod', ['cash', 'bank'] as const, true) ?? 'cash';
    const mkId = typeof b.marketingCompanyId === 'string' && isUuid(b.marketingCompanyId) ? b.marketingCompanyId : null;
    const out = await db.tx(async (q) => {
      if (mkId && !(await one(q, `SELECT 1 FROM marketing_companies WHERE id = $1`, [mkId]))) throw invalid('اختار شركة التسويق', { field: 'marketingCompanyId' });
      // a marketing company's money waits for the company's code once 084 runs (the same rule as «صرف» from its page)
      const companyOtp = !!mkId && await companyOtpInstalled(q);
      if (companyOtp) await companyForPayment(q, mkId!);
      if (ref) {
        const dup = await priorByClientRef(q, 'cash_expenses', ref, a.id, (r) => r.cashbox === box && r.owner_draw_id == null
          && sameAmount(r.amount_egp, amount) && r.category === category && r.payment_method === method
          && (r.marketing_company_id ?? null) === mkId);
        if (dup) return { id: dup.id, duplicate: true };
      }
      // optional group / category (086): metadata only — it changes nothing of the amount, approval or payment below
      const cls = (b.groupId || b.categoryId) && await classificationInstalled(q) ? await checkClassification(q, b.groupId, b.categoryId) : null;
      const s = await one(q, `SELECT expense_approval_threshold FROM company_settings LIMIT 1`);
      const threshold = Number(s?.expense_approval_threshold ?? 1000);
      // HR records directly; above the threshold the manager approves first. Office expenses are the manager's own.
      const needsApproval = box === 'hr' && !canOffice(a) && amount > threshold;
      const status = needsApproval ? 'pending_approval' : companyOtp ? 'awaiting_otp' : 'posted';
      const x = await one(q, ...withFile(`
        INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, notes, attachment, client_ref, occurred_at, recorded_by,
               status, approved_by, approved_at, payment_method, marketing_company_id)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) RETURNING id, ref_no, marketing_company_id, amount_egp`,
        [box, amount, category, reason, beneficiary, notes, att, ref, occurred, a.id,
          status, status === 'posted' ? a.id : null, status === 'posted' ? clock() : null, method, mkId], 'attachment', attFile));
      if (cls && (cls.groupId || cls.categoryId)) {
        await q.query(`UPDATE cash_expenses SET expense_group_id = $2, expense_category_id = $3 WHERE id = $1`, [x.id, cls.groupId, cls.categoryId]);
      }
      if (status === 'awaiting_otp') await tellCompany(q, x, a.fullName, category);
      await audit(q, a.id, 'cash.expense', 'cash_expense', x.id, undefined,
        { cashbox: box, amount, category, reason, beneficiary, status, threshold, ...(cls ? { groupId: cls.groupId, categoryId: cls.categoryId } : {}) });
      if (needsApproval) {
        for (const m of await cashOfficers(q, a.id)) {
          await notify(q, { to: m, type: 'cash_expense_awaiting', title: `مصروف محتاج موافقتك: ${fmt(amount)}`,
            body: `${category} — ${beneficiary}`, entity: 'cash_expense', entityId: x.id, dedupeKey: `cash:expense:${x.id}:awaiting` });
        }
      }
      return { id: x.id, duplicate: false };
    });
    const full = await one(db, `${await expenseSelect(db)} WHERE x.id = $1`, [out.id]);
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
    // classification filters (086): ?groupId= · ?categoryId= · ?unclassified=1
    if (await classificationInstalled(db)) {
      const g = req.query.get('groupId'), cId = req.query.get('categoryId');
      if (g && isUuid(g)) { vals.push(g); where.push(`x.expense_group_id = $${vals.length}`); }
      if (cId && isUuid(cId)) { vals.push(cId); where.push(`x.expense_category_id = $${vals.length}`); }
      if (req.query.get('unclassified') === '1') where.push(`x.expense_group_id IS NULL AND x.expense_category_id IS NULL AND x.ex_kind IS NULL AND x.sale_id IS NULL AND x.owner_draw_id IS NULL`);
    }
    const rows = await db.query(`${await expenseListSelect(db)} WHERE ${where.join(' AND ')} ORDER BY x.occurred_at DESC, x.id LIMIT 500`, vals);
    return ok({ currency: 'EGP', expenses: rows.rows.map(shapeExpense) });
  });

  // ------------------------------------------------------------------ مصروفات ثابتة
  const canBox = (a: Actor, box: string) => (box === 'office' ? canOffice(a) : hrDesk(a) || canOffice(a));
  // a fixed expense belongs to no cashbox: whoever presses «صرف» pays it from his own (المحاسب ← خزنة المحاسب، المدير ← خزنة المكتب)
  const canFixed = (a: Actor) => hrDesk(a) || canOffice(a);
  const ownBox = (a: Actor): 'hr' | 'office' => (hrDesk(a) ? 'hr' : 'office');
  const shapeFixed = (f: any) => ({ id: f.id, name: f.name, category: f.category, amount: Number(f.amount_egp), beneficiary: f.beneficiary,
    cashbox: f.cashbox, paymentMethod: f.payment_method, notes: f.notes, active: f.active,
    expenseGroupId: f.expense_group_id ?? null, expenseCategoryId: f.expense_category_id ?? null,
    paid: f.exp_id ? { expenseId: f.exp_id, cashbox: f.exp_box, status: f.exp_status, refNo: Number(f.exp_ref), hasAttachment: f.exp_att === true || !!f.exp_att_file } : null });

  r.get('/cash/fixed-expenses', async (req) => {
    const a = await authenticate(db, req);
    if (!canFixed(a)) throw forbidden();
    const m = req.query.get('month');
    const period = m && /^\d{4}-\d{2}$/.test(m) ? `${m}-01` : local(clock()).date.slice(0, 7) + '-01';
    const rows = await db.query(`
      SELECT f.*, x.id AS exp_id, x.cashbox AS exp_box, x.status AS exp_status, x.ref_no AS exp_ref, (x.attachment IS NOT NULL) AS exp_att, to_jsonb(x) ->> 'attachment_file_id' AS exp_att_file
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
      const b0 = obj(req.body);
      if (('groupId' in b0 || 'categoryId' in b0) && await classificationInstalled(q)) {
        const cls = await checkClassification(q, b0.groupId, b0.categoryId);
        Object.assign(row, (await one(q, `UPDATE fixed_expenses SET expense_group_id = $2, expense_category_id = $3 WHERE id = $1 RETURNING expense_group_id, expense_category_id`,
          [row.id, cls.groupId, cls.categoryId])));
      }
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
      const b0 = obj(req.body);
      if (('groupId' in b0 || 'categoryId' in b0) && await classificationInstalled(q)) {
        const cls = await checkClassification(q, b0.groupId, b0.categoryId);
        Object.assign(row, (await one(q, `UPDATE fixed_expenses SET expense_group_id = $2, expense_category_id = $3 WHERE id = $1 RETURNING expense_group_id, expense_category_id`,
          [o.id, cls.groupId, cls.categoryId])));
      }
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
      // the fixed expense's group / category (086) goes with each month's expense — metadata only
      if ((f.expense_group_id || f.expense_category_id) && await classificationInstalled(q)) {
        await q.query(`UPDATE cash_expenses SET expense_group_id = $2, expense_category_id = $3 WHERE id = $1`, [x.id, f.expense_group_id ?? null, f.expense_category_id ?? null]);
      }
      await audit(q, a.id, 'cash.fixed_expense.pay', 'cash_expense', x.id, undefined, { fixedExpenseId: f.id, period, amount, cashbox: box });
      if (needsApproval) {
        for (const o of await cashOfficers(q, a.id)) {
          await notify(q, { to: o, type: 'cash_expense_awaiting', title: `مصروف ثابت محتاج موافقتك: ${fmt(amount)}`, body: `${f.name} — ${f.beneficiary}`,
            entity: 'cash_expense', entityId: x.id, dedupeKey: `cash:expense:${x.id}:awaiting` });
        }
      }
      return x;
    });
    const full = await one(db, `${await expenseSelect(db)} WHERE x.id = $1`, [out.id]);
    return ok({ expense: shapeExpense(full) }, 201);
  });

  /** The signed receipt's photo, added after the beneficiary signs (once). */
  r.post('/cash/expenses/:id/attachment', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const att = attachment(obj(req.body));
    if (!att) throw invalid('ارفع صورة الإيصال', { field: 'attachment' });
    const fileId = await storeAttachment(db, 'expense_attachment', att, 'receipt', a.id);
    await db.tx(async (q) => {
      const x = await one(q, `SELECT id, cashbox, recorded_by, attachment IS NOT NULL ${fileId ? 'OR attachment_file_id IS NOT NULL' : ''} AS has FROM cash_expenses WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!x) throw notFound();
      if (!canBox(a, x.cashbox) || !canAttachmentUpload(a)) throw forbidden();
      if (fileId) await q.query(`UPDATE cash_expenses SET attachment = NULL, attachment_file_id = $2 WHERE id = $1`, [x.id, fileId]);
      else await q.query(`UPDATE cash_expenses SET attachment = $2 WHERE id = $1`, [x.id, att]);
      await audit(q, a.id, 'cash.expense.attachment', 'cash_expense', x.id, undefined, { replaced: x.has });
    });
    return ok({ ok: true });
  });

  r.get('/cash/expenses/:id/attachment', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const x = await one(db, `SELECT * FROM cash_expenses WHERE id = $1`, [req.params.id]);
    if (!x || (!x.attachment && !x.attachment_file_id)) throw notFound();
    if (!canSee(a, x.cashbox) || !canAttachmentView(a)) throw forbidden();
    return ok({ attachment: (await readFileBytes(db, x.attachment, x.attachment_file_id)).toString('base64') });
  });

  // ------------------------------------------------------------------ نقل من البنك إلى خزنة المكتب
  r.get('/cash/bank-moves', async (req) => {
    const a = await authenticate(db, req);
    if (!can(a, 'cash.bank_view', 'cash.office') || !canOffice(a)) throw forbidden();
    const rows = await db.query(`SELECT m.*, e.full_name AS by_name FROM cash_bank_moves m JOIN employees e ON e.id = m.created_by
                                  ORDER BY m.created_at DESC LIMIT 200`);
    return ok({ moves: rows.rows.map((m) => ({ id: m.id, refNo: Number(m.ref_no), cashbox: m.cashbox, direction: m.direction,
      amount: Number(m.amount_egp), note: m.note, at: m.created_at, byName: m.by_name })) });
  });

  /** بين البنك والنقدي في خزنة المكتب: نقل من البنك للخزنة، أو توريد كاش للبنك — the box's total stays the same. */
  r.post('/cash/bank-moves', async (req) => {
    const a = await authenticate(db, req);
    if (!can(a, 'cash.bank_transfer', 'cash.office') || !canOffice(a)) throw forbidden('نقل الفلوس بين البنك والخزنة للمالك / المدير العام');
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
    if (!can(a, 'cash.approve', 'cash.office')) throw forbidden();
    const b = obj(req.body);
    const decision = oneOf(b, 'decision', ['approve', 'reject'] as const)!;
    const reason = decision === 'reject' ? str(b, 'reason', { min: 3, max: 500 })! : null;
    await expenseStep(req.params.id, a, async (q, x) => {
      if (x.status !== 'pending_approval') throw conflict('This expense is not waiting for approval');
      if (x.recorded_by === a.id) throw forbidden('You cannot approve your own expense');
      if (x.owner_draw_id && !(await ownerIds(q)).includes(a.id)) throw forbidden('سحب الأرباح يوافق عليه مالك تاني');
      if (decision === 'approve' && x.marketing_company_id && await companyOtpInstalled(q)) {
        // approved, and now waits for the company's code (posted — out of the cashbox — when the payer enters it)
        await q.query(`UPDATE cash_expenses SET status = 'awaiting_otp', approved_by = $2, reviewed_by = $2, reviewed_at = now() WHERE id = $1`, [x.id, a.id]);
        const payer = await one(q, `SELECT full_name FROM employees WHERE id = $1`, [x.recorded_by]);
        await tellCompany(q, x, payer?.full_name ?? '', x.category);
      } else if (decision === 'approve') {
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
    if (!can(a, 'cash.approve', 'cash.office')) throw forbidden();
    await expenseStep(req.params.id, a, async (q, x) => {
      if (x.reviewed_at) return;
      await q.query(`UPDATE cash_expenses SET reviewed_by = $2, reviewed_at = now() WHERE id = $1`, [x.id, a.id]);
      await audit(q, a.id, 'cash.expense.review', 'cash_expense', x.id, undefined, { reviewed: true });
    });
    return ok({ ok: true });
  });

  r.post('/cash/expenses/:id/reverse', async (req) => {
    const a = await authenticate(db, req);
    if (!can(a, 'cash.reverse', 'cash.office')) throw forbidden('Only the manager or the owner can reverse an expense');
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
    const x = await one(db, `SELECT * FROM ${t} WHERE id = $1`, [req.params.id]);
    if (!x || (!x.attachment && !x.attachment_file_id)) throw notFound();
    // the one who recorded it, or who sees that cashbox and its receipts' photos
    if (x.recorded_by !== a.id && !(canSee(a, x.cashbox) && canAttachmentView(a))) throw forbidden();
    return ok({ attachment: (await readFileBytes(db, x.attachment, x.attachment_file_id)).toString('base64') });
  });

  // ------------------------------------------------------------------ صورة الإيصال الموقّع: transfers and payouts
  async function attachmentAccess(a: Actor, entity: string, id: string, write: boolean) {
    if (!['transfer', 'payout'].includes(entity) || !isUuid(id)) throw notFound();
    const photo = write ? canAttachmentUpload(a) : canAttachmentView(a);
    if (entity === 'transfer') {
      if (!(await one(db, `SELECT 1 FROM cash_transfers WHERE id = $1`, [id]))) throw notFound();
      if (!canHrView(a) && !canOffice(a)) throw forbidden();
      if (write && !canHrOperate(a) && !canOffice(a)) throw forbidden();
      if (!photo) throw forbidden();
      return;
    }
    const p = await one(db, `SELECT employee_id, created_by FROM payouts WHERE id = $1`, [id]);
    if (!p) throw notFound();
    const staff = canHrOperate(a) || canOffice(a) || has(a, 'finance.disburse');
    // the employee always sees the receipt of what he was paid; the staff with the receipts' photos permission
    if (!(staff && photo) && !(p.employee_id === a.id && !write)) throw forbidden();
  }
  r.get('/cash/attachments/:entity/:id', async (req) => {
    const a = await authenticate(db, req);
    await attachmentAccess(a, req.params.entity, req.params.id, false);
    const x = await one(db, `SELECT * FROM cash_attachments WHERE entity = $1 AND entity_id = $2`, [req.params.entity, req.params.id]);
    if (!x) throw notFound();
    return ok({ attachment: (await readFileBytes(db, x.attachment, x.attachment_file_id)).toString('base64') });
  });
  r.post('/cash/attachments/:entity/:id', async (req) => {
    const a = await authenticate(db, req);
    await attachmentAccess(a, req.params.entity, req.params.id, true);
    const b = obj(req.body);
    const raw = String(b.attachment ?? '');
    if (raw.length > 1_000_000) throw invalid('الصورة كبيرة — اختار صورة أصغر', { field: 'attachment' });
    const buf = imageAttachment(raw, 'attachment', 700_000, 'الصورة مش واضحة');
    if (buf.length < 100) throw invalid('الصورة مش واضحة', { field: 'attachment' });
    const fileId = await storeAttachment(db, 'cash_attachment', buf, 'receipt', a.id);
    await db.query(...withFile(`INSERT INTO cash_attachments (entity, entity_id, attachment, updated_by, updated_at) VALUES ($1,$2,$3,$4,$5)
                    ON CONFLICT (entity, entity_id) DO UPDATE SET attachment = EXCLUDED.attachment, updated_by = EXCLUDED.updated_by,
                      updated_at = EXCLUDED.updated_at`, [req.params.entity, req.params.id, buf, a.id, clock()], 'attachment', fileId));
    await audit(db, a.id, 'cash.attachment', req.params.entity, req.params.id, undefined, { bytes: buf.length });
    return ok({ ok: true });
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
    if (!can(a, 'cash.approve', 'cash.office') || !canOffice(a)) throw forbidden();
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
      if (x.requested_by !== a.id || (!canHrOperate(a) && !canOffice(a))) throw forbidden();
      if (!['requested', 'approved'].includes(x.status)) throw conflict('This transfer can no longer be cancelled');
      await q.query(`UPDATE cash_transfers SET status = 'cancelled' WHERE id = $1`, [x.id]);
      await audit(q, a.id, 'cash.transfer.cancel', 'cash_transfer', x.id, { status: x.status }, { status: 'cancelled' });
    });
    return ok({ ok: true });
  });
};
