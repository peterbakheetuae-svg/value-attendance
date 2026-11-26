import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { harness, cast, type Harness } from './helpers.ts';
import { META_STATES, metaConnectionState } from '../src/lib/meta-oauth.ts';

/**
 * 2026-11-26: GET /integrations/meta/oauth/status names ONE explicit state — not configured / not connected / authorization
 * pending / connected / permission denied / token expired or revoked / sync failed / sync succeeded. A successful OAuth
 * callback is «connected», never «sync_succeeded»: only a sync pass that ran, complete and without errors, is. Meta is faked;
 * nothing reaches the network and no token appears in any answer.
 */
const now = new Date('2026-11-25T10:00:00Z');
const base = { configured: true, hasToken: true, tokenValid: true, expiresAt: '2027-01-01T00:00:00.000Z', now, missingRequired: [] as string[],
  pendingAuthorization: false, lastOAuth: 'connected' as const, connectedAt: now, lastSync: null };

test('the pure state: every one of the eight, in priority order', () => {
  const seen = new Set<string>();
  const s = (x: Partial<Parameters<typeof metaConnectionState>[0]>) => { const v = metaConnectionState({ ...base, ...x } as any); seen.add(v); return v; };
  assert.equal(s({ configured: false }), 'not_configured');
  assert.equal(s({ hasToken: false, lastOAuth: null }), 'not_connected');
  assert.equal(s({ hasToken: false, pendingAuthorization: true }), 'authorization_pending');
  assert.equal(s({}), 'connected', 'connected, no sync yet');
  assert.equal(s({ missingRequired: ['leads_retrieval'] }), 'permission_denied');
  assert.equal(s({ hasToken: false, lastOAuth: 'declined' as any }), 'permission_denied');
  assert.equal(s({ hasToken: false, lastOAuth: 'incomplete' as any }), 'permission_denied');
  assert.equal(s({ tokenValid: false }), 'token_expired_or_revoked');
  assert.equal(s({ expiresAt: '2026-11-25T09:59:59.000Z' }), 'token_expired_or_revoked');
  assert.equal(s({ hasToken: false, lastOAuth: 'deauthorized' as any }), 'token_expired_or_revoked');
  assert.equal(s({ lastSync: { ok: false, at: new Date(now.getTime() + 1000) } }), 'sync_failed');
  assert.equal(s({ lastSync: { ok: true, at: new Date(now.getTime() + 1000) } }), 'sync_succeeded');
  // a sync from before a reconnection says nothing about the new connection
  assert.equal(s({ lastSync: { ok: true, at: new Date(now.getTime() - 1000) } }), 'connected');
  // token problems outrank a good last sync; a never-expiring token (expires_at 0) is not expired
  assert.equal(s({ tokenValid: false, lastSync: { ok: true, at: new Date(now.getTime() + 1000) } }), 'token_expired_or_revoked');
  assert.equal(s({ expiresAt: new Date(0).toISOString() }), 'connected');
  assert.deepEqual([...seen].sort(), [...META_STATES].sort(), 'all eight are reachable');
});

let h: Harness; let c: Awaited<ReturnType<typeof cast>>;
const realFetch = globalThis.fetch;
const KEYS = ['SECRETS_KEY', 'META_APP_ID', 'META_APP_SECRET', 'META_OAUTH_REDIRECT_URI', 'META_APP_SECRETS'] as const;
const saved: Record<string, string | undefined> = {};
const APP = '1234567890';
const ALL = ['pages_show_list', 'pages_read_engagement', 'pages_manage_metadata', 'pages_manage_ads', 'leads_retrieval', 'ads_management', 'business_management', 'ads_read'];
let tokenValid = true; let formsFail = false; let formsCalls = 0;
before(async () => {
  for (const k of KEYS) saved[k] = process.env[k];
  delete process.env.META_APP_SECRETS;
  Object.assign(process.env, {
    SECRETS_KEY: Buffer.alloc(32, 6).toString('base64'), META_APP_ID: APP, META_APP_SECRET: 'app-secret-0123456789abcdef',
    META_OAUTH_REDIRECT_URI: 'https://api.example.com/public/meta/oauth/callback',
  });
  h = await harness('2026-11-25T10:00:00Z'); c = await cast(h);
  await h.db.query(`UPDATE employees SET position_key = 'admin_officer' WHERE id = $1`, [c.ids.acc]);
  globalThis.fetch = (async (url: any, init: any) => {
    const u = new URL(String(url));
    if (u.hostname !== 'graph.facebook.com') return realFetch(url, init);
    const j = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });
    const path = u.pathname.replace(/^\/v[0-9]+\.0\//, '');
    if (path === 'oauth/access_token' && u.searchParams.get('code')) return j({ access_token: 'SHORT-LONG-TOKEN-STATESTATESTATE' });
    if (path === 'oauth/access_token') return j({ access_token: 'LONG-TOKEN-STATESTATESTATE', expires_in: 5_184_000 });
    if (path === 'debug_token') return j({ data: { is_valid: tokenValid, app_id: APP, type: 'USER', user_id: '4242', expires_at: 1_800_000_000, scopes: ALL } });
    if (path === 'me/permissions') return j({ data: ALL.map((p) => ({ permission: p, status: 'granted' })) });
    if (path === 'me/accounts') return j({ data: [{ id: '2001', name: 'Value Group', access_token: 'PAGE-TOKEN-STATESTATE' }] });
    if (path.endsWith('/subscribed_apps')) return j({ success: true });
    if (path === '2001/leadgen_forms') {
      formsCalls++;
      return formsFail ? j({ error: { message: 'temporary failure', code: 2 } }, 500) : j({ data: [{ id: '9001' }] });
    }
    if (path === '9001/leads') return j({ data: [] });
    if (path.endsWith('/ads')) return j({ data: [] });
    return j({ error: { message: `unexpected ${path}` } }, 400);
  }) as typeof fetch;
});
after(async () => {
  globalThis.fetch = realFetch;
  for (const k of KEYS) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  await h.close();
});

