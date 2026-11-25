import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { signState } from '../src/lib/meta-oauth.ts';

/**
 * Official Meta OAuth (lib/meta-oauth.ts, routes in modules/integrations.ts): start → Meta → callback → sealed token +
 * connected pages; status; who may do it. Meta's endpoints are faked; nothing reaches the network.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const realFetch = globalThis.fetch;
const KEYS = ['SECRETS_KEY', 'META_APP_ID', 'META_APP_SECRET', 'META_OAUTH_REDIRECT_URI'] as const;
const saved: Record<string, string | undefined> = {};
const codes = new Set(['GOOD-CODE-123456']);   // Meta's codes are single-use
before(async () => {
  for (const k of KEYS) saved[k] = process.env[k];
  Object.assign(process.env, {
    SECRETS_KEY: Buffer.alloc(32, 5).toString('base64'), META_APP_ID: '1234567890', META_APP_SECRET: 'app-secret-0123456789abcdef',
    META_OAUTH_REDIRECT_URI: 'https://api.example.com/public/meta/oauth/callback',
  });
  h = await harness('2026-11-25T10:00:00Z'); c = await cast(h);
  globalThis.fetch = (async (url: any, init: any) => {
    const u = new URL(String(url));
    if (u.hostname !== 'graph.facebook.com') return realFetch(url, init);
    const j = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });
    const path = u.pathname.replace(/^\/v[0-9]+\.0\//, '');
    const tok = u.searchParams.get('access_token');
    if (path === 'oauth/access_token' && u.searchParams.get('code')) {
      assert.equal(u.searchParams.get('redirect_uri'), 'https://api.example.com/public/meta/oauth/callback', 'the registered redirect, always');
      if (!codes.delete(u.searchParams.get('code')!)) return j({ error: { message: 'This authorization code has been used. access_token=EAAleakleakleakleak' } }, 400);
      return j({ access_token: 'SHORT-USER-TOKEN-xxxxxxxx' });
    }
    if (path === 'oauth/access_token' && u.searchParams.get('grant_type') === 'fb_exchange_token') return j({ access_token: 'LONG-USER-TOKEN-xxxxxxxxx', expires_in: 5_184_000 });
    if (path === 'me/permissions' && tok === 'LONG-USER-TOKEN-xxxxxxxxx') {
      return j({ data: [{ permission: 'pages_show_list', status: 'granted' }, { permission: 'leads_retrieval', status: 'declined' }] });
    }
    if (path === 'me/accounts' && tok === 'LONG-USER-TOKEN-xxxxxxxxx') return j({ data: [{ id: '2001', name: 'Value Group', access_token: 'PAGE-OAUTH-A' }] });
    if (path.endsWith('/subscribed_apps')) return j({ success: true });
    if (path === 'debug_token') {
      assert.equal(tok, '1234567890|app-secret-0123456789abcdef', 'debug_token uses the app token, server side');
      return j({ data: { is_valid: true, expires_at: 1_800_000_000, scopes: ['pages_show_list', 'pages_manage_metadata'] } });
    }
    return j({ error: { message: `unexpected ${path}` } }, 400);
  }) as typeof fetch;
});
after(async () => {
  globalThis.fetch = realFetch;
  for (const k of KEYS) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  await h.close();
});

test('start: only a person with leads.config (never an employee without it); the dialog URL carries a signed state, not the secret', async () => {
  assert.equal((await h.call(null, 'POST', '/integrations/meta/oauth/start', {})).status, 401);
  assert.equal((await h.call(c.t.e1, 'POST', '/integrations/meta/oauth/start', {})).status, 403);
  const r = await h.call(c.t.acc, 'POST', '/integrations/meta/oauth/start', {});
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.configured, true);
  const u = new URL(r.body.url);
  assert.equal(u.hostname, 'www.facebook.com');
  assert.ok(u.searchParams.get('state')!.includes('.'));
  assert.ok(!r.body.url.includes('app-secret'), 'the app secret never leaves the server');
});

test('callback: a bad / foreign state, a declined dialog or a reused code connects nothing; errors never echo Meta tokens', async () => {
  const cb = (q: string) => h.call(null, 'GET', `/public/meta/oauth/callback?${q}`);
  assert.equal((await cb('code=GOOD-CODE-123456&state=forged.sig')).status, 400);
  // a valid state of a person who may not manage Meta
  const e1 = (await h.db.query(`SELECT id FROM employees WHERE id = $1`, [c.ids.e1])).rows[0].id;
  assert.equal((await cb(`code=GOOD-CODE-123456&state=${encodeURIComponent(signState(e1, h.now.value))}`)).status, 403);
  assert.equal((await cb(`error=access_denied&error_reason=user_denied&state=${encodeURIComponent(signState(c.ids.acc, h.now.value))}`)).status, 400);
  const reused = await cb(`code=USED-CODE-0000000&state=${encodeURIComponent(signState(c.ids.acc, h.now.value))}`);
  assert.equal(reused.status, 502);
  assert.ok(!reused.raw.toString().includes('EAAleak'));
  const err = (await h.db.query(`SELECT last_error, access_token FROM integrations WHERE source = 'meta'`)).rows[0];
  assert.ok(!String(err?.last_error ?? '').includes('EAAleak'), 'the kept error is redacted');
  assert.equal(err?.access_token ?? null, null, 'nothing stored on a failure');
});

test('callback: the code becomes a long-lived token, sealed at rest; the pages are connected; missing permissions are reported', async () => {
  const r = await h.call(null, 'GET', `/public/meta/oauth/callback?code=GOOD-CODE-123456&state=${encodeURIComponent(signState(c.ids.acc, h.now.value))}`);
  const html = r.raw.toString();
  assert.equal(r.status, 200, html);
  assert.match(r.headers.get('content-type') ?? '', /text\/html/);
  assert.ok(!html.includes('LONG-USER-TOKEN') && !html.includes('PAGE-OAUTH-A'), 'no token on the page');
  assert.ok(html.includes('leads_retrieval'), 'the declined permission is named');
  const it = (await h.db.query(`SELECT access_token, active FROM integrations WHERE source = 'meta'`)).rows[0];
  assert.ok(it.active && it.access_token.startsWith('enc:v1:') && !it.access_token.includes('LONG-USER'), 'sealed (VA-05)');
  const pages = (await h.db.query(`SELECT page_id, access_token, subscribed FROM meta_pages`)).rows;
  assert.deepEqual(pages.map((p) => p.page_id), ['2001']);
  assert.ok(pages[0].subscribed && pages[0].access_token.startsWith('enc:v1:'));
  const audit = (await h.db.query(`SELECT action FROM audit_log WHERE action LIKE 'integration.meta_oauth%'`)).rows.map((x) => x.action);
  assert.ok(audit.includes('integration.meta_oauth_connected'));
});

test('status: connection, expiry and missing scopes, without any token; employees without the permission are refused', async () => {
  assert.equal((await h.call(c.t.e1, 'GET', '/integrations/meta/oauth/status')).status, 403);
  const s = await h.call(c.t.acc, 'GET', '/integrations/meta/oauth/status');
  assert.equal(s.status, 200, JSON.stringify(s.body));
  assert.equal(s.body.configured, true);
  assert.equal(s.body.connected, true);
  assert.equal(s.body.tokenValid, true);
  assert.equal(s.body.expiresAt, new Date(1_800_000_000 * 1000).toISOString());
  assert.ok(s.body.missingScopes.includes('leads_retrieval'));
  assert.equal(s.body.pages.n, 1);
  assert.ok(!JSON.stringify(s.body).match(/TOKEN|PAGE-OAUTH|app-secret/));
});

test('not configured: start answers which settings are missing (names only); the callback refuses', async () => {
  const id = process.env.META_APP_ID; delete process.env.META_APP_ID;
  try {
    const r = await h.call(c.t.acc, 'POST', '/integrations/meta/oauth/start', {});
    assert.equal(r.status, 200);
    assert.deepEqual(r.body, { configured: false, missing: ['META_APP_ID'] });
    assert.equal((await h.call(null, 'GET', '/public/meta/oauth/callback?code=x&state=y')).status, 503);
  } finally { process.env.META_APP_ID = id; }
});
