# VALUNIVO API — Cloudflare Workers migration (Phase F)

Status: **staging candidate on branch `cloudflare/worker-migration`** (based on production `main` @ `cbd00b3`).
Production stays on Vercel (`value-attendance`) and remains the rollback target. **No billing activated, no DNS /
routing / endpoint change made.** Everything below that costs money or touches production needs explicit approval.

## 1. What changes (and what does not)

| Area | Change |
|---|---|
| Business logic, routes, API contracts, DB schema | **None.** The same `buildRouter` serves every route. No migrations. |
| `api/cloudflare/worker.ts` | Workers entry. DB via Hyperdrive; one small pool (3 sockets) per request, closed with `ctx.waitUntil`; router built once, reaches the request's pool through `AsyncLocalStorage`. Fail-closed 503 without a database. Never runs migrations or seeding. |
| `api/wrangler.jsonc` | Worker `valunivo-api-staging`, `nodejs_compat`, Hyperdrive binding, var `VA_PLATFORM=cloudflare`, workers.dev only (no routes). **No secrets.** |
| `api/src/auth/ratelimit.ts` | On Workers the per-IP sign-in throttle trusts only `CF-Connecting-IP` (set by Cloudflare's edge). Without it the throttle would silently be off. Vercel unchanged. |
| `api/src/lib/webpush.ts` | VAPID ES256 signature built from an inline JWK (Workers rejects a `KeyObject` + `dsaEncoding`). Byte-identical behaviour on Node, verified. |
| `api/package.json` | `pg` floor `^8.16.3` (Hyperdrive minimum; npm already resolves 8.23.x). |
| `vercel.json`, `api/vercel.json`, `api/netlify.toml` | This branch never builds on Vercel or Netlify (a preview there would run branch code with production env vars). |
| `api/cloudflare/cpu-probe.ts`, `wrangler.probe.jsonc`, `cf-check.mjs`, `.github/workflows/cloudflare-staging.yml` | Measurement and staging tooling (below). Read-only checks print figures only, never secrets. |

## 2. Verification so far (local, scratch database only)

- API test suite **365 / 365 pass**; typecheck clean.
- Real Workers runtime (workerd via `wrangler dev`) + Hyperdrive binding to a scratch Postgres: health/ready, login,
  wrong password 401, forced password change, `/me`, 16 parallel list GETs, xlsx exports, 401 without token, CORS 204.
- Crypto on workerd: scrypt, VAPID ES256, RFC 8291 encryption, RS256 (FCM) — all OK. Bundle 306 KiB gzip.

## 3. CPU — is the Free plan possible?

**How Cloudflare counts:** only active execution counts as CPU time; waiting on the database/network does not.
Free = 10 ms CPU per request; over it the request fails with **error 1102** ("Worker exceeded resource limits"),
with only occasional overruns tolerated. Raising the limit is Paid-only.

**Measured (CPU time, not wall time)** — `process.cpuUsage()` on a 2.1 GHz Xeon, production parameters
(scrypt N=16384, r=8, p=1, unchanged):

| Operation | CPU time |
|---|---|
| one password check (scrypt) | **34–39 ms** (wall 39 ms — scrypt is pure CPU, so CPU ≈ wall) |
| full `/auth/login` request | ~40–87 ms (first call includes warm-up) |
| change password (check + new hash) | ~2 × scrypt ≈ 70–80 ms |
| typical GETs on a tiny scratch DB | `/employees` 1.7, `/notifications` 1.9, `/me` 2.6, `/attendance/today` 2.7, `/cash/overview` 6.3, `/dashboard` 8.2 ms |

The earlier "55 ms" was a wall-clock reading inside local workerd; the numbers above are true CPU time.

**Conclusion (pending confirmation on real Cloudflare):** a single scrypt check costs 3–4× the Free limit. Cloudflare's
servers may be somewhat faster, but not 4×. scrypt is memory-hard by design: there is no way to make the same
hash fit in 10 ms without lowering N (weakening it), which is not allowed. Changing algorithm (e.g. PBKDF2 at a
safe iteration count) is just as expensive. Also, `/dashboard` and `/cash/overview` already approach 10 ms on an
almost empty database, so with production data they would risk 1102 errors too. Only Paid is viable.
Moving sign-in alone to another host would keep two platforms in production and is not recommended.

**Real-Cloudflare confirmation:** the `cpu-probe` job deploys a throwaway Worker (no DB, no secrets) running the
exact production password check, calls it 40×, reads p50/p90/p99 CPU from Cloudflare Analytics, then deletes it.
On a Free account, `1102`/`exceededCpu` outcomes are themselves the proof.

## 4. Cost estimate (Workers Paid, official pricing)

Paid: **US$5/month minimum**, includes 10 M requests + 30 M CPU-ms; then US$0.30 per extra million requests and
US$0.02 per extra million CPU-ms. Hyperdrive included. Neon cost unchanged.

Traffic model (59 employees; the app polls alerts every 20 s while open, tracking ping every 5 min on shift):

| Scenario | Requests / month | CPU-ms / month (avg 4 ms; logins ~40 ms) | Bill |
|---|---|---|---|
| Expected (app open ~4 h/day) | ~1.9 M | ~8 M | **US$5.00** |
| Heavy (app open ~9 h/day) | ~3.6 M | ~15 M | **US$5.00** |
| Stress (2 × heavy, avg 8 ms) | ~7.2 M | ~58 M | ~US$5.56 |

Note: the heavy scenario (~120 k requests/day) is also above the Free plan's 100 k/day. Vercel request data
needs Vercel's paid Observability Plus, so the real figure comes from the existing mirror Worker's analytics
(it already carries most traffic): set repo variable `CF_MIRROR_SCRIPT` to its name and the workflow prints 7 days of counts.
Prices exclude any VAT Cloudflare applies to the billing address.

## 5. Spending controls (configure at activation — needs Paid)

- **Budget alerts** (Billing → Billable Usage): email only, **never interrupt service**. Recommended at US$6 and US$10.
- **Workers spending limit** (Billing → Spend limits): covers usage charges only (not the US$5), and when reached
  Cloudflare **rejects all Worker invocations (error 1103) — the API would go down** until the next period or a
  higher limit; reporting lag means it is not an exact cap. Recommendation: alerts only, or a limit set far above
  normal use (e.g. US$25) purely as a runaway guard. Your decision.

## 6. Hyperdrive caching (must be OFF)

Hyperdrive caches `SELECT` results for 60 s by default. For this app that would mean stale sessions, permissions,
revoked tokens and cash balances. The Hyperdrive config must be created with caching **disabled**. The staging job
refuses to deploy (`cf-check.mjs hyperdrive`) unless: caching disabled, origin user ≠ `neondb_owner`, direct
(non-pooler) Neon host. The same gate must run before any production deploy.

## 7. Staging — what you do (no money, no secrets in chat)

After Phases A–E (rotated credentials):
1. Cloudflare dashboard → My Profile → API Tokens → create a token with **Workers Scripts: Edit, Account Analytics: Read, Hyperdrive: Read** for this account only.
2. GitHub → repo Settings → Secrets → Actions: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`. (Optional variable `CF_MIRROR_SCRIPT`.)
   → the CPU probe runs on the next push / manual run. **Works on the Free plan; no billing needed.**
3. Hyperdrive → Create: Neon **direct** host, user `valunivo_app`, **Caching: disabled**. Put its id in repo variable `CF_HYPERDRIVE_ID`.
4. Worker `valunivo-api-staging` → Settings → Variables: secrets `BREVO_API_KEY`, `MAIL_FROM`, `FCM_SERVICE_ACCOUNT`, `BACKUP_TOKEN`, `VAPID_PRIVATE_KEY`, `SECRETS_KEY` (+ `META_APP_SECRETS` if used). Rotated values only.
   → staging deploys to `*.workers.dev`, read-only smoke test. On Free, reads work but sign-ins are expected to hit 1102 — that is the Paid justification, not a bug.

Staging shares the production database: read-only checks only (no fake employees, no money/attendance edits, no broadcast notifications, no backup/restore).

## 8. Production cutover plan — FOR APPROVAL (nothing done)

Gate 0 (prerequisites): Phases A–E done; CPU probe report reviewed; Workers Paid approved & activated with budget alerts; staging green incl. sign-in on Paid; Hyperdrive gate green.

1. Deploy the API Worker as `valunivo-api` (workers.dev, no routes) from the reviewed commit; secrets as in §7.
2. Verify on its URL: sign-in with a real account, list screens, exports, web-push key; compare `/healthz/latency` with Vercel.
3. **Cutover = the existing mirror Worker** (the app already calls it first, Vercel second). Change it to forward to the new
   API Worker through a **Service Binding** (worker-to-worker), keeping Vercel as its fallback — a mode var
   `UPSTREAM_MODE=vercel|worker`. No app rebuild, no DNS change, no endpoint change.
4. Watch 24–72 h: error rate (1102/1103/5xx), CPU p99, latency, Neon connections, push and e-mail delivery, nightly backup.
5. **Rollback:** set `UPSTREAM_MODE=vercel` (seconds). If the mirror itself fails, the app already falls back to Vercel.
   Vercel project, deployments and env vars are not touched or deleted until you approve decommissioning later.

Sources: Cloudflare docs — Workers limits & pricing, Hyperdrive (Neon, query caching), Node.js compat (`process.env`, `zlib`, `crypto`), Billing spend management & budget alerts.
