import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  META_SCOPES, META_SCOPES_LATER_INSIGHTS, META_SCOPES_OPTIONAL, META_SCOPES_REQUIRED, callbackPage, codeExchangeUrl, dialogUrl,
  graphVersion, longLivedUrl, metaFetch, missingScopes, newState, nonceHash, oauthConfig, redirectUriOk, safeMetaError, signStateWith,
  tokenFrom, tokenIsOurs, verifyState,
} from '../src/lib/meta-oauth.ts';
const signState = (actor: string, at: Date, e: Record<string, string | undefined>) => newState(actor, at, e).state;

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
  // the webhook signing secrets are never used as the OAuth app secret (separate credentials)
  const borrowed = oauthConfig(env({ META_APP_SECRET: undefined, META_APP_SECRETS: 'abcdef0123456789abcdef' }));
  assert.equal(borrowed.ok, false);
  assert.deepEqual((borrowed as any).missing, ['META_APP_SECRET']);
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
  const v = verifyState(s, now, e) as any;
  assert.equal(v.ok, true); assert.equal(v.actorId, 'emp-1'); assert.match(v.nonce, /^[A-Za-z0-9_-]{16,64}$/);
  assert.equal((verifyState(s, new Date(now.getTime() + 9 * 60_000), e) as any).actorId, 'emp-1');
  // the stored hash is bound to the person: the same nonce under another person's id is a different hash
  assert.notEqual(nonceHash('emp-1', v.nonce), nonceHash('emp-2', v.nonce));
  assert.equal(nonceHash('emp-1', v.nonce), nonceHash('emp-1', v.nonce));
  // a signed state with a malformed nonce is refused
  assert.equal((verifyState(signStateWith('emp-1', 'x', now.getTime() + 60_000, e), now, e) as any).reason, 'malformed');
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

test('least privilege: required vs optional vs later (Insights) scopes; ads_read is not asked yet', () => {
  assert.deepEqual([...META_SCOPES], [...META_SCOPES_REQUIRED, ...META_SCOPES_OPTIONAL]);
  assert.ok(META_SCOPES_REQUIRED.includes('leads_retrieval') && META_SCOPES_REQUIRED.includes('pages_manage_metadata'));
  assert.ok(META_SCOPES_LATER_INSIGHTS.every((s) => !(META_SCOPES as readonly string[]).includes(s)), 'later scopes are not requested');
  assert.equal(new Set(META_SCOPES).size, META_SCOPES.length, 'no duplicates');
});

test('token answers are validated; only a valid user token of our app is accepted', () => {
  assert.deepEqual(tokenFrom({ access_token: 'EAAB' + 'x'.repeat(40), expires_in: 5_184_000 }), { token: 'EAAB' + 'x'.repeat(40), expiresIn: 5_184_000 });
  for (const bad of [null, {}, { access_token: '' }, { access_token: 'short' }, { access_token: 123 }, { access_token: 'has space '.repeat(5) }]) {
    assert.throws(() => tokenFrom(bad), /no valid access token/);
  }
  assert.equal(tokenFrom({ access_token: 'T'.repeat(30) }).expiresIn, null, 'no expires_in → unknown, not 0');
  const ours = (data: unknown) => tokenIsOurs({ data }, '1234567890');
  assert.equal(ours({ is_valid: true, app_id: '1234567890', type: 'USER' }), true, 'a valid user token of our app');
  assert.equal(ours({ is_valid: true, app_id: 1234567890, type: 'USER' }), true, 'a numeric app_id is the same app');
  assert.equal(ours({ is_valid: true, app_id: '1234567890' }), false, 'type missing');
  assert.equal(ours({ is_valid: true, app_id: '1234567890', type: null }), false, 'type null');
  assert.equal(ours({ is_valid: true, app_id: '1234567890', type: 'PAGE' }), false, 'PAGE token');
  assert.equal(ours({ is_valid: true, app_id: '1234567890', type: 'APP' }), false, 'APP token');
  assert.equal(ours({ is_valid: true, app_id: '1234567890', type: 'SYSTEM_USER' }), false, 'SYSTEM_USER token');
  assert.equal(ours({ is_valid: true, app_id: '1234567890', type: 'user' }), false, 'case matters');
  assert.equal(ours({ is_valid: true, app_id: '999', type: 'USER' }), false, 'wrong app_id');
  assert.equal(ours({ is_valid: true, type: 'USER' }), false, 'no app_id');
  assert.equal(ours({ is_valid: false, app_id: '1234567890', type: 'USER' }), false, 'invalid (revoked / expired)');
  assert.equal(ours({ is_valid: 'true', app_id: '1234567890', type: 'USER' }), false, 'is_valid must be the boolean true');
  assert.equal(tokenIsOurs(null, '1234567890'), false);
  assert.equal(tokenIsOurs({}, '1234567890'), false);
});

