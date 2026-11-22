import { test, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import gateway, { sign, AUTH_PATHS } from '../cloudflare/gateway.ts';
import { clientIp, gatewaySignature } from '../src/auth/ratelimit.ts';
import { canonical } from '../src/lib/gateway-sig.ts';
import { createHash, randomUUID } from 'node:crypto';

/**
 * Cloudflare gateway (cloudflare/gateway.ts) and the Vercel side of its signed client IP (src/auth/ratelimit.ts).
 * No database and no network: the upstream (Vercel) is a stub.
 */
const SECRET = 'x'.repeat(40);
const UP = 'https://value-attendance.vercel.app';
const realFetch = globalThis.fetch;
let seen: { url: string; init: RequestInit & { headers: Headers } }[] = [];
const stub = (res: () => Response | Promise<Response>) => {
  seen = [];
  globalThis.fetch = (async (url: string, init: any) => { seen.push({ url, init }); return res(); }) as any;
};
afterEach(() => { globalThis.fetch = realFetch; delete process.env.VA_GATEWAY_SECRET; delete process.env.VA_GATEWAY_SECRET_PREVIOUS; delete process.env.VERCEL; delete process.env.TRUST_PLATFORM_IP; });
const env = (x: object = {}) => ({ UPSTREAM: UP, VA_GATEWAY_SECRET: SECRET, ...x });
const req = (path: string, init: RequestInit & { headers?: Record<string, string> } = {}) =>
  new Request('https://valunivo-gateway-staging.example.workers.dev' + path, init);
/** what the Vercel router hands to a handler for the request the gateway forwarded */
const asReq = (sent: { url: string; init: any }) => {
  const u = new URL(sent.url);
  return { method: sent.init.method, path: u.pathname, query: u.searchParams, headers: Object.fromEntries(sent.init.headers.entries()),
    raw: Buffer.from(sent.init.body ?? new ArrayBuffer(0)) } as any;
};
/** a directly built (attacker-side) envelope */
const forge = (o: { secret?: string; method?: string; path?: string; query?: string; ts?: number; id?: string; ip?: string; body?: string; sigFor?: Partial<{ method: string; path: string; query: string; body: string; ip: string }> } = {}) => {
  const ts = String(o.ts ?? Math.floor(Date.now() / 1000)); const id = o.id ?? randomUUID(); const ip = o.ip ?? '203.0.113.9';
  const method = o.method ?? 'POST', path = o.path ?? '/auth/login', query = o.query ?? '', body = o.body ?? '{}';
  const f = { method, path, query, body, ip, ...(o.sigFor ?? {}) };
  const sig = gatewaySignature(o.secret ?? SECRET, canonical({ method: f.method, path: f.path, query: f.query, ts, id, ip: f.ip,
    bodySha256: createHash('sha256').update(f.body).digest('base64url') }));
  return { method, path, query: new URLSearchParams(query), raw: Buffer.from(body),
    headers: { 'x-va-gw-ip': ip, 'x-va-gw-ts': ts, 'x-va-gw-id': id, 'x-va-gw-sig': sig, 'x-vercel-forwarded-for': '198.51.100.7' } as Record<string, string> } as any;
};
const refused = (fn: () => unknown) => assert.throws(fn, (e: any) => e.code === 'forbidden' && e.details?.reason === 'gateway_signature_invalid');

test('forwards method, path, query, body and Authorization unchanged; never caches', async () => {
  stub(() => new Response('{"ok":1}', { status: 201, headers: { 'content-type': 'application/json', 'cache-control': 'public, max-age=600' } }));
  const r = await gateway.fetch(req('/cash/expenses?x=1&y=%D8%A7', { method: 'POST', body: '{"a":1}',
    headers: { authorization: 'Bearer T', 'content-type': 'application/json', 'cf-connecting-ip': '203.0.113.9' } }), env());
  assert.equal(r.status, 201);
  assert.equal(r.headers.get('cache-control'), 'no-store', 'responses are never cacheable');
  assert.equal(seen[0].url, UP + '/cash/expenses?x=1&y=%D8%A7');
  assert.equal(seen[0].init.method, 'POST');
  assert.equal(seen[0].init.cache, 'no-store');
  assert.equal(seen[0].init.redirect, 'manual');
  assert.equal(new TextDecoder().decode(seen[0].init.body as ArrayBuffer), '{"a":1}');
  assert.equal(seen[0].init.headers.get('authorization'), 'Bearer T');
});

test('client-supplied impersonation headers are stripped; the gateway envelope verifies on Vercel', async () => {
  stub(() => new Response('{}'));
  await gateway.fetch(req('/auth/login?x=%20a+b&y=1', { method: 'POST', body: '{"identifier":"E1"}', headers: { 'cf-connecting-ip': '203.0.113.9',
    'x-forwarded-for': '6.6.6.6', 'x-real-ip': '6.6.6.6', 'x-vercel-forwarded-for': '6.6.6.6', 'x-va-gw-ip': '6.6.6.6', 'x-va-gw-sig': 'forged',
    'x-va-gw-ts': '1', 'x-va-gw-id': 'x', 'true-client-ip': '6.6.6.6', forwarded: 'for=6.6.6.6' } }), env());
  const h = seen[0].init.headers;
  for (const k of ['x-forwarded-for', 'x-real-ip', 'x-vercel-forwarded-for', 'true-client-ip', 'forwarded', 'cf-connecting-ip'])
    assert.equal(h.get(k), null, k);
  assert.equal(h.get('x-va-gw-ip'), '203.0.113.9');
  process.env.VA_GATEWAY_SECRET = SECRET;
  assert.equal(clientIp(asReq(seen[0])), '203.0.113.9', 'Web Crypto (gateway) and node:crypto (Vercel) agree');
});

test('signature binds method, path, query, body and IP', () => {
  process.env.VA_GATEWAY_SECRET = SECRET; process.env.VERCEL = '1';
  assert.equal(clientIp(forge()), '203.0.113.9');
  refused(() => clientIp(forge({ sigFor: { method: 'GET' } })));
  refused(() => clientIp(forge({ sigFor: { path: '/auth/forgot' } })));
  refused(() => clientIp(forge({ sigFor: { query: 'a=1' } })));
  refused(() => clientIp(forge({ sigFor: { body: '{"identifier":"OTHER"}' } })));
  refused(() => clientIp(forge({ sigFor: { ip: '6.6.6.6' } })));
});

test('replay of the same request id is refused; timestamps outside the window fail closed', () => {
  process.env.VA_GATEWAY_SECRET = SECRET;
  const id = randomUUID();
  assert.equal(clientIp(forge({ id })), '203.0.113.9');
  refused(() => clientIp(forge({ id })));
  const now = Math.floor(Date.now() / 1000);
  refused(() => clientIp(forge({ ts: now - 61 })));
  refused(() => clientIp(forge({ ts: now + 11 })));
  assert.equal(clientIp(forge({ ts: now - 59 })), '203.0.113.9');
});

test('direct requests to Vercel cannot forge the gateway IP (fail closed); no gateway headers = platform IP as before', () => {
  process.env.VA_GATEWAY_SECRET = SECRET; process.env.VERCEL = '1';
  refused(() => clientIp(forge({ secret: 'y'.repeat(40) })));
  const partial = forge(); delete partial.headers['x-va-gw-sig'];
  refused(() => clientIp(partial));
  const junk = forge(); junk.headers['x-va-gw-id'] = 'not-a-uuid';
  refused(() => clientIp(junk));
  assert.equal(clientIp({ headers: { 'x-vercel-forwarded-for': '198.51.100.7' } } as any), '198.51.100.7');
});

test('feature off on Vercel (no / short secret): gateway headers ignored, behaviour exactly as before', () => {
  process.env.VERCEL = '1';
  assert.equal(clientIp(forge()), '198.51.100.7');
  process.env.VA_GATEWAY_SECRET = 'short';
  assert.equal(clientIp(forge({ secret: 'short' })), '198.51.100.7');
});

test('secret rotation: previous secret accepted only while configured', () => {
  const OLD = 'o'.repeat(40);
  process.env.VA_GATEWAY_SECRET = SECRET; process.env.VA_GATEWAY_SECRET_PREVIOUS = OLD;
  assert.equal(clientIp(forge({ secret: OLD })), '203.0.113.9', 'gateway still on the old secret');
  assert.equal(clientIp(forge({ secret: SECRET })), '203.0.113.9', 'gateway already on the new secret');
  delete process.env.VA_GATEWAY_SECRET_PREVIOUS;
  refused(() => clientIp(forge({ secret: OLD })));
});

test('without a gateway secret no IP headers are sent', async () => {
  stub(() => new Response('{}'));
  await gateway.fetch(req('/me', { headers: { 'cf-connecting-ip': '203.0.113.9' } }), env({ VA_GATEWAY_SECRET: '' }));
  assert.equal(seen[0].init.headers.get('x-va-gw-ip'), null);
});

test('upstream down → 502, timeout → 504; no other backend is tried', async () => {
  stub(() => { throw new TypeError('fetch failed'); });
  const r = await gateway.fetch(req('/me'), env());
  assert.equal(r.status, 502);
  assert.equal((await r.json()).error.code, 'upstream_unavailable');
  assert.equal(seen.length, 1);
  stub(() => { const e = new Error('t'); e.name = 'TimeoutError'; throw e; });
  assert.equal((await gateway.fetch(req('/me'), env())).status, 504);
});

test('edge filtering: bad method, oversized body, missing upstream', async () => {
  stub(() => new Response('{}'));
  assert.equal((await gateway.fetch(req('/me', { method: 'PROPFIND' }), env())).status, 405);
  assert.equal((await gateway.fetch(req('/x', { method: 'POST', body: 'a', headers: { 'content-length': String(9 * 1024 * 1024) } }), env())).status, 413);
  assert.equal((await gateway.fetch(req('/me'), env({ UPSTREAM: 'http://insecure.example' }))).status, 503);
  assert.equal(seen.length, 0, 'nothing forwarded');
});

test('optional edge rate limit applies only to sign-in / recovery POSTs', async () => {
  stub(() => new Response('{}'));
  const calls: string[] = [];
  const AUTH_RL = { limit: async ({ key }: { key: string }) => { calls.push(key); return { success: false }; } };
  const r = await gateway.fetch(req('/auth/login', { method: 'POST', body: '{}', headers: { 'cf-connecting-ip': '203.0.113.9' } }), env({ AUTH_RL }));
  assert.equal(r.status, 429);
  assert.equal(calls[0], '203.0.113.9|/auth/login');
  assert.equal((await gateway.fetch(req('/employees', { headers: { 'cf-connecting-ip': '203.0.113.9' } }), env({ AUTH_RL }))).status, 200);
  assert.ok(AUTH_PATHS.has('/auth/forgot/reset'));
});
