import { ok, type Module } from '../ctx.ts';
import { one, type Q } from '../db.ts';
import { AppError, conflict, forbidden, invalid, notFound } from '../http/errors.ts';
import { isUuid, num, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, can, type Actor } from '../auth/context.ts';
import { local } from '../lib/time.ts';
import { canHrOperate, canOffice, parseReceipt, recordReceipt } from './cash.ts';

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
const canPropose = (a: Actor) => can(a, 'brokerage.propose', 'exclusive.reserve');
const canApprove = (a: Actor) => can(a, 'brokerage.approve', 'commission.approve');
const canViewAll = (a: Actor) => can(a, 'brokerage.view_all', 'commission.approve') || canOffice(a);
const canCollect = (a: Actor) => canOffice(a) || canHrOperate(a);

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

const mine = (a: Actor, d: any) => [d.proposed_by, d.contributor_id, d.closer_id, d.sales_manager_id].includes(a.id);

async function load(q: Q, ids: string[], a: Actor) {
  if (!ids.length) return [];
  const deals = (await q.query(`
    SELECT d.*, pe.full_name AS proposed_by_name, ce.full_name AS contributor_name, cl.full_name AS closer_name,
           sm.full_name AS sales_manager_name, de.full_name AS decided_by_name,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.brokerage_deal_id = d.id AND r.brokerage_side = 'owner' AND r.status = 'posted'), 0) AS owner_collected,
           COALESCE((SELECT sum(r.amount_egp) FROM cash_receipts r WHERE r.brokerage_deal_id = d.id AND r.brokerage_side = 'client' AND r.status = 'posted'), 0) AS client_collected
      FROM brokerage_deals d
      JOIN employees pe ON pe.id = d.proposed_by JOIN employees ce ON ce.id = d.contributor_id JOIN employees cl ON cl.id = d.closer_id
      LEFT JOIN employees sm ON sm.id = d.sales_manager_id LEFT JOIN employees de ON de.id = d.decided_by
     WHERE d.id = ANY($1::uuid[]) ORDER BY d.created_at DESC`, [ids])).rows;
  const shares = (await q.query(`
    SELECT s.*, e.full_name AS employee_name, ce.id AS entitlement_id, ce.period AS entitlement_period
      FROM brokerage_shares s LEFT JOIN employees e ON e.id = s.employee_id
      LEFT JOIN commission_entitlements ce ON ce.brokerage_share_id = s.id
     WHERE s.deal_id = ANY($1::uuid[])
     ORDER BY array_position(ARRAY['contributor','closer','sales_manager','other'], s.role), s.created_at, s.id`, [ids])).rows;
  const all = canViewAll(a) || canApprove(a);
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
        entitlementId: s.entitlement_id ?? null, period: s.entitlement_period ? String(s.entitlement_period).slice(0, 7) : null })),
      canApprove: d.status === 'proposed' && canApprove(a) && !mine(a, d),
      canCollect: d.status === 'approved' && canCollect(a),
    };
  });
}

