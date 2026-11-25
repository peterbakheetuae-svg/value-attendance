import { ok, type Module } from '../ctx.ts';
import { one, type Db, type Q } from '../db.ts';
import { AppError, forbidden, invalid, notFound } from '../http/errors.ts';
import { isUuid, obj, oneOf, str } from '../http/validate.ts';
import { audit, authenticate, has, isOwner, requirePerm } from '../auth/context.ts';
import type { Req } from '../http/router.ts';
import { hasBackupToken } from '../lib/backup-token.ts';
import { unseal } from '../lib/secretbox.ts';
import { graph } from './meta_sync.ts';
import { Budget, eachWithin, passComplete, SCHEDULED_BUDGET_MS } from '../lib/meta-sync-limits.ts';
import { isRateLimited, safeMetaError } from '../lib/meta-oauth.ts';
import { costPer, dayComplete, insightsPath, parseInsightRow, sumOrNull, type InsightDay } from '../lib/meta-insights.ts';

/**
 * Marketing Intelligence (092): Meta Ads Insights snapshots (D), lead quality (E), KPI calculation sources (F), campaign
 * attribution / ownership reads (C) and the unified dashboard (G). Every route checks its permission on the server; a
 * marketing company's token never reaches these routes (auth/context.ts partnerRoute).
 */

// ------------------------------------------------------------------ D. Ads Insights
const day = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (s: string, n: number) => day(new Date(Date.parse(`${s}T00:00:00Z`) + n * 86_400_000));
/** Meta keeps changing recent days (attribution windows): each pass re-reads the last days before its checkpoint */
const REREAD_DAYS = 3; const FIRST_DAYS = 28;

export async function upsertInsightDay(q: Q, d: InsightDay, now: Date): Promise<'stored' | 'kept'> {
  // a stored day is replaced only by a COMPLETE answer: an incomplete (partial) answer never overwrites history
  const r = await q.query(`
    INSERT INTO meta_insights_daily (meta_campaign_id, day, account_id, account_currency, campaign_name, objective, impressions, reach,
      clicks, spend, cpm, cpc, ctr, leads, cost_per_lead, fetched_at)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)
    ON CONFLICT (meta_campaign_id, day) DO UPDATE SET account_id = EXCLUDED.account_id, account_currency = EXCLUDED.account_currency,
      campaign_name = EXCLUDED.campaign_name, objective = EXCLUDED.objective, impressions = EXCLUDED.impressions, reach = EXCLUDED.reach,
      clicks = EXCLUDED.clicks, spend = EXCLUDED.spend, cpm = EXCLUDED.cpm, cpc = EXCLUDED.cpc, ctr = EXCLUDED.ctr, leads = EXCLUDED.leads,
      cost_per_lead = EXCLUDED.cost_per_lead, fetched_at = EXCLUDED.fetched_at
    WHERE $17::boolean`,
    [d.metaCampaignId, d.day, d.accountId, d.currency, d.campaignName, d.objective, d.impressions, d.reach, d.clicks, d.spend, d.cpm, d.cpc,
      d.ctr, d.leads, d.costPerLead, now, dayComplete(d)]);
  return r.rowCount ? 'stored' : 'kept';
}

/**
 * One insights pass: every Meta campaign linked to an active campaign of ours, day by day, from the checkpoint
 * (insights_synced_through − 3 days, or the last 28 days) to yesterday. The budget is checked before every request and
 * every day stored; a rate limit, an error or the budget makes the pass incomplete and the checkpoint stays.
 */
