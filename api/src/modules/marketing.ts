import { addMonths, local } from '../lib/time.ts';
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
import { grantedScopes, insightsGranted, isPermissionError, isRateLimited, safeMetaError } from '../lib/meta-oauth.ts';
import { costPer, dayComplete, insightsPath, readInsightsPage, sumOrNull, type InsightDay } from '../lib/meta-insights.ts';

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
  const it = await one(db, `SELECT access_token, insights_synced_through, meta_scopes FROM integrations WHERE source = 'meta'`);
  const token = unseal(it?.access_token);
  if (!token) return { ran: false as const, reason: 'not_connected' };
  // Insights needs ads_read (Meta's Insights API). Never called without it, never reported as working without it.
  let scopes: string[] | null = it?.meta_scopes ?? null;
  if (!scopes) {
    // a token whose permissions are not known yet (pasted by hand): read them once and keep them with the token
    try { scopes = grantedScopes(await graph('me/permissions', token)); }
    catch (e) { return { ran: true as const, complete: false, stored: 0, kept: 0, rateLimited: isRateLimited(e), since: null, until: null,
      errors: [`Insights: the token's permissions could not be read — ${safeMetaError(e)}`] }; }
    await db.query(`UPDATE integrations SET meta_scopes = $1 WHERE source = 'meta'`, [scopes]);
  }
  if (!insightsGranted(scopes)) return { ran: false as const, reason: 'insights_permission_missing' };
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
        // a malformed answer (data not a list, a bad row, a next page without a cursor) is never a complete page: the
        // valid days are kept (idempotent upsert), the pass is incomplete and the checkpoint does not move
        const pg = readInsightsPage(r, id);
        if (pg.problems.length) { complete = false; errors.push(`Insights ${id}: ${pg.problems[0]}${pg.problems.length > 1 ? ` (+${pg.problems.length - 1})` : ''}`); }
        if (!(await eachWithin(pg.days, budget, async (d) => { (await upsertInsightDay(db, d, now)) === 'stored' ? stored++ : kept++; }))) { complete = false; break; }
        if (pg.problems.some((p) => p.startsWith('malformed response'))) break;
        next = pg.after ? `${insightsPath(id, since, until)}&after=${encodeURIComponent(pg.after)}` : null;
      }
    } catch (e) {
      complete = false;
      if (isPermissionError(e)) {
        // ads_read revoked (or never effective for this ad account): Insights is off until a reconnection grants it again
        errors.push(`Insights unavailable: Meta refused for a missing permission (ads_read) — ${safeMetaError(e)}`);
        await db.query(`UPDATE integrations SET meta_scopes = array_remove(meta_scopes, 'ads_read') WHERE source = 'meta'`);
        break;
      }
      errors.push(safeMetaError(e));
      if (isRateLimited(e)) { rateLimited = true; break; }   // Meta asked us to slow down: stop the pass, retry next time
    }
  }
  complete = passComplete(complete, budget);
  if (complete) await db.query(`UPDATE integrations SET insights_synced_through = $1 WHERE source = 'meta'`, [until]);
  if (errors.length) await db.query(`UPDATE integrations SET last_error = $1 WHERE source = 'meta'`, [`Insights: ${errors.at(-1)}`]).catch(() => undefined);
  return { ran: true as const, complete, stored, kept, rateLimited, since, until, errors: [...new Set(errors)].slice(0, 5) };
}

/**
 * The scheduled Insights pass under a claim (integrations.insights_sync_at), one at a time across instances:
 *  - a complete pass keeps the claim for INSIGHTS_EVERY_MINUTES (Insights change slowly);
 *  - Meta's rate limit keeps it too (Meta asked us to slow down);
 *  - any other incomplete pass, an error or an unexpected exception gives the claim back early: the next knock after
 *    INSIGHTS_RETRY_MINUTES runs again. That is far longer than a run can live (function limit 30 s), so two runs never
 *    overlap. Only our own claim is given back (WHERE insights_sync_at = the time we claimed).
 * The checkpoint (insights_synced_through) is moved only inside a complete pass (syncInsights), never here.
 */
