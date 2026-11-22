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
| 8 | **Approve production release**: merge order (release PR #9, then this branch — only `vercel.json` / `api/vercel.json` conflict, union of `deploymentEnabled`), Vercel deploy with `VA_GATEWAY_SECRET`, replace mirror Worker code with `gateway.ts` + same secret | Signed visitor IP fixes the company-wide sign-in lockout risk via the mirror | 1–7 | merge dry-run: 457 tests, 456 passed; the 1 failure (a test of mine using a payout kind the release branch restricts) is fixed and re-verified on both trees |
| 9 | Optional, after 1–8 are stable: approve deleting the Netlify site and its variables | Final cleanup | 1, 5 | — |

Note for 8: after merging, proposed migration 086 (release branch) adds `expense_group_categories`, which the API deletes
from; rerun the role script (6) after 086 is applied so that table gets DELETE. Everything else in the merged tree passed
the least-privilege run too, except those four 086 tests (DELETE on that table).
