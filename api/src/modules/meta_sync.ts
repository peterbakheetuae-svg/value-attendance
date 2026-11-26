import type { Db, Q } from '../db.ts';
import { one } from '../db.ts';
import { phoneNorm, readLead } from './leads.ts';
import { deliverLead, type RouteMode } from './lead_routing.ts';
import { seeMetaCampaign } from './partners.ts';
import { unseal } from '../lib/secretbox.ts';
import { graphBase, metaFetch } from '../lib/meta-oauth.ts';
import { Budget, CLAIM_MINUTES, SCHEDULED_BUDGET_MS, eachWithin, passComplete } from '../lib/meta-sync-limits.ts';
export { CLAIM_MINUTES, SCHEDULED_BUDGET_MS };

/**
 * Meta lead ads (db/migrations/081_meta_pages_sync.sql):
 *  - several Facebook pages, each with its own page token (the webhook reads a lead with the token of its page);
 *  - the leads of a Meta campaign linked to one of our campaigns are pulled from Meta by themselves — right when it is
 *    linked (what it already has) and then every few minutes — besides the ones the webhook pushes. Each Meta lead comes
 *    in once (leads.meta_lead_id).
 */
// one Graph API version for all Meta calls (META_GRAPH_VERSION, default v25.0 — see lib/meta-oauth.ts)
export const LEAD_FIELDS = 'id,field_data,form_id,ad_id,ad_name,adset_id,campaign_id,campaign_name,created_time';
const META_ID = /^[0-9]{3,30}$/;

export async function graph(path: string, token: string, init?: RequestInit): Promise<any> {
  const sep = path.includes('?') ? '&' : '?';
  // the URL carries the token: metaFetch never logs it and never puts it in an error
  return metaFetch(`${graphBase()}/${path}${sep}access_token=${encodeURIComponent(token)}`, init);
}

/**
 * A lead Meta sent that can never be taken as it is (ingestion policy): it has no usable phone number. Retrying it
 * gives the same answer, so a sync pass reports it (`rejected`) and is still complete. Every other failure — the
 * database, a campaign without a project (configuration, fixed by a person), anything unexpected — is a processing
 * failure: the pass is incomplete and the checkpoint stays, so the next run reads the lead again.
 */
export class MetaLeadRejected extends Error {
  constructor(message: string) { super(message); this.name = 'MetaLeadRejected'; }
}

/** a Meta lead to the campaign of ours that its Meta campaign (or its form) is linked to — null = not ours / already in */
/** how a lead reached us (attribution, 092): the webhook or a sync pass, and the page it came on when known */
export interface MetaLeadOrigin { source: 'meta_webhook' | 'meta_sync'; pageId?: string | null }
const metaIdOrNull = (v: unknown) => { const x = String(v ?? ''); return META_ID.test(x) ? x : null; };

