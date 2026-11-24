import { createHash, randomInt } from 'node:crypto';
import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { isUuid, num, obj, oneOf, str } from '../http/validate.ts';
import { adminOfficerSql, audit, authenticate, can, type Actor } from '../auth/context.ts';
import { holdersOf, notify } from './notify.ts';
import { local } from '../lib/time.ts';
import { canHrOperate, canOffice, parseReceipt, recordReceipt, type ReceiptInput } from './cash.ts';
import { leadForReservation } from './leads.ts';

/**
 * Resale (إعادة بيع) and rental (إيجار) under «التسويق» — PROPOSED migration 087; until it runs every route answers
 * installed:false / 409 brokerage_not_installed and nothing else in the system changes.
 *
 *  - The sales employee registers the deal and PROPOSES the commission: resale 1 % – 2.5 % of the price, paid by the
 *    owner (seller), the client (buyer) or both; rental one month from the owner / from the tenant / half from each /
 *    a fixed amount (each side's own). The property contributor and the closing salesperson are recorded separately.
 *  - The general manager (brokerage.approve, else commission.approve) approves the agreement and its DISTRIBUTION —
 *    contributor, closer, sales manager, other beneficiaries, each a percentage or a fixed amount, never more than the
 *    commission (the office keeps the rest). Nobody approves a deal he proposed or takes a share of. From then on the
 *    agreement and distribution are frozen (database trigger) and kept as an immutable snapshot.
 *  - Office revenue only when COLLECTED: each side's commission is received into a cashbox as a 'commission' receipt
 *    (numbered, idempotent by clientRef); the rest is a receivable, never cash. Once all of it is collected each employee
 *    share becomes a commission entitlement of that month (payroll / «صرف العمولة» — paid once, like every commission).
 *  - Every step is in the audit log.
 */

const r2 = (n: number) => Math.round(n * 100) / 100;
const N = (v: unknown) => Number(v ?? 0);
const cents = (n: number) => Math.round(n * 100);
const ARR = ['owner_month', 'client_month', 'half_each', 'fixed'] as const;
const ROLES = ['contributor', 'closer', 'sales_manager', 'other'] as const;

export async function brokerageInstalled(q: Q) {
  return !!(await one(q, `SELECT to_regclass('public.brokerage_deals') IS NOT NULL AS ok`))?.ok;
}
async function needInstalled(q: Q) {
  if (!(await brokerageInstalled(q))) {
    throw new AppError('conflict', 'الإعادة بيع والإيجار محتاجين تحديث قاعدة البيانات (087) — مستني موافقة المالك', { reason: 'brokerage_not_installed' });
  }
}
const canApprove = (a: Actor) => can(a, 'brokerage.approve', 'commission.approve');
const canViewAll = (a: Actor) => can(a, 'brokerage.view_all', 'commission.approve') || canOffice(a);
const canCollect = (a: Actor) => canOffice(a) || canHrOperate(a);
/** «إضافة» a deal: the owner's choice (2026-11-23) — everyone who works these pages adds deals (the sales people, the GM,
 * the admin officer, the cashbox holders); nobody still approves a deal he proposed or takes a share of */
const canPropose = (a: Actor) => can(a, 'brokerage.propose', 'exclusive.reserve') || canApprove(a) || canViewAll(a) || canCollect(a);

/** the commission each side pays, from the proposed terms */
export function commissionTerms(kind: 'resale' | 'rental', b: Record<string, unknown>) {
  const price = num(b, 'price', { min: 1, max: 10_000_000_000 })!;
  if (kind === 'resale') {
    const rate = num(b, 'ratePct', { min: 0, max: 100 })!;
    if (rate < 1 || rate > 2.5) throw invalid('نسبة عمولة إعادة البيع بين 1٪ و 2.5٪', { field: 'ratePct' });
    const total = r2(price * rate / 100);
    const paidBy = oneOf(b, 'paidBy', ['owner', 'client', 'both'] as const)!;
    let owner = paidBy === 'owner' ? total : paidBy === 'client' ? 0 : num(b, 'ownerAmount', { min: 0, max: total })!;
    owner = r2(owner);
    return { price, rate, arrangement: 'percent', owner, client: r2(total - owner) };
  }
  const arrangement = oneOf(b, 'arrangement', ARR)!;
  let owner = 0, client = 0;
  if (arrangement === 'owner_month') owner = price;
  else if (arrangement === 'client_month') client = price;
  else if (arrangement === 'half_each') { owner = r2(price / 2); client = r2(price - owner); }
  else {
    owner = num(b, 'ownerAmount', { min: 0, max: 10_000_000_000, optional: true }) ?? 0;
    client = num(b, 'clientAmount', { min: 0, max: 10_000_000_000, optional: true }) ?? 0;
  }
  if (cents(owner) + cents(client) <= 0) throw invalid('العمولة لازم تكون أكبر من صفر', { field: 'ownerAmount' });
  return { price, rate: null, arrangement, owner: r2(owner), client: r2(client) };
}

/** the approved distribution: amounts from percentages / fixed values, validated against the commission */
export function distribution(total: number, list: unknown[], deal: { contributor_id: string; closer_id: string; sales_manager_id: string | null }) {
  if (!Array.isArray(list) || !list.length || list.length > 12) throw invalid('حدد المستفيدين (من 1 لـ 12)', { field: 'shares' });
  const out = list.map((x0, i) => {
    const x = obj(x0);
    const role = oneOf(x, 'role', ROLES)!;
    const employeeId = typeof x.employeeId === 'string' && x.employeeId ? x.employeeId : null;
    if (employeeId && !isUuid(employeeId)) throw invalid('موظف غير صحيح', { field: `shares.${i}.employeeId` });
    const beneficiary = (str(x, 'beneficiary', { optional: true, max: 120 }) ?? '').trim();
    const must = role === 'contributor' ? deal.contributor_id : role === 'closer' ? deal.closer_id : role === 'sales_manager' ? deal.sales_manager_id : null;
    if (role !== 'other' && (!must || employeeId !== must)) throw invalid('المستفيد لازم يكون صاحب الدور المسجل في الصفقة', { field: `shares.${i}.employeeId` });
    if (!employeeId && beneficiary.length < 2) throw invalid('اسم المستفيد', { field: `shares.${i}.beneficiary` });
    const mode = oneOf(x, 'mode', ['pct', 'fixed'] as const)!;
    const value = num(x, 'value', { min: 0.0001, max: 10_000_000_000 })!;
    if (mode === 'pct' && value > 100) throw invalid('النسبة أكبر من 100٪', { field: `shares.${i}.value` });
    const amount = r2(mode === 'pct' ? total * value / 100 : value);
    if (amount <= 0) throw invalid('نصيب المستفيد لازم يكون أكبر من صفر', { field: `shares.${i}.value` });
    return { role, employeeId, beneficiary, mode, value, amount };
  });
  const sum = out.reduce((t, x) => t + cents(x.amount), 0);
  if (sum > cents(total)) throw invalid(`التوزيع (${sum / 100}) أكبر من العمولة (${total})`, { field: 'shares', reason: 'over_distributed' });
  const ids = out.filter((x) => x.employeeId).map((x) => `${x.role}:${x.employeeId}`);
  if (new Set(ids).size !== ids.length) throw invalid('نفس المستفيد متكرر لنفس الدور', { field: 'shares' });
  return { shares: out, distributed: r2(sum / 100), office: r2((cents(total) - sum) / 100) };
}

async function employee(q: Q, id: unknown, field: string, optional = false) {
  if (id == null || id === '') { if (optional) return null; throw invalid('اختار الموظف', { field }); }
  if (typeof id !== 'string' || !isUuid(id)) throw invalid('موظف غير صحيح', { field });
  const e = await one(q, `SELECT id FROM employees WHERE id = $1 AND status = 'active'`, [id]);
  if (!e) throw invalid('موظف غير صحيح', { field });
  return id;
}

/**
 * A commission receipt of a deal was reversed (same transaction as the reversal): refused while any share was already
 * paid out (an employee commission payout, or an outside beneficiary's settlement) — the money went on, the reversal must
 * not leave it unbacked. Otherwise a collected deal is re-opened (approved) and its employee entitlements are cancelled,
 * so they can no longer be paid or counted in payroll; collecting again re-activates the same entitlements.
 */
export async function onBrokerageReceiptReversed(q: Q, receipt: { id: string; brokerage_deal_id?: string | null }, a: Actor) {
  if (!receipt.brokerage_deal_id) return;
  const d = await one(q, `SELECT * FROM brokerage_deals WHERE id = $1 FOR UPDATE`, [receipt.brokerage_deal_id]);
  if (!d) return;
  const paid = await one(q, `
    SELECT 1 FROM brokerage_shares s
     WHERE s.deal_id = $1 AND (
       EXISTS (SELECT 1 FROM commission_entitlements ce JOIN payouts po ON po.commission_entitlement_id = ce.id AND po.status <> 'cancelled'
                WHERE ce.brokerage_share_id = s.id)
       OR EXISTS (SELECT 1 FROM cash_expenses x WHERE x.brokerage_share_id = s.id AND x.status <> 'reversed'))
     LIMIT 1`, [d.id]);
  if (paid) {
    throw new AppError('conflict', 'نصيب من عمولة الصفقة دي اتصرف — إلغاء الصرف الأول قبل عكس التحصيل', { reason: 'brokerage_shares_paid' });
  }
  const ents = (await q.query(`
    UPDATE commission_entitlements SET status = 'cancelled', cancelled_at = now()
     WHERE status = 'active' AND brokerage_share_id IN (SELECT id FROM brokerage_shares WHERE deal_id = $1) RETURNING id`, [d.id])).rows;
  if (d.status === 'collected') {
    await q.query(`UPDATE brokerage_deals SET status = 'approved', collected_at = NULL, updated_at = now() WHERE id = $1`, [d.id]);
  }
  await audit(q, a.id, 'brokerage.reopen', 'brokerage_deal', d.id, { status: d.status },
    { status: d.status === 'collected' ? 'approved' : d.status, reversedReceipt: receipt.id, cancelledEntitlements: ents.map((x) => x.id) });
  await syncListing(q, d.id);
}