export async function syncInsights(db: Db, now: Date, opts: { deadlineMs?: number; clock?: () => number } = {}) {
  const budget = new Budget(opts.deadlineMs ?? SCHEDULED_BUDGET_MS, opts.clock ?? Date.now);
  const it = await one(db, `SELECT access_token, insights_synced_through FROM integrations WHERE source = 'meta'`);
  const token = unseal(it?.access_token);
  if (!token) return { ran: false as const, reason: 'not_connected' };
  const ids = (await db.query(`SELECT DISTINCT unnest(meta_campaign_ids) AS id FROM lead_campaigns WHERE active`)).rows
    .map((x) => String(x.id)).filter((x) => /^[0-9]{3,30}$/.test(x)).sort();
  if (!ids.length) return { ran: false as const, reason: 'no_linked_campaigns' };
  const until = addDays(day(now), -1);
  const through = it?.insights_synced_through ? day(new Date(it.insights_synced_through)) : null;
  const since = through ? addDays(through, -REREAD_DAYS) : addDays(until, -(FIRST_DAYS - 1));
  let complete = true; let stored = 0; let kept = 0; let rateLimited = false;
  const errors: string[] = [];
  for (const id of ids) {
    if (!budget.left()) { complete = false; break; }
    try {
      let next: string | null = insightsPath(id, since, until);
      for (let page = 0; next; page++) {
        if (page >= 10 || !budget.left()) { complete = false; break; }
        const r: any = await graph(next, token);
        const rows: any[] = Array.isArray(r.data) ? r.data : [];
        const days: InsightDay[] = rows.map(parseInsightRow).filter((d): d is InsightDay => !!d && d.metaCampaignId === id);
        if (!(await eachWithin(days, budget, async (d) => { (await upsertInsightDay(db, d, now)) === 'stored' ? stored++ : kept++; }))) { complete = false; break; }
        const after = r?.paging?.cursors?.after;
        next = r?.paging?.next && after ? `${insightsPath(id, since, until)}&after=${encodeURIComponent(after)}` : null;
      }
    } catch (e) {
      complete = false;
      errors.push(safeMetaError(e));
      if (isRateLimited(e)) { rateLimited = true; break; }   // Meta asked us to slow down: stop the pass, retry next time
    }
  }
  complete = passComplete(complete, budget);
  if (complete) await db.query(`UPDATE integrations SET insights_synced_through = $1 WHERE source = 'meta'`, [until]);
  if (errors.length) await db.query(`UPDATE integrations SET last_error = $1 WHERE source = 'meta'`, [`Insights: ${errors.at(-1)}`]).catch(() => undefined);
  return { ran: true as const, complete, stored, kept, rateLimited, since, until, errors: [...new Set(errors)].slice(0, 5) };
}

// ------------------------------------------------------------------ F. KPI calculators (candidates — none active by default)
/**
 * The calculation sources a KPI definition can be mapped to. Each one is an exact formula on records the system already
 * keeps; none is used until the owner maps it to a definition AND approves it (kpi_definitions.calc_approved_at).
 * Period = the KPI month, in Cairo time.
 */
interface Calculator { label: string; formula: string; sql: string }
const IN_MONTH = (col: string) => `${col} >= ($2::date::timestamp AT TIME ZONE 'Africa/Cairo') AND ${col} < (($2::date + interval '1 month')::timestamp AT TIME ZONE 'Africa/Cairo')`;
export const KPI_CALCULATORS: Record<string, Calculator> = {
  lead_actions: { label: 'كل الإجراءات اليدوية على الليدز', formula: 'count(lead_actions) by the employee, not automatic, in the month',
    sql: `SELECT count(*)::int n FROM lead_actions WHERE by_id = $1 AND NOT auto AND ${IN_MONTH('created_at')}` },
  answered_calls: { label: 'مكالمات اترد عليها', formula: 'count(lead_actions) by the employee with answered = true, in the month',
    sql: `SELECT count(*)::int n FROM lead_actions WHERE by_id = $1 AND answered IS TRUE AND ${IN_MONTH('created_at')}` },
  meetings_set: { label: 'ميتنجات اتحددت', formula: "count(lead_actions) by the employee moving a lead to stage 'meeting', in the month",
    sql: `SELECT count(*)::int n FROM lead_actions WHERE by_id = $1 AND stage = 'meeting' AND ${IN_MONTH('created_at')}` },
  reservations: { label: 'حجوزات', formula: "count(lead_actions) by the employee moving a lead to stage 'reservation', in the month",
    sql: `SELECT count(*)::int n FROM lead_actions WHERE by_id = $1 AND stage = 'reservation' AND ${IN_MONTH('created_at')}` },
  deals_won: { label: 'صفقات تمت', formula: "count(lead_actions) by the employee moving a lead to stage 'done_deal', in the month",
    sql: `SELECT count(*)::int n FROM lead_actions WHERE by_id = $1 AND stage = 'done_deal' AND ${IN_MONTH('created_at')}` },
  qualified_leads: { label: 'ليدز اتصنفت مؤهلة', formula: "count(distinct leads assigned to the employee whose quality became 'qualified' in the month)",
    sql: `SELECT count(DISTINCT e.lead_id)::int n FROM lead_quality_events e JOIN leads l ON l.id = e.lead_id
           WHERE l.assigned_to = $1 AND e.to_q = 'qualified' AND ${IN_MONTH('e.at')}` },
};

