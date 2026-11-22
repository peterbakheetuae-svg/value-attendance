#!/usr/bin/env node
/**
 * Read-only Cloudflare checks used by .github/workflows/cloudflare-staging.yml. Prints figures only — never tokens,
 * connection strings or any other secret.
 *
 *   node cloudflare/cf-check.mjs cpu <scriptName> <fromISO>   → requests, outcomes and CPU-time percentiles (ms)
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
} else {
  console.error('usage: cf-check.mjs cpu <script> <fromISO>'); process.exit(2);
}
