/**
 * Real-Cloudflare checks of the ISOLATED staging gateway (gateway → synthetic verifier, no Vercel, no database).
 * Run by .github/workflows/cloudflare-staging.yml. Prints PASS/FAIL lines only — never secrets or signatures.
 *
 *   node --import tsx cloudflare/staging-checks.mts <phase>
 *   env: GW (gateway URL), VF (verifier URL), MYIP (runner's public IPv4), S_CUR (secret the verifier holds as current),
 *        S_GATEWAY (secret the gateway signs with)
 * phases: main | rotation-overlap | rotation-done
 */
import { createHash, createHmac, randomUUID } from 'node:crypto';
import { canonical } from '../src/lib/gateway-sig.ts';

const { GW, VF, MYIP, S_CUR } = process.env as Record<string, string>;
const phase = process.argv[2] ?? 'main';
let failed = 0;
const check = (name: string, cond: boolean, info = '') => { if (!cond) failed++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${info ? `  (${info})` : ''}`); };
const j = async (r: Response) => { try { return await r.json() as any; } catch { return {}; } };
const sha = (b: string) => createHash('sha256').update(b).digest('base64url');
/** a request straight to the verifier, as an attacker (or a mis-built client) could send straight to Vercel */
const direct = async (o: { secret?: string; ts?: number; method?: string; signMethod?: string; body?: string; signBody?: string; ip?: string } = {}) => {
  const ts = String(o.ts ?? Math.floor(Date.now() / 1000)); const id = randomUUID(); const ip = o.ip ?? '203.0.113.77';
  const method = o.method ?? 'POST'; const body = o.body ?? '{"k":1}';
  const sig = createHmac('sha256', o.secret ?? S_CUR).update(canonical({ method: o.signMethod ?? method, path: '/auth/login', query: '', ts, id, ip,
    bodySha256: sha(o.signBody ?? body) })).digest('base64url');
  const r = await fetch(`${VF}/auth/login`, { method, body: method === 'GET' ? undefined : body,
    headers: { 'x-va-gw-ip': ip, 'x-va-gw-ts': ts, 'x-va-gw-id': id, 'x-va-gw-sig': sig } });
  return j(r);
};

if (phase === 'main') {
  // 1. isolation: every answer comes from the synthetic verifier
  const h = await fetch(`${GW}/__gateway/health`); check('gateway health', h.status === 200);
  const spoof = await fetch(`${GW}/employees?b=2&a=%20x`, { headers: { 'x-forwarded-for': '6.6.6.6', 'x-real-ip': '6.6.6.6', 'true-client-ip': '6.6.6.6',
    'cf-connecting-ip': '6.6.6.6', 'x-va-gw-ip': '6.6.6.6', 'x-va-gw-sig': 'forged', authorization: 'Bearer not-a-real-token' } });
  const s = await j(spoof);
  check('isolation: answer is synthetic (no Vercel, no data)', s.synthetic === true && spoof.status === 200);
  check('no-store on the response', spoof.headers.get('cache-control') === 'no-store');
  // 2. visitor IP: Cloudflare's own CF-Connecting-IP wins over every client-supplied header
  check('visitor IP = runner public IP, spoofed headers ignored', s.verdict === 'trusted' && s.ip === MYIP, `${s.verdict}`);
  check('client forwarding headers stripped', !['x-forwarded-for', 'x-real-ip', 'true-client-ip'].some((k) => (s.headerNames ?? []).includes(k)));
  check('query normalized and signed', s.query === 'b=2&a=+x');
  // 3. body hashing
  const body = JSON.stringify({ identifier: 'synthetic', n: randomUUID() });
  const p = await j(await fetch(`${GW}/auth/login`, { method: 'POST', body, headers: { 'content-type': 'application/json' } }));
  check('POST through gateway verified', p.verdict === 'trusted' && p.method === 'POST');
  check('body hash end-to-end equal', p.bodySha256 === sha(body));
  // 4. replay (instance-local detection)
  const rp = await j(await fetch(`${GW}/__verify/replay`, { method: 'POST', body: 'x' }));
  check('same signed request presented twice → second refused', rp.verdict === 'trusted' && rp.replay?.verdict === 'refused');
  // 5. direct requests (bypassing the gateway)
  check('direct, no gateway headers → treated as direct', (await j(await fetch(`${VF}/auth/login`, { method: 'POST', body: '{}' }))).verdict === 'direct');
  check('direct, valid signature → trusted (signer parity CI ↔ Workers)', (await direct()).verdict === 'trusted');
  check('direct, wrong secret → refused', (await direct({ secret: 'z'.repeat(43) })).verdict === 'refused');
  check('direct, 61 s old → refused', (await direct({ ts: Math.floor(Date.now() / 1000) - 61 })).verdict === 'refused');
  check('direct, 11 s in the future → refused', (await direct({ ts: Math.floor(Date.now() / 1000) + 11 })).verdict === 'refused');
  check('direct, body changed after signing → refused', (await direct({ signBody: '{"k":2}' })).verdict === 'refused');
  check('direct, method changed after signing → refused', (await direct({ method: 'PUT', signMethod: 'POST' })).verdict === 'refused');
  const partial = await j(await fetch(`${VF}/auth/login`, { method: 'POST', body: '{}', headers: { 'x-va-gw-ip': '203.0.113.77' } }));
  check('direct, incomplete gateway headers → refused (fail closed)', partial.verdict === 'refused');
  // 6. failure behaviour / filtering at the edge
  const e500 = await fetch(`${GW}/__verify/status-500`); check('upstream 500 passed through, no-store', e500.status === 500 && e500.headers.get('cache-control') === 'no-store');
  check('unknown method → 405', (await fetch(`${GW}/x`, { method: 'PROPFIND' })).status === 405);
  check('body over 8 MiB → 413', (await fetch(`${GW}/x`, { method: 'POST', body: 'a'.repeat(8 * 1024 * 1024 + 1) })).status === 413);
} else if (phase === 'rotation-overlap') {
  // verifier: current = new secret, previous = old; gateway still signs with the old one
  const r = await j(await fetch(`${GW}/me`));
  check('rotation: gateway on OLD secret accepted while previous is configured', r.verdict === 'trusted');
  check('rotation: NEW secret accepted', (await direct()).verdict === 'trusted');
} else if (phase === 'rotation-done') {
  const r = await j(await fetch(`${GW}/me`));
  check('rotation: OLD secret refused once previous is removed', r.verdict === 'refused');
}
console.log(failed ? `${failed} FAILED` : 'all passed');
process.exit(failed ? 1 : 0);
