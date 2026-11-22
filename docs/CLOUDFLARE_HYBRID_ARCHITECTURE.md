# VALUNIVO — Hybrid API architecture (Cloudflare gateway + Vercel backend)

Branch `cloudflare/worker-migration` (from production `main` @ `cbd00b3`). **Staging only. Production, DNS, routing,
billing: unchanged.** The earlier "whole API on Cloudflare with database access" candidate was dropped (it remains
in Git history only); it is not deployed and nothing in this branch gives Cloudflare database access.

## 1. Architecture

```
Flutter app / web ──► Cloudflare gateway (Worker, no DB, no secrets except VA_GATEWAY_SECRET) ──► Vercel API ──► Neon
                  └──────────────────────────── (app's existing fallback: Vercel directly) ───────┘
```

- **Vercel = the only API.** Authentication, authorization, every database read/write, reports, backups, push, mail.
  It stays independently secure when the gateway is bypassed (all checks live in Vercel; nothing trusts the gateway
  except one optional, HMAC-signed client-IP header).
- **Cloudflare gateway (`api/cloudflare/gateway.ts`)**: transparent forwarding to `UPSTREAM` (Vercel), plus
  - strips client headers that could impersonate the platform/gateway (`x-forwarded-*`, `x-real-ip`, `x-vercel-*`,
    `forwarded`, `true-client-ip`, `cf-*`, `x-va-gw-*`, hop-by-hop);
  - passes the visitor IP (`CF-Connecting-IP`) to Vercel signed with `VA_GATEWAY_SECRET` (HMAC-SHA256, 60 s window,
    bound to the IP) so Vercel's per-IP sign-in throttle sees each visitor instead of Cloudflare's address;
  - no caching anywhere: subrequest `cache: "no-store"`, every response forced to `Cache-Control: no-store`
    (Vercel already sends `no-store` on every response);
  - rejects unknown methods (405) and bodies over the API's own 8 MiB limit (413) before they reach Vercel;
  - optional per-IP edge limit on `/auth/login`, `/auth/forgot*` if an `AUTH_RL` rate-limit binding is added later
    (approximate and per-location by Cloudflare's design; Vercel's database-backed limit stays authoritative);
  - Workers Logs **off** (invocation logs would record URLs); it logs nothing; no bodies or tokens are read;
  - Vercel unreachable → 502, timeout (25 s) → 504. It never tries another backend itself.
- **Vercel change (`src/auth/ratelimit.ts`)**: accepts the gateway IP only with a valid, fresh signature and a
  `VA_GATEWAY_SECRET` ≥ 32 chars; otherwise behaviour is exactly as today. Inactive until the secret is set on Vercel.

## 2. Endpoint classification (413 routes inspected)

| Class | Routes | Where |
|---|---|---|
| A. Sensitive | All routes that touch data or identity: `/auth/*`, `/me*`, `/employees*`, `/attendance*`, `/tracking*`, `/outings*`, `/payroll*`, `/payouts*`, `/commissions*`, `/cash*`, `/finance*`, `/sales*`, `/leads*`, `/partners*`/`/partner/*`, `/reports*`, `/permissions*`, `/backup*`, `/data-reset*`, `/year-closing*`, `/integrations*`, `/public/hooks/meta`, … | **Vercel** (executed only there) |
| B. Edge-eligible | `/__gateway/health` (gateway self-check, no data). Nothing else: even `/healthz*`, `/readyz` query the database. | Cloudflare |
| C. Routing/protection | Every class-A route passes through the gateway unchanged | Cloudflare → Vercel |

## 3. Verification (scratch database + stubbed / local upstream; production not touched)

- API suite **369/369** (incl. 7 new gateway / signed-IP tests). Typecheck clean.
- Authorization matrix (`test/security/authz-matrix.ts`, every route × anon / employee / sales manager / accountant / HR):
  anonymous 2xx only on `/healthz`, `/healthz/latency`, `/readyz`, `/public/hooks/meta` (signature-checked webhook); employee 2xx
  only on self-scoped lists (own payouts, entitlements, leads, payroll lines…), covered by the isolation/permission suites.
