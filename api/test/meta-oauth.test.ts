import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  META_SCOPES, callbackPage, codeExchangeUrl, dialogUrl, graphVersion, longLivedUrl, missingScopes, oauthConfig,
  redirectUriOk, safeMetaError, signState, verifyState,
} from '../src/lib/meta-oauth.ts';

/** Meta OAuth (official Facebook Login, server-side code flow) — the rules that need no network or database */
const KEY = Buffer.alloc(32, 9).toString('base64');
const env = (over: Record<string, string | undefined> = {}) => ({
  SECRETS_KEY: KEY, META_APP_ID: '1234567890', META_APP_SECRET: 'abcdef0123456789abcdef',
  META_OAUTH_REDIRECT_URI: 'https://api.example.com/public/meta/oauth/callback', ...over,
});
const now = new Date('2026-11-25T20:00:00Z');

test('configuration: names (never values) of what is missing; no SECRETS_KEY → OAuth off', () => {
  const c = oauthConfig(env());
  assert.equal(c.ok, true);
  const none = oauthConfig({});
  assert.equal(none.ok, false);
  assert.deepEqual((none as any).missing, ['META_APP_ID', 'META_APP_SECRET', 'META_OAUTH_REDIRECT_URI', 'SECRETS_KEY']);
  assert.ok(!JSON.stringify(oauthConfig(env({ SECRETS_KEY: undefined }))).includes('abcdef0123'), 'the secret is never echoed');
  // a single webhook signing secret doubles as the app secret; several are ambiguous
  assert.equal(oauthConfig(env({ META_APP_SECRET: undefined, META_APP_SECRETS: 'abcdef0123456789abcdef' })).ok, true);
  assert.equal(oauthConfig(env({ META_APP_SECRET: undefined, META_APP_SECRETS: 'abcdef0123456789abcdef,fedcba9876543210fedcba' })).ok, false);
});

test('redirect URI: exactly our callback over https; http only on a local non-production API', () => {
  assert.ok(redirectUriOk('https://api.example.com/public/meta/oauth/callback', {}));
  for (const bad of ['', 'not a url', 'https://api.example.com/other', 'https://api.example.com/public/meta/oauth/callback?x=1',
    'https://api.example.com/public/meta/oauth/callback#f', 'https://u:p@api.example.com/public/meta/oauth/callback',
    'http://api.example.com/public/meta/oauth/callback', 'javascript:alert(1)']) assert.equal(redirectUriOk(bad, {}), false, bad);
  assert.ok(redirectUriOk('http://localhost:3000/public/meta/oauth/callback', {}));
  assert.equal(redirectUriOk('http://localhost:3000/public/meta/oauth/callback', { VERCEL_ENV: 'production' }), false);
});

test('state: signed, bound to the person, expires in 10 minutes, tamper-proof', () => {
  const e = env();
  const s = signState('emp-1', now, e);
  assert.deepEqual(verifyState(s, now, e), { ok: true, actorId: 'emp-1' });
  assert.deepEqual(verifyState(s, new Date(now.getTime() + 9 * 60_000), e), { ok: true, actorId: 'emp-1' });
  assert.equal((verifyState(s, new Date(now.getTime() + 10 * 60_000 + 1), e) as any).reason, 'expired');
  assert.notEqual(signState('emp-1', now, e), s, 'a fresh nonce each time');
  // another person's id spliced into the payload
  const [p, sig] = s.split('.');
  const forged = Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(p, 'base64url').toString()), a: 'emp-2' })).toString('base64url');
  assert.equal((verifyState(`${forged}.${sig}`, now, e) as any).reason, 'bad_signature');
  assert.equal((verifyState(s, now, env({ SECRETS_KEY: Buffer.alloc(32, 1).toString('base64') })) as any).reason, 'bad_signature', 'another key');
  for (const bad of [undefined, 42, '', 'x', 'a.b.c', '.'.repeat(700)]) assert.equal(verifyState(bad, now, e).ok, false, String(bad));
  assert.equal((verifyState(s, now, {}) as any).reason, 'no_key');
  assert.throws(() => signState('emp-1', now, {}), /SECRETS_KEY/);
  // a state dated far in the future (a forged clock) is refused even if it were signed
  assert.equal(verifyState(signState('emp-1', new Date(now.getTime() + 3_600_000), e), now, e).ok, false);
});

test('URLs: the login dialog asks the minimum scopes with the fixed redirect; the exchange URLs stay server-side', () => {
  const cfg = (oauthConfig(env()) as any).cfg;
  const u = new URL(dialogUrl(cfg, 'st.ate'));
  assert.equal(u.origin + u.pathname, 'https://www.facebook.com/v21.0/dialog/oauth');
  assert.equal(u.searchParams.get('client_id'), '1234567890');
  assert.equal(u.searchParams.get('redirect_uri'), 'https://api.example.com/public/meta/oauth/callback');
  assert.equal(u.searchParams.get('response_type'), 'code');
  assert.equal(u.searchParams.get('state'), 'st.ate');
  assert.deepEqual(u.searchParams.get('scope')!.split(','), [...META_SCOPES]);
  assert.ok(!u.toString().includes('abcdef0123'), 'the app secret is never in the browser URL');
  const x = new URL(codeExchangeUrl(cfg, 'the-code'));
  assert.equal(x.searchParams.get('redirect_uri'), cfg.redirectUri);
  assert.equal(x.searchParams.get('code'), 'the-code');
  assert.equal(new URL(longLivedUrl(cfg, 't')).searchParams.get('grant_type'), 'fb_exchange_token');
  assert.equal(graphVersion({ META_GRAPH_VERSION: 'v25.0' }), 'v25.0');
  assert.equal(graphVersion({ META_GRAPH_VERSION: '25; DROP' }), 'v21.0', 'an invalid version falls back');
});

test('permissions: what was not granted is reported (declined ≠ granted)', () => {
  assert.deepEqual(missingScopes({ data: META_SCOPES.map((p) => ({ permission: p, status: 'granted' })) }), []);
  assert.deepEqual(missingScopes({ data: [{ permission: 'pages_show_list', status: 'granted' }, { permission: 'leads_retrieval', status: 'declined' }] }),
    META_SCOPES.filter((s) => s !== 'pages_show_list'));
  assert.deepEqual(missingScopes(null), [...META_SCOPES]);
});

test('errors and the landing page never carry a token, a secret or markup from Meta', () => {
  const m = safeMetaError(new Error('bad https://graph.facebook.com/x?access_token=EAAsecretsecretsecret&client_secret=zz code=abc'));
  assert.ok(!m.includes('EAAsecret') && !m.includes('zz') && !m.includes('abc'), m);
  const html = callbackPage(false, 'فشل <b>', '<script>alert(1)</script>');
  assert.ok(!html.includes('<script>') && html.includes('&lt;script&gt;') && html.includes('dir="rtl"'));
});