export async function takeMetaLead(db: Db, g: any, now: Date, origin: MetaLeadOrigin = { source: 'meta_sync' }): Promise<'added' | 'skipped' | 'exists' | 'unlinked'> {
  const metaId = String(g?.id ?? '').replace(/\D/g, '');
  if (metaId && await one(db, `SELECT 1 FROM leads WHERE meta_lead_id = $1`, [metaId])) return 'exists';
  const f: Record<string, string> = {};
  for (const x of Array.isArray(g?.field_data) ? g.field_data : []) f[String(x.name).toLowerCase()] = Array.isArray(x.values) ? String(x.values[0] ?? '') : '';
  const metaCampaign = String(g?.campaign_id ?? '').replace(/\D/g, '');
  const c = (metaCampaign ? await one(db, `SELECT * FROM lead_campaigns WHERE $1 = ANY(meta_campaign_ids) AND active`, [metaCampaign]) : null)
    ?? (g?.form_id ? await one(db, `SELECT * FROM lead_campaigns WHERE meta_form_id = $1 AND active`, [String(g.form_id)]) : null);
  if (metaCampaign) await seeMetaCampaign(db, metaCampaign, String(g?.campaign_name ?? ''), !c);
  if (!c) return 'unlinked';
  if (!c.project_id) throw new Error(`the campaign «${c.name}» has no project`);
  const fullName = f.full_name || [f.first_name, f.last_name].filter(Boolean).join(' ') || 'عميل من فيسبوك';
  const phone = f.phone_number || f.phone || f.mobile || '';
  if (phoneNorm(phone).length < 7) throw new MetaLeadRejected('lead without a phone');
  const extra = Object.entries(f).filter(([k]) => !['full_name', 'first_name', 'last_name', 'phone_number', 'phone', 'email'].includes(k))
    .map(([k, v]) => `${k}: ${v}`);
  const notes = [g.campaign_name ? `حملة: ${g.campaign_name}` : '', g.ad_name ? `إعلان: ${g.ad_name}` : '', ...extra].filter(Boolean).join(' — ').slice(0, 1900);
  const x = readLead({ fullName, phone, email: f.email ?? '', notes, kind: 'fresh' });
  const lead = await db.tx(async (q: Q) => {
    // one Meta lead at a time across webhook deliveries and sync runs (a transaction-scoped advisory lock, released at
    // commit), then checked again inside the lock: two concurrent takers never both add it, nor hit the unique index
    if (metaId) {
      await q.query(`SELECT pg_advisory_xact_lock(hashtext('meta_lead:' || $1))`, [metaId]);
      if (await one(q, `SELECT 1 FROM leads WHERE meta_lead_id = $1`, [metaId])) return 'exists' as const;
    }
    x.projectId ??= c.project_id ?? null; x.channelId ??= c.channel_id ?? null; x.campaignId = c.id;
    // the same number twice on the same campaign the same day: once
    if (await one(q, `SELECT 1 FROM leads WHERE campaign_id = $1 AND phone_norm = $2 AND created_at > $3::timestamptz - interval '1 day'`,
      [c.id, phoneNorm(x.phone), now])) return null;
    const l = await deliverLead(q, x, (c.assign_mode ?? 'turn') as RouteMode, c.form_assignees ?? [], now, 'فيسبوك', c.name ?? '');
    if (metaId) await q.query(`UPDATE leads SET meta_lead_id = $2 WHERE id = $1`, [l.id, metaId]);
    // attribution (092), once, as Meta gave it: an id Meta did not send stays NULL; the marketing company is the campaign's
    // owner at this moment (a later ownership change never rewrites it — leads_attribution_once)
    await q.query(`UPDATE leads SET meta_page_id = $2, meta_form_id = $3, meta_campaign_id = $4, meta_adset_id = $5, meta_ad_id = $6,
        attributed_company_id = $7, attributed_at = $8, attribution_source = $9 WHERE id = $1 AND attribution_source IS NULL`,
      [l.id, metaIdOrNull(origin.pageId), metaIdOrNull(g?.form_id), metaIdOrNull(g?.campaign_id), metaIdOrNull(g?.adset_id),
        metaIdOrNull(g?.ad_id), c.marketing_company_id ?? null, now, origin.source]);
    return l;
  });
  return lead === 'exists' ? 'exists' : lead ? 'added' : 'skipped';
}

/** the token a page's leads are read with: its own, else the office's saved one */
export async function pageToken(db: Db, pageId: string | null): Promise<string | null> {
  if (pageId) {
    const p = await one(db, `SELECT access_token FROM meta_pages WHERE page_id = $1`, [pageId]);
    if (p) return unseal(p.access_token);
  }
  return unseal((await one(db, `SELECT access_token FROM integrations WHERE source = 'meta'`))?.access_token);
}

/**
 * Pulls the leads of the linked Meta campaigns (all, or one campaign of ours) from every saved page's lead forms (and,
 * with the office's token, from the campaigns' ads). Returns how many came in. Never throws: errors are kept on the page /
 * the integration.
 */
