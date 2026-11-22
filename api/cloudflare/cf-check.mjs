#!/usr/bin/env node
/**
 * Read-only Cloudflare checks used by .github/workflows/cloudflare-staging.yml. Prints figures only — never tokens,
 * connection strings or any other secret.
 *
 *   node cloudflare/cf-check.mjs cpu <scriptName> <fromISO>   → requests, outcomes and CPU-time percentiles (ms)
 *   node cloudflare/cf-check.mjs traffic <scriptName> <days>   → requests per day (UTC), daily average, monthly projection
 *
 * Env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID.
 */
const token = process.env.CLOUDFLARE_API_TOKEN;
const account = process.env.CLOUDFLARE_ACCOUNT_ID;
if (!token || !account) { console.error('CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID missing'); process.exit(2); }
const api = (path, init = {}) => fetch(`https://api.cloudflare.com/client/v4${path}`,
  { ...init, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...(init.headers ?? {}) } });

const [cmd, a1, a2] = process.argv.slice(2);

if (cmd === 'cpu') {
  const query = `query ($acct: String!, $script: String!, $from: Time!, $to: Time!) {
    viewer { accounts(filter: { accountTag: $acct }) {
      workersInvocationsAdaptive(limit: 20, filter: { scriptName: $script, datetime_geq: $from, datetime_leq: $to }) {
        dimensions { status }
        sum { requests errors }
        quantiles { cpuTimeP50 cpuTimeP75 cpuTimeP90 cpuTimeP99 cpuTimeP999 }
      } } } }`;
  const to = new Date().toISOString();
  const r = await (await api('/graphql', { method: 'POST', body: JSON.stringify({ query, variables: { acct: account, script: a1, from: a2, to } }) })).json();
  if (r.errors?.length) { console.error('analytics error:', r.errors.map((e) => e.message).join('; ')); process.exit(1); }
  const rows = r.data?.viewer?.accounts?.[0]?.workersInvocationsAdaptive ?? [];
  if (!rows.length) { console.log('no analytics rows yet'); process.exit(3); }
  const ms = (us) => (us == null ? '-' : (us / 1000).toFixed(2));
  console.log(`script ${a1} since ${a2}`);
  console.log('status            requests errors   cpu p50   p75   p90   p99  p99.9 (ms)');
  for (const x of rows) {
    const q = x.quantiles;
    console.log(`${x.dimensions.status.padEnd(17)} ${String(x.sum.requests).padStart(8)} ${String(x.sum.errors).padStart(6)}  ${[q.cpuTimeP50, q.cpuTimeP75, q.cpuTimeP90, q.cpuTimeP99, q.cpuTimeP999].map(ms).map((s) => s.padStart(6)).join('')}`);
  }
} else if (cmd === 'traffic') {
  const days = Math.min(Math.max(Number(a2) || 7, 1), 30);
  const to = new Date(); const from = new Date(to.getTime() - days * 86400_000);
  const query = `query ($acct: String!, $script: String!, $from: Time!, $to: Time!) {
    viewer { accounts(filter: { accountTag: $acct }) {
      workersInvocationsAdaptive(limit: 1000, filter: { scriptName: $script, datetime_geq: $from, datetime_leq: $to }) {
        dimensions { date status } sum { requests errors subrequests }
      } } } }`;
  const r = await (await api('/graphql', { method: 'POST', body: JSON.stringify({ query, variables: { acct: account, script: a1, from: from.toISOString(), to: to.toISOString() } }) })).json();
  if (r.errors?.length) { console.error('analytics error:', r.errors.map((e) => e.message).join('; ')); process.exit(1); }
  const rows = r.data?.viewer?.accounts?.[0]?.workersInvocationsAdaptive ?? [];
  const byDay = new Map();
  for (const x of rows) { const d = byDay.get(x.dimensions.date) ?? { req: 0, err: 0 }; d.req += x.sum.requests; d.err += x.sum.errors; byDay.set(x.dimensions.date, d); }
  const list = [...byDay.entries()].sort();
  console.log(`script ${a1}: requests per UTC day (last ${days} days; first/last day may be partial)`);
  for (const [d, v] of list) console.log(`${d}  ${String(v.req).padStart(8)}  errors ${v.err}`);
  const full = list.slice(1, -1).map(([, v]) => v.req);
  const avg = full.length ? full.reduce((a, b) => a + b, 0) / full.length : 0;
  const max = full.length ? Math.max(...full) : 0;
  console.log(`full days: ${full.length}  avg/day ${Math.round(avg)}  max/day ${max}  → ~${(avg * 30 / 1e6).toFixed(2)} M/month`);
  console.log(`Workers Free allows 100,000/day: ${max > 100000 ? 'EXCEEDED on at least one day' : 'within the limit'}`);
} else {
  console.error('usage: cf-check.mjs cpu <script> <fromISO> | traffic <script> <days>'); process.exit(2);
}