test('metaFetch: a network failure or timeout never surfaces the URL (token / secret / code)', async () => {
  const real = globalThis.fetch;
  try {
    globalThis.fetch = (async () => { throw new TypeError('fetch failed', { cause: new Error('connect ECONNREFUSED https://graph.facebook.com/x?client_secret=SECRET&code=CODE') }); }) as any;
    await assert.rejects(metaFetch('https://graph.facebook.com/x?client_secret=SECRET&code=CODE'), (e: any) => {
      assert.equal(e.message, 'Meta could not be reached'); assert.equal(e.cause, undefined); return true;
    });
    globalThis.fetch = (async () => { const e = new Error('timeout'); e.name = 'TimeoutError'; throw e; }) as any;
    await assert.rejects(metaFetch('https://graph.facebook.com/x?access_token=EAAsecret'), /did not answer in time/);
    globalThis.fetch = (async () => new Response(JSON.stringify({ error: { message: 'Invalid OAuth access token.' } }), { status: 400 })) as any;
    await assert.rejects(metaFetch('https://graph.facebook.com/x?access_token=EAAsecret'), /Invalid OAuth access token/);
  } finally { globalThis.fetch = real; }
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

import { createHmac } from 'node:crypto';
import { isRateLimited, metaUserHash, parseSignedRequest } from '../src/lib/meta-oauth.ts';

test('signed_request (deauthorize / data deletion): only our app secret\'s HMAC-SHA256 is accepted', () => {
  const secret = 'app-secret-0123456789abcdef';
  const sign = (p: unknown, key = secret) => {
    const payload = Buffer.from(JSON.stringify(p)).toString('base64url');
    return `${createHmac('sha256', key).update(payload).digest('base64url')}.${payload}`;
  };
  assert.deepEqual(parseSignedRequest(sign({ algorithm: 'HMAC-SHA256', user_id: '1234567', issued_at: 1 }), secret), { user_id: '1234567', issued_at: 1 });
  assert.equal(parseSignedRequest(sign({ algorithm: 'HMAC-SHA256', user_id: '1234567' }, 'another-secret-xxxxxxxx'), secret), null, 'another key');
  assert.equal(parseSignedRequest(sign({ algorithm: 'none', user_id: '1234567' }), secret), null, 'another algorithm');
  assert.equal(parseSignedRequest(sign({ algorithm: 'HMAC-SHA256', user_id: 'x' }), secret), null, 'a malformed user id');
  const good = sign({ algorithm: 'HMAC-SHA256', user_id: '1234567' });
  const [s, p] = good.split('.');
  const tampered = Buffer.from(JSON.stringify({ algorithm: 'HMAC-SHA256', user_id: '7654321' })).toString('base64url');
  assert.equal(parseSignedRequest(`${s}.${tampered}`, secret), null, 'payload changed');
  for (const bad of [undefined, 42, '', 'a.b.c', 'x'.repeat(5000), `${s}.${p}.x`]) assert.equal(parseSignedRequest(bad, secret), null);
  assert.equal(parseSignedRequest(good, ''), null, 'no secret configured');
  assert.match(metaUserHash('1234567'), /^[0-9a-f]{64}$/);
  assert.notEqual(metaUserHash('1234567'), metaUserHash('1234568'));
});

test('rate limits are recognised from Meta\'s error codes or HTTP 429', () => {
  for (const c of [4, 17, 32, 613, 80000, 80004, 80014]) assert.ok(isRateLimited({ metaCode: c }), String(c));
  assert.ok(isRateLimited({ httpStatus: 429 }));
  for (const c of [1, 100, 190, 80015, null]) assert.equal(isRateLimited({ metaCode: c }), false, String(c));
});