export const INSIGHTS_EVERY_MINUTES = 60; export const INSIGHTS_RETRY_MINUTES = 5;
export async function runInsightsClaimed(db: Db, now: Date, pass: (db: Db, now: Date) => ReturnType<typeof syncInsights> = syncInsights) {
  const claimed = await one(db, `UPDATE integrations SET insights_sync_at = $1 WHERE source = 'meta' AND active
      AND (insights_sync_at IS NULL OR insights_sync_at < $1::timestamptz - make_interval(mins => $2)) RETURNING 1`, [now, INSIGHTS_EVERY_MINUTES]);
  if (!claimed) {
    const it = await one(db, `SELECT active FROM integrations WHERE source = 'meta'`);
    return { ran: false, reason: !it?.active ? 'off' : 'recent', errors: [] as string[] };
  }
  const giveBack = () => db.query(`UPDATE integrations SET insights_sync_at = $1::timestamptz - make_interval(mins => $2)
      WHERE source = 'meta' AND insights_sync_at = $1`, [now, INSIGHTS_EVERY_MINUTES - INSIGHTS_RETRY_MINUTES]).catch(() => undefined);
  try {
    const out = await pass(db, now);
    if (!out.ran || (!out.complete && !out.rateLimited)) await giveBack();
    return { errors: [] as string[], ...out };
  } catch (e) {
    // never left holding the claim for an hour; the error is recorded without any token / URL
    await giveBack();
    const m = `Insights: ${safeMetaError(e)}`;
    await db.query(`UPDATE integrations SET last_error = $1 WHERE source = 'meta'`, [m.slice(0, 300)]).catch(() => undefined);
    return { ran: true, complete: false, errors: [m] };
  }
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

/**
 * The recurring run (POST /kpi/auto/scheduled — .github/workflows/kpi-auto.yml, main only): the current Cairo month, and
 * during the first KPI_CLOSE_DAYS days of a month also the month before (actions logged late on its last day). Only
 * owner-approved calculators run (runAutoKpis reads calc_approved_at); with none approved nothing is written. It fills
 * the result rows that exist (a period's rows are snapshotted when the KPI page of that employee and month is first
 * opened — unchanged) and never touches a manual entry or a completed result. Idempotent: the same records give the
 * same values, so a repeated or overlapping knock is harmless.
 */
export const KPI_CLOSE_DAYS = 3;
export async function runScheduledKpis(db: Db, now: Date) {
  const today = local(now).date;
  const current = `${today.slice(0, 7)}-01`;
  const periods = Number(today.slice(8, 10)) <= KPI_CLOSE_DAYS ? [addMonths(current, -1), current] : [current];
  const runs: { period: string; definitions: number; updated: number }[] = [];
  for (const period of periods) runs.push({ period, ...(await runAutoKpis(db, period, now)) });
  return { ran: true, runs, errors: [] as string[] };
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
    return ok(await runInsightsClaimed(db, clock()));
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
  r.post('/kpi/auto/scheduled', async (req) => {
    if (!hasBackupToken(req.headers)) { const a = await authenticate(db, req); requirePerm(a, 'kpi.config'); }
    return ok(await runScheduledKpis(db, clock()));
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
    const it = await one(db, `SELECT active, access_token IS NOT NULL AS connected, last_error, last_at, meta_sync_at, insights_synced_through, meta_scopes FROM integrations WHERE source = 'meta'`);
    const pages = (await one(db, `SELECT count(*)::int n, count(*) FILTER (WHERE subscribed)::int subscribed FROM meta_pages`)) ?? { n: 0, subscribed: 0 };
    const month = `${to.slice(0, 7)}-01`;
    const kpi = (await one(db, `SELECT count(*) FILTER (WHERE source = 'auto')::int auto, count(*) FILTER (WHERE source = 'manual' AND actual IS NOT NULL)::int manual,
        count(*) FILTER (WHERE actual IS NULL)::int empty FROM kpi_results WHERE period = $1`, [month])) ?? { auto: 0, manual: 0, empty: 0 };
    return ok({ from, to,
      integration: { connected: !!it?.connected, active: !!it?.active, pages: pages.n, subscribedPages: pages.subscribed,
        lastWebhookAt: it?.last_at ?? null, lastSyncAt: it?.meta_sync_at ?? null, insightsThrough: it?.insights_synced_through ?? null,
        // true / false from the token's granted permissions; null = not known yet (read at the next Insights run)
        insightsAvailable: !it?.connected ? false : it?.meta_scopes ? insightsGranted(it.meta_scopes) : null,
        lastError: it?.last_error ? safeMetaError(it.last_error) : null },
      totals: { leads: Object.values(byQuality).reduce((s: number, n: any) => s + n, 0), byQuality, bySource },
      campaigns, employees, kpi: { period: month, ...kpi } });
  });
};
