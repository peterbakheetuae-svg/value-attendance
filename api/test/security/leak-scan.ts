// Security review tool: every GET route, as the owner and as a plain employee — any key that looks like a secret.
import { harness, cast } from '../helpers.ts';
import { buildRouter } from '../../src/app.ts';
const h = await harness('2026-03-20T08:00:00Z'); const c = await cast(h);
await h.db.query(`UPDATE integrations SET access_token = 'tok_secret_value', verify_token = 'verify_secret' WHERE TRUE`).catch(() => {});
const routes = buildRouter({ db: h.db, clock: () => h.now.value }).list().filter((r) => r.startsWith('GET ') && !r.includes(':'));
const bad = /secret|token|hash|password|pin_?code|api_?key|private|otp|cookie|p256dh|auth_key/i;
const seen = new Set<string>();
const walk = (v: any, path: string, out: string[]) => {
  if (Array.isArray(v)) { v.slice(0, 3).forEach((x, i) => walk(x, path + '[]', out)); return; }
  if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) { if (bad.test(k) && x !== null && x !== false && x !== '') out.push(`${path}.${k}=${String(JSON.stringify(x)).slice(0, 40)}`); walk(x, path + '.' + k, out); }
};
for (const who of ['owner', 'e1'] as const) {
  for (const rt of routes) {
    const p = rt.slice(4);
    if (p.startsWith('/backup') || p.startsWith('/partner')) continue;
    const r = await h.call(c.t[who], 'GET', p);
    if (!r.body) continue;
    const out: string[] = []; walk(r.body, '', out);
    for (const o of out) { const k = `${who} ${p} ${o}`; if (!seen.has(k)) { seen.add(k); console.log(k); } }
  }
}
console.log("scanned", routes.length, "GET routes x 2 roles"); await h.close(); process.exit(0);
