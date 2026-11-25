import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { STATE_ACTION, nonceHash, signStateWith, verifyState } from '../src/lib/meta-oauth.ts';

/**
 * Official Meta OAuth (lib/meta-oauth.ts, routes in modules/integrations.ts): start → Meta → callback. The state is
 * single-use (its nonce recorded in action_otps and consumed atomically); the token must be a valid user token of our app
 * with the required permissions; a failure never replaces a working connection. Meta is faked; nothing reaches the network.
 */
let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const realFetch = globalThis.fetch;
const KEYS = ['SECRETS_KEY', 'META_APP_ID', 'META_APP_SECRET', 'META_OAUTH_REDIRECT_URI', 'META_APP_SECRETS'] as const;
const saved: Record<string, string | undefined> = {};
const APP = '1234567890';
// each code is single-use at Meta and maps to the long-lived token it yields
const codes = new Map<string, string>();
const tokens: Record<string, { app: string; valid: boolean; granted: string[] }> = {};
const ALL = ['pages_show_list', 'pages_read_engagement', 'pages_manage_metadata', 'pages_manage_ads', 'leads_retrieval', 'ads_management', 'business_management'];
const code = (id: string, long: string, t: { app?: string; valid?: boolean; granted?: string[] } = {}) => {
  codes.set(id, long); tokens[long] = { app: t.app ?? APP, valid: t.valid ?? true, granted: t.granted ?? ALL };
};
before(async () => {
  for (const k of KEYS) saved[k] = process.env[k];
  delete process.env.META_APP_SECRETS;
  Object.assign(process.env, {
    SECRETS_KEY: Buffer.alloc(32, 5).toString('base64'), META_APP_ID: APP, META_APP_SECRET: 'app-secret-0123456789abcdef',
    META_OAUTH_REDIRECT_URI: 'https://api.example.com/public/meta/oauth/callback',
  });
  h = await harness('2026-11-25T10:00:00Z'); c = await cast(h);
  // leads.config comes with the administrative officer's position (as in meta_sync.test.ts); the accountant role lacks it
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  globalThis.fetch = (async (url: any, init: any) => {
    const u = new URL(String(url));
    if (u.hostname !== 'graph.facebook.com') return realFetch(url, init);
    const j = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });
    const path = u.pathname.replace(/^\/v[0-9]+\.0\//, '');
    const tok = u.searchParams.get('access_token') ?? '';
    if (path === 'oauth/access_token' && u.searchParams.get('code')) {
      assert.equal(u.searchParams.get('redirect_uri'), 'https://api.example.com/public/meta/oauth/callback', 'the registered redirect, always');
      const long = codes.get(u.searchParams.get('code')!);
      if (!long) return j({ error: { message: 'This authorization code has been used. access_token=EAAleakleakleakleak' } }, 400);
      codes.delete(u.searchParams.get('code')!);
      return j({ access_token: `SHORT-${long}` });
    }
    if (path === 'oauth/access_token' && u.searchParams.get('grant_type') === 'fb_exchange_token') {
      return j({ access_token: String(u.searchParams.get('fb_exchange_token')).replace(/^SHORT-/, ''), expires_in: 5_184_000 });
    }
    if (path === 'debug_token') {
      assert.equal(tok, `${APP}|app-secret-0123456789abcdef`, 'debug_token uses the app token, server side');
      const t = tokens[u.searchParams.get('input_token') ?? ''];
      return j({ data: t ? { is_valid: t.valid, app_id: t.app, type: 'USER', expires_at: 1_800_000_000, scopes: t.granted } : { is_valid: false } });
    }
    if (path === 'me/permissions' && tokens[tok]) return j({ data: ALL.map((p) => ({ permission: p, status: tokens[tok].granted.includes(p) ? 'granted' : 'declined' })) });
    if (path === 'me/accounts' && tokens[tok]) return j({ data: [{ id: '2001', name: 'Value Group', access_token: `PAGE-OF-${tok}` }] });
    if (path.endsWith('/subscribed_apps')) return j({ success: true });
    return j({ error: { message: `unexpected ${path}` } }, 400);
  }) as typeof fetch;
});
after(async () => {
  globalThis.fetch = realFetch;
  for (const k of KEYS) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  await h.close();
});

/** a state through the real start route (its nonce recorded) */
const start = async (token = c.t.acc) => {
  const r = await h.call(token, 'POST', '/integrations/meta/oauth/start', {});
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return new URL(r.body.url).searchParams.get('state')!;
};
const cb = (q: string) => h.call(null, 'GET', `/public/meta/oauth/callback?${q}`);
const withState = (codeId: string, state: string) => cb(`code=${codeId}&state=${encodeURIComponent(state)}`);
const meta = async () => (await h.db.query(`SELECT access_token, active, last_error FROM integrations WHERE source = 'meta'`)).rows[0];

