import { test, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import gateway, { sign, AUTH_PATHS } from '../cloudflare/gateway.ts';
import { clientIp, gatewaySignature } from '../src/auth/ratelimit.ts';

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
afterEach(() => { globalThis.fetch = realFetch; delete process.env.VA_GATEWAY_SECRET; delete process.env.VERCEL; delete process.env.TRUST_PLATFORM_IP; });
const env = (x: object = {}) => ({ UPSTREAM: UP, VA_GATEWAY_SECRET: SECRET, ...x });
const req = (path: string, init: RequestInit & { headers?: Record<string, string> } = {}) =>
  new Request('https://valunivo-gateway-staging.example.workers.dev' + path, init);
const asReq = (h: Headers) => ({ headers: Object.fromEntries(h.entries()) } as any);

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

test('client-supplied impersonation headers are stripped; the real IP is signed', async () => {
  stub(() => new Response('{}'));
  await gateway.fetch(req('/me', { headers: { 'cf-connecting-ip': '203.0.113.9', 'x-forwarded-for': '6.6.6.6', 'x-real-ip': '6.6.6.6',
    'x-vercel-forwarded-for': '6.6.6.6', 'x-va-gw-ip': '6.6.6.6', 'x-va-gw-sig': 'forged', 'x-va-gw-ts': '1', 'true-client-ip': '6.6.6.6',
    forwarded: 'for=6.6.6.6' } }), env());
  const h = seen[0].init.headers;
  for (const k of ['x-forwarded-for', 'x-real-ip', 'x-vercel-forwarded-for', 'true-client-ip', 'forwarded', 'cf-connecting-ip'])
    assert.equal(h.get(k), null, k);
  assert.equal(h.get('x-va-gw-ip'), '203.0.113.9');
  assert.equal(h.get('x-va-gw-sig'), gatewaySignature(SECRET, h.get('x-va-gw-ts')!, '203.0.113.9'), 'Workers and Node signatures match');
  // Vercel side accepts it
  process.env.VA_GATEWAY_SECRET = SECRET;
  assert.equal(clientIp(asReq(h)), '203.0.113.9');
});

test('Vercel: forged / expired / wrong-secret gateway headers are ignored (routing bypass)', async () => {
  process.env.VA_GATEWAY_SECRET = SECRET;
  const now = String(Math.floor(Date.now() / 1000));
  const forged = { 'x-va-gw-ip': '6.6.6.6', 'x-va-gw-ts': now, 'x-va-gw-sig': await sign('y'.repeat(40), now, '6.6.6.6') };
  assert.equal(clientIp({ headers: forged } as any), null, 'wrong secret, off-platform → nothing trusted');
  process.env.VERCEL = '1';
  assert.equal(clientIp({ headers: { ...forged, 'x-vercel-forwarded-for': '198.51.100.7' } } as any), '198.51.100.7', 'falls back to the platform header');
  const old = String(Math.floor(Date.now() / 1000) - 120);
  assert.equal(clientIp({ headers: { 'x-va-gw-ip': '6.6.6.6', 'x-va-gw-ts': old, 'x-va-gw-sig': gatewaySignature(SECRET, old, '6.6.6.6'),
    'x-vercel-forwarded-for': '198.51.100.7' } } as any), '198.51.100.7', 'stale signature rejected');
  // signature bound to the IP: reusing it for another address fails
  assert.equal(clientIp({ headers: { 'x-va-gw-ip': '6.6.6.7', 'x-va-gw-ts': now, 'x-va-gw-sig': gatewaySignature(SECRET, now, '6.6.6.6'),
    'x-vercel-forwarded-for': '198.51.100.7' } } as any), '198.51.100.7');
  // no / short secret on Vercel → the feature is off, behaviour exactly as before
  process.env.VA_GATEWAY_SECRET = 'short';
  assert.equal(clientIp({ headers: { 'x-va-gw-ip': '6.6.6.6', 'x-va-gw-ts': now, 'x-va-gw-sig': gatewaySignature('short', now, '6.6.6.6'),
    'x-vercel-forwarded-for': '198.51.100.7' } } as any), '198.51.100.7');
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
