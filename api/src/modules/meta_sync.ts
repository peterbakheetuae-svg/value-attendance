import type { Db, Q } from '../db.ts';
import { one } from '../db.ts';
import { phoneNorm, readLead } from './leads.ts';
import { deliverLead, type RouteMode } from './lead_routing.ts';
import { seeMetaCampaign } from './partners.ts';
import { unseal } from '../lib/secretbox.ts';
import { graphBase } from '../lib/meta-oauth.ts';

/**
 * Meta lead ads (db/migrations/081_meta_pages_sync.sql):
 *  - several Facebook pages, each with its own page token (the webhook reads a lead with the token of its page);
 *  - the leads of a Meta campaign linked to one of our campaigns are pulled from Meta by themselves — right when it is
 *    linked (what it already has) and then every few minutes — besides the ones the webhook pushes. Each Meta lead comes
 *    in once (leads.meta_lead_id).
 */
// one Graph API version for all Meta calls (META_GRAPH_VERSION, default v21.0 — see lib/meta-oauth.ts)
const LEAD_FIELDS = 'id,field_data,form_id,ad_name,campaign_id,campaign_name,created_time';
const META_ID = /^[0-9]{3,30}$/;

export async function graph(path: string, token: string, init?: RequestInit): Promise<any> {
  const sep = path.includes('?') ? '&' : '?';
  const res = await fetch(`${graphBase()}/${path}${sep}access_token=${encodeURIComponent(token)}`, { ...init, signal: AbortSignal.timeout(8000) });
  const g: any = await res.json().catch(() => ({}));
  if (!res.ok || g?.error) throw new Error(g?.error?.message ?? `Meta ${res.status}`);
  return g ?? {};
}