export async function syncMeta(db: Db, now: Date, opts: { campaignId?: string; deadlineMs?: number; clock?: () => number } = {}): Promise<{ added: number; errors: string[]; rejected: string[]; complete: boolean }> {
  // the budget is checked before every Meta request and before every lead (each lead is its own transaction, under its
  // advisory lock): once it is spent no new work starts, so a run ends within budget + one request / one lead
  const budget = new Budget(opts.deadlineMs ?? 20_000, opts.clock ?? Date.now);
  const errors: string[] = [];
  const rejected: string[] = [];
  let added = 0;
  // a pass is complete only if nothing was cut short (budget, the 20-page cap, a page whose forms could not be read);
  // only a complete pass moves the campaigns' checkpoint — otherwise the next run reads the same window again (idempotent)
  let complete = true;
  const camps = (await db.query(`SELECT id, meta_campaign_ids, meta_synced_at FROM lead_campaigns
      WHERE active AND cardinality(meta_campaign_ids) > 0 ${opts.campaignId ? 'AND id = $1' : ''}`, opts.campaignId ? [opts.campaignId] : [])).rows;
  if (!camps.length) return { added, errors, rejected, complete };
  const wanted = new Set<string>(camps.flatMap((c) => (c.meta_campaign_ids ?? []).map(String)));
  // from the oldest sync of these campaigns (a campaign never synced: its last 90 days)
  const since = new Date(Math.min(...camps.map((c) => (c.meta_synced_at ? new Date(c.meta_synced_at).getTime() - 3_600_000 : now.getTime() - 90 * 86_400_000))));
  const filtering = encodeURIComponent(JSON.stringify([{ field: 'time_created', operator: 'GREATER_THAN', value: Math.floor(since.getTime() / 1000) }]));
  const takeFrom = (pageId: string | null) => async (g: any) => {
    if (!wanted.has(String(g?.campaign_id ?? ''))) return;
    try { if (await takeMetaLead(db, g, now, { source: 'meta_sync', pageId }) === 'added') added++; }
    catch (e: any) {
      const id = String(g?.id ?? '').replace(/\D/g, '').slice(0, 30);
      // a permanent rejection (no phone) is reported and not retried forever: the pass stays complete
      if (e instanceof MetaLeadRejected) { rejected.push(`${e.message} (lead ${id})`); return; }
      // anything else (database, configuration, unexpected) is a processing failure: the pass is incomplete, the
      // checkpoint does not move and the next run reads this lead again (idempotent: meta_lead_id + advisory lock)
      complete = false;
      errors.push(String(e?.message ?? e));
    }
  };
  const leadsOf = async (edge: string, token: string, pageId: string | null) => {
    let next: string | null = `${edge}/leads?fields=${LEAD_FIELDS}&limit=100&filtering=${filtering}`;
    for (let page = 0; next && page < 20 && budget.left(); page++) {
      const r: any = await graph(next, token);
      if (!(await eachWithin(Array.isArray(r.data) ? r.data : [], budget, takeFrom(pageId)))) { complete = false; return; }
      const after = r?.paging?.cursors?.after;
      next = r?.paging?.next && after ? `${edge}/leads?fields=${LEAD_FIELDS}&limit=100&filtering=${filtering}&after=${encodeURIComponent(after)}` : null;
    }
    if (next) complete = false;   // the budget or the page cap stopped it with pages left
  };
  const pages = (await db.query(`SELECT page_id, access_token FROM meta_pages ORDER BY added_at`)).rows;
  const office = unseal((await one(db, `SELECT access_token FROM integrations WHERE source = 'meta'`))?.access_token);
  // 1) every page's lead forms (a page token reads its own forms' leads)
  const sources = [...pages.map((p) => ({ id: String(p.page_id), token: unseal(p.access_token) ?? '' })).filter((p) => p.token), ...(office && !pages.length ? [{ id: 'me', token: office }] : [])];
  for (const p of sources) {
    if (!budget.left()) { complete = false; break; }
    try {
      const forms = await graph(`${p.id}/leadgen_forms?fields=id&limit=100`, p.token);
      for (const fm of Array.isArray(forms.data) ? forms.data : []) {
        if (!budget.left()) { complete = false; break; }
        if (META_ID.test(String(fm.id))) await leadsOf(String(fm.id), p.token, p.id === 'me' ? null : p.id);
      }
      if (p.id !== 'me' && budget.left()) await db.query(`UPDATE meta_pages SET last_error = NULL WHERE page_id = $1`, [p.id]);
    } catch (e: any) {
      complete = false;
      const m = String(e?.message ?? e).slice(0, 300);
      errors.push(m);
      if (p.id !== 'me') await db.query(`UPDATE meta_pages SET last_error = $2 WHERE page_id = $1`, [p.id, m]);
    }
  }
  // 2) the office's (ads) token: the campaigns' ads' leads
  if (office) {
    for (const mc of wanted) {
      if (!budget.left()) { complete = false; break; }
      try {
        const ads = await graph(`${mc}/ads?fields=id&limit=200`, office);
        for (const ad of Array.isArray(ads.data) ? ads.data : []) {
          if (!budget.left()) { complete = false; break; }
          if (META_ID.test(String(ad.id))) await leadsOf(String(ad.id), office, null);
        }
      } catch { /* a page token cannot read ads: the forms above are enough (not an incomplete pass) */ }
    }
  }
  // the budget is checked once more right before the checkpoint: a pass whose last lead ran past the deadline is
  // incomplete, and its checkpoint stays where it was (the next run resumes from it — idempotent)
  complete = passComplete(complete, budget);
  if (complete) await db.query(`UPDATE lead_campaigns SET meta_synced_at = $2 WHERE id = ANY($1::uuid[])`, [camps.map((c) => c.id), now]);
  // finalization after this point never touches the checkpoint
  if (errors.length) await db.query(`UPDATE integrations SET last_error = $1 WHERE source = 'meta'`, [errors.at(-1)!.slice(0, 300)]).catch(() => undefined);
  return { added, errors, rejected, complete };
}

