import { test } from 'node:test';
import assert from 'node:assert/strict';
import { costPer, dayComplete, insightsPath, parseInsightRow, sumOrNull } from '../src/lib/meta-insights.ts';

/** Meta Ads Insights parsing (Phase D): unavailable stays NULL, never 0; only a complete day replaces a stored one */
const row = (over: Record<string, unknown> = {}) => ({
  campaign_id: '777', campaign_name: 'Spring', objective: 'OUTCOME_LEADS', account_id: '555', account_currency: 'EGP',
  date_start: '2026-11-20', date_stop: '2026-11-20', impressions: '1200', reach: '900', clicks: '45', spend: '350.25',
  cpm: '291.875', cpc: '7.783333', ctr: '3.75', actions: [{ action_type: 'link_click', value: '45' }, { action_type: 'lead', value: '7' }],
  cost_per_action_type: [{ action_type: 'lead', value: '50.035714' }], ...over,
});

test('a full day: numbers parsed from Meta\'s strings; leads from the exact "lead" action', () => {
  const d = parseInsightRow(row())!;
  assert.deepEqual([d.metaCampaignId, d.day, d.currency, d.impressions, d.reach, d.clicks, d.spend, d.leads, d.costPerLead],
    ['777', '2026-11-20', 'EGP', 1200, 900, 45, 350.25, 7, 50.035714]);
  assert.equal(dayComplete(d), true);
});

test('missing metrics are unavailable (null), not zero; a real zero stays zero', () => {
  const d = parseInsightRow(row({ reach: undefined, actions: [{ action_type: 'link_click', value: '3' }], cost_per_action_type: undefined, cpc: '' }))!;
  assert.equal(d.reach, null);
  assert.equal(d.leads, null, 'no "lead" action → unavailable, not 0');
  assert.equal(d.costPerLead, null);
  assert.equal(d.cpc, null);
  const z = parseInsightRow(row({ impressions: '0', spend: '0', actions: [{ action_type: 'lead', value: '0' }] }))!;
  assert.deepEqual([z.impressions, z.spend, z.leads], [0, 0, 0], 'a real zero is kept');
  assert.equal(dayComplete(z), true);
});

test('an incomplete day (no spend or no impressions) never replaces a stored one', () => {
  assert.equal(dayComplete(parseInsightRow(row({ spend: undefined }))!), false);
  assert.equal(dayComplete(parseInsightRow(row({ impressions: undefined }))!), false);
});

test('invalid rows are refused: a multi-day row, a bad id or date, negative or non-numeric values, a bad currency', () => {
  assert.equal(parseInsightRow(row({ date_stop: '2026-11-21' })), null, 'time_increment=1 rows only');
  assert.equal(parseInsightRow(row({ campaign_id: 'abc' })), null);
  assert.equal(parseInsightRow(row({ date_start: '20-11-2026' })), null);
  assert.equal(parseInsightRow(null), null);
  const d = parseInsightRow(row({ spend: '-5', clicks: '4.5', impressions: 'many', account_currency: 'egp' }))!;
  assert.deepEqual([d.spend, d.clicks, d.impressions, d.currency], [null, null, null, null]);
});

test('reporting sums: unknown unless at least one day had the metric; cost per needs spend and a non-zero count', () => {
  assert.equal(sumOrNull([null, null]), null);
  assert.equal(sumOrNull([null, 2, 3]), 5);
  assert.equal(sumOrNull([0, 0]), 0);
  assert.equal(costPer(100, 4), 25);
  assert.equal(costPer(100, 0), null);
  assert.equal(costPer(null, 4), null);
  assert.equal(costPer(100, null), null);
});

test('the request: one campaign, daily rows, an inclusive range, the documented fields', () => {
  const u = new URL(`https://graph.facebook.com/v21.0/${insightsPath('777', '2026-11-01', '2026-11-24')}`);
  assert.equal(u.pathname, '/v21.0/777/insights');
  assert.equal(u.searchParams.get('time_increment'), '1');
  assert.deepEqual(JSON.parse(u.searchParams.get('time_range')!), { since: '2026-11-01', until: '2026-11-24' });
  assert.ok(u.searchParams.get('fields')!.split(',').includes('spend'));
});