const status = async () => {
  const r = await h.call(c.t.acc, 'GET', '/integrations/meta/oauth/status');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(!JSON.stringify(r.body).match(/LONG-TOKEN|PAGE-TOKEN|app-secret|SHORT-/), 'never a token or the secret');
  return r.body;
};
const start = async () => new URL((await h.call(c.t.acc, 'POST', '/integrations/meta/oauth/start', {})).body.url).searchParams.get('state')!;
const cb = (q: string) => h.call(null, 'GET', `/public/meta/oauth/callback?${q}`);

test('the route: pending → denied → connected (callback alone is not a sync) → sync succeeded / failed → revoked', async () => {
  assert.equal((await status()).state, 'not_connected');
  const st1 = await start();
  const s1 = await status();
  assert.equal(s1.state, 'authorization_pending'); assert.equal(s1.authorizationPending, true);
  assert.equal((await cb(`error=access_denied&error_reason=user_denied&state=${encodeURIComponent(st1)}`)).status, 400);
  assert.equal((await status()).state, 'permission_denied', 'the person declined on Facebook');

  h.now.value = new Date(h.now.value.getTime() + 60_000);
  const st2 = await start();
  const ok = await cb(`code=CODE-STATE-000001&state=${encodeURIComponent(st2)}`);
  assert.equal(ok.status, 200, ok.raw.toString());
  const s2 = await status();
  assert.equal(s2.state, 'connected', 'a successful callback is a connection, not a synchronization');
  assert.equal(s2.lastSyncResult, null);

  // a campaign linked to a Meta campaign: the existing sync runs; empty answers, complete pass → succeeded
  const pid = (await h.call(c.t.owner, 'POST', '/exclusive/projects', { name: 'مشروع الحالة', ownerName: 'أ. سامي', ownerPhone: '0100' })).body.project.id;
  const ch = (await h.call(c.t.acc, 'GET', '/leads/meta')).body.channels[0].id;
  await h.call(c.t.acc, 'POST', '/leads/campaigns', { name: 'حملة الحالة', channelId: ch, projectId: pid });
  await h.db.query(`UPDATE lead_campaigns SET meta_campaign_ids = '{777}' WHERE name = 'حملة الحالة'`);
  h.now.value = new Date(h.now.value.getTime() + 60_000);
  const r1 = await h.call(c.t.owner, 'POST', '/integrations/meta/sync', {});
  assert.equal(r1.status, 200, JSON.stringify(r1.body));
  assert.ok(formsCalls >= 1, 'the sync really asked Meta');
  const s3 = await status();
  assert.equal(s3.state, 'sync_succeeded'); assert.equal(s3.lastSyncResult.ok, true); assert.equal(s3.lastSyncResult.complete, true);

  // the same outcome again adds no audit row (the scheduler does not flood the log)
  const rows = async () => (await h.db.query(`SELECT count(*)::int n FROM audit_log WHERE action = 'integration.meta_sync_result'`)).rows[0].n;
  const n1 = await rows();
  h.now.value = new Date(h.now.value.getTime() + 60_000);
  await h.call(c.t.owner, 'POST', '/integrations/meta/sync', {});
  assert.equal(await rows(), n1);

  // Meta fails: sync_failed (the connection itself is fine)
  formsFail = true;
  h.now.value = new Date(h.now.value.getTime() + 60_000);
  await h.call(c.t.owner, 'POST', '/integrations/meta/sync', {});
  const s4 = await status();
  assert.equal(s4.state, 'sync_failed'); assert.equal(s4.connected, true); assert.equal(s4.lastSyncResult.ok, false);
  assert.equal(await rows(), n1 + 1);
  formsFail = false;

  // the token is revoked at Meta: expired / revoked outranks the sync history
  tokenValid = false;
  assert.equal((await status()).state, 'token_expired_or_revoked');
  tokenValid = true;
});

test('not configured: the state says so and names nothing secret', async () => {
  const secret = process.env.META_APP_SECRET; delete process.env.META_APP_SECRET;
  try {
    const s = await status();
    assert.equal(s.state, 'not_configured'); assert.deepEqual(s.missing, ['META_APP_SECRET']);
  } finally { process.env.META_APP_SECRET = secret; }
});
