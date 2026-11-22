# VALUNIVO API — Cloudflare Workers migration (Phase F)

Status: **staging candidate on branch `cloudflare/worker-migration`** (based on production `main` @ `cbd00b3`).
Production stays on Vercel (`value-attendance`) and is the rollback target. No DNS / routing change has been made.

## 1. What changes (and what does not)

| Area | Change |
|---|---|
| Business logic, routes, API contracts, DB schema | **None.** The same `buildRouter` serves every route. No migrations added. |
| `api/cloudflare/worker.ts` (new) | Workers entry. Database via the Hyperdrive binding; one small pool (3 sockets) per request, closed with `ctx.waitUntil`; the router is built once and reaches the request's pool through `AsyncLocalStorage`. Returns 503 `not_configured` when no database is bound (fail-closed, like the other entries). |
| `api/wrangler.jsonc` (new) | Worker `valunivo-api-staging`, `nodejs_compat`, Hyperdrive binding, var `VA_PLATFORM=cloudflare`. **No secrets.** |
| `api/src/auth/ratelimit.ts` | On Workers the per-IP sign-in throttle reads `CF-Connecting-IP` (set by Cloudflare's edge, not forgeable by a caller). Vercel behaviour unchanged. Without this the IP throttle would silently be off on Workers. |
| `api/src/lib/webpush.ts` | VAPID ES256 signing passes the JWK inline instead of a `KeyObject`. Workers' `Sign.sign()` rejects a `KeyObject` together with `dsaEncoding`. Identical signatures on Node (verified). |
| `api/package.json` | `pg` floor raised to `^8.16.3` (Hyperdrive minimum). npm already resolves 8.23.x today. |
| `vercel.json`, `api/vercel.json` | This branch never deploys to Vercel (a preview there would run branch code against production env vars). |
| Not deployed by this branch | Build-time migrations / seeding. The Worker never runs `migrate` or `seed`. |

## 2. Verification done (local, scratch database only)

- Full API test suite: **365 / 365 pass** (incl. new `ratelimit-cloudflare.test.ts`).
- `wrangler dev` (workerd runtime) against a scratch Postgres through the Hyperdrive binding:
  `/healthz`, `/readyz`; login, wrong password → 401, forced password change, re-login, `/me`; 16 parallel GETs
  (employees, cash overview, notifications, attendance, dashboard, commissions, payouts) all 200; xlsx exports
  (zlib) valid; no-auth → 401; CORS preflight from `jaurea.com` → 204.
- Crypto inside workerd: scrypt hash + verify, VAPID ES256 signing, RFC 8291 payload encryption, RS256 (FCM) signing — all work.
- Measured scrypt cost: ~55 ms per hash (password parameters unchanged — hashing is **not** weakened).

## 3. Cost and limits (Cloudflare official docs, checked 2026-11-22)

- **Workers Free**: 10 ms CPU per request, 100,000 requests/day. Sign-in / password change need ~55 ms CPU for scrypt → **Free is not viable**.
- **Workers Paid: US$5 / month minimum** (account-wide). Includes 10 M requests and 30 M CPU-ms per month; overage US$0.30 per extra million requests and US$0.02 per extra million CPU-ms. Hyperdrive is included with no query limit on Paid.
- Expected cost at VALUNIVO's size (~60 employees): **US$5 / month**, overage unlikely. Not "free".
- **Nothing paid has been enabled. Workers Paid needs your explicit approval before staging can run sign-ins.**

## 4. Required settings (for whoever creates the staging resources)

1. Hyperdrive config → origin = Neon **direct (non-pooled)** host, user **`valunivo_app`** (never `neondb_owner`).
   Create it with **`--caching-disabled`**: Hyperdrive caches `SELECT` results for 60 s by default, which would
   serve stale sessions, permissions and cash balances right after a write.
2. Worker secrets (dashboard or `wrangler secret put`, never Git): `BREVO_API_KEY`, `MAIL_FROM`, `FCM_SERVICE_ACCOUNT`,
   `BACKUP_TOKEN`, `VAPID_PRIVATE_KEY`, `SECRETS_KEY`, `META_APP_SECRETS` (only if used), `CORS_ORIGINS` (optional).
   Use the **rotated** values only (after Phases A–E).
3. Put the Hyperdrive id (not a secret) in `wrangler.jsonc`, then `npx wrangler@4 deploy` from `api/` → `*.workers.dev` URL only.

## 5. Staging tests (production-safe)

Against the staging URL, which shares the production database: read-only checks only — `/healthz/latency`, `/readyz`,
sign-in with an existing account, list screens, report exports, web-push public key. No new employees, no edits to
attendance or money, no notifications to everyone, no backup/restore runs. Compare latency and errors with Vercel
(`/healthz/latency` on both).

## 6. Cutover / rollback (outline — needs your approval)

- Cutover = point the existing Cloudflare mirror worker (`api/cloudflare-proxy/worker.js`, `UPSTREAM`) or the
  `valunivo` hostname at the new Worker. The app and web need no rebuild if the hostname stays the same.
- Rollback = point it back at `value-attendance.vercel.app`. Vercel and its env vars stay untouched until Cloudflare is proven stable.
- Backups: the Apps Script calls `/backup/...` with `X-Backup-Token`. It keeps working if the hostname is unchanged.
- Remaining before cutover: approval of Workers Paid; Phases A–E done; staging comparison report; your go-ahead.
