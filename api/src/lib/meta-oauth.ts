import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { isProductionRuntime } from './meta-signature.ts';

/**
 * Official Meta (Facebook Login) OAuth for the office's Meta connection — the manual-flow "code" grant, done on the server
 * (https://developers.facebook.com/docs/facebook-login/guides/advanced/manual-flow):
 *   1. an authorized person asks the API for the login dialog URL; the API signs a short-lived `state` bound to that person;
 *   2. Meta redirects the browser to the ONE configured redirect URI with `code` + `state`;
 *   3. the API checks the state, exchanges the code (server side, with the app secret) and keeps the long-lived token sealed.
 * Nothing here talks to the network or the database, so every rule is unit-tested on its own (test/meta-oauth.test.ts).
 *
 * Configuration (host environment, never in the repository — see docs/MARKETING_INTELLIGENCE_PROGRESS.md):
 *   META_APP_ID              the Meta app id (digits)
 *   META_APP_SECRET          that app's secret (else the single entry of META_APP_SECRETS, the webhook signing secrets)
 *   META_OAUTH_REDIRECT_URI  exactly the "Valid OAuth Redirect URI" registered on the Meta app: https://<api host>/public/meta/oauth/callback
 *   META_GRAPH_VERSION       optional, e.g. v25.0 (default: the version the rest of the Meta code already uses)
 *   SECRETS_KEY              required: signs the state and seals the token at rest (lib/secretbox.ts)
 */

/** the version the existing Meta code was built and tested on (meta_sync.ts, integrations.ts) */
export const DEFAULT_GRAPH_VERSION = 'v21.0';
const VERSION = /^v[0-9]{2}\.0$/;

export function graphVersion(env: Record<string, string | undefined> = process.env): string {
  const v = (env.META_GRAPH_VERSION ?? '').trim();
  return VERSION.test(v) ? v : DEFAULT_GRAPH_VERSION;
}
export const graphBase = (env: Record<string, string | undefined> = process.env) => `https://graph.facebook.com/${graphVersion(env)}`;

/**
 * The permissions asked for — the minimum the features in use need, per Meta's Lead Ads retrieval and webhooks guides
 * (https://developers.facebook.com/docs/marketing-api/guides/lead-ads/retrieving):
 *  - pages_show_list, pages_read_engagement: list the pages and read their lead forms
 *  - pages_manage_metadata: subscribe the app to a page's «leadgen» webhook
 *  - leads_retrieval: read the leads
 *  - ads_management: Meta requires it to read a lead's ad-level fields (campaign_id, ad_id) used for attribution
 *  - ads_read: list the ad accounts / campaigns and read their insights
 *  - business_management: reach pages and ad accounts owned through a business portfolio
 * Several need Meta App Review (Advanced Access) before people outside the app's roles can grant them.
 */
export const META_SCOPES = [
  'pages_show_list', 'pages_read_engagement', 'pages_manage_metadata', 'leads_retrieval', 'ads_management', 'ads_read', 'business_management',
] as const;

export interface OAuthConfig { appId: string; appSecret: string; redirectUri: string; version: string }

/** the configuration, or the names (never the values) of what is missing or invalid */
export function oauthConfig(env: Record<string, string | undefined> = process.env): { ok: true; cfg: OAuthConfig } | { ok: false; missing: string[] } {
  const missing: string[] = [];
  const appId = (env.META_APP_ID ?? '').trim();
  if (!/^[0-9]{5,30}$/.test(appId)) missing.push('META_APP_ID');
  const listed = (env.META_APP_SECRETS ?? '').split(',').map((x) => x.trim()).filter(Boolean);
  const appSecret = (env.META_APP_SECRET ?? '').trim() || (listed.length === 1 ? listed[0] : '');
  if (appSecret.length < 16) missing.push('META_APP_SECRET');
  const redirectUri = (env.META_OAUTH_REDIRECT_URI ?? '').trim();
  if (!redirectUriOk(redirectUri, env)) missing.push('META_OAUTH_REDIRECT_URI');
  if (!stateKey(env)) missing.push('SECRETS_KEY');
  return missing.length ? { ok: false, missing } : { ok: true, cfg: { appId, appSecret, redirectUri, version: graphVersion(env) } };
}

/** https, no credentials / fragment, ends at our callback path; plain http only for a local, non-production API */
export function redirectUriOk(uri: string, env: Record<string, string | undefined> = process.env): boolean {
  let u: URL;
  try { u = new URL(uri); } catch { return false; }
  if (u.username || u.password || u.hash || u.search) return false;
  if (u.pathname !== '/public/meta/oauth/callback') return false;
  if (u.protocol === 'https:') return true;
  return u.protocol === 'http:' && !isProductionRuntime(env) && ['localhost', '127.0.0.1'].includes(u.hostname);
}

// ------------------------------------------------------------------ state (CSRF protection, bound to the person)
const STATE_TTL_MS = 10 * 60_000;
const b64u = (b: Buffer) => b.toString('base64url');

/** a key used only for the OAuth state, derived from SECRETS_KEY (no key → OAuth is off: tokens could not be sealed) */
function stateKey(env: Record<string, string | undefined> = process.env): Buffer | null {
  const raw = Buffer.from(env.SECRETS_KEY ?? '', 'base64');
  if (raw.length !== 32) return null;
  return createHmac('sha256', raw).update('valunivo/meta-oauth-state/v1').digest();
}