- Secret-leak scan (`test/security/leak-scan.ts`, 120 GET routes × owner/employee): **0 findings**.
- End-to-end **through the gateway** to the real API over TLS: 41 checks, all pass (one was first mis-aimed: GET on the POST-only `/backup/sweep` gave 404; POST gives 401, also with a wrong backup token) — anonymous 401 on employees / cash / commissions /
  payouts / attendance / leads / tracking / payroll / reports / backup; forged JWT 401; sign-in works; 22 SQL-injection /
  traversal payloads → no 5xx, no SQL error text; 30 failures from one visitor → 429 for that visitor only, others still
  sign in; forged gateway headers sent directly to Vercel are ignored; `no-store` on JSON and xlsx; CORS allows only
  approved origins.
- In workerd: `cache: "no-store"` fetch works; WebCrypto signature == Node signature. Gateway bundle 1.7 KiB gzip.

## 4. Not verified / residual risks

- **Real Cloudflare** not exercised yet (needs your API token): gateway CPU in production, and the scrypt probe.
- **Production database roles** not inspected (no access, not authorized). Run `db/checks/role_audit.sql` (SELECT-only).
- `CREATE ON SCHEMA public` for `valunivo_app` remains the documented temporary exception.
- Today's mirror Worker (`api/cloudflare-proxy/worker.js`, production) forwards all headers and likely makes every
  user look like Cloudflare's IP to Vercel: 30 failed sign-ins company-wide in 15 min could throttle everyone on that
  path (the app then falls back to Vercel directly). Fixed by the gateway + `VA_GATEWAY_SECRET`, which needs a
  production deploy → your approval.
- `/readyz` and `/healthz/latency` are public: they reveal migration count, push/mail/backup on-off and DB region, and
  `/healthz/latency` runs 4 DB queries per call. Pre-existing; candidates for restriction in a later approved change.
- Cloudflare's rate-limit binding is approximate/per-location; not enabled.

## 5. CPU and cost

- Gateway: HMAC + proxy only, ≈1 ms CPU → **fits Workers Free (10 ms)**.
- Free's 100,000 requests/day is the real constraint: estimated 60k–120k requests/day (59 users, 20-s alert polling).
  Over the limit, workers.dev requests fail and the app falls back to Vercel directly. Real counts: set `CF_MIRROR_SCRIPT`.
- Paid (US$5/month min.) is **not justified** for the gateway unless traffic is consistently > 100k/day; then ≈US$5.00/month
  (well inside 10 M requests / 30 M CPU-ms). No Hyperdrive, no KV/D1, no logging costs.
- Vercel usage is **not reduced** (all API work still runs there). This design buys isolation and edge filtering, not Vercel savings.
- Password hashing: measured 34–39 ms CPU per scrypt check (Node). Stays on Vercel; parameters unchanged.
- Spending controls (only after a Paid approval): budget alerts are e-mail only; a Workers spending limit blocks all
  Worker invocations (error 1103) and is not an exact cap.

## 6. Staging — your actions (Free plan, no billing)

1. Cloudflare API token: **Workers Scripts: Edit + Account Analytics: Read**, this account only.
2. GitHub → Settings → Secrets → Actions: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`.
   Variables: `CF_GATEWAY_STAGING=on`; optional `CF_MIRROR_SCRIPT=<existing mirror Worker name>`.
3. Optional: Worker `valunivo-gateway-staging` → secret `VA_GATEWAY_SECRET` (random ≥ 32 chars). Not set on Vercel yet.
   → workflow deploys `valunivo-gateway-staging.<account>.workers.dev` → production Vercel, runs read-only checks (no sign-in, no writes).

## 7. Production plan — FOR APPROVAL (nothing done)

1. Set `VA_GATEWAY_SECRET` on Vercel + deploy the `ratelimit.ts` change (merge-approved commit).
2. Point the app's first API address at the gateway: either replace the existing mirror Worker's code with `gateway.ts`
   (same hostname → no app rebuild) or add a route. Vercel stays the app's second address.
3. Watch 48 h: 5xx/502/504 at the gateway, 429 distribution, Vercel errors, sign-in success.
4. **Rollback:** redeploy the previous mirror code (one command) — or do nothing: the app already falls back to Vercel.