test('start: only a person with leads.config; the URL carries a signed state, never the secret; its nonce is recorded hashed', async () => {
  assert.equal((await h.call(null, 'POST', '/integrations/meta/oauth/start', {})).status, 401);
  assert.equal((await h.call(c.t.e1, 'POST', '/integrations/meta/oauth/start', {})).status, 403);
  const r = await h.call(c.t.acc, 'POST', '/integrations/meta/oauth/start', {});
  assert.equal(r.body.configured, true);
  assert.ok(!r.body.url.includes('app-secret'));
  const st = verifyState(new URL(r.body.url).searchParams.get('state'), h.now.value) as any;
  const row = (await h.db.query(`SELECT code_hash, used_at, expires_at FROM action_otps WHERE employee_id = $1 AND action = $2 ORDER BY created_at DESC LIMIT 1`,
    [c.ids.acc, STATE_ACTION])).rows[0];
  assert.equal(row.code_hash, nonceHash(c.ids.acc, st.nonce), 'stored as a hash, bound to the person');
  assert.ok(!JSON.stringify(row).includes(st.nonce), 'the nonce itself is never stored');
  assert.equal(row.used_at, null);
});

test('a valid state succeeds once; the same state is refused the second time', async () => {
  code('CODE-ONCE-0000001', 'LONG-TOKEN-AAAAAAAAAAAAAAAAAAAA');
  const st = await start();
  const first = await withState('CODE-ONCE-0000001', st);
  assert.equal(first.status, 200, first.raw.toString());
  code('CODE-ONCE-0000002', 'LONG-TOKEN-BBBBBBBBBBBBBBBBBBBB');
  const again = await withState('CODE-ONCE-0000002', st);
  assert.equal(again.status, 400, 'replayed state');
  assert.ok(codes.has('CODE-ONCE-0000002'), 'refused before any exchange with Meta');
  const it = await meta();
  assert.ok(it.active && it.access_token.startsWith('enc:v1:'), 'sealed at rest');
});

test('two concurrent callbacks with the same state: exactly one consumes it', async () => {
  code('CODE-RACE-0000001', 'LONG-TOKEN-RACE1RACE1RACE1RACE1'); code('CODE-RACE-0000002', 'LONG-TOKEN-RACE2RACE2RACE2RACE2');
  const st = await start();
  const [a, b] = await Promise.all([withState('CODE-RACE-0000001', st), withState('CODE-RACE-0000002', st)]);
  assert.deepEqual([a.status, b.status].sort(), [200, 400]);
  const used = (await h.db.query(`SELECT count(*)::int n FROM action_otps WHERE action = $1 AND code_hash = $2 AND used_at IS NOT NULL`,
    [STATE_ACTION, nonceHash(c.ids.acc, (verifyState(st, h.now.value) as any).nonce)])).rows[0].n;
  assert.equal(used, 1);
});

test('expired, forged, wrong-person and unrecorded states fail; nothing is exchanged', async () => {
  code('CODE-NEVER-000001', 'LONG-TOKEN-NEVERNEVERNEVERNEVER');
  const st = await start();
  // forged: not our signature
  assert.equal((await withState('CODE-NEVER-000001', 'eyJhIjoieCJ9.c2ln')).status, 400);
  // wrong person: a correctly signed state naming the owner, carrying the accountant's recorded nonce
  const nonce = (verifyState(st, h.now.value) as any).nonce;
  const wrong = signStateWith(c.ids.owner, nonce, h.now.value.getTime() + 5 * 60_000);
  assert.equal((await withState('CODE-NEVER-000001', wrong)).status, 400);
  // signed but never issued by the start route (no recorded nonce)
  assert.equal((await withState('CODE-NEVER-000001', signStateWith(c.ids.acc, 'A'.repeat(22), h.now.value.getTime() + 60_000))).status, 400);
  // expired: 10 minutes later
  h.now.value = new Date(h.now.value.getTime() + 11 * 60_000);
  assert.equal((await withState('CODE-NEVER-000001', st)).status, 400);
  assert.ok(codes.has('CODE-NEVER-000001'), 'Meta was never asked');
});

test('a person whose permission was revoked after starting cannot complete the callback', async () => {
  code('CODE-REVOKED-0001', 'LONG-TOKEN-REVOKEDREVOKEDREVOKED');
  const before = await meta();
  // the sales manager is granted leads.config personally, starts, then the grant is turned into a denial
  await h.db.query(`INSERT INTO employee_permissions (employee_id, perm_key, allow) VALUES ($1, 'leads.config', true)
                    ON CONFLICT (employee_id, perm_key) DO UPDATE SET allow = true`, [c.ids.sm1]);
  const st = await start(c.t.sm1);
  await h.db.query(`UPDATE employee_permissions SET allow = false WHERE employee_id = $1 AND perm_key = 'leads.config'`, [c.ids.sm1]);
  const r = await withState('CODE-REVOKED-0001', st);
  assert.equal(r.status, 403, r.raw.toString());
  assert.deepEqual(await meta(), before, 'nothing changed');
});