export function signState(actorId: string, now: Date, env: Record<string, string | undefined> = process.env): string {
  const k = stateKey(env);
  if (!k) throw new Error('SECRETS_KEY is not configured');
  const payload = b64u(Buffer.from(JSON.stringify({ a: actorId, n: b64u(randomBytes(16)), e: now.getTime() + STATE_TTL_MS }), 'utf8'));
  return `${payload}.${b64u(createHmac('sha256', k).update(payload).digest())}`;
}

export type StateCheck = { ok: true; actorId: string } | { ok: false; reason: 'malformed' | 'bad_signature' | 'expired' | 'no_key' };

/**
 * A state is accepted only if it is ours (HMAC), unexpired and not dated in the future beyond its lifetime. Replaying a
 * state does not help an attacker: Meta's authorization code is single-use and bound to the same redirect URI.
 */
export function verifyState(state: unknown, now: Date, env: Record<string, string | undefined> = process.env): StateCheck {
  const k = stateKey(env);
  if (!k) return { ok: false, reason: 'no_key' };
  if (typeof state !== 'string' || state.length > 600) return { ok: false, reason: 'malformed' };
  const [payload, sig, extra] = state.split('.');
  if (!payload || !sig || extra !== undefined) return { ok: false, reason: 'malformed' };
  const want = createHmac('sha256', k).update(payload).digest();
  let got: Buffer;
  try { got = Buffer.from(sig, 'base64url'); } catch { return { ok: false, reason: 'malformed' }; }
  if (got.length !== want.length || !timingSafeEqual(got, want)) return { ok: false, reason: 'bad_signature' };
  let p: any;
  try { p = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')); } catch { return { ok: false, reason: 'malformed' }; }
  if (typeof p?.a !== 'string' || typeof p?.e !== 'number' || typeof p?.n !== 'string') return { ok: false, reason: 'malformed' };
  if (p.e <= now.getTime() || p.e > now.getTime() + STATE_TTL_MS + 60_000) return { ok: false, reason: 'expired' };
  return { ok: true, actorId: p.a };
}

// ------------------------------------------------------------------ the URLs and the answers
export function dialogUrl(cfg: OAuthConfig, state: string): string {
  const u = new URL(`https://www.facebook.com/${cfg.version}/dialog/oauth`);
  u.searchParams.set('client_id', cfg.appId);
  u.searchParams.set('redirect_uri', cfg.redirectUri);
  u.searchParams.set('state', state);
  u.searchParams.set('response_type', 'code');
  u.searchParams.set('scope', META_SCOPES.join(','));
  // a permission declined earlier is asked again on a reconnection
  u.searchParams.set('auth_type', 'rerequest');
  return u.toString();
}

/** the code → token exchange (server side; the secret goes to Meta only, never to a client) */
export function codeExchangeUrl(cfg: OAuthConfig, code: string): string {
  const u = new URL(`https://graph.facebook.com/${cfg.version}/oauth/access_token`);
  u.searchParams.set('client_id', cfg.appId);
  u.searchParams.set('redirect_uri', cfg.redirectUri);
  u.searchParams.set('client_secret', cfg.appSecret);
  u.searchParams.set('code', code);
  return u.toString();
}

/** a short-lived user token → a long-lived one (about 60 days) */
export function longLivedUrl(cfg: OAuthConfig, shortToken: string): string {
  const u = new URL(`https://graph.facebook.com/${cfg.version}/oauth/access_token`);
  u.searchParams.set('grant_type', 'fb_exchange_token');
  u.searchParams.set('client_id', cfg.appId);
  u.searchParams.set('client_secret', cfg.appSecret);
  u.searchParams.set('fb_exchange_token', shortToken);
  return u.toString();
}

/** the asked permissions the person did not grant (from GET /me/permissions → data[{permission, status}]) */
export function missingScopes(perms: unknown): string[] {
  const granted = new Set((Array.isArray((perms as any)?.data) ? (perms as any).data : [])
    .filter((p: any) => p?.status === 'granted').map((p: any) => String(p.permission)));
  return META_SCOPES.filter((s) => !granted.has(s));
}

/** Meta's error text without anything token-like (a message is shown to admins and kept in integrations.last_error) */
export function safeMetaError(e: unknown): string {
  return String((e as any)?.message ?? e ?? 'Meta error')
    .replace(/EAA[A-Za-z0-9]{10,}/g, '[token]')
    .replace(/(access_token|client_secret|code)=[^&\s]+/gi, '$1=[redacted]')
    .slice(0, 300);
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

/** the page the browser lands on after Meta (Arabic, RTL, no script, no token) */
export function callbackPage(ok: boolean, title: string, detail: string): string {
  return `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>${esc(title)}</title>
<style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;text-align:center;color:#1f2937}
h1{font-size:1.25rem;color:${ok ? '#047857' : '#b91c1c'}}p{line-height:1.7}</style></head>
<body><h1>${esc(title)}</h1><p>${esc(detail)}</p><p>ارجع للتطبيق — حالة الربط بتظهر في إعدادات الربط (Meta).</p></body></html>`;
}