/**
 * The scheduler's run (POST /integrations/meta/sync/run — a GitHub Actions cron, see .github/workflows/meta-sync.yml):
 * independent of anyone opening the app. It claims the same «meta_sync_at» slot as maybeSyncMeta (one run at a time across
 * API instances, at most every 5 minutes), with a longer time budget. Idempotent: every Meta lead comes in once
 * (leads.meta_lead_id is unique), so a webhook and a scheduled run that see the same lead add it once.
 */
export async function runScheduledMetaSync(db: Db, now: Date): Promise<{ ran: boolean; reason?: string; added?: number; complete?: boolean; errors?: string[]; rejected?: string[] }> {
  const claimed = await one(db, `UPDATE integrations SET meta_sync_at = $1
      WHERE source = 'meta' AND active AND (meta_sync_at IS NULL OR meta_sync_at < $1::timestamptz - make_interval(mins => $2))
        AND (access_token IS NOT NULL OR EXISTS (SELECT 1 FROM meta_pages))
      RETURNING 1`, [now, CLAIM_MINUTES]);
  if (!claimed) {
    const it = await one(db, `SELECT active, access_token IS NOT NULL OR EXISTS (SELECT 1 FROM meta_pages) AS connected FROM integrations WHERE source = 'meta'`);
    return { ran: false, reason: !it?.active ? 'off' : !it.connected ? 'not_connected' : 'recent' };
  }
  if (!(await one(db, `SELECT 1 FROM lead_campaigns WHERE active AND cardinality(meta_campaign_ids) > 0 LIMIT 1`))) {
    return { ran: false, reason: 'no_linked_campaigns' };
  }
  // the time budget stays inside the function's hard limit (maxDuration 30 s, scripts/vercel-build.mjs): 18 s of work + at
  // most one Meta request in flight (8 s timeout) + the checkpoint write. A killed run loses nothing: each lead is its own
  // transaction and the checkpoint (meta_synced_at) only moves after a complete pass, so the next run re-reads the window.
  // Two scheduled runs cannot overlap: the claim lasts 5 minutes, ten times the longest a run can live.
  const r = await syncMeta(db, now, { deadlineMs: SCHEDULED_BUDGET_MS });
  return { ran: true, added: r.added, complete: r.complete, errors: [...new Set(r.errors)].slice(0, 5), rejected: [...new Set(r.rejected)].slice(0, 5) };
}

/** every 10 minutes at most (the first request after that pays it, with a short time budget) */
export async function maybeSyncMeta(db: Db, now: Date): Promise<void> {
  const claimed = await one(db, `UPDATE integrations SET meta_sync_at = $1
      WHERE source = 'meta' AND active AND (meta_sync_at IS NULL OR meta_sync_at < $1::timestamptz - interval '10 minutes')
        AND (access_token IS NOT NULL OR EXISTS (SELECT 1 FROM meta_pages))
        AND EXISTS (SELECT 1 FROM lead_campaigns WHERE active AND cardinality(meta_campaign_ids) > 0)
      RETURNING 1`, [now]).catch(() => null);
  if (!claimed) return;
  await syncMeta(db, now, { deadlineMs: 6000 }).catch(() => undefined);
}
