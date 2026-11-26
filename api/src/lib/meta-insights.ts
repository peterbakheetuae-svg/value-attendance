/**
 * Meta Ads Insights (Phase D) — the pure part: what to ask for and how one answer row becomes a stored day. No network, no
 * database (test/meta-insights.test.ts). Endpoint: GET /{campaign-id}/insights with time_increment=1 (one row per day, in
 * the ad account's time zone) — https://developers.facebook.com/docs/marketing-api/insights
 *
 * Rules: Meta returns numbers as strings and leaves out what it does not have. A metric that is absent stays NULL
 * (unavailable) — it is never turned into 0. Leads come from the `actions` entry whose action_type is exactly "lead";
 * when Meta sends no such entry the day's leads are unavailable (NULL), not zero.
 */
export const INSIGHTS_FIELDS = [
  'campaign_id', 'campaign_name', 'objective', 'account_id', 'account_currency', 'date_start', 'date_stop',
  'impressions', 'reach', 'clicks', 'spend', 'cpm', 'cpc', 'ctr', 'actions', 'cost_per_action_type',
] as const;

export interface InsightDay {
  metaCampaignId: string; day: string; accountId: string | null; currency: string | null; campaignName: string | null;
  objective: string | null; impressions: number | null; reach: number | null; clicks: number | null; spend: number | null;
  cpm: number | null; cpc: number | null; ctr: number | null; leads: number | null; costPerLead: number | null;
}

const numOrNull = (v: unknown, int = false): number | null => {
  if (v === undefined || v === null || v === '') return null;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) return null;
  return int ? (Number.isInteger(n) ? n : null) : n;
};
const actionValue = (list: unknown, type: string): number | null => {
  if (!Array.isArray(list)) return null;
  const a = list.find((x: any) => x?.action_type === type);
  return a ? numOrNull(a.value) : null;
};
const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** one answer row → a day, or null when the row is not a single valid day of a valid campaign */
export function parseInsightRow(row: any): InsightDay | null {
  const id = String(row?.campaign_id ?? '');
  const day = String(row?.date_start ?? '');
  if (!/^[0-9]{3,30}$/.test(id) || !DAY.test(day) || String(row?.date_stop ?? day) !== day) return null;
  const currency = typeof row?.account_currency === 'string' && /^[A-Z]{3}$/.test(row.account_currency) ? row.account_currency : null;
  const leads = actionValue(row?.actions, 'lead');
  return {
    metaCampaignId: id, day, accountId: row?.account_id ? String(row.account_id) : null, currency,
    campaignName: row?.campaign_name ? String(row.campaign_name).slice(0, 300) : null, objective: row?.objective ? String(row.objective).slice(0, 80) : null,
    impressions: numOrNull(row?.impressions, true), reach: numOrNull(row?.reach, true), clicks: numOrNull(row?.clicks, true),
    spend: numOrNull(row?.spend), cpm: numOrNull(row?.cpm), cpc: numOrNull(row?.cpc), ctr: numOrNull(row?.ctr),
    leads: leads === null ? null : Math.round(leads), costPerLead: actionValue(row?.cost_per_action_type, 'lead'),
  };
}

/** a day counts as complete when Meta reported its delivery (impressions) and its spend: only such a day replaces a stored one */
export const dayComplete = (d: InsightDay) => d.impressions !== null && d.spend !== null;

/** the request path for one campaign and a date range (inclusive, account days) */
export function insightsPath(metaCampaignId: string, since: string, until: string): string {
  const range = encodeURIComponent(JSON.stringify({ since, until }));
  return `${metaCampaignId}/insights?fields=${INSIGHTS_FIELDS.join(',')}&time_increment=1&time_range=${range}&limit=100`;
}

/** sums for reporting: a total is NULL unless at least one day had the metric (unavailable ≠ 0) */
export function sumOrNull(values: (number | null)[]): number | null {
  const have = values.filter((v): v is number => v !== null);
  return have.length ? have.reduce((a, b) => a + b, 0) : null;
}
/** cost per lead over a period: only when both spend and leads are known and leads > 0 */
export const costPer = (spend: number | null, n: number | null) => (spend === null || n === null || n === 0 ? null : Math.round((spend / n) * 100) / 100);

// ------------------------------------------------------------------ response validation (review P2)
const INT_FIELDS = ['impressions', 'reach', 'clicks'] as const;
const NUM_FIELDS = ['spend', 'cpm', 'cpc', 'ctr'] as const;
const present = (v: unknown) => v !== undefined && v !== null && v !== '';
const badNumber = (v: unknown, int: boolean) => {
  if (typeof v !== 'string' && typeof v !== 'number') return true;
  const n = Number(v);
  return !Number.isFinite(n) || n < 0 || (int && !Number.isInteger(n));
};
const badActions = (list: unknown) => present(list) && (!Array.isArray(list)
  || list.some((a: any) => !a || typeof a !== 'object' || typeof a.action_type !== 'string' || (present(a.value) && badNumber(a.value, false))));

/**
 * Why a row cannot be trusted, or null. Absent metrics are fine (they stay NULL); a metric that is present but is not a
 * non-negative number, a malformed actions list, a missing / wrong campaign or a row that is not one day are problems.
 */
export function insightRowProblem(row: any, metaCampaignId: string): string | null {
  if (!row || typeof row !== 'object' || Array.isArray(row)) return 'row is not an object';
  if (String(row.campaign_id ?? '') !== metaCampaignId) return 'row of another or no campaign';
  const day = String(row.date_start ?? '');
  if (!DAY.test(day) || String(row.date_stop ?? day) !== day) return 'row is not a single day';
  for (const f of INT_FIELDS) if (present(row[f]) && badNumber(row[f], true)) return `invalid ${f}`;
  for (const f of NUM_FIELDS) if (present(row[f]) && badNumber(row[f], false)) return `invalid ${f}`;
  if (badActions(row.actions)) return 'invalid actions';
  if (badActions(row.cost_per_action_type)) return 'invalid cost_per_action_type';
  if (present(row.account_currency) && !(typeof row.account_currency === 'string' && /^[A-Z]{3}$/.test(row.account_currency))) return 'invalid account_currency';
  return null;
}

/**
 * One page of the Insights answer: the days that can be stored, and the problems that make the pass incomplete. A
 * response whose `data` is not a list is never an empty valid page; a `next` link without a cursor is never the end.
 */
export function readInsightsPage(r: any, metaCampaignId: string): { days: InsightDay[]; problems: string[]; after: string | null } {
  if (!r || typeof r !== 'object' || !Array.isArray(r.data)) return { days: [], problems: ['malformed response: data is not a list'], after: null };
  const problems: string[] = []; const days: InsightDay[] = [];
  for (const row of r.data) {
    const p = insightRowProblem(row, metaCampaignId);
    const d = p ? null : parseInsightRow(row);
    if (!d) problems.push(`malformed row: ${p ?? 'unreadable'}`); else days.push(d);
  }
  const next = r.paging?.next;
  const after = typeof r.paging?.cursors?.after === 'string' && r.paging.cursors.after ? r.paging.cursors.after : null;
  if (next && !after) problems.push('malformed response: a next page without a cursor');
  return { days, problems, after: next && after ? after : null };
}