test('missing required permissions: the token is not kept and a working connection stays as it was', async () => {
  const before = await meta();
  code('CODE-PARTIAL-0001', 'LONG-TOKEN-PARTIALPARTIALPARTIAL', { granted: ['pages_show_list', 'business_management'] });
  const r = await withState('CODE-PARTIAL-0001', await start());
  assert.equal(r.status, 400);
  assert.ok(r.raw.toString().includes('leads_retrieval'), 'the missing permission is named');
  assert.deepEqual(await meta(), before, 'not replaced, not switched off');
  const a = (await h.db.query(`SELECT after FROM audit_log WHERE action = 'integration.meta_oauth_incomplete' ORDER BY at DESC LIMIT 1`)).rows[0];
  assert.ok(JSON.stringify(a.after).includes('leads_retrieval') && !JSON.stringify(a.after).includes('LONG-TOKEN'));
});

test('a token of another Meta app, or an invalid one, is refused; errors are redacted', async () => {
  const before = await meta();
  code('CODE-OTHERAPP-001', 'LONG-TOKEN-OTHERAPPOTHERAPPOTHER', { app: '999999' });
  assert.equal((await withState('CODE-OTHERAPP-001', await start())).status, 502);
  code('CODE-INVALID-0001', 'LONG-TOKEN-INVALIDINVALIDINVALID', { valid: false });
  assert.equal((await withState('CODE-INVALID-0001', await start())).status, 502);
  const reused = await withState('CODE-USED-0000001', await start());   // Meta: code already used (its error carries a token)
  assert.equal(reused.status, 502);
  assert.ok(!reused.raw.toString().includes('EAAleak'));
  const it = await meta();
  assert.equal(it.access_token, before.access_token, 'the working token stays');
  assert.ok(!String(it.last_error ?? '').includes('EAAleak'), 'the kept error is redacted');
});

test('reconnection updates the same page (no duplicate) and its token', async () => {
  code('CODE-RECONNECT-01', 'LONG-TOKEN-RECONNECTRECONNECTREC');
  assert.equal((await withState('CODE-RECONNECT-01', await start())).status, 200);
  const pages = (await h.db.query(`SELECT page_id, access_token FROM meta_pages`)).rows;
  assert.deepEqual(pages.map((p) => p.page_id), ['2001']);
  assert.ok(pages[0].access_token.startsWith('enc:v1:'));
});

test('only the optional business_management missing: the connection is kept (not blocking) and status lists it as optional', async () => {
  h.now.value = new Date(h.now.value.getTime() + 11 * 60_000);   // a fresh start-rate window (5 per 10 minutes)
  code('CODE-NOBIZ-000001', 'LONG-TOKEN-NOBIZNOBIZNOBIZNOBIZ', { granted: ALL.filter((p) => p !== 'business_management') });
  const r = await withState('CODE-NOBIZ-000001', await start());
  assert.equal(r.status, 200, r.raw.toString());
  assert.ok(r.raw.toString().includes('business_management'), 'named as an optional permission');
  const s = await h.call(c.t.acc, 'GET', '/integrations/meta/oauth/status');
  assert.deepEqual(s.body.missingRequired, []);
  assert.deepEqual(s.body.missingOptional, ['business_management']);
  // back to a full grant for the next test
  code('CODE-FULL-00000001', 'LONG-TOKEN-FULLFULLFULLFULLFULLF');
  assert.equal((await withState('CODE-FULL-00000001', await start())).status, 200);
});

test('status: validity, expiry and missing permissions, without any token or secret; employees are refused', async () => {
  assert.equal((await h.call(c.t.e1, 'GET', '/integrations/meta/oauth/status')).status, 403);
  const s = await h.call(c.t.acc, 'GET', '/integrations/meta/oauth/status');
  assert.equal(s.status, 200, JSON.stringify(s.body));
  assert.equal(s.body.connected, true);
  assert.equal(s.body.tokenValid, true);
  assert.equal(s.body.expiresAt, new Date(1_800_000_000 * 1000).toISOString());
  assert.deepEqual(s.body.missingRequired, []);
  assert.deepEqual(s.body.missingOptional, []);
  assert.ok(!JSON.stringify(s.body).match(/LONG-TOKEN|PAGE-OF|app-secret/));
});

test('the start rate limit is kept in the database (5 per 10 minutes per person)', async () => {
  h.now.value = new Date(h.now.value.getTime() + 11 * 60_000);
  for (let i = 0; i < 5; i++) assert.equal((await h.call(c.t.owner, 'POST', '/integrations/meta/oauth/start', {})).status, 200);
  assert.equal((await h.call(c.t.owner, 'POST', '/integrations/meta/oauth/start', {})).status, 429);
});

test('not configured — including META_APP_SECRETS alone: start names what is missing; the callback refuses', async () => {
  const secret = process.env.META_APP_SECRET; delete process.env.META_APP_SECRET;
  process.env.META_APP_SECRETS = 'webhook-signing-secret-0123456789';
  try {
    const r = await h.call(c.t.acc, 'POST', '/integrations/meta/oauth/start', {});
    assert.deepEqual(r.body, { configured: false, missing: ['META_APP_SECRET'] });
    assert.equal((await cb('code=x&state=y')).status, 404, 'not set up: 404, never a 5xx');
  } finally { process.env.META_APP_SECRET = secret; delete process.env.META_APP_SECRETS; }
});