/** approve a proposed deal with its distribution (shares written once, an immutable snapshot) — same transaction */
async function approveDeal(q: Q, a: Actor, d: any, sharesIn: unknown[], note: string, now: Date) {
  const total = N(d.total_commission_egp);
  const dist = distribution(total, sharesIn, d);
  if (dist.shares.some((s) => s.employeeId === a.id)) throw forbidden('مينفعش تعتمد توزيع ليك نصيب فيه');
  for (const s of dist.shares) {
    if (s.employeeId) await employee(q, s.employeeId, 'shares');
    await q.query(`INSERT INTO brokerage_shares (deal_id, role, employee_id, beneficiary, mode, value, amount_egp, created_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
      [d.id, s.role, s.employeeId, s.beneficiary, s.mode, s.value, s.amount, now]);
  }
  const snapshot = {
    kind: d.kind, property: d.property, owner: d.owner_name, client: d.client_name, price: N(d.price_egp), ratePct: d.rate_pct == null ? null : N(d.rate_pct),
    arrangement: d.arrangement, commission: { owner: N(d.owner_commission_egp), client: N(d.client_commission_egp), total },
    contributor: d.contributor_id, closer: d.closer_id, salesManager: d.sales_manager_id, proposedBy: d.proposed_by,
    shares: dist.shares, distributed: dist.distributed, office: dist.office, approvedBy: a.id, approvedAt: now.toISOString(), note,
  };
  await q.query(`UPDATE brokerage_deals SET status = 'approved', decided_by = $2, decided_at = $3, decision_note = $4, snapshot = $5, updated_at = $3 WHERE id = $1`,
    [d.id, a.id, now, note, JSON.stringify(snapshot)]);
  await audit(q, a.id, 'brokerage.approve', 'brokerage_deal', d.id, { status: 'proposed' }, snapshot);
}

/** the commission received from one side into a cashbox; all of it in → collected, employee shares → entitlements */
async function collectSide(q: Q, a: Actor, d: any, side: 'owner' | 'client', b: Record<string, unknown>, at: Date) {
  const input = parseReceipt({ ...b, kind: 'commission', payerName: b.payerName || (side === 'owner' ? d.owner_name : d.client_name),
    payerPhone: b.payerPhone ?? (side === 'owner' ? d.owner_phone : d.client_phone),
    purpose: `عمولة ${d.kind === 'resale' ? 'إعادة بيع' : 'إيجار'} — ${d.property} (${side === 'owner' ? 'المالك' : d.kind === 'resale' ? 'المشتري' : 'المستأجر'})` }, a, at);
  if (input.ref) {
    const prior = await one(q, `SELECT id FROM cash_receipts WHERE client_ref = $1`, [input.ref]);
    if (prior) { const rec = await recordReceipt(q, a, { ...input, brokerageDealId: d.id, brokerageSide: side }); return { id: rec.id, duplicate: rec.duplicate }; }
  }
  if (d.status !== 'approved') throw conflict(d.status === 'collected' ? 'العمولة اتحصلت بالكامل' : 'الصفقة لسه مش معتمدة');
  const due = N(side === 'owner' ? d.owner_commission_egp : d.client_commission_egp);
  const got = N((await one(q, `SELECT COALESCE(sum(amount_egp), 0) s FROM cash_receipts WHERE brokerage_deal_id = $1 AND brokerage_side = $2 AND status = 'posted'`, [d.id, side])).s);
  if (cents(input.amount) > cents(due) - cents(got)) {
    throw new AppError('unprocessable', `الباقي من الطرف ده ${r2(due - got)}`, { reason: 'over_collect', remaining: r2(due - got) });
  }
  const rec = await recordReceipt(q, a, { ...input, brokerageDealId: d.id, brokerageSide: side });
  await audit(q, a.id, 'brokerage.collect', 'brokerage_deal', d.id, undefined, { side, amount: input.amount, receiptId: rec.id });
  await closeIfCollected(q, a, d, at);
  return { id: rec.id, duplicate: rec.duplicate };
}

/** an APPROVED deal whose commission is all in → closed, and every employee share becomes a commission entitlement of this
 *  month (after a collection — or after the split of a commission already handed over against the recipient's code, 090) */
async function closeIfCollected(q: Q, a: Actor, d: any, at: Date) {
  const all = N((await one(q, `SELECT COALESCE(sum(amount_egp), 0) s FROM cash_receipts WHERE brokerage_deal_id = $1 AND status = 'posted'`, [d.id])).s);
  if (cents(all) >= cents(N(d.total_commission_egp))) {
    const now = at; const period = local(now).date.slice(0, 7) + '-01';
    await q.query(`UPDATE brokerage_deals SET status = 'collected', collected_at = $2, updated_at = $2 WHERE id = $1`, [d.id, now]);
    await q.query(`
      INSERT INTO commission_entitlements (request_id, brokerage_share_id, employee_id, role, amount_egp, period, included_at, created_at)
      SELECT NULL, s.id, s.employee_id, CASE WHEN s.role = 'sales_manager' THEN 'manager' ELSE 'sales' END, s.amount_egp, $2, $3, $3
        FROM brokerage_shares s WHERE s.deal_id = $1 AND s.employee_id IS NOT NULL
      ON CONFLICT (brokerage_share_id) DO UPDATE SET status = 'active', cancelled_at = NULL, period = EXCLUDED.period,
             included_at = EXCLUDED.included_at, amount_egp = EXCLUDED.amount_egp
       WHERE commission_entitlements.status = 'cancelled'`, [d.id, period, now]);
    await audit(q, a.id, 'brokerage.collected', 'brokerage_deal', d.id, { status: 'approved' }, { status: 'collected', period });
    await syncListing(q, d.id);
    await leadFromDeal(q, d.id, 'collected', a.id, now);
  }
}

// ------------------------------------------------------------------ listings (088): a property offered for resale / rent
export const FINISHING = { none: 'بدون تشطيب', semi: 'نص تشطيب', full: 'تشطيب كامل', super_lux: 'سوبر لوكس', ultra_super_lux: 'الترا سوبر لوكس' } as const;
const FIN_KEYS = Object.keys(FINISHING) as (keyof typeof FINISHING)[];
const MAX_PHOTOS = 8;

export async function listingsInstalled(q: Q) {
  return !!(await one(q, `SELECT to_regclass('public.brokerage_listings') IS NOT NULL AS ok`))?.ok;
}
async function needListings(q: Q) {
  if (!(await listingsInstalled(q))) {
    throw new AppError('conflict', 'عرض العقارات محتاج تحديث قاعدة البيانات (088)', { reason: 'listings_not_installed' });
  }
}
/** the «مسؤول إداري» (by position, whatever its key) */
async function isAdminOfficer(q: Q, id: string) {
  return !!(await one(q, `SELECT ${adminOfficerSql('e')} AS ao FROM employees e WHERE e.id = $1 AND e.status = 'active'`, [id]))?.ao;
}
/** who receives a listing sale's commission and sets its split: the administrative officer (or an approver) holding a cashbox */
async function canReceive(q: Q, a: Actor) {
  return canCollect(a) && (canApprove(a) || await isAdminOfficer(q, a.id));
}

// ------------------------------------------------------------------ 090: the commission handed over against the recipient's code
export async function handoverInstalled(q: Q) {
  return !!(await one(q, `SELECT 1 FROM information_schema.columns
                           WHERE table_schema = 'public' AND table_name = 'brokerage_deals' AND column_name = 'handover_to'`));
}
async function needHandover(q: Q) {
  if (!(await handoverInstalled(q))) {
    throw new AppError('conflict', 'تسليم العمولة بالكود محتاج تحديث قاعدة البيانات (090)', { reason: 'handover_not_installed' });
  }
}
/** who can receive a seller's commission: the general manager (or the owner), the accountant or an administrative officer —
 *  holding the office cashbox (the receipt is written in his name; cash.ts refuses anyone else) — never the seller himself */
async function handoverRecipients(q: Q, exclude: string) {
  return (await q.query(`
    SELECT e.id, e.full_name AS name,
           CASE WHEN e.role_key IN ('manager', 'owner') THEN 'general_manager' WHEN e.role_key = 'accountant' THEN 'accountant'
                ELSE 'admin_officer' END AS role
      FROM employees e
     WHERE e.status = 'active' AND (e.legacy_fields->>'status') IS DISTINCT FROM 'تم التصفيه' AND e.id <> $1
       AND (e.role_key IN ('manager', 'owner', 'accountant') OR ${adminOfficerSql('e')})
       AND EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_key = COALESCE(e.position_key, e.role_key) AND rp.perm_key = 'cash.office')
     ORDER BY e.full_name`, [exclude])).rows as { id: string; name: string; role: string }[];
}
/** the same rules as a payout's code (payouts.ts): only a hash is kept; a new code ends the previous one; 5 wrong tries end a
 *  code; 15 wrong tries in an hour stop the deal for an hour; at most 5 codes in 15 minutes */
const HANDOVER_OTP_TTL_MIN = Math.min(30, Math.max(2, Number(process.env.PAYOUT_OTP_TTL_MIN ?? 10) || 10));
const handoverAction = (id: string) => `brokerage:${id}`;
const handoverHash = (recipient: string, id: string, code: string) =>
  createHash('sha256').update(`${recipient}:${handoverAction(id)}:${code}`).digest('hex');
/** a listing follows its deal: waiting → pending, collected → sold, rejected / cancelled → available again */
async function syncListing(q: Q, dealId: string) {
  if (!(await listingsInstalled(q))) return;
  await q.query(`
    UPDATE brokerage_listings l SET status = CASE WHEN d.status IN ('proposed', 'approved') THEN 'pending'
                                                  WHEN d.status = 'collected' THEN 'sold' ELSE 'available' END, updated_at = now()
      FROM brokerage_deals d WHERE d.id = $1 AND d.listing_id = l.id AND l.status <> 'withdrawn'`, [dealId]);
}
function listingFields(b: Record<string, unknown>, partial = false) {
  const o = { optional: partial };
  const f: Record<string, unknown> = {};
  const t = str(b, 'title', { ...o, min: 2, max: 160 }); if (t != null) f.title = t.trim();
  const ad = str(b, 'address', { ...o, min: 2, max: 300 }); if (ad != null) f.address = ad.trim();
  const ar = num(b, 'area', { ...o, min: 1, max: 1_000_000 }); if (ar != null) f.area_m2 = ar;
  const pr = num(b, 'price', { ...o, min: 1, max: 10_000_000_000 }); if (pr != null) f.price_egp = pr;
  const fi = oneOf(b, 'finishing', FIN_KEYS, partial); if (fi != null) f.finishing = fi;
  const de = str(b, 'description', { optional: true, max: 3000 }); if (de != null) f.description = de.trim();
  const on = str(b, 'ownerName', { optional: true, max: 120 }); if (on != null) f.owner_name = on.trim();
  const op = str(b, 'ownerPhone', { optional: true, max: 30 }); if (op != null) f.owner_phone = op.trim();
  return f;
}
function photoInput(b: Record<string, unknown>) {
  const mime = oneOf(b, 'mime', ['image/jpeg', 'image/png', 'image/webp'] as const)!;
  const data = str(b, 'image', { min: 16, max: 1_400_000 })!;
  if (!/^[A-Za-z0-9+/=]+$/.test(data)) throw invalid('الصورة مش سليمة', { field: 'image' });
  return { mime, data };
}

/** 089: brokerage_deals.lead_id exists */
async function dealLeadInstalled(q: Q) {
  return !!(await one(q, `SELECT 1 AS ok FROM information_schema.columns WHERE table_name = 'brokerage_deals' AND column_name = 'lead_id'`))?.ok;
}
/**
 * A sale / rental made from a lead: the lead follows its deal like a project unit's reservation — sold → «حجز» (waiting for
 * the commission), the commission received → «صفقة مكتملة», cancelled / rejected → «متابعة» (follow up tomorrow).
 * Each step is a system action on the lead.
 */
async function leadFromDeal(q: Q, dealId: string, event: 'sold' | 'collected' | 'cancel', byId: string | null, now: Date) {
  if (!(await dealLeadInstalled(q))) return;
  const d = await one(q, `SELECT d.id, d.kind, d.lead_id, d.price_egp, COALESCE(l.title, d.property) AS title FROM brokerage_deals d LEFT JOIN brokerage_listings l ON l.id = d.listing_id
                           WHERE d.id = $1`, [dealId]);
  if (!d?.lead_id) return;
  const lead = await one(q, `SELECT id, stage FROM leads WHERE id = $1 FOR UPDATE`, [d.lead_id]);
  if (!lead || (lead.stage === 'done_deal' && event !== 'collected')) return;
  const what = d.kind === 'rental' ? 'إيجار' : 'بيع';
  const text = {
    sold: `${what} عقار «${d.title ?? ''}» بـ ${N(d.price_egp).toLocaleString('en-US')} ج — مستني استلام العمولة`,
    collected: `تم ${what === 'إيجار' ? 'تأجير' : 'بيع'} عقار «${d.title ?? ''}» 🎉`,
    cancel: `اتلغى ${what} عقار «${d.title ?? ''}»`,
  }[event];
  const stage = event === 'collected' ? 'done_deal' : event === 'cancel' ? 'following' : 'reservation';
  const next = event === 'cancel' ? new Date(now.getTime() + 24 * 3600_000) : null;
  await q.query(`INSERT INTO lead_actions (lead_id, stage, answered, comment, next_at, auto, by_id, created_at) VALUES ($1,$2,true,$3,$4,true,$5,$6)`,
    [lead.id, stage, text, next, byId, now]);
  await q.query(`UPDATE leads SET stage = $2, stage_changed_at = CASE WHEN stage = $2 THEN stage_changed_at ELSE $3 END, next_at = $4, reminded_at = NULL,
      last_action_at = $3, last_action_by = COALESCE($5, last_action_by), last_comment = $6, updated_at = $3 WHERE id = $1`,
    [lead.id, stage, now, next, byId, text]);
}

const mine = (a: Actor, d: any) => [d.proposed_by, d.contributor_id, d.closer_id, d.sales_manager_id].includes(a.id);

async function load(q: Q, ids: string[], a: Actor) {
  if (!ids.length) return [];
  const receiver = await canReceive(q, a);
  const handover = await handoverInstalled(q);
  const deals = (await q.query(`
    SELECT d.*, pe.full_name AS proposed_by_name, ce.full_name AS contributor_name, cl.full_name AS closer_name,
           sm.full_name AS sales_manager_name, de.full_name AS decided_by_name,
           ${handover ? `(SELECT full_name FROM employees WHERE id = d.handover_to)` : 'NULL'} AS handover_to_name,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.brokerage_deal_id = d.id AND r.brokerage_side = 'owner' AND r.status = 'posted'), 0) AS owner_collected,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.brokerage_deal_id = d.id AND r.brokerage_side = 'client' AND r.status = 'posted'), 0) AS client_collected
      FROM brokerage_deals d
      JOIN employees pe ON pe.id = d.proposed_by JOIN employees ce ON ce.id = d.contributor_id JOIN employees cl ON cl.id = d.closer_id
      LEFT JOIN employees sm ON sm.id = d.sales_manager_id LEFT JOIN employees de ON de.id = d.decided_by
     WHERE d.id = ANY($1::uuid[]) ORDER BY d.created_at DESC`, [ids])).rows;
  const shares = (await q.query(`
    SELECT s.*, e.full_name AS employee_name, ce.id AS entitlement_id, ce.period AS entitlement_period, ce.status AS entitlement_status,
           x.id AS settlement_id, x.ref_no AS settlement_ref
      FROM brokerage_shares s LEFT JOIN employees e ON e.id = s.employee_id
      LEFT JOIN commission_entitlements ce ON ce.brokerage_share_id = s.id
      LEFT JOIN cash_expenses x ON x.brokerage_share_id = s.id AND x.status <> 'reversed'
     WHERE s.deal_id = ANY($1::uuid[])
     ORDER BY array_position(ARRAY['contributor','closer','sales_manager','other'], s.role), s.created_at, s.id`, [ids])).rows;
  const all = canViewAll(a) || canApprove(a) || receiver;
  return deals.map((d) => {
    const owner = { due: N(d.owner_commission_egp), collected: r2(N(d.owner_collected)) };
    const client = { due: N(d.client_commission_egp), collected: r2(N(d.client_collected)) };
    const sh = shares.filter((s) => s.deal_id === d.id).filter((s) => all || s.employee_id === a.id);
    return {
      id: d.id, kind: d.kind, status: d.status, property: d.property,
      owner: { name: d.owner_name, phone: all ? d.owner_phone : null }, client: { name: d.client_name, phone: all ? d.client_phone : null },
      price: N(d.price_egp), ratePct: d.rate_pct == null ? null : N(d.rate_pct), arrangement: d.arrangement,
      commission: {
        total: N(d.total_commission_egp), owner: { ...owner, receivable: r2(owner.due - owner.collected) },
        client: { ...client, receivable: r2(client.due - client.collected) },
        collected: r2(owner.collected + client.collected), receivable: r2(owner.due + client.due - owner.collected - client.collected),
      },
      contributor: { id: d.contributor_id, name: d.contributor_name }, closer: { id: d.closer_id, name: d.closer_name },
      salesManager: d.sales_manager_id ? { id: d.sales_manager_id, name: d.sales_manager_name } : null,
      proposedBy: { id: d.proposed_by, name: d.proposed_by_name }, notes: d.notes,
      decidedBy: d.decided_by ? { id: d.decided_by, name: d.decided_by_name } : null, decidedAt: d.decided_at, decisionNote: d.decision_note,
      collectedAt: d.collected_at, createdAt: d.created_at,
      snapshot: all ? d.snapshot : null,
      shares: sh.map((s) => ({ id: s.id, role: s.role, employee: s.employee_id ? { id: s.employee_id, name: s.employee_name } : null,
        beneficiary: s.beneficiary, mode: s.mode, value: N(s.value), amount: N(s.amount_egp),
        entitlementId: s.entitlement_status === 'active' ? s.entitlement_id : null,
        period: s.entitlement_status === 'active' && s.entitlement_period ? String(s.entitlement_period).slice(0, 7) : null,
        settlement: s.settlement_id ? { expenseId: s.settlement_id, refNo: s.settlement_ref } : null,
        canSettle: !s.employee_id && !s.settlement_id && d.status === 'collected' && canOffice(a) })),
      canApprove: d.status === 'proposed' && canApprove(a) && !mine(a, d),
      canCollect: d.status === 'approved' && canCollect(a),
      listingId: d.listing_id ?? null, leadId: d.lead_id ?? null,
      canReceive: d.status === 'proposed' && !!d.listing_id && receiver && !mine(a, d) && !(d.handover_to && !d.handover_at),
      // 090: the commission stated as a % or an amount, handed to one person against the code his app shows
      commissionBasis: d.commission_basis ?? null, commissionPct: d.commission_pct == null ? null : N(d.commission_pct),
      handover: d.handover_to ? {
        to: { id: d.handover_to, name: d.handover_to_name }, at: d.handover_at ?? null,
        waiting: d.status === 'proposed' && !d.handover_at,
        canShowCode: d.status === 'proposed' && !d.handover_at && d.handover_to === a.id,   // the recipient
        canEnterCode: d.status === 'proposed' && !d.handover_at && d.proposed_by === a.id,  // the seller
      } : null,
    };
  });
}

export const brokerageModule: Module = (r, { db, clock }) => {
  r.get('/brokerage/status', async (req) => {
    const a = await authenticate(db, req);
    return ok({ installed: await brokerageInstalled(db),
      listings: await listingsInstalled(db), handover: await handoverInstalled(db),
      can: { propose: canPropose(a), approve: canApprove(a), collect: canCollect(a), viewAll: canViewAll(a), receive: await canReceive(db, a) } });
  });

  // the colleagues a deal can name (contributor / closer / sales manager): active staff, names only
  r.get('/brokerage/people', async (req) => {
    const a = await authenticate(db, req);
    if (!canPropose(a) && !canApprove(a)) throw forbidden();
    const rows = (await db.query(`SELECT id, full_name AS name FROM employees WHERE status = 'active' ORDER BY full_name LIMIT 2000`)).rows;
    return ok({ people: rows });
  });

  // 090: who the seller can hand a commission to (the general manager, the accountant, an administrative officer)
  r.get('/brokerage/recipients', async (req) => {
    const a = await authenticate(db, req);
    if (!canPropose(a)) throw forbidden();
    if (!(await handoverInstalled(db))) return ok({ installed: false, recipients: [] });
    return ok({ installed: true, recipients: await handoverRecipients(db, a.id) });
  });

  r.get('/brokerage/deals', async (req) => {
    const a = await authenticate(db, req);
    if (!(await brokerageInstalled(db))) return ok({ installed: false, deals: [] });
    if (!canPropose(a) && !canViewAll(a) && !canApprove(a) && !canCollect(a)) throw forbidden();
    const kind = req.query.get('kind');
    const vals: unknown[] = []; const where: string[] = [];
    if (kind === 'resale' || kind === 'rental') { vals.push(kind); where.push(`kind = $${vals.length}`); }
    if (!(canViewAll(a) || canApprove(a) || canCollect(a))) {
      vals.push(a.id); where.push(`(proposed_by = $${vals.length} OR contributor_id = $${vals.length} OR closer_id = $${vals.length} OR sales_manager_id = $${vals.length})`);
    }
    const ids = (await db.query(`SELECT id FROM brokerage_deals ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY created_at DESC LIMIT 500`, vals)).rows.map((x) => x.id);
    return ok({ installed: true, deals: await load(db, ids, a) });
  });

  r.post('/brokerage/deals', async (req) => {
    const a = await authenticate(db, req);
    if (!canPropose(a)) throw forbidden();
    const b = obj(req.body);
    const out = await db.tx(async (q) => {
      await needInstalled(q);
      const kind = oneOf(b, 'kind', ['resale', 'rental'] as const)!;
      const ref = typeof b.clientRef === 'string' && b.clientRef ? b.clientRef : null;
      if (ref && !isUuid(ref)) throw invalid('clientRef must be a uuid', { field: 'clientRef' });
      if (ref) {
        await q.query(`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, [`brokerage:${ref}`]);
        const dup = await one(q, `SELECT id, proposed_by, kind FROM brokerage_deals WHERE client_ref = $1`, [ref]);
        if (dup) {
          if (dup.proposed_by !== a.id || dup.kind !== kind) throw new AppError('conflict', 'رقم الطلب ده اتسجل لحركة تانية', { reason: 'client_ref_reused' });
          return { id: dup.id, duplicate: true };
        }
      }
      // the client is ALWAYS an existing lead (whoever proposes — the owner included): name and phone come from it
      const leadId = typeof b.leadId === 'string' && b.leadId ? b.leadId : null;
      if (!leadId) throw invalid('اختار العميل من الليدز — مينفعش تكتب بيانات عميل مش موجود في لوحة السيلز', { field: 'leadId', reason: 'lead_required' });
      if (!isUuid(leadId)) throw invalid('leadId must be a uuid', { field: 'leadId' });
      if (!(await dealLeadInstalled(q))) throw new AppError('conflict', 'الصفقة من الليد محتاجة تحديث قاعدة البيانات (089)', { reason: 'deal_lead_not_installed' });
      const lead = await leadForReservation(q, a, leadId);
      const clientName = String(lead.full_name ?? '').trim().slice(0, 120);
      const clientPhone = String(lead.phone ?? '').trim().slice(0, 30);
      if (clientName.length < 2) throw invalid('اسم العميل في الليد ناقص — كمّله من ملف العميل الأول', { field: 'leadId' });
      const t = commissionTerms(kind, b);
      const contributor = await employee(q, b.contributorId ?? a.id, 'contributorId');
      const closer = await employee(q, b.closerId ?? a.id, 'closerId');
      const manager = await employee(q, b.salesManagerId, 'salesManagerId', true);
      const d = await one(q, `
        INSERT INTO brokerage_deals (kind, property, owner_name, owner_phone, client_name, client_phone, price_egp, rate_pct, arrangement,
               owner_commission_egp, client_commission_egp, contributor_id, closer_id, sales_manager_id, proposed_by, notes, client_ref, created_at, updated_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$18) RETURNING *`,
        [kind, str(b, 'property', { min: 2, max: 300 })!.trim(), str(b, 'ownerName', { min: 2, max: 120 })!.trim(),
          (str(b, 'ownerPhone', { optional: true, max: 30 }) ?? '').trim(), clientName,
          clientPhone, t.price, t.rate, t.arrangement, t.owner, t.client,
          contributor, closer, manager, a.id, (str(b, 'notes', { optional: true, max: 1000 }) ?? '').trim(), ref, clock()]);
      // the lead follows the deal (waiting → done deal when collected; back to follow-up if it is rejected / cancelled)
      await q.query(`UPDATE brokerage_deals SET lead_id = $2 WHERE id = $1`, [d.id, lead.id]);
      await leadFromDeal(q, d.id, 'sold', a.id, clock());
      await audit(q, a.id, 'brokerage.propose', 'brokerage_deal', d.id, undefined,
        { kind, leadId: lead.id, price: t.price, ratePct: t.rate, arrangement: t.arrangement, owner: t.owner, client: t.client, contributor, closer, manager });
      return { id: d.id, duplicate: false };
    });
    return ok({ deal: (await load(db, [out.id], a))[0], duplicate: out.duplicate }, out.duplicate ? 200 : 201);
  });

  // the proposer (or an approver) corrects the terms while the deal waits — every change audited
  r.patch('/brokerage/deals/:id', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    await db.tx(async (q) => {
      await needInstalled(q);
      const d = await one(q, `SELECT * FROM brokerage_deals WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!d || !(d.proposed_by === a.id || canApprove(a))) throw notFound();
      if (d.status !== 'proposed') throw conflict('الصفقة اتعتمدت أو اتقفلت — مفيش تعديل');
      const t = commissionTerms(d.kind, { price: d.price_egp, ...b });
      await q.query(`UPDATE brokerage_deals SET price_egp = $2, rate_pct = $3, arrangement = $4, owner_commission_egp = $5, client_commission_egp = $6,
                       notes = COALESCE($7, notes), updated_at = $8 WHERE id = $1`,
        [d.id, t.price, t.rate, t.arrangement, t.owner, t.client, typeof b.notes === 'string' ? b.notes.slice(0, 1000) : null, clock()]);
      await audit(q, a.id, 'brokerage.terms', 'brokerage_deal', d.id,
        { price: N(d.price_egp), ratePct: d.rate_pct, arrangement: d.arrangement, owner: N(d.owner_commission_egp), client: N(d.client_commission_egp) },
        { price: t.price, ratePct: t.rate, arrangement: t.arrangement, owner: t.owner, client: t.client });
    });
    return ok({ deal: (await load(db, [req.params.id], a))[0] });
  });

  r.post('/brokerage/deals/:id/decision', async (req) => {
    const a = await authenticate(db, req);
    if (!canApprove(a)) throw forbidden('اعتماد العمولة للمدير العام أو المفوض بس');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const decision = oneOf(b, 'decision', ['approve', 'reject'] as const)!;
    const note = (str(b, 'note', { optional: true, max: 500 }) ?? '').trim();
    await db.tx(async (q) => {
      await needInstalled(q);
      const d = await one(q, `SELECT * FROM brokerage_deals WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!d) throw notFound();
      if (d.status !== 'proposed') throw conflict('الصفقة اتقرر فيها قبل كده');
      if (mine(a, d)) throw forbidden('مينفعش تعتمد صفقة إنت مقدمها أو ليك نصيب فيها');
      const now = clock();
      if (decision === 'reject') {
        // a commission already in a cashbox (handed over against the recipient's code) is never left without its deal
        if (await one(q, `SELECT 1 FROM cash_receipts WHERE brokerage_deal_id = $1 AND status = 'posted' LIMIT 1`, [d.id])) {
          throw new AppError('conflict', 'العمولة اتسلمت وفي الخزنة — حدد التقسيمة، أو اعكس الإيصال الأول', { reason: 'commission_received' });
        }
        await q.query(`UPDATE brokerage_deals SET status = 'rejected', decided_by = $2, decided_at = $3, decision_note = $4, updated_at = $3 WHERE id = $1`, [d.id, a.id, now, note]);
        await audit(q, a.id, 'brokerage.reject', 'brokerage_deal', d.id, { status: 'proposed' }, { status: 'rejected', note });
        await syncListing(q, d.id);
        await leadFromDeal(q, d.id, 'cancel', a.id, now);
        return;
      }
      await approveDeal(q, a, d, b.shares as unknown[], note, now);
    });
    return ok({ deal: (await load(db, [req.params.id], a))[0] });
  });

  // the commission actually received from one side — office revenue from this moment; the rest stays a receivable
  r.post('/brokerage/deals/:id/collect', async (req) => {
    const a = await authenticate(db, req);
    if (!canCollect(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const side = oneOf(b, 'side', ['owner', 'client'] as const)!;
    const out = await db.tx(async (q) => {
      await needInstalled(q);
      const d = await one(q, `SELECT * FROM brokerage_deals WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!d) throw notFound();
      return collectSide(q, a, d, side, b, clock());
    });
    return ok({ receiptId: out.id, duplicate: out.duplicate, deal: (await load(db, [req.params.id], a))[0] }, out.duplicate ? 200 : 201);
  });

  // an approved beneficiary outside the staff: paid from the office cashbox once the commission is all in — one expense
  // linked to his share (a commission cost of the office), audited; a retry with the same clientRef gives the same one
  r.post('/brokerage/deals/:id/shares/:shareId/settle', async (req) => {
    const a = await authenticate(db, req);
    if (!canOffice(a)) throw forbidden('صرف نصيب مستفيد خارجي من الخزنة الرئيسية بس');
    if (!isUuid(req.params.id) || !isUuid(req.params.shareId)) throw notFound();
    const b = obj(req.body);
    const method = oneOf(b, 'paymentMethod', ['cash', 'bank'] as const, true) ?? 'cash';
    const ref = typeof b.clientRef === 'string' && b.clientRef ? b.clientRef : null;
    if (ref && !isUuid(ref)) throw invalid('clientRef must be a uuid', { field: 'clientRef' });
    const out = await db.tx(async (q) => {
      await needInstalled(q);
      const d = await one(q, `SELECT * FROM brokerage_deals WHERE id = $1 FOR UPDATE`, [req.params.id]);
      const s = d && await one(q, `SELECT * FROM brokerage_shares WHERE id = $1 AND deal_id = $2`, [req.params.shareId, d.id]);
      if (!d || !s) throw notFound();
      if (ref) {
        const dup = await one(q, `SELECT id, recorded_by, brokerage_share_id FROM cash_expenses WHERE client_ref = $1`, [ref]);
        if (dup) {
          if (dup.recorded_by !== a.id || dup.brokerage_share_id !== s.id) throw new AppError('conflict', 'رقم الطلب ده اتسجل لحركة تانية', { reason: 'client_ref_reused' });
          return { id: dup.id, duplicate: true };
        }
      }
      if (s.employee_id) throw conflict('نصيب الموظف بيتصرف من العمولات (صرف العمولة)');
      if (d.status !== 'collected') throw conflict('العمولة لسه متحصلتش بالكامل');
      if (await one(q, `SELECT 1 FROM cash_expenses WHERE brokerage_share_id = $1 AND status <> 'reversed'`, [s.id])) {
        throw new AppError('conflict', 'النصيب ده اتصرف قبل كده', { reason: 'already_settled' });
      }
      const now = clock();
      const x = await one(q, `
        INSERT INTO cash_expenses (cashbox, amount_egp, category, reason, beneficiary, notes, client_ref, occurred_at, recorded_by,
               status, approved_by, approved_at, payment_method, brokerage_share_id)
        VALUES ('office', $1, 'عمولة وسيط', $2, $3, $4, $5, $6, $7, 'posted', $7, $6, $8, $9) RETURNING id, ref_no`,
        [N(s.amount_egp), `عمولة ${d.kind === 'resale' ? 'إعادة بيع' : 'إيجار'} — ${d.property}`, s.beneficiary,
          (str(b, 'notes', { optional: true, max: 500 }) ?? '').trim(), ref, now, a.id, method, s.id]);
      await audit(q, a.id, 'brokerage.settle_external', 'brokerage_deal', d.id, undefined,
        { shareId: s.id, beneficiary: s.beneficiary, amount: N(s.amount_egp), expenseId: x.id, method });
      return { id: x.id, duplicate: false };
    });
    return ok({ expenseId: out.id, duplicate: out.duplicate, deal: (await load(db, [req.params.id], a))[0] }, out.duplicate ? 200 : 201);
  });

  // a deal nobody has paid anything for can be withdrawn (the proposer while it waits; an approver until money comes in)
  r.post('/brokerage/deals/:id/cancel', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    await db.tx(async (q) => {
      await needInstalled(q);
      const d = await one(q, `SELECT * FROM brokerage_deals WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!d) throw notFound();
      const allowed = (d.status === 'proposed' && (d.proposed_by === a.id || canApprove(a))) || (d.status === 'approved' && canApprove(a));
      if (!allowed) throw d.status === 'proposed' || d.status === 'approved' ? forbidden() : conflict('الصفقة متقفلة');
      if (await one(q, `SELECT 1 FROM cash_receipts WHERE brokerage_deal_id = $1 AND status = 'posted' LIMIT 1`, [d.id])) {
        throw conflict('اتحصل جزء من العمولة — مينفعش تتلغي');
      }
      await q.query(`UPDATE brokerage_deals SET status = 'cancelled', updated_at = $2 WHERE id = $1`, [d.id, clock()]);
      await audit(q, a.id, 'brokerage.cancel', 'brokerage_deal', d.id, { status: d.status }, { status: 'cancelled', note: (str(b, 'note', { optional: true, max: 300 }) ?? '') });
      await syncListing(q, d.id);
      await leadFromDeal(q, d.id, 'cancel', a.id, clock());
    });
    return ok({ deal: (await load(db, [req.params.id], a))[0] });
  });

  // ------------------------------------------------------------------ listings (088)
  const shapeListing = (l: any, a: Actor, all: boolean, photos: any[]) => {
    const own = l.listed_by === a.id;
    return {
      id: l.id, kind: l.kind, status: l.status, title: l.title, address: l.address, area: N(l.area_m2), price: N(l.price_egp),
      finishing: l.finishing, finishingAr: FINISHING[l.finishing as keyof typeof FINISHING] ?? l.finishing, description: l.description,
      owner: all || own ? { name: l.owner_name, phone: l.owner_phone } : null,
      listedBy: { id: l.listed_by, name: l.listed_by_name }, createdAt: l.created_at, updatedAt: l.updated_at,
      photos: photos.filter((p) => p.listing_id === l.id).map((p) => p.id),
      deal: l.deal_id ? { id: l.deal_id, status: l.deal_status } : null,
      can: {
        edit: l.status === 'available' && (own || all),
        withdraw: l.status === 'available' && (own || all),
        sell: l.status === 'available' && canPropose(a),
      },
    };
  };
  async function loadListings(q: Q, a: Actor, where: string, vals: unknown[]) {
    const rows = (await q.query(`
      SELECT l.*, e.full_name AS listed_by_name,
             (SELECT d.id FROM brokerage_deals d WHERE d.listing_id = l.id AND d.status NOT IN ('rejected', 'cancelled') ORDER BY d.created_at DESC LIMIT 1) AS deal_id,
             (SELECT d.status FROM brokerage_deals d WHERE d.listing_id = l.id AND d.status NOT IN ('rejected', 'cancelled') ORDER BY d.created_at DESC LIMIT 1) AS deal_status
        FROM brokerage_listings l JOIN employees e ON e.id = l.listed_by ${where} ORDER BY l.created_at DESC LIMIT 500`, vals)).rows;
    if (!rows.length) return [];
    const photos = (await q.query(`SELECT id, listing_id FROM brokerage_listing_photos WHERE listing_id = ANY($1::uuid[]) AND NOT removed ORDER BY position, created_at, id`,
      [rows.map((x) => x.id)])).rows;
    const all = canViewAll(a) || canApprove(a) || canCollect(a);
    return rows.map((l) => shapeListing(l, a, all, photos));
  }
  const viewer = (a: Actor) => { if (!canPropose(a) && !canViewAll(a) && !canApprove(a) && !canCollect(a)) throw forbidden(); };

  r.get('/brokerage/listings', async (req) => {
    const a = await authenticate(db, req);
    viewer(a);
    if (!(await listingsInstalled(db))) return ok({ installed: false, listings: [] });
    const kind = req.query.get('kind');
    const vals: unknown[] = []; const where: string[] = [];
    if (kind === 'resale' || kind === 'rental') { vals.push(kind); where.push(`l.kind = $${vals.length}`); }
    // a withdrawn listing: its lister and the administration only
    if (!(canViewAll(a) || canApprove(a) || canCollect(a))) { vals.push(a.id); where.push(`(l.status <> 'withdrawn' OR l.listed_by = $${vals.length})`); }
    return ok({ installed: true, listings: await loadListings(db, a, where.length ? 'WHERE ' + where.join(' AND ') : '', vals) });
  });

  // «ملاك العقارات» (no table of their own): the owners named on the listings (name + phone), one per phone number; opening
  // one shows all his properties — rental and resale, the available, the rented / sold and the withdrawn. The administration
  // sees every owner; a salesperson only the owners of the listings he added (the owner's contact is never anyone else's).
  r.get('/brokerage/owners', async (req) => {
    const a = await authenticate(db, req);
    viewer(a);
    if (!(await listingsInstalled(db))) return ok({ installed: false, owners: [] });
    const all = canViewAll(a) || canApprove(a) || canCollect(a);
    const vals: unknown[] = []; const where: string[] = [`(l.owner_phone <> '' OR l.owner_name <> '')`];
    if (!all) { vals.push(a.id); where.push(`l.listed_by = $${vals.length}`); }
    const s = (req.query.get('q') ?? '').trim().toLowerCase().slice(0, 60);
    if (s) {
      vals.push(`%${s}%`);
      const n = vals.length;
      vals.push(`%${s.replace(/\D/g, '') || '∅'}%`);
      where.push(`(lower(l.owner_name) LIKE $${n} OR regexp_replace(l.owner_phone, '\\D', '', 'g') LIKE $${vals.length})`);
    }
    const listings = await loadListings(db, a, 'WHERE ' + where.join(' AND '), vals);
    // one owner per phone (its last 10 digits — 010… and +2010… are the same); no phone → by name
    const key = (o: { name: string; phone: string }) => {
      const d = String(o.phone ?? '').replace(/\D/g, '').slice(-10);
      return d.length >= 8 ? 'p' + d : 'n' + String(o.name ?? '').trim().toLowerCase();
    };
    const owners = new Map<string, { key: string; name: string; phone: string; listings: any[] }>();
    for (const l of listings) {
      if (!l.owner) continue;
      const k = key(l.owner);
      const o = owners.get(k) ?? { key: k, name: l.owner.name, phone: l.owner.phone, listings: [] };
      if (!o.name && l.owner.name) o.name = l.owner.name;
      if (!o.phone && l.owner.phone) o.phone = l.owner.phone;
      o.listings.push(l);
      owners.set(k, o);
    }
    const count = (xs: any[], f: (x: any) => boolean) => xs.filter(f).length;
    return ok({ installed: true, owners: [...owners.values()].map((o) => ({ ...o,
      counts: { total: o.listings.length, rental: count(o.listings, (x) => x.kind === 'rental'), resale: count(o.listings, (x) => x.kind === 'resale'),
        available: count(o.listings, (x) => x.status === 'available' || x.status === 'pending'),
        rented: count(o.listings, (x) => x.kind === 'rental' && x.status === 'sold'), sold: count(o.listings, (x) => x.kind === 'resale' && x.status === 'sold') },
    })).sort((x, y) => y.counts.total - x.counts.total || String(x.name).localeCompare(String(y.name), 'ar')) });
  });

  r.post('/brokerage/listings', async (req) => {
    const a = await authenticate(db, req);
    if (!canPropose(a)) throw forbidden();
    const b = obj(req.body);
    const out = await db.tx(async (q) => {
      await needListings(q);
      const kind = oneOf(b, 'kind', ['resale', 'rental'] as const)!;
      const ref = typeof b.clientRef === 'string' && b.clientRef ? b.clientRef : null;
      if (ref && !isUuid(ref)) throw invalid('clientRef must be a uuid', { field: 'clientRef' });
      if (ref) {
        await q.query(`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, [`listing:${ref}`]);
        const dup = await one(q, `SELECT id, listed_by FROM brokerage_listings WHERE client_ref = $1`, [ref]);
        if (dup) {
          if (dup.listed_by !== a.id) throw new AppError('conflict', 'رقم الطلب ده اتسجل لحركة تانية', { reason: 'client_ref_reused' });
          return { id: dup.id, duplicate: true };
        }
      }
      const f = listingFields(b);
      const now = clock();
      const l = await one(q, `
        INSERT INTO brokerage_listings (kind, title, address, area_m2, price_egp, finishing, description, owner_name, owner_phone, listed_by, client_ref, created_at, updated_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$12) RETURNING id`,
        [kind, f.title, f.address, f.area_m2, f.price_egp, f.finishing, f.description ?? '', f.owner_name ?? '', f.owner_phone ?? '', a.id, ref, now]);
      await audit(q, a.id, 'brokerage.listing.create', 'brokerage_listing', l.id, undefined, { kind, ...f, owner_phone: undefined });
      return { id: l.id, duplicate: false };
    });
    return ok({ listing: (await loadListings(db, a, 'WHERE l.id = $1', [out.id]))[0], duplicate: out.duplicate }, out.duplicate ? 200 : 201);
  });

  /** the lister (or the administration) while it is still available */
  async function editable(q: Q, a: Actor, id: string) {
    await needListings(q);
    if (!isUuid(id)) throw notFound();
    const l = await one(q, `SELECT * FROM brokerage_listings WHERE id = $1 FOR UPDATE`, [id]);
    if (!l) throw notFound();
    if (!(l.listed_by === a.id || canViewAll(a) || canApprove(a) || canCollect(a))) throw forbidden();
    if (l.status !== 'available') throw conflict(l.status === 'withdrawn' ? 'العقار ده اتشال من العرض' : 'العقار ده اتباع أو عليه بيع — مفيش تعديل');
    return l;
  }

  r.patch('/brokerage/listings/:id', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    await db.tx(async (q) => {
      const l = await editable(q, a, req.params.id);
      const f = listingFields(b, true);
      const keys = Object.keys(f);
      if (!keys.length) return;
      await q.query(`UPDATE brokerage_listings SET ${keys.map((k, i) => `${k} = $${i + 2}`).join(', ')}, updated_at = $${keys.length + 2} WHERE id = $1`,
        [l.id, ...keys.map((k) => f[k]), clock()]);
      await audit(q, a.id, 'brokerage.listing.edit', 'brokerage_listing', l.id,
        Object.fromEntries(keys.map((k) => [k, l[k]])), f);
    });
    return ok({ listing: (await loadListings(db, a, 'WHERE l.id = $1', [req.params.id]))[0] });
  });

  r.post('/brokerage/listings/:id/withdraw', async (req) => {
    const a = await authenticate(db, req);
    await db.tx(async (q) => {
      const l = await editable(q, a, req.params.id);
      await q.query(`UPDATE brokerage_listings SET status = 'withdrawn', updated_at = $2 WHERE id = $1`, [l.id, clock()]);
      await audit(q, a.id, 'brokerage.listing.withdraw', 'brokerage_listing', l.id, { status: 'available' }, { status: 'withdrawn' });
    });
    return ok({ listing: (await loadListings(db, a, 'WHERE l.id = $1', [req.params.id]))[0] });
  });

  // photos: one per request (each up to ~1 MB) — the hosting limits a request body
  r.post('/brokerage/listings/:id/photos', async (req) => {
    const a = await authenticate(db, req);
    const b = obj(req.body);
    const p = photoInput(b);
    const out = await db.tx(async (q) => {
      const l = await editable(q, a, req.params.id);
      const n = Number((await one(q, `SELECT count(*)::int n, COALESCE(max(position), -1) m FROM brokerage_listing_photos WHERE listing_id = $1 AND NOT removed`, [l.id])).n);
      if (n >= MAX_PHOTOS) throw new AppError('unprocessable', `أقصى عدد ${MAX_PHOTOS} صور`, { reason: 'too_many_photos' });
      const pos = Number((await one(q, `SELECT COALESCE(max(position), -1) + 1 p FROM brokerage_listing_photos WHERE listing_id = $1`, [l.id])).p);
      const x = await one(q, `INSERT INTO brokerage_listing_photos (listing_id, mime, data, position, added_by, created_at) VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
        [l.id, p.mime, p.data, pos, a.id, clock()]);
      await q.query(`UPDATE brokerage_listings SET updated_at = $2 WHERE id = $1`, [l.id, clock()]);
      await audit(q, a.id, 'brokerage.listing.photo', 'brokerage_listing', l.id, undefined, { photoId: x.id, mime: p.mime, bytes: p.data.length });
      return x.id as string;
    });
    return ok({ photoId: out }, 201);
  });

  r.post('/brokerage/listings/:id/photos/:photoId/remove', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.photoId)) throw notFound();
    await db.tx(async (q) => {
      const l = await editable(q, a, req.params.id);
      const x = await one(q, `UPDATE brokerage_listing_photos SET removed = true WHERE id = $1 AND listing_id = $2 AND NOT removed RETURNING id`, [req.params.photoId, l.id]);
      if (!x) throw notFound();
      await audit(q, a.id, 'brokerage.listing.photo_remove', 'brokerage_listing', l.id, undefined, { photoId: x.id });
    });
    return ok({ removed: true });
  });

  r.get('/brokerage/listings/:id/photos/:photoId', async (req) => {
    const a = await authenticate(db, req);
    viewer(a);
    if (!isUuid(req.params.id) || !isUuid(req.params.photoId)) throw notFound();
    await needListings(db);
    const x = await one(db, `SELECT mime, data FROM brokerage_listing_photos WHERE id = $1 AND listing_id = $2 AND NOT removed`, [req.params.photoId, req.params.id]);
    if (!x) throw notFound();
    return ok({ image: `data:${x.mime};base64,${x.data}` });
  });

  // anyone sells / rents a listing: the client, the final price and the commission he took — the administrative officer is told
  r.post('/brokerage/listings/:id/sell', async (req) => {
    const a = await authenticate(db, req);
    if (!canPropose(a)) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const out = await db.tx(async (q) => {
      await needListings(q);
      const ref = typeof b.clientRef === 'string' && b.clientRef ? b.clientRef : null;
      if (ref && !isUuid(ref)) throw invalid('clientRef must be a uuid', { field: 'clientRef' });
      if (ref) {
        await q.query(`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, [`brokerage:${ref}`]);
        const dup = await one(q, `SELECT id, proposed_by, listing_id FROM brokerage_deals WHERE client_ref = $1`, [ref]);
        if (dup) {
          if (dup.proposed_by !== a.id || dup.listing_id !== req.params.id) throw new AppError('conflict', 'رقم الطلب ده اتسجل لحركة تانية', { reason: 'client_ref_reused' });
          return { id: dup.id, duplicate: true };
        }
      }
      const l = await one(q, `SELECT * FROM brokerage_listings WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!l) throw notFound();
      if (l.status !== 'available') throw new AppError('conflict', l.status === 'withdrawn' ? 'العقار ده اتشال من العرض' : 'العقار ده اتباع أو عليه بيع قبل كده', { reason: 'listing_not_available' });
      // the client is ALWAYS an existing lead of the sales board (whoever sells — the owner included): never typed by hand.
      // Its name and phone come from the lead; clientName / clientPhone in the request are ignored.
      const leadId = typeof b.leadId === 'string' && b.leadId ? b.leadId : null;
      if (!leadId) throw invalid('اختار العميل من الليدز — مينفعش تكتب بيانات عميل مش موجود في لوحة السيلز', { field: 'leadId', reason: 'lead_required' });
      if (!isUuid(leadId)) throw invalid('leadId must be a uuid', { field: 'leadId' });
      if (!(await dealLeadInstalled(q))) throw new AppError('conflict', 'البيع من الليد محتاج تحديث قاعدة البيانات (089)', { reason: 'deal_lead_not_installed' });
      const lead = await leadForReservation(q, a, leadId);
      const clientName = String(lead.full_name ?? '').trim().slice(0, 120);
      const clientPhone = String(lead.phone ?? '').trim().slice(0, 30);
      if (clientName.length < 2) throw invalid('اسم العميل في الليد ناقص — كمّله من ملف العميل الأول', { field: 'leadId' });
      const price = num(b, 'finalPrice', { min: 1, max: 10_000_000_000 })!;
      // the commission: a percentage of the sale price / the monthly rent, or an amount — the amount is what is stored
      const basis = oneOf(b, 'commissionBasis', ['amount', 'percent'] as const, true) ?? 'amount';
      const pct = basis === 'percent' ? num(b, 'commissionPct', { min: 0.01, max: 100 })! : null;
      const commission = pct != null ? r2(price * pct / 100) : r2(num(b, 'commission', { min: 1, max: 10_000_000_000 })!);
      if (commission < 1) throw invalid('العمولة طلعت أقل من جنيه', { field: 'commissionPct' });
      const notes = (str(b, 'notes', { optional: true, max: 1000 }) ?? '').trim();
      // 090: the person the commission is handed to — he receives it against the code his app shows
      const handover = await handoverInstalled(q);
      let recipient: { id: string; name: string } | null = null;
      if (handover) {
        const rid = typeof b.recipientId === 'string' && isUuid(b.recipientId) ? b.recipientId : null;
        if (!rid) throw invalid('اختار مين هيستلم العمولة', { field: 'recipientId' });
        recipient = (await handoverRecipients(q, a.id)).find((x) => x.id === rid) ?? null;
        if (!recipient) throw invalid('المستلم لازم يكون المدير العام أو المحاسب أو مسؤول إداري ماسك خزنة المكتب', { field: 'recipientId' });
      }
      const lister = (await one(q, `SELECT id FROM employees WHERE id = $1 AND status = 'active'`, [l.listed_by]))?.id ?? a.id;
      const now = clock();
      const d = await one(q, `
        INSERT INTO brokerage_deals (kind, property, owner_name, owner_phone, client_name, client_phone, price_egp, rate_pct, arrangement,
               owner_commission_egp, client_commission_egp, contributor_id, closer_id, sales_manager_id, proposed_by, notes, client_ref, listing_id, created_at, updated_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,NULL,'fixed',0,$8,$9,$10,NULL,$10,$11,$12,$13,$14,$14) RETURNING id`,
        [l.kind, `${l.title} — ${l.address}`.slice(0, 300), l.owner_name.trim().length >= 2 ? l.owner_name.trim() : 'مالك العقار', l.owner_phone,
          clientName, clientPhone, price, commission, lister, a.id, notes, ref, l.id, now]);
      await q.query(`UPDATE brokerage_listings SET status = 'pending', updated_at = $2 WHERE id = $1`, [l.id, now]);
      await q.query(`UPDATE brokerage_deals SET lead_id = $2 WHERE id = $1`, [d.id, lead.id]);
      await leadFromDeal(q, d.id, 'sold', a.id, now);
      if (handover) {
        await q.query(`UPDATE brokerage_deals SET commission_basis = $2, commission_pct = $3, handover_to = $4 WHERE id = $1`,
          [d.id, basis, pct, recipient!.id]);
      }
      await audit(q, a.id, 'brokerage.listing.sell', 'brokerage_deal', d.id, undefined,
        { listingId: l.id, kind: l.kind, leadId: lead.id, clientName, price, commission, basis, pct, recipient: recipient?.id ?? null, lister, seller: a.id });
      const what = l.kind === 'resale' ? 'بيع' : 'إيجار';
      if (recipient) {
        // the recipient is told a commission waits for his code — the code itself never travels in a notification
        await notify(q, { to: recipient.id, type: 'brokerage_handover', title: `${what} عقار — عمولة ${commission.toLocaleString('en-US')} ج مستنية تأكيدك`,
          body: `${l.title} — ${clientName}. افتح التطبيق: هيظهرلك كود من 4 أرقام، قوله لـ ${a.fullName} وهو يكتبه`,
          entity: 'brokerage_deal', entityId: d.id, dedupeKey: `brokerage_handover:${d.id}` });
        return { id: d.id, duplicate: false };
      }
      // before 090: the administrative officer(s) — or, when none is set, whoever approves commissions
      let to = (await q.query(`SELECT e.id FROM employees e WHERE e.status = 'active' AND ${adminOfficerSql('e')} AND e.id <> $1`, [a.id])).rows.map((x) => x.id as string);
      if (!to.length) to = await holdersOf(q, 'brokerage.approve', [a.id]);
      for (const id of to) {
        await notify(q, { to: id, type: 'brokerage_sale', title: `${what} عقار — عمولة ${commission.toLocaleString('en-US')} ج`,
          body: `${l.title} — ${clientName}. استلم العمولة وحدد التقسيمة`, entity: 'brokerage_deal', entityId: d.id, dedupeKey: `brokerage_sale:${d.id}` });
      }
      return { id: d.id, duplicate: false };
    });
    return ok({ deal: (await load(db, [out.id], a))[0], duplicate: out.duplicate }, out.duplicate ? 200 : 201);
  });

  // 090 — the recipient's code for a commission handed to him (a new one each time; the previous one ends)
  r.post('/brokerage/deals/:id/handover/code', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const out = await db.tx(async (q) => {
      await needHandover(q);
      const d = await one(q, `SELECT d.*, s.full_name AS seller FROM brokerage_deals d JOIN employees s ON s.id = d.proposed_by
                               WHERE d.id = $1 FOR UPDATE OF d`, [req.params.id]);
      if (!d || d.handover_to !== a.id) throw notFound(); // only the recipient — the seller never sees the code
      if (d.status !== 'proposed' || d.handover_at) throw conflict('العمولة دي اتسلمت أو الصفقة اتقفلت');
      const act = handoverAction(d.id);
      const recent = await one(q, `SELECT count(*)::int AS n FROM action_otps WHERE employee_id = $1 AND action = $2 AND created_at > now() - interval '15 minutes'`, [a.id, act]);
      if (recent.n >= 5) throw new AppError('rate_limited', 'طلبت أكواد كتير للعمولة دي — استنى ربع ساعة', { reason: 'otp_rate_limited' });
      const code = String(randomInt(0, 10_000)).padStart(4, '0');
      await q.query(`UPDATE action_otps SET expires_at = now() WHERE employee_id = $1 AND action = $2 AND used_at IS NULL AND expires_at > now()`, [a.id, act]);
      const o = await one(q, `INSERT INTO action_otps (employee_id, action, code_hash, expires_at) VALUES ($1, $2, $3, now() + make_interval(mins => $4))
                              RETURNING expires_at`, [a.id, act, handoverHash(a.id, d.id, code), HANDOVER_OTP_TTL_MIN]);
      await audit(q, a.id, 'brokerage.handover_code_issued', 'brokerage_deal', d.id, undefined, { expiresAt: o.expires_at }); // never the code
      return { code, expiresAt: o.expires_at, amount: N(d.client_commission_egp), kind: d.kind, property: d.property, client: d.client_name, sellerName: d.seller };
    });
    return ok(out);
  });

  // 090 — the seller enters the code the recipient told him: only then the commission is in the recipient's office cashbox
  // (a numbered receipt in his name). The split is set afterwards («استلام وتقسيم» → POST /brokerage/deals/:id/receive).
  r.post('/brokerage/deals/:id/handover/verify', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const code = obj(req.body).code;
    const bad = (reason = 'otp_invalid') => new AppError('validation_failed',
      reason === 'otp_locked' ? 'اتكتب كود غلط كتير — استنى ساعة أو اطلب من المستلم كود جديد بعدها' : 'الكود غلط أو خلص وقته — اطلب من المستلم كود جديد',
      { reason, field: 'code' });
    if (typeof code !== 'string' || !/^\d{4}$/.test(code)) throw bad();
    const now = clock();
    const res = await db.tx(async (q) => {
      await needHandover(q);
      const d = await one(q, `SELECT * FROM brokerage_deals WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!d || !d.handover_to || d.proposed_by !== a.id) throw notFound(); // the seller of this very deal
      if (d.status !== 'proposed' || d.handover_at) throw new AppError('conflict', 'العمولة دي اتسلمت أو الصفقة اتقفلت', { reason: 'not_open' });
      const act = handoverAction(d.id);
      const tries = await one(q, `SELECT COALESCE(sum(attempts), 0)::int AS n FROM action_otps WHERE employee_id = $1 AND action = $2 AND created_at > now() - interval '1 hour'`,
        [d.handover_to, act]);
      if (tries.n >= 15) return { fail: 'otp_locked' as const };
      const o = await one(q, `SELECT * FROM action_otps WHERE employee_id = $1 AND action = $2 AND used_at IS NULL AND expires_at > now()
                               ORDER BY created_at DESC LIMIT 1 FOR UPDATE`, [d.handover_to, act]);
      if (!o || o.attempts >= 5) return { fail: 'otp_invalid' as const };
      if (o.code_hash !== handoverHash(d.handover_to, d.id, code)) return { fail: 'otp_invalid' as const, wrong: o.id as string };
      await q.query(`UPDATE action_otps SET used_at = now() WHERE id = $1`, [o.id]);
      const side = d.kind === 'resale' ? 'المشتري' : 'المستأجر';
      const input: ReceiptInput = {
        box: 'office', recipientId: d.handover_to, kind: 'commission', amount: N(d.client_commission_egp),
        payerName: d.client_name, payerPhone: d.client_phone ?? '',
        purpose: `عمولة ${d.kind === 'resale' ? 'إعادة بيع' : 'إيجار'} — ${d.property} (${side})`.slice(0, 300),
        method: 'cash', externalNo: null, notes: 'اتسلمت للمستلم بالكود اللي ظهرله', ref: null, att: null, occurred: now,
        brokerageDealId: d.id, brokerageSide: 'client',
      };
      const rec = await recordReceipt(q, a, input);
      await q.query(`UPDATE brokerage_deals SET handover_at = $2, updated_at = $2 WHERE id = $1`, [d.id, now]);
      await audit(q, a.id, 'brokerage.handover', 'brokerage_deal', d.id, { handedOver: false },
        { handedOver: true, by: 'otp', recipient: d.handover_to, amount: N(d.client_commission_egp), receiptId: rec.id });
      // whoever sets the split (the administrative officer(s), else whoever approves commissions) — never a party of the deal
      const parties = [d.proposed_by, d.contributor_id, d.closer_id, d.sales_manager_id].filter(Boolean) as string[];
      let to = (await q.query(`SELECT e.id FROM employees e WHERE e.status = 'active' AND ${adminOfficerSql('e')} AND NOT e.id = ANY($1::uuid[])`, [parties]))
        .rows.map((x) => x.id as string);
      if (!to.length) to = await holdersOf(q, 'brokerage.approve', parties);
      for (const id of to) {
        await notify(q, { to: id, type: 'brokerage_sale', title: `عمولة ${N(d.client_commission_egp).toLocaleString('en-US')} ج اتسلمت — حدد التقسيمة`,
          body: `${d.property} — ${d.client_name}`, entity: 'brokerage_deal', entityId: d.id, dedupeKey: `brokerage_split:${d.id}` });
      }
      return { receiptId: rec.id };
    });
    if ('fail' in res) {
      // a wrong try is counted on its own (outside the refused step, so it is never rolled back)
      if (res.wrong) {
        await db.query(`UPDATE action_otps SET attempts = attempts + 1 WHERE id = $1`, [res.wrong]);
        await audit(db, a.id, 'brokerage.handover_code_wrong', 'brokerage_deal', req.params.id);
      }
      throw bad(res.fail);
    }
    return ok({ receiptId: res.receiptId, deal: (await load(db, [req.params.id], a))[0] });
  });

  // the administrative officer receives the commission of a listing sale and sets its split in one step:
  // the seller, the lister (when someone else), the sales manager — by amount or % — the office keeps the rest
  r.post('/brokerage/deals/:id/receive', async (req) => {
    const a = await authenticate(db, req);
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const out = await db.tx(async (q) => {
      await needListings(q);
      if (!(await canReceive(q, a))) throw forbidden('استلام العمولة وتقسيمها للمسؤول الإداري أو المدير العام');
      let d = await one(q, `SELECT * FROM brokerage_deals WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!d) throw notFound();
      const ref = typeof b.clientRef === 'string' && b.clientRef ? b.clientRef : null;
      if (ref && d.status === 'collected' && await one(q, `SELECT 1 FROM cash_receipts WHERE client_ref = $1 AND brokerage_deal_id = $2`, [ref, d.id])) {
        return { id: (await one(q, `SELECT id FROM cash_receipts WHERE client_ref = $1`, [ref])).id as string, duplicate: true };
      }
      if (!d.listing_id) throw conflict('الصفقة دي مش من عرض عقار');
      if (d.status !== 'proposed') throw conflict('العمولة اتستلمت أو الصفقة اتقفلت');
      if (mine(a, d)) throw forbidden('مينفعش تستلم وتقسم عمولة صفقة إنت طرف فيها');
      // 090: waiting for the recipient's code → nothing to split yet; handed over → split only (the receipt exists)
      if (d.handover_to && !d.handover_at) {
        throw new AppError('conflict', 'العمولة لسه متسلمتش — مستنية كود المستلم', { reason: 'handover_pending' });
      }
      const handedOver = !!d.handover_at;
      const now = clock();
      // the commission actually received (the seller's figure unless corrected) and the sales manager of the split;
      // a commission handed over against the code keeps the amount that entered the cashbox
      const amount = handedOver ? N(d.client_commission_egp) : r2(num(b, 'amount', { min: 1, max: 10_000_000_000 })!);
      if (handedOver && b.amount !== undefined && b.amount !== null && cents(Number(b.amount)) !== cents(amount)) {
        throw new AppError('conflict', `العمولة اتسلمت بـ ${amount} — مينفعش تتغير`, { reason: 'handover_amount_fixed', amount });
      }
      const manager = await employee(q, b.salesManagerId, 'salesManagerId', true);
      if (manager === a.id) throw forbidden('مينفعش تحدد نصيب ليك');
      if (cents(amount) !== cents(N(d.client_commission_egp)) || (manager ?? null) !== (d.sales_manager_id ?? null)) {
        await q.query(`UPDATE brokerage_deals SET client_commission_egp = $2, sales_manager_id = $3, updated_at = $4 WHERE id = $1`, [d.id, amount, manager, now]);
        await audit(q, a.id, 'brokerage.terms', 'brokerage_deal', d.id, { commission: N(d.client_commission_egp), salesManager: d.sales_manager_id },
          { commission: amount, salesManager: manager });
        d = await one(q, `SELECT * FROM brokerage_deals WHERE id = $1`, [d.id]);
      }
      await approveDeal(q, a, d, b.shares as unknown[], (str(b, 'note', { optional: true, max: 500 }) ?? '').trim(), now);
      d = await one(q, `SELECT * FROM brokerage_deals WHERE id = $1`, [d.id]);
      if (handedOver) {
        await closeIfCollected(q, a, d, now);
        const rec = await one(q, `SELECT id FROM cash_receipts WHERE brokerage_deal_id = $1 AND status = 'posted' ORDER BY created_at LIMIT 1`, [d.id]);
        return { id: rec.id as string, duplicate: false };
      }
      return collectSide(q, a, d, 'client', { ...b, amount }, now);
    });
    return ok({ receiptId: out.id, duplicate: out.duplicate, deal: (await load(db, [req.params.id], a))[0] }, out.duplicate ? 200 : 201);
  });

};