/**
 * Fills the automatic KPI results of a month: only definitions with an APPROVED calculator; only result rows that are
 * automatic already or still empty (no value, nobody entered one); never a completed row; never a manual entry.
 * Each value carries its formula, the calculator and the moment it was calculated.
 */
export async function runAutoKpis(db: Db, period: string, now: Date) {
  const defs = (await db.query(`SELECT id, key, calc_source FROM kpi_definitions WHERE calc_source IS NOT NULL AND calc_approved_at IS NOT NULL`)).rows
    .filter((d) => KPI_CALCULATORS[d.calc_source]);
  let updated = 0;
  for (const d of defs) {
    const calc = KPI_CALCULATORS[d.calc_source];
    const rows = (await db.query(`SELECT id, employee_id FROM kpi_results WHERE kpi_id = $1 AND period = $2 AND state <> 'completed'
        AND (source = 'auto' OR (actual IS NULL AND entered_by IS NULL))`, [d.id, period])).rows;
    for (const r of rows) {
      const n = (await one(db, calc.sql, [r.employee_id, period]))?.n ?? null;
      const u = await db.query(`UPDATE kpi_results SET actual = $2, state = 'in_progress', source = 'auto', calculated_at = $3, evidence = $4, updated_at = $3
          WHERE id = $1 AND state <> 'completed' AND (source = 'auto' OR (actual IS NULL AND entered_by IS NULL))`,
        [r.id, n, now, JSON.stringify({ calculator: d.calc_source, formula: calc.formula, period, value: n })]);
      updated += u.rowCount ?? 0;
    }
  }
  return { definitions: defs.length, updated };
}

// ------------------------------------------------------------------ E. lead quality
export const QUALITY = ['unreviewed', 'qualified', 'not_qualified', 'invalid_contact', 'duplicate', 'unreachable'] as const;
const NEEDS_REASON = new Set(['not_qualified', 'invalid_contact', 'duplicate', 'unreachable']);

