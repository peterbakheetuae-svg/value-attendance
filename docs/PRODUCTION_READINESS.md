# VALUNIVO — Production-readiness assessment (branch `cloudflare/worker-migration`)

Status key: VERIFIED · IMPLEMENTED, NOT YET VERIFIED · BLOCKED BY USER ACTION · REQUIRES APPROVAL · N/A.
Production (Vercel `value-attendance`, Neon, DNS, routing) is unchanged; nothing merged.

## 1. Assessment

| # | Area | Status | Evidence |
|---|---|---|---|
| 1 | Credential rotation | BLOCKED BY USER ACTION (scheduled last, per owner) | Runbook §3. Old values still active everywhere. |
| 2 | Netlify isolation | BLOCKED BY USER ACTION | **Legacy API is live and connected to production**: `value-attendance-api.netlify.app/readyz` → `{"ok":true,"migrations":73,"push":true,"mail":true,"backup":false}` (old code, Nov 5). No app, web, workflow or Apps Script consumer references it (repo search). Netlify bakes env vars into deployed functions, so deleting variables alone does not cut it off; revoking the old DB password / Brevo key / Firebase key (§3) does. Branch builds blocked (`ignore = "exit 0"` on this branch). |
| 3 | Neon role audit | BLOCKED BY USER ACTION | `db/checks/role_audit.sql` = SELECT-only (verified: no DDL/DML; ran clean on a scratch DB). Code-derived needs in `CLOUDFLARE_HYBRID_ARCHITECTURE.md` §4; no production facts claimed. |
| 4 | Cloudflare staging isolation | IMPLEMENTED, NOT YET VERIFIED on Cloudflare | Gateway → Service Binding → synthetic verifier; `.invalid` placeholder upstream; CI gate on configs; checks abort unless the first answer is synthetic; per-run secrets masked; both Workers deleted. 19/20 checks pass in local workerd. |
| 5 | Real Cloudflare visitor-IP | BLOCKED BY USER ACTION | Only provable on Cloudflare (token needed). |
| 6 | Signature & replay | VERIFIED (code/runtime) · replay instance-local, accepted | 11 unit tests + workerd/Node parity + e2e. Signature only feeds the sign-in throttle; grants no access; replay needs the Cloudflare→Vercel TLS stream and repeats the identical request ≤ 60 s. Distributed store not justified. |
| 7 | Financial duplicates | VERIFIED (synthetic DB, concurrent) | `test/financial-concurrency.test.ts` (8 parallel copies each): opening balance, receipt (clientRef), expense (clientRef), expense approve + reverse, receipt reverse, transfer decide / execute / receive, payout code confirmation (cash out once), manual payout double-tap, sale registration + collection → each takes effect once. Sequential: payroll line pay, advance deduction, salary payout, company fee (existing tests). Note: concurrent duplicate receipts/expenses get 409 (sequential resend gets 200 + same receipt) — money recorded once either way. |
| 8 | Traffic & plan | BLOCKED BY USER ACTION | `traffic` job: 14-day per-day counts, avg, peak, monthly projection, 100k/day check (analytics only, deploys nothing). Mirror script name very likely `value-attendance-api` (the backup script calls `value-attendance-api.peter-bakheet-uae.workers.dev`). |
| 9 | Application/API security | VERIFIED (synthetic) with fixes | Authorization matrix (413 routes × 5 roles) unchanged; leak scan 0; malformed-input fuzz of every write route (5 payload kinds) and every read route (hostile queries): **2 bugs found and fixed** (NUL byte → 500 on 7 routes; `/leads?tab=constructor` → 500); DB privilege errors no longer echo table names; health endpoints no longer disclose config; CORS / no-store / nosniff on every response. |
| 10 | Backup & recovery | VERIFIED (mechanism, synthetic) · real restore NOT verified | `backup-restore.test.ts`: encrypted export → restore into a new DB → every table, same rows. Token compared timing-safe, ≥ 24 chars; export refused without `BACKUP_ENCRYPTION_KEY`; credentials redacted; Drive keeps 30 days. A real Drive backup has never been restored. |
| 11 | CI & tests | VERIFIED | API suite 387/387 locally; CI runs listed in the final report. |
| 12 | Remaining production risks | — | §2 |

## 2. Remaining production risks (ordered)

1. **Legacy Netlify API live with production DB, mail and push credentials** (exposed earlier). Closed by §3 steps 1–3.
2. **Mirror Worker shares one IP for all users** → 30 failed sign-ins company-wide can block everyone on that path until fallback.
   Closed by the gateway + `VA_GATEWAY_SECRET` (production deploy — approval).
3. Runtime role has CREATE on `public` (temporary exception) — removal needs a separate migration credential (approval).
4. No real restore test yet (§4).

## 3. Credential rotation runbook (LAST step; enter values only in provider dashboards)

Consumers (repo + infra search): DATABASE_URL — Vercel `value-attendance`, `value-attendance-api`, Netlify. BREVO_API_KEY — both Vercel, Netlify.
FCM_SERVICE_ACCOUNT — both Vercel, Netlify (also seeds web-push keys unless `VAPID_PRIVATE_KEY` is set). BACKUP_TOKEN — Vercel `value-attendance`,
Netlify (inactive: <24 chars), Apps Script property. None in GitHub secrets. MAIL_FROM not a secret.

Order (each step: update → redeploy Vercel → verify → only then revoke):
1. **Database**: create `valunivo_app` (SQL already provided) → set its URL as `DATABASE_URL` on both Vercel projects → redeploy →
   check `/readyz` = ok and one sign-in → in Neon reset the `neondb_owner` password (this also cuts Netlify off).
2. **VAPID** first, then **Firebase**: add `VAPID_PRIVATE_KEY` (new) on Vercel → redeploy (browsers re-subscribe automatically) → new
   service-account key → `FCM_SERVICE_ACCOUNT` on both Vercel → redeploy → test one push → delete the old key in Google Cloud.
3. **Brevo**: new key → both Vercel → redeploy → "forgot password" on your own account → mail arrives → delete the old key.
4. **Backup token**: new random ≥ 32 chars → Vercel + Apps Script property at the same time → redeploy → run `backupNow` once → files appear.
5. Netlify: then (approval) delete the four variables / the site. I verify each step read-only (env names/dates, build logs, `/readyz`).

## 4. Recovery test (when you approve)

Create a Neon **branch** (isolated copy, not production) → run `api/scripts/backup-restore.mjs` with that branch's URL and the latest
Drive backup → compare table counts. Nothing touches production.
