# FINAL_USER_ACTIONS — VALUNIVO (do all at the final stage, in this order)

Everything else is implemented and verified on branch `cloudflare/worker-migration`. Each action below needs your
account, a dashboard, a credential, or an approval. Never paste secret values in chat; type them only into the
provider's own dashboard. After each step I verify read-only and report.

| # | Action | Why | Depends on | Prepared |
|---|---|---|---|---|
| 1 | **Approve + do Netlify containment**: Netlify → Deploys → drag-and-drop `deploy/netlify-retired/` files → "Lock to stop auto publishing" → Build settings → "Stop builds" | Legacy API is public and holds live DB / mail / push credentials | — | stub files, rollback, verification (`PRODUCTION_READINESS.md` §5) |
| 2 | **Run the Neon role audit**: Neon → SQL editor → paste `db/checks/role_audit.sql` → run → send me the result tables (no passwords in them) | Real privileges are unknown; I only proved what the app needs | — | SELECT-only script |
| 3 | **GitHub secrets / variables** (Settings → Secrets and variables → Actions): secrets `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_ANALYTICS_TOKEN` (Account Analytics: Read only), `CLOUDFLARE_API_TOKEN` (Workers Scripts: Edit + Account Analytics: Read); variables `CF_MIRROR_SCRIPT=value-attendance-api`, `CF_GATEWAY_STAGING=on`; then rerun workflow "Cloudflare — …" on the branch | 14-day traffic, real CPU probe, real visitor-IP / signature checks on isolated staging | — | workflow, isolation gates, cleanup |
| 4 | **GitHub environment `production-db`** with required reviewer (you) and secret `MIGRATION_DATABASE_URL` (owner URL) | Migrations leave the runtime role; owner credential never on Vercel | 2 | `.github/workflows/db-migrate.yml` (only on `main`) |
| 5 | **Credential rotation** (runbook `PRODUCTION_READINESS.md` §3): DB (create `valunivo_app`, Vercel both projects, redeploy, verify, reset `neondb_owner`), VAPID then Firebase, Brevo, backup token (Vercel + Apps Script) — revoke each old one only after I verify | Old values were exposed | 1, 2 | runbook + consumer map |
| 6 | **Approve the least-privilege grants**: run `db/roles/valunivo_app_least_privilege.sql` as owner | Removes CREATE / extra DELETE; proven sufficient by the full suite under that role | 2, 4, 5 | script (applies cleanly on scratch) |
| 7 | **Recovery test**: create a Neon *branch* (copy, not production) and give me its connection in Vercel/GitHub secret form, or run `api/scripts/backup-restore.mjs` yourself with the latest Drive backup | No real backup has ever been restored | 5 | script + procedure (§4) |
| 8 | **Approve production release**: merge order (release PR #9, then this branch — conflicts: `vercel.json` / `api/vercel.json` (union of `deploymentEnabled`) and, since the R3/R6 remediation, `api/src/modules/cash.ts` + `sales.ts` (resolution written in `SPEED_ENGINEER_AUDIT.md` §7A; merged preview: API 466 tests 0 failures, app 62/62)), Vercel deploy with `VA_GATEWAY_SECRET`, replace mirror Worker code with `gateway.ts` + same secret | Signed visitor IP fixes the company-wide sign-in lockout risk via the mirror | 1–7 | merge dry-run with the remediation (local, not pushed): API 466 tests, 464 pass, 0 fail, 2 skipped; app 62/62 |
| 10 | Paste the text of `speed-engineer-SKILL.md` into the chat or commit it (it has not arrived yet) | The speed audit could not read its required method file; checklist items are BLOCKED until then | — | `SPEED_ENGINEER_AUDIT.md` §2 |
| 11 | Approve a few read-only production calls: `valunivo.vercel.app/healthz/latency` ×3 and 3 requests with `accept-encoding` | Real DB round trip and real compression decide how bad the N+1 reports are in production | — | `SPEED_ENGINEER_AUDIT.md` §10 |
| 12 | Flutter profiling on one Android phone (profile build + DevTools on your PC) | Startup, frame time, memory and battery cannot be measured here | — | `SPEED_ENGINEER_AUDIT.md` §3 |
| 13 | Tell me the expected growth: employees in 1–2 years, leads per month, branches, how long attendance / notifications / audit history must be kept | Sets the performance tier and when indexes / pagination changes become necessary (`SPEED_ENGINEER_AUDIT.md` §2–3) | — | assumptions listed |
| 14 | **After the release (8): install the new app build on every phone, and paste the updated `backup/google-drive-backup.gs` into Apps Script** (R1–R7 approved and implemented: `SPEED_ENGINEER_AUDIT.md` §7A) | R1 (offline cross-user data), R2 (stale balances) and R7 (error states) only take effect in a new app build; the Drive backup uses the R6 cursor only with the updated script (until then it still works, by key + offset) | 8 | done on the branch: code, tests, before/after evidence |
| 9 | Optional, after 1–8 are stable: approve deleting the Netlify site and its variables | Final cleanup | 1, 5 | — |

Note for 8: after merging, proposed migration 086 (release branch) adds `expense_group_categories`, which the API deletes
from; rerun the role script (6) after 086 is applied so that table gets DELETE. Everything else in the merged tree passed
the least-privilege run too, except those four 086 tests (DELETE on that table).