export const marketingModule: Module = (r, { db, clock }) => {
  const manager = async (req: Req) => {
    const a = await authenticate(db, req);
    if (a.partner || !has(a, 'leads.read_all')) throw forbidden('للإدارة بس');
    return a;
  };
  const metaManager = async (req: Req) => {
    const a = await authenticate(db, req);
    if (a.partner || !has(a, 'leads.config')) throw forbidden('ربط Meta لمن عنده إعدادات الليدز');
    return a;
  };

  // ---------------------------------------------- D. insights: the scheduler's knock (or a person with leads.config)
  r.post('/integrations/meta/insights/run', async (req) => {
    if (!hasBackupToken(req.headers)) await metaManager(req);
    const now = clock();
    // one pass at a time, at most every 60 minutes (the same claim pattern as the leads sync)
    const claimed = await one(db, `UPDATE integrations SET insights_sync_at = $1 WHERE source = 'meta' AND active
        AND (insights_sync_at IS NULL OR insights_sync_at < $1::timestamptz - interval '60 minutes') RETURNING 1`, [now]);
    if (!claimed) {
      const it = await one(db, `SELECT active FROM integrations WHERE source = 'meta'`);
      return ok({ ran: false, reason: !it?.active ? 'off' : 'recent', errors: [] });
    }
    const out = await syncInsights(db, now);
    return ok({ errors: [], ...out });
  });

  // ---------------------------------------------- E. quality: classify (with history), read the history
  r.post('/leads/:id/quality', async (req) => {
    const a = await authenticate(db, req);
    if (a.partner || !has(a, 'leads.quality')) throw forbidden('تصنيف جودة الليد لمن عنده صلاحية «تصنيف جودة الليد»');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const to = oneOf(b, 'quality', QUALITY)!;
    const reason = (str(b, 'reason', { optional: true, max: 500 }) ?? '').trim();
    if (NEEDS_REASON.has(to) && reason.length < 3) throw invalid('اكتب السبب', { field: 'reason' });
    const evidence = b.evidence && typeof b.evidence === 'object' && !Array.isArray(b.evidence) && JSON.stringify(b.evidence).length <= 2000 ? b.evidence : null;
    const out = await db.tx(async (q) => {
      const l = await one(q, `SELECT id, quality FROM leads WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!l) throw notFound();
      if (l.quality === to) return { changed: false, quality: to };
      await q.query(`INSERT INTO lead_quality_events (lead_id, from_q, to_q, reason, evidence, by_id, at) VALUES ($1,$2,$3,$4,$5,$6,$7)`,
        [l.id, l.quality, to, reason, evidence ? JSON.stringify(evidence) : null, a.id, clock()]);
      await q.query(`UPDATE leads SET quality = $2 WHERE id = $1`, [l.id, to]);
      await audit(q, a.id, 'lead.quality', 'lead', l.id, { quality: l.quality }, { quality: to });
      return { changed: true, quality: to };
    });
    return ok(out);
  });
  r.get('/leads/:id/quality', async (req) => {
    const a = await authenticate(db, req);
    if (a.partner || !(has(a, 'leads.quality') || has(a, 'leads.read_all'))) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const l = await one(db, `SELECT id, quality, attribution_source, attributed_at, attributed_company_id, meta_page_id, meta_form_id,
        meta_campaign_id, meta_adset_id, meta_ad_id FROM leads WHERE id = $1`, [req.params.id]);
    if (!l) throw notFound();
    const history = (await db.query(`SELECT e.from_q, e.to_q, e.reason, e.at, emp.full_name AS by_name FROM lead_quality_events e
        LEFT JOIN employees emp ON emp.id = e.by_id WHERE e.lead_id = $1 ORDER BY e.at DESC LIMIT 100`, [l.id])).rows;
    return ok({ quality: l.quality, canClassify: has(a, 'leads.quality'),
      attribution: { source: l.attribution_source, at: l.attributed_at, companyId: l.attributed_company_id, pageId: l.meta_page_id,
        formId: l.meta_form_id, campaignId: l.meta_campaign_id, adsetId: l.meta_adset_id, adId: l.meta_ad_id },
      history: history.map((h) => ({ from: h.from_q, to: h.to_q, reason: h.reason, at: h.at, by: h.by_name })) });
  });

  // ---------------------------------------------- C. manual attribution (a lead with none yet) and ownership history
  r.post('/leads/:id/attribution', async (req) => {
    const a = await authenticate(db, req);
    if (a.partner || !has(a, 'leads.config')) throw forbidden();
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const company = b.companyId === null || b.companyId === undefined ? null : String(b.companyId);
    if (company && !(isUuid(company) && await one(db, `SELECT 1 FROM marketing_companies WHERE id = $1`, [company]))) throw invalid('شركة غير معروفة', { field: 'companyId' });
    const u = await db.query(`UPDATE leads SET attribution_source = 'manual', attributed_company_id = $2, attributed_at = $3
        WHERE id = $1 AND attribution_source IS NULL`, [req.params.id, company, clock()]);
    if (!u.rowCount) {
      if (!(await one(db, `SELECT 1 FROM leads WHERE id = $1`, [req.params.id]))) throw notFound();
      throw new AppError('conflict', 'الليد ده مصدره متسجل خلاص — المصدر بيتسجل مرة واحدة');
    }
    await audit(db, a.id, 'lead.attribution_manual', 'lead', req.params.id, undefined, { companyId: company });
    return ok({ ok: true });
  });
  r.get('/leads/campaigns/:id/owners', async (req) => {
    await manager(req);
    if (!isUuid(req.params.id)) throw notFound();
    const rows = (await db.query(`SELECT o.marketing_company_id, mc.name, o.from_at, o.to_at FROM lead_campaign_owners o
        LEFT JOIN marketing_companies mc ON mc.id = o.marketing_company_id WHERE o.campaign_id = $1 ORDER BY o.from_at DESC`, [req.params.id])).rows;
    return ok({ owners: rows.map((x) => ({ companyId: x.marketing_company_id, company: x.name ?? null, officeDirect: !x.marketing_company_id, from: x.from_at, to: x.to_at })) });
  });

  // ---------------------------------------------- F. KPI sources: list, map (kpi.config), approve (owner), run
  r.get('/kpi/calculators', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'kpi.config');
    const defs = (await db.query(`SELECT id, key, name_ar, calc_source, calc_approved_at FROM kpi_definitions ORDER BY name_ar`)).rows;
    return ok({ calculators: Object.entries(KPI_CALCULATORS).map(([key, c]) => ({ key, label: c.label, formula: c.formula })),
      definitions: defs.map((d) => ({ id: d.id, key: d.key, nameAr: d.name_ar, calcSource: d.calc_source, approvedAt: d.calc_approved_at,
        status: !d.calc_source ? 'manual' : d.calc_approved_at ? 'auto' : 'pending_approval' })) });
  });
  r.patch('/kpi/definitions/:id/calc', async (req) => {
    const a = await authenticate(db, req); requirePerm(a, 'kpi.config');
    if (!isUuid(req.params.id)) throw notFound();
    const b = obj(req.body);
    const src = b.calcSource === null ? null : oneOf(b, 'calcSource', Object.keys(KPI_CALCULATORS) as [string, ...string[]])!;
    // a new mapping always needs a new approval
    const d = await one(db, `UPDATE kpi_definitions SET calc_source = $2, calc_approved_by = NULL, calc_approved_at = NULL WHERE id = $1 RETURNING id`, [req.params.id, src]);
    if (!d) throw notFound();
    await audit(db, a.id, 'kpi.calc_map', 'kpi_definition', d.id, undefined, { calcSource: src });
    return ok({ ok: true, status: src ? 'pending_approval' : 'manual' });
  });
  r.post('/kpi/definitions/:id/calc/approve', async (req) => {
    const a = await authenticate(db, req);
    if (!isOwner(a)) throw forbidden('اعتماد الحساب التلقائي للمؤشر للمالك بس');
    if (!isUuid(req.params.id)) throw notFound();
    const d = await one(db, `UPDATE kpi_definitions SET calc_approved_by = $2, calc_approved_at = $3 WHERE id = $1 AND calc_source IS NOT NULL RETURNING id, calc_source`,
      [req.params.id, a.id, clock()]);
    if (!d) throw invalid('المؤشر مالوش مصدر حساب محدد', { field: 'calcSource' });
    await audit(db, a.id, 'kpi.calc_approve', 'kpi_definition', d.id, undefined, { calcSource: d.calc_source });
    return ok({ ok: true });
  });
  r.post('/kpi/auto/run', async (req) => {
    if (!hasBackupToken(req.headers)) { const a = await authenticate(db, req); requirePerm(a, 'kpi.config'); }
    const b = obj(req.body ?? {});
    const period = String(b.period ?? '');
    if (!/^\d{4}-\d{2}-01$/.test(period)) throw invalid('الشهر لازم يكون أول يوم في الشهر (YYYY-MM-01)', { field: 'period' });
    return ok(await runAutoKpis(db, period, clock()));
  });

  // ---------------------------------------------- G. the unified dashboard (management only)
  r.get('/marketing/overview', async (req) => {
    await manager(req);
    const q = req.query;
    const isDay = (s: string | null) => !!s && /^\d{4}-\d{2}-\d{2}$/.test(s) && !Number.isNaN(Date.parse(s));
    const to = isDay(q.get('to')) ? q.get('to')! : day(clock());
    const from = isDay(q.get('from')) ? q.get('from')! : addDays(to, -29);
    if (from > to) throw invalid('من لازم يكون قبل إلى', { field: 'from' });
    const f: string[] = [`l.created_at >= ($1::date::timestamp AT TIME ZONE 'Africa/Cairo')`, `l.created_at < (($2::date + 1)::timestamp AT TIME ZONE 'Africa/Cairo')`];
    const p: unknown[] = [from, to];
    const add = (sql: string, v: unknown) => { p.push(v); f.push(sql.replace('?', `$${p.length}`)); };
    const id = (k: string) => { const v = q.get(k); if (v && !isUuid(v)) throw invalid('معرّف غير صالح', { field: k }); return v; };
    if (id('campaignId')) add('l.campaign_id = ?', q.get('campaignId'));
    if (id('companyId')) add('l.attributed_company_id = ?', q.get('companyId'));
    if (id('employeeId')) add('l.assigned_to = ?', q.get('employeeId'));
    const source = q.get('source');
    if (source) { if (!['meta_webhook', 'meta_sync', 'manual', 'unknown'].includes(source)) throw invalid('مصدر غير معروف', { field: 'source' });
      if (source === 'unknown') f.push('l.attribution_source IS NULL'); else add('l.attribution_source = ?', source); }
    const quality = q.get('quality');
    if (quality) { if (!(QUALITY as readonly string[]).includes(quality)) throw invalid('جودة غير معروفة', { field: 'quality' }); add('l.quality = ?', quality); }
    const where = f.join(' AND ');
    const byQuality = Object.fromEntries((await db.query(`SELECT l.quality, count(*)::int n FROM leads l WHERE ${where} GROUP BY 1`, p)).rows.map((x) => [x.quality, x.n]));
    const bySource = Object.fromEntries((await db.query(`SELECT COALESCE(l.attribution_source, 'unknown') s, count(*)::int n FROM leads l WHERE ${where} GROUP BY 1`, p)).rows.map((x) => [x.s, x.n]));
    const camps = (await db.query(`SELECT c.id, c.name, c.marketing_company_id, mc.name AS company, c.meta_campaign_ids,
        count(l.id)::int leads, count(l.id) FILTER (WHERE l.quality = 'qualified')::int qualified,
        count(l.id) FILTER (WHERE l.stage = 'reservation')::int reservations, count(l.id) FILTER (WHERE l.stage = 'done_deal')::int won
      FROM lead_campaigns c LEFT JOIN marketing_companies mc ON mc.id = c.marketing_company_id
      JOIN leads l ON l.campaign_id = c.id AND ${where}
      GROUP BY c.id, mc.name ORDER BY leads DESC LIMIT 100`, p)).rows;
    // spend: Meta's daily snapshots of each campaign's Meta campaigns in the range (account currency); none stored = unknown
    const ins = (await db.query(`SELECT meta_campaign_id, account_currency, spend, impressions, clicks, leads FROM meta_insights_daily WHERE day BETWEEN $1 AND $2`, [from, to])).rows;
    const campaigns = camps.map((c) => {
      const mine = ins.filter((x) => (c.meta_campaign_ids ?? []).map(String).includes(String(x.meta_campaign_id)));
      const currencies = [...new Set(mine.map((x) => x.account_currency).filter(Boolean))];
      const spend = currencies.length > 1 ? null : sumOrNull(mine.map((x) => (x.spend === null ? null : Number(x.spend))));
      return { id: c.id, name: c.name, companyId: c.marketing_company_id, company: c.company ?? null, officeDirect: !c.marketing_company_id,
        leads: c.leads, qualified: c.qualified, reservations: c.reservations, won: c.won,
        spend, currency: currencies.length === 1 ? currencies[0] : null, mixedCurrencies: currencies.length > 1,
        impressions: sumOrNull(mine.map((x) => (x.impressions === null ? null : Number(x.impressions)))),
        metaLeads: sumOrNull(mine.map((x) => (x.leads === null ? null : Number(x.leads)))),
        costPerLead: costPer(spend, c.leads), costPerQualified: costPer(spend, c.qualified) };
    });
    const employees = (await db.query(`SELECT e.id, e.full_name, count(l.id)::int leads, count(l.id) FILTER (WHERE l.quality = 'qualified')::int qualified,
        count(l.id) FILTER (WHERE l.stage = 'done_deal')::int won
      FROM leads l JOIN employees e ON e.id = l.assigned_to WHERE ${where} GROUP BY e.id ORDER BY leads DESC LIMIT 100`, p)).rows
      .map((x) => ({ id: x.id, name: x.full_name, leads: x.leads, qualified: x.qualified, won: x.won }));
    const it = await one(db, `SELECT active, access_token IS NOT NULL AS connected, last_error, last_at, meta_sync_at, insights_synced_through FROM integrations WHERE source = 'meta'`);
    const pages = (await one(db, `SELECT count(*)::int n, count(*) FILTER (WHERE subscribed)::int subscribed FROM meta_pages`)) ?? { n: 0, subscribed: 0 };
    const month = `${to.slice(0, 7)}-01`;
    const kpi = (await one(db, `SELECT count(*) FILTER (WHERE source = 'auto')::int auto, count(*) FILTER (WHERE source = 'manual' AND actual IS NOT NULL)::int manual,
        count(*) FILTER (WHERE actual IS NULL)::int empty FROM kpi_results WHERE period = $1`, [month])) ?? { auto: 0, manual: 0, empty: 0 };
    return ok({ from, to,
      integration: { connected: !!it?.connected, active: !!it?.active, pages: pages.n, subscribedPages: pages.subscribed,
        lastWebhookAt: it?.last_at ?? null, lastSyncAt: it?.meta_sync_at ?? null, insightsThrough: it?.insights_synced_through ?? null,
        lastError: it?.last_error ? safeMetaError(it.last_error) : null },
      totals: { leads: Object.values(byQuality).reduce((s: number, n: any) => s + n, 0), byQuality, bySource },
      campaigns, employees, kpi: { period: month, ...kpi } });
  });
};