/** a Meta lead to the campaign of ours that its Meta campaign (or its form) is linked to — null = not ours / already in */
export async function takeMetaLead(db: Db, g: any, now: Date): Promise<'added' | 'skipped' | 'exists' | 'unlinked'> {
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
  if (phoneNorm(phone).length < 7) throw new Error('lead without a phone');
  const extra = Object.entries(f).filter(([k]) => !['full_name', 'first_name', 'last_name', 'phone_number', 'phone', 'email'].includes(k))
    .map(([k, v]) => `${k}: ${v}`);
  const notes = [g.campaign_name ? `حملة: ${g.campaign_name}` : '', g.ad_name ? `إعلان: ${g.ad_name}` : '', ...extra].filter(Boolean).join(' — ').slice(0, 1900);
  const x = readLead({ fullName, phone, email: f.email ?? '', notes, kind: 'fresh' });
  const lead = await db.tx(async (q: Q) => {
    x.projectId ??= c.project_id ?? null; x.channelId ??= c.channel_id ?? null; x.campaignId = c.id;
    // the same number twice on the same campaign the same day: once
    if (await one(q, `SELECT 1 FROM leads WHERE campaign_id = $1 AND phone_norm = $2 AND created_at > $3::timestamptz - interval '1 day'`,
      [c.id, phoneNorm(x.phone), now])) return null;
    const l = await deliverLead(q, x, (c.assign_mode ?? 'turn') as RouteMode, c.form_assignees ?? [], now, 'فيسبوك', c.name ?? '');
    if (metaId) await q.query(`UPDATE leads SET meta_lead_id = $2 WHERE id = $1`, [l.id, metaId]);
    return l;
  });
  return lead ? 'added' : 'skipped';
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
export async function syncMeta(db: Db, now: Date, opts: { campaignId?: string; deadlineMs?: number } = {}): Promise<{ added: number; errors: string[] }> {
  const stop = Date.now() + (opts.deadlineMs ?? 20_000);
  const errors: string[] = [];
  let added = 0;
  const camps = (await db.query(`SELECT id, meta_campaign_ids, meta_synced_at FROM lead_campaigns
      WHERE active AND cardinality(meta_campaign_ids) > 0 ${opts.campaignId ? 'AND id = $1' : ''}`, opts.campaignId ? [opts.campaignId] : [])).rows;
  if (!camps.length) return { added, errors };
  const wanted = new Set<string>(camps.flatMap((c) => (c.meta_campaign_ids ?? []).map(String)));
  // from the oldest sync of these campaigns (a campaign never synced: its last 90 days)
  const since = new Date(Math.min(...camps.map((c) => (c.meta_synced_at ? new Date(c.meta_synced_at).getTime() - 3_600_000 : now.getTime() - 90 * 86_400_000))));
  const filtering = encodeURIComponent(JSON.stringify([{ field: 'time_created', operator: 'GREATER_THAN', value: Math.floor(since.getTime() / 1000) }]));
  const take = async (g: any) => {
    if (!wanted.has(String(g?.campaign_id ?? ''))) return;
    try { if (await takeMetaLead(db, g, now) === 'added') added++; } catch (e: any) { errors.push(String(e?.message ?? e)); }
  };
  const leadsOf = async (edge: string, token: string) => {
    let next: string | null = `${edge}/leads?fields=${LEAD_FIELDS}&limit=100&filtering=${filtering}`;
    for (let page = 0; next && page < 20 && Date.now() < stop; page++) {
      const r: any = await graph(next, token);
      for (const g of Array.isArray(r.data) ? r.data : []) await take(g);
      const after = r?.paging?.cursors?.after;
      next = r?.paging?.next && after ? `${edge}/leads?fields=${LEAD_FIELDS}&limit=100&filtering=${filtering}&after=${encodeURIComponent(after)}` : null;
    }
  };
  const pages = (await db.query(`SELECT page_id, access_token FROM meta_pages ORDER BY added_at`)).rows;
  const office = unseal((await one(db, `SELECT access_token FROM integrations WHERE source = 'meta'`))?.access_token);
  // 1) every page's lead forms (a page token reads its own forms' leads)
  const sources = [...pages.map((p) => ({ id: String(p.page_id), token: unseal(p.access_token) ?? '' })).filter((p) => p.token), ...(office && !pages.length ? [{ id: 'me', token: office }] : [])];
  for (const p of sources) {
    if (Date.now() >= stop) break;
    try {
      const forms = await graph(`${p.id}/leadgen_forms?fields=id&limit=100`, p.token);
      for (const fm of Array.isArray(forms.data) ? forms.data : []) {
        if (Date.now() >= stop) break;
        if (META_ID.test(String(fm.id))) await leadsOf(String(fm.id), p.token);
      }
      if (p.id !== 'me') await db.query(`UPDATE meta_pages SET last_error = NULL WHERE page_id = $1`, [p.id]);
    } catch (e: any) {
      const m = String(e?.message ?? e).slice(0, 300);
      errors.push(m);
      if (p.id !== 'me') await db.query(`UPDATE meta_pages SET last_error = $2 WHERE page_id = $1`, [p.id, m]);
    }
  }
  // 2) the office's (ads) token: the campaigns' ads' leads
  if (office) {
    for (const mc of wanted) {
      if (Date.now() >= stop) break;
      try {
        const ads = await graph(`${mc}/ads?fields=id&limit=200`, office);
        for (const ad of Array.isArray(ads.data) ? ads.data : []) {
          if (Date.now() >= stop) break;
          if (META_ID.test(String(ad.id))) await leadsOf(String(ad.id), office);
        }
      } catch { /* a page token cannot read ads: the forms above are enough */ }
    }
  }
  if (Date.now() < stop) await db.query(`UPDATE lead_campaigns SET meta_synced_at = $2 WHERE id = ANY($1::uuid[])`, [camps.map((c) => c.id), now]);
  if (errors.length) await db.query(`UPDATE integrations SET last_error = $1 WHERE source = 'meta'`, [errors.at(-1)!.slice(0, 300)]).catch(() => undefined);
  return { added, errors };
}

/**
 * The scheduler's run (POST /integrations/meta/sync/run — a GitHub Actions cron, see .github/workflows/meta-sync.yml):
 * independent of anyone opening the app. It claims the same «meta_sync_at» slot as maybeSyncMeta (one run at a time across
 * API instances, at most every 5 minutes), with a longer time budget. Idempotent: every Meta lead comes in once
 * (leads.meta_lead_id is unique), so a webhook and a scheduled run that see the same lead add it once.
 */
export async function runScheduledMetaSync(db: Db, now: Date): Promise<{ ran: boolean; reason?: string; added?: number; errors?: string[] }> {
  const claimed = await one(db, `UPDATE integrations SET meta_sync_at = $1
      WHERE source = 'meta' AND active AND (meta_sync_at IS NULL OR meta_sync_at < $1::timestamptz - interval '5 minutes')
        AND (access_token IS NOT NULL OR EXISTS (SELECT 1 FROM meta_pages))
      RETURNING 1`, [now]);
  if (!claimed) {
    const it = await one(db, `SELECT active, access_token IS NOT NULL OR EXISTS (SELECT 1 FROM meta_pages) AS connected FROM integrations WHERE source = 'meta'`);
    return { ran: false, reason: !it?.active ? 'off' : !it.connected ? 'not_connected' : 'recent' };
  }
  if (!(await one(db, `SELECT 1 FROM lead_campaigns WHERE active AND cardinality(meta_campaign_ids) > 0 LIMIT 1`))) {
    return { ran: false, reason: 'no_linked_campaigns' };
  }
  const r = await syncMeta(db, now, { deadlineMs: 45_000 });
  return { ran: true, added: r.added, errors: [...new Set(r.errors)].slice(0, 5) };
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