export const brokerageModule: Module = (r, { db, clock }) => {
  r.get('/brokerage/status', async (req) => {
    const a = await authenticate(db, req);
    return ok({ installed: await brokerageInstalled(db),
      can: { propose: canPropose(a), approve: canApprove(a), collect: canCollect(a), viewAll: canViewAll(a) } });
  });

  // the colleagues a deal can name (contributor / closer / sales manager): active staff, names only
  r.get('/brokerage/people', async (req) => {
    const a = await authenticate(db, req);
    if (!canPropose(a) && !canApprove(a)) throw forbidden();
    const rows = (await db.query(`SELECT id, full_name AS name FROM employees WHERE status = 'active' ORDER BY full_name LIMIT 2000`)).rows;
    return ok({ people: rows });
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
      const t = commissionTerms(kind, b);
      const contributor = await employee(q, b.contributorId ?? a.id, 'contributorId');
      const closer = await employee(q, b.closerId ?? a.id, 'closerId');
      const manager = await employee(q, b.salesManagerId, 'salesManagerId', true);
      const d = await one(q, `
        INSERT INTO brokerage_deals (kind, property, owner_name, owner_phone, client_name, client_phone, price_egp, rate_pct, arrangement,
               owner_commission_egp, client_commission_egp, contributor_id, closer_id, sales_manager_id, proposed_by, notes, client_ref, created_at, updated_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$18) RETURNING *`,
        [kind, str(b, 'property', { min: 2, max: 300 })!.trim(), str(b, 'ownerName', { min: 2, max: 120 })!.trim(),
          (str(b, 'ownerPhone', { optional: true, max: 30 }) ?? '').trim(), str(b, 'clientName', { min: 2, max: 120 })!.trim(),
          (str(b, 'clientPhone', { optional: true, max: 30 }) ?? '').trim(), t.price, t.rate, t.arrangement, t.owner, t.client,
          contributor, closer, manager, a.id, (str(b, 'notes', { optional: true, max: 1000 }) ?? '').trim(), ref, clock()]);
      await audit(q, a.id, 'brokerage.propose', 'brokerage_deal', d.id, undefined,
        { kind, price: t.price, ratePct: t.rate, arrangement: t.arrangement, owner: t.owner, client: t.client, contributor, closer, manager });
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
        await q.query(`UPDATE brokerage_deals SET status = 'rejected', decided_by = $2, decided_at = $3, decision_note = $4, updated_at = $3 WHERE id = $1`, [d.id, a.id, now, note]);
        await audit(q, a.id, 'brokerage.reject', 'brokerage_deal', d.id, { status: 'proposed' }, { status: 'rejected', note });
        return;
      }
      const total = N(d.total_commission_egp);
      const dist = distribution(total, b.shares as unknown[], d);
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
      const input = parseReceipt({ ...b, kind: 'commission', payerName: b.payerName || (side === 'owner' ? d.owner_name : d.client_name),
        payerPhone: b.payerPhone ?? (side === 'owner' ? d.owner_phone : d.client_phone),
        purpose: `عمولة ${d.kind === 'resale' ? 'إعادة بيع' : 'إيجار'} — ${d.property} (${side === 'owner' ? 'المالك' : d.kind === 'resale' ? 'المشتري' : 'المستأجر'})` }, a, clock());
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
      // all of it collected → the deal is closed and every employee share becomes a commission entitlement of this month
      const all = N((await one(q, `SELECT COALESCE(sum(amount_egp), 0) s FROM cash_receipts WHERE brokerage_deal_id = $1 AND status = 'posted'`, [d.id])).s);
      if (cents(all) >= cents(N(d.total_commission_egp))) {
        const now = clock(); const period = local(now).date.slice(0, 7) + '-01';
        await q.query(`UPDATE brokerage_deals SET status = 'collected', collected_at = $2, updated_at = $2 WHERE id = $1`, [d.id, now]);
        await q.query(`
          INSERT INTO commission_entitlements (request_id, brokerage_share_id, employee_id, role, amount_egp, period, included_at, created_at)
          SELECT NULL, s.id, s.employee_id, CASE WHEN s.role = 'sales_manager' THEN 'manager' ELSE 'sales' END, s.amount_egp, $2, $3, $3
            FROM brokerage_shares s WHERE s.deal_id = $1 AND s.employee_id IS NOT NULL
          ON CONFLICT (brokerage_share_id) DO NOTHING`, [d.id, period, now]);
        await audit(q, a.id, 'brokerage.collected', 'brokerage_deal', d.id, { status: 'approved' }, { status: 'collected', period });
      }
      return { id: rec.id, duplicate: rec.duplicate };
    });
    return ok({ receiptId: out.id, duplicate: out.duplicate, deal: (await load(db, [req.params.id], a))[0] }, out.duplicate ? 200 : 201);
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
    });
    return ok({ deal: (await load(db, [req.params.id], a))[0] });
  });
};
