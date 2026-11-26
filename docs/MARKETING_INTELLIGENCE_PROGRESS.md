# Marketing Intelligence & Employee Performance — implementation progress

Specification: «VALUNIVO — Complete Remaining Marketing Intelligence & Employee Performance Implementation» (owner, 2026-11-25).
This file is the persistent checklist: each session continues from the first item that is not ✅.

## Baseline (verified 2026-11-25)

| Item | Verified state |
|---|---|
| `main` | `98f9f69` — PR #17 (revert of the Flutter dependency bumps). No later commits. |
| Working branch | `feat/marketing-intelligence`, from `98f9f69`. |
| Production database | Neon `valunivo-attendance-eu`, branch `main`. **As recorded on 2026-11-25** (an earlier read-only inspection; not re-verified on 2026-11-26 — see «Pre-release readiness» → migration history): `schema_migrations` 091 applied 09:04 UTC, 090 applied after it (14:39 UTC). A branch `restore-before-091-2026-11-25` existed then. |
| Production data relevant here | 0 `lead_campaigns`, 0 `leads`, 0 `meta_pages`, 1 `integrations` row for Meta, 2 `marketing_companies`, 12 `kpi_definitions`, 0 active `kpi_sets`, 0 `kpi_results`. No plain Meta token (`EAA…`) stored. |
| Graph API | At baseline the code was pinned to v21.0 (Meta removes it on 2027-01-21). **Current code: default v25.0**, configurable with `META_GRAPH_VERSION` (see «P2 — Graph API version»). Not yet exercised against Meta with real credentials. |

Status keys: ✅ done (tested) · 🟡 partial · ⛔ blocked (external) · 🔒 owner decision · ⬜ not started.
"Tested here" = unit tests run in the session; "CI" = Postgres-backed tests written for `api-ci.yml` (the session could not install `pg`).

## Phase 1 — Audit

| Requirement | Existing | Missing | Status |
|---|---|---|---|
| Meta settings, tokens, pages, webhook, sync | `meta_sync.ts` (pull from page forms + campaign ads, `meta_lead_id` unique), `integrations.ts` (manual token, pages, verify token, signed webhook `metaSignatureOk`), `secretbox.ts` (AES-256-GCM at rest), 081 | OAuth, independent scheduler, checkpoints, dead-letter, sync metrics | ✅ audited |
| Campaign ↔ marketing company | `lead_campaigns.marketing_company_id`, `meta_campaign_ids`, partner isolation (`partnerHidden`, VA-11) | ownership history, ad account / ad set / ad entities, office-direct flag, drill-down | ✅ audited |
| KPI engine | `kpi.ts` (definitions, versioned sets per employee / position / job title, snapshots of weight + target, manual `actual`, null ≠ 0) | automatic actuals, source/evidence, calculation timestamp | ✅ audited |
| Lead quality | `leads.rating`, `stars`, `duplicate_of`, `cancel_reason_id`, `lead_logs` | a separate quality classification with reasons and authority | ✅ audited |

## Phase 2 — Official Meta OAuth

| Requirement (spec §2) | Implementation | Status |
|---|---|---|
| Official Facebook Login (server-side code flow) | `api/src/lib/meta-oauth.ts`; `POST /integrations/meta/oauth/start`, `GET /public/meta/oauth/callback` | ✅ code · ⛔ needs a Meta app |
| Least-privilege permissions | see «Meta permissions» below — required, optional and Insights are separate lists; the login dialog asks for all three (`META_SCOPES`); only the required list blocks a connection | ✅ |
| Separate app credentials | `META_APP_SECRET` is its own setting; never borrowed from `META_APP_SECRETS` (webhook signing) | ✅ |
| State validation / CSRF, redirect URI validation | HMAC-signed state bound to the person, 10-minute expiry; **single-use**: nonce recorded hashed in `action_otps` (082, action `meta_oauth_state`) at start, consumed by one atomic `UPDATE … WHERE used_at IS NULL … RETURNING` at callback (no migration needed); one fixed `META_OAUTH_REDIRECT_URI`, https only | ✅ unit here · ✅ CI written (replay, concurrent, expired, forged, wrong person, revoked) |
| Permission checks | start/status: `leads.config`, never a marketing company; callback re-checks the person who started | ✅ CI |
| Token stored only on the server, sealed | long-lived token sealed in `integrations.access_token`; OAuth refuses to run without `SECRETS_KEY` | ✅ CI |
| No secrets in responses / errors | `safeMetaError` redacts tokens / secrets / codes; landing page has none | ✅ tested here + CI |
| Token lifecycle, reconnection, revoked permissions | token answers validated (`tokenFrom`); long-lived exchange; `debug_token` must show a valid USER token **of our app**; missing required permissions → token not kept, a working connection left as it was; reconnection upserts pages (no duplicates); `auth_type=rerequest`; status shows validity, expiry, `missingRequired` | ✅ CI written · ⛔ real check |
| No secrets in diagnostics | `metaFetch` (all Meta calls, incl. `graph()`) never logs and never surfaces the URL or a network error's cause | ✅ unit here |
| Connection status, missing permissions, last sync, errors | `GET /integrations/meta/oauth/status`; Flutter section in `leads_integrations.dart` | ✅ API (CI) · 🟡 Flutter not compiled here |
| Pages / ad accounts / campaigns / forms discovery | pages reuse the existing discovery (`connectPages`); campaigns via existing `/integrations/meta/campaigns` | 🟡 ad sets, ads, business-level asset selection → Phase 4 |
| Manual token kept for compatibility | unchanged, relabelled «ربط بتوكن (متقدم)» | ✅ |

## Phase 3 — Reliable synchronization

| Requirement (spec §3) | Implementation | Status |
|---|---|---|
| Webhook ingestion | existing, signed (fail-closed in production) | ✅ existing |
| Independent scheduler (no app open) | `POST /integrations/meta/sync/run` (X-Backup-Token or `leads.config`) + `.github/workflows/meta-sync.yml` | ✅ CI · ⛔ needs `BACKUP_TOKEN` repo secret |
| One run at a time, idempotent with the webhook | 5-minute claim on `integrations.meta_sync_at`; a run's budget is 18 s (+ one 8 s request) inside the function's 30 s `maxDuration`, so two scheduled runs cannot overlap (`lib/meta-sync-limits.ts`, checked against `vercel-build.mjs`). Manual / per-campaign syncs may overlap a run: each lead is taken under a transaction-scoped advisory lock and re-checked, so it is added once without a unique-index error | ✅ unit here · ✅ CI written |
| Workflow reliability | fails on: missing secret, 401/403, 5xx / timeout / network after 3 attempts (15 s, 45 s backoff), other statuses, non-JSON answers, a sync that ran with errors; a declined run (off / recent / not connected) is green with a notice; no secret printed | ✅ 10 scenarios run here against a fake API |
| Historical sync | existing: 90 days on first link, then from `meta_synced_at` − 1 h | ✅ existing |
| Per-source checkpoints, retry/backoff, dead-letter, counters (processed / added / duplicates / rejected) | — needs storage → migration proposal | ⬜ 🔒 schema approval |
| Admin retry / resync | existing «اسحب الليدز دلوقتي»; per-campaign resync on link | 🟡 |

## Phases A–K (continuation after V3, migration 092)

| Phase | Status | Where |
|---|---|---|
| A Meta lifecycle: deauthorize, data deletion (+ status URL), token forget, `meta_user_hash` | ✅ code + tests | `integrations.ts`, `meta-oauth.ts parseSignedRequest` |
| C Attribution set once at intake (page/form/campaign/ad set/ad/company), campaign ownership history, manual attribution once | ✅ | `meta_sync.ts takeMetaLead`, 092 triggers, `marketing.ts` |
| D Ads Insights daily snapshots, missing ≠ 0, rate-limit stop, time budget, checkpoint only when complete | ✅ code + tests (fake Graph) | `meta-insights.ts`, `marketing.ts syncInsights` |
| E Lead quality: structure + history (append-only), reason required for a rejection; permission `leads.quality` granted to the owner only | ✅ — **who else classifies is an owner decision** | 092, `marketing.ts` |
| F Automatic KPIs: 6 calculators, each **pending until the owner approves**; a manual entry (or a manual correction of an automatic one) is never overwritten | ✅ infrastructure; **no formula active** | `marketing.ts KPI_CALCULATORS / runAutoKpis` |
| G Unified dashboard API (`GET /marketing/overview`, `leads.read_all`) | ✅ | `marketing.ts` |
| H Flutter: لوحة التسويق, lead quality pill + dialog, KPI «تلقائي» badge, OAuth status | ✅ code; analyze/build in CI (`app-check.yml`) | `app/lib/jph/pages/leads/marketing_overview_page.dart`, `lead_page.dart`, `lib/pages/kpi_page.dart` |
| I Security | ✅ reviewed (see below) | |
| J Migration 092 (additive) + rollback | ✅ CI PG16 / PG18 | `db/proposed/092_*`, `db/migrations/092_*` |
| K Tests | ✅ `marketing.test.ts`, `meta-insights.test.ts` + earlier | |

### KPI definitions and automatic sources (none active; activation = owner approval via `POST /kpi/definitions/:id/calc/approve`)

| KPI key | Candidate calculator | Formula (exact, Cairo month) | Status |
|---|---|---|---|
| `calls` | `answered_calls` (or `lead_actions`) | count of the employee's lead actions with answered = true | needs owner choice + approval |
| `follow_ups` | `lead_actions` | count of the employee's manual lead actions | needs approval |
| `qualified_leads` | `qualified_leads` | distinct leads assigned to the employee that became `qualified` in the month | needs approval **and** a decision on who classifies |
| `meetings` | `meetings_set` | actions moving a lead to stage `meeting` | needs approval |
| `closed_deals` | `deals_won` | actions moving a lead to stage `done_deal` | needs approval |
| `viewings`, `offers` | none (no stage / record defines a viewing or an offer) | — | manual; needs a business definition |
| `sales_target` | none (target money vs. which sales table and which date is not defined) | — | manual |
| `attendance_commit`, `punctuality` | none yet (attendance metrics exist; the scoring rule — e.g. % of working days, grace — is not approved) | — | manual; needs the rule |
| `follow_up_quality`, `manager_rating` | none (judgement) | — | manual by design |

Weights, targets, periods and existing manual results are unchanged by this work.

### Security review (phase I)
- Public Meta callbacks (`/public/meta/deauthorize`, `/public/meta/data-deletion`) accept only a valid `signed_request` (HMAC-SHA256 with `META_APP_SECRET`, constant-time compare); a bad signature changes nothing; form bodies are accepted only under `/public/meta/`.
- The status URL reveals only a status for a random confirmation code; no user id is stored in clear (`meta_user_hash`).
- No token, secret or Graph URL in responses, logs or errors (`safeMetaError`); the dashboard returns no token fields (tested).
- Every new route checks its permission on the server (`leads.quality`, `leads.config`, `leads.read_all`, owner-only formula approval); partners refused.
- Fixed in this pass: a manual correction of an automatic KPI kept `source='auto'` and would have been overwritten by the next run.
- Data Deletion behaviour: see «Review corrections — P1 Data Deletion» below (the earlier status page overstated what was held; corrected).

### Meta configuration still required (exact)
In the Meta app (Settings → Basic / Facebook Login): Valid OAuth Redirect URI `https://<API host>/public/meta/oauth/callback`; **Deauthorize callback URL** `https://<API host>/public/meta/deauthorize`; **Data Deletion Request URL** `https://<API host>/public/meta/data-deletion`; Webhooks → Page → `leadgen` → `https://<API host>/public/hooks/meta`. Host env: `META_APP_ID`, `META_APP_SECRET`, `META_OAUTH_REDIRECT_URI`, `SECRETS_KEY`, optional `META_GRAPH_VERSION` (default **v25.0** since the review corrections; see below). Insights needs `ads_read` (Meta's Insights API states it as its permission); requested in the login dialog, not required (see «ads_read correction» below). GitHub secret `BACKUP_TOKEN` for `meta-sync.yml` (only runs on `main`). Nothing was set by this work and no real Meta call was made.

### Vercel
- Both `vercel.json` (root) and `api/vercel.json` (the project `value-attendance` builds from `api/`) carry `"feat/marketing-intelligence": false`; commits after 38b7037 got **0** Vercel statuses (checked on 132be3e).
- Migrations at build time run only from `api/scripts/migrate-if-production.mjs` (Vercel production build of `main` of the real project); a preview never migrates. A second path exists: `.github/workflows/db-migrate.yml` (manual, `main` only, environment `production-db`). Which one applies 092 is an open owner decision — see «Pre-release readiness». `meta-sync.yml` knocks only on `refs/heads/main`.
- **Cleanup to do by hand:** preview deployment `2jCzuWMHPFB33nCUo2TeAKRVpLgv` (project `value-attendance`, commit 06b5080) was created by mistake before the `api/vercel.json` fix. It is **not deleted** (no Vercel access from here); its current existence is **unverified** (GitHub still shows Vercel's «Deployment has completed» status for it, 2026-11-25 21:16 UTC). The same commit's status on the retired project `value-attendance-api` (`589n7wPBxs6E54Wsb9qemXkY3fwC`) reads «Canceled by Ignored Build Step» — not deployed. Delete it in Vercel → project `value-attendance` → Deployments → that id → ⋯ → Delete; and keep Deployment Protection on for previews.

### Release process (not done — waits for an independent review)
1. Review `feat/marketing-intelligence` (diff vs `main`), CI green (API PG16/18 + least-privilege, App analyze/build check).
2. Take a Neon branch/snapshot of production `main` before merge.
3. Decide the migration path first (see «Pre-release readiness» → blockers), then merge into `main`. If the Vercel build's database credential may create tables, its production build of `main` runs `migrate-if-production.mjs` → applies `092_marketing_intelligence.sql` (additive) before the new code goes live; if it may not, that build fails and the previous deployment stays live — then 092 must be applied with `db-migrate.yml` (approved) first. Rollback file: `db/proposed/092_rollback.sql` (drops only what 092 creates).
4. Set the Meta env vars and app callbacks above; connect via «اربط بحساب فيسبوك».
5. App: **a merge that touches `app/**` starts `app.yml` automatically** (push to `main`), which builds and publishes the APK / web as a GitHub release and the live update — the merge is itself the app release. Only after the owner's explicit authorisation; not run by this work.
6. After release, the owner decides who gets `leads.quality` and approves KPI formulas one by one.

## Meta permissions (`api/src/lib/meta-oauth.ts`)

Verified against the code on 2026-11-26 (commit 6a83b42): the login dialog's `scope` is `META_SCOPES` = required + `business_management` + `ads_read`, in that order; a grant missing any **required** permission is not kept; the two optional ones never block.

| List | Permissions | Used for | Asked by the current OAuth |
|---|---|---|---|
| **Required** (`META_SCOPES_REQUIRED`) — a grant without any of them is not kept | `pages_show_list`, `pages_read_engagement` | list pages, read their lead forms | yes |
| | `pages_manage_metadata` | subscribe a page to the `leadgen` webhook | yes |
| | `pages_manage_ads` | Meta lists it for retrieving all lead and ad-level data | yes |
| | `leads_retrieval` | read leads (bulk + webhook) | yes |
| | `ads_management` | a lead's `campaign_id` / `ad_id` (attribution); Meta documents no read-only alternative | yes |
| **Optional** (`META_SCOPES_OPTIONAL`) — not blocking | `business_management` | pages owned through a business portfolio only | yes |
| **Optional — Insights** (`META_SCOPES_INSIGHTS`) — not blocking | `ads_read` | `GET /{campaign}/insights`; declined → Insights off and reported as unavailable, Lead Ads unaffected | yes |

## External configuration still required (nothing set by this work)

1. **Meta app** (developers.facebook.com): product «Facebook Login» with the Valid OAuth Redirect URI `https://<API host>/public/meta/oauth/callback`; Webhooks product, object Page, field `leadgen`, callback `https://<API host>/public/hooks/meta` with the existing verify token.
2. **App Review / Advanced Access** for the permissions the current OAuth asks for — required: `pages_show_list`, `pages_read_engagement`, `pages_manage_metadata`, `pages_manage_ads`, `leads_retrieval`, `ads_management`; optional: `business_management` (only app roles can grant them before review); Business Verification as Meta requires. `ads_read` (Insights) must be in the review too for Insights to work for people outside the app's roles.
3. **API host environment** (Vercel): `META_APP_ID`, `META_APP_SECRET`, `META_OAUTH_REDIRECT_URI`, existing `META_APP_SECRETS` and `SECRETS_KEY`; optional `META_GRAPH_VERSION`.
4. **GitHub repository secret** `BACKUP_TOKEN` (same value as on the host) for `meta-sync.yml`.

## Changes on `feat/marketing-intelligence`

| File | Change |
|---|---|
| `api/src/lib/meta-oauth.ts` | new: OAuth configuration, scopes, signed state, URLs, permission check, error redaction, landing page |
| `api/src/modules/integrations.ts` | OAuth start / callback / status routes; scheduler route; page discovery shared (`connectPages`); one Graph version |
| `api/src/modules/meta_sync.ts` | `runScheduledMetaSync`; one Graph version |
| `app/lib/jph/pages/leads/leads_integrations.dart` | «اربط بحساب فيسبوك» + connection status section |
| `.github/workflows/meta-sync.yml` | new scheduled knock |
| `api/test/meta-oauth.test.ts` | new unit tests (ran here) |
| `api/src/lib/meta-sync-limits.ts` | new: the scheduled run's time limits |
| `api/src/auth/action_otp.ts` | the e-mailed code rate limit does not count OAuth state nonces |
| `api/test/meta-sync-limits.test.ts` | new unit test (ran here) |
| `api/test/meta-oauth-routes.test.ts`, `api/test/meta-sync-run.test.ts` | Postgres tests (CI): 11 + 4 |

### Test record (2026-11-25, security corrections)

| Kind | Result |
|---|---|
| Executed here: every DB-free test file (8 files, incl. 3 new) | **49 passed, 0 failed** |
| Workflow script against a fake API (10 scenarios) | all exit codes as specified; secret never printed |
| Typecheck (strict, whole API, Node types) | 0 errors in project code; 2 = `nodemailer` package absent here |
| Written, not executed (need `pg`; package installs blocked here) | `meta-oauth-routes.test.ts` (11), `meta-sync-run.test.ts` (4) — run in `api-ci.yml` |
| Flutter | not compiled / analysed (no Flutter SDK here) |

No migration was added at that stage (migration 092 came later, in phases A–K). No production data, schema, environment or deployment was changed.

### Final correction pass (2026-11-25)

| Finding | Correction |
|---|---|
| `tokenIsOurs` accepted a missing type | `debug_token.data.type` must be exactly `USER` (missing / PAGE / APP / SYSTEM_USER refused) |
| Deadline checked only between page requests | `Budget` + `eachWithin` (`lib/meta-sync-limits.ts`): checked before every Meta request and every lead; no new database work after it; per-lead transaction + advisory lock unchanged |
| Checkpoint could advance after a cut-short pass | `syncMeta` returns `complete`; the checkpoint moves only after a complete pass (budget, the 20-page cap, or an unreadable page's forms make it incomplete) |
| Permissions list | required / optional / future separated at that stage (ads_read was then not requested; it is now — see «ads_read correction»); `pages_manage_ads` in the App Review list |
| Flutter status | required missing (blocking, «إعادة ربط») vs optional missing (`business_management`, not blocking) — API status returns `missingRequired` and `missingOptional` |
| Workflow branch guard | the knock job runs only when `github.ref == refs/heads/main`; a dispatch from another branch only prints a notice. Endpoint and secrets unchanged |

| Kind | Result |
|---|---|
| Executed here: every DB-free test file (8 files) | **52 passed, 0 failed** |
| Workflow knock script against a fake API (9 scenarios) | exit codes as specified; secret never printed |
| Typecheck (strict, whole API) | 0 errors in project code; 2 = `nodemailer` absent here |
| Written, not executed (need `pg`) | `meta-oauth-routes.test.ts` (12), `meta-sync-run.test.ts` (5) — CI |
| Unavailable | Flutter analyse/compile (no SDK); the workflow `if:` branch guard (needs a GitHub Actions run) |

### Real CI execution (2026-11-25, branch `feat/marketing-intelligence` @ 953ec98, run 45703878259)

GitHub Actions `API tests` — a real PostgreSQL service (16 and 18), every migration applied to a fresh database, the whole
API suite (not mocks of the database; Meta's HTTP endpoints are faked inside the tests):

| Job | typecheck | `npm test` | least-privilege runtime role |
|---|---|---|---|
| Postgres 16 | ✅ | 592 passed, 0 failed, 2 skipped (role-only tests) | 593 passed, 0 failed |
| Postgres 18 | ✅ | 592 passed, 0 failed, 2 skipped | 593 passed, 0 failed |

Defects the real run found and fixed: the OAuth callback set `integrations.last_error = NULL` (column is NOT NULL, 062 —
every successful connection would have failed); an unconfigured callback answered 503 (no read route may answer 5xx → 404);
the callback was missing from `security.test.ts`'s public-route list; test setup (the accountant needs the administrative
officer position for `leads.config`; `audit_log` time column is `at`).

Migrations: **none needed or applied** (single-use state uses `action_otps`, 082). Live database checked read-only:
090's columns / constraint / index present, 091's `file_objects` present — applied out of numeric order, independent, no gap.

Deployment control: the branch is listed in `deploymentEnabled: false` in BOTH `vercel.json` and `api/vercel.json`
(the API project builds from `api/`). Before `api/vercel.json` was updated, commit `06b5080` produced one Vercel PREVIEW
deployment on project `value-attendance` (no migration: previews never migrate).

### Real CI execution (2026-11-26, phases A–K)
- API tests, run 45716091763 @ 3350d3d: PostgreSQL 16 — 611 pass / 0 fail / 2 skipped, least-privilege runtime role 612 / 612; PostgreSQL 18 — same. Migration 092 applied on fresh databases in order.
- App check, run 45715657993 @ 132be3e (last commit touching `app/`): `flutter analyze` 0 errors (Flutter 3.38.10), Android release build check with a throwaway key, web build check — success; nothing published.
- Vercel: 0 deployment statuses on 132be3e and 3350d3d.

## Review corrections (2026-11-26, independent review of `feat/marketing-intelligence`)

### P1 — lead sync errors and the checkpoint (`api/src/modules/meta_sync.ts`)
- Ingestion policy: a lead Meta sent **without a usable phone number** is a permanent rejection (`MetaLeadRejected`): it is reported in `rejected` (lead id only), adds nothing, and the pass stays complete — re-reading it gives the same answer.
- Every other failure on a lead (database error, a linked campaign without a project, anything unexpected) is a processing failure: `complete = false`, the error is in `errors`, and `lead_campaigns.meta_synced_at` does not move, so the next run reads the same window again. Idempotency (unique `meta_lead_id`) and the per-lead advisory lock are unchanged.
- `meta-sync.yml`: errors fail the run (red); rejected leads give a warning; an incomplete pass without errors (time budget) is a notice. Fixed: the incomplete check used `jq '.complete // true'`, which reads `false` as `true`.

### P1 — Data Deletion (`api/src/modules/meta_deletion.ts`, 092 `meta_data_deletion_requests`)
What this app holds from Facebook about the person in the signed request (an app-scoped user id):
| Data | Where | On a matching request |
|---|---|---|
| user access token of the person who connected the office (Facebook Login) | `integrations.access_token` | deleted |
| SHA-256 hash of that person's app-scoped id | `integrations.meta_user_hash` | deleted |
| page access tokens obtained through that token, with page ids / names | `meta_pages` | deleted (all rows) |
| leads submitted through the company's Lead Ads forms (name, phone, answers, Meta campaign / form / ad ids) | `leads` | **not deleted**: stored as the company's lead records **without any Facebook user id**, so a request carrying an app-scoped id cannot identify them |

- Every verified request is recorded first (`pending`), then processed in one transaction; the result is `completed` (with what was removed) or `no_data_found`. A failure leaves it `pending`; the scheduler (`POST /integrations/meta/sync/run`) retries pending requests first. The hash is kept only while pending.
- The status page states exactly what was done, says plainly that Lead Ads lead records are not covered by the request and that the person can ask the company directly. It never claims a deletion that did not happen, and no longer claims that nothing else is stored.
- Unsigned / wrongly signed requests are refused (401) and not recorded. Not verified: whether this matches the published privacy policy, and whether any law requires more — **owner / legal decision**; no legal exception is claimed.

### P2 — Ads Insights completeness (`api/src/lib/meta-insights.ts readInsightsPage / insightRowProblem`)
A response whose `data` is not a list, a row that is not an object, belongs to another campaign, is not one day, has a present-but-invalid number / currency / actions list, or a `next` link without a cursor makes the pass incomplete with an error; valid days of the page are still stored (idempotent); the checkpoint does not move. Absent metrics stay NULL (not a problem).

### P2 — Insights claim recovery (`runInsightsClaimed`)
A complete pass and a rate-limited pass keep the 60-minute claim; any other incomplete pass, an error or an exception gives the claim back so the next knock after **5 minutes** runs (a run lives ≤ 30 s, so no overlap). Only our own claim is given back. The checkpoint is only moved inside a complete pass.

### P2 — Lead quality history (092 trigger `lead_quality_events_immutable`)
BEFORE UPDATE **and DELETE**: any direct change or deletion raises. Allowed only what the foreign keys do: ON DELETE CASCADE when the lead no longer exists (a duplicate merged away), ON DELETE SET NULL of `by_id` when that employee no longer exists, ON UPDATE CASCADE of a renamed id. TRUNCATE (owner data reset / ops scripts) is not a row operation and stays possible.

### P2 — Graph API version
Default `v25.0` (was v21.0). Reviewed against the public changelogs v22.0–v26.0 for every endpoint used: OAuth dialog / code exchange / `fb_exchange_token`, `debug_token`, `me/accounts`, `me/businesses`, `{page}/subscribed_apps`, `{page}/leadgen_forms`, `{form|ad}/leads` with `filtering`, `{campaign}/ads`, `{campaign}/insights` with `time_increment=1`. No change listed for them (v24.0 deprecates creating Messenger lead ads, not used; v26.0 removes `pretty` / `date_format` / `debug` / ETag, not used). v26.0 is also expected to work (set `META_GRAPH_VERSION=v26.0`); its full changelog page could not be retrieved here, which is why v25.0 is the default. **Remaining uncertainty:** no call was made to Meta with this version (no credentials); the first real connection should be checked end to end.

### P2 — Automatic KPI execution
There was no recurring trigger (only the manual `POST /kpi/auto/run`). Added `POST /kpi/auto/scheduled` (scheduler token or `kpi.config`) → `runScheduledKpis`: the current Cairo month, plus the previous month during its first 3 days. Only owner-approved calculators run; manual and completed results are never touched; idempotent. `meta-sync.yml` knocks it hourly (the :07 run), nightly and on dispatch — on `main` only. Limitation (unchanged behaviour): result rows of a month exist once that employee's KPI page for the month is opened (snapshot of weights / targets); the run fills existing rows only.


### Real CI execution (review corrections, 2026-11-26)
- API tests, run 45720109854 @ 8869c83: PostgreSQL 16 — 622 pass / 0 fail / 2 skipped, least-privilege runtime role 623 / 623; PostgreSQL 18 — same. Migration 092 (amended) applied on fresh databases.
- No `app/` change in this pass, so the Flutter check was not re-run (last: run 45715657993 @ 132be3e, success).
- `meta-sync.yml` script exercised locally with a stubbed `curl` (no network): errors → exit 1; rejected leads → warning, exit 0; incomplete → notice; KPI knock only at :07, nightly and on dispatch.
- Vercel: 0 deployment statuses on 8869c83.

### ads_read correction (2026-11-26, second review)
- Finding: Insights was implemented and scheduled, but `ads_read` (the permission Meta's Insights API states) was not requested; the earlier note that `ads_management` was enough was not verified and is withdrawn.
- `ads_read` is now in `META_SCOPES` as its own group `META_SCOPES_INSIGHTS`, **not** in `META_SCOPES_REQUIRED` (unchanged: `pages_show_list`, `pages_read_engagement`, `pages_manage_metadata`, `pages_manage_ads`, `leads_retrieval`, `ads_management`).
- The permissions actually granted are stored with the token (`integrations.meta_scopes`, 092) by the OAuth callback and refreshed by the status check (debug_token); cleared with the token (deauthorize / data deletion); NULL for a token pasted by hand — Insights then reads `me/permissions` once.
- `syncInsights` never calls Meta without `ads_read` → `{ ran: false, reason: 'insights_permission_missing' }` (workflow warning); a permission error from Meta during Insights (code 10 / 200–299) reports «Insights unavailable», drops `ads_read` from the stored list, keeps the checkpoint. Lead sync, webhooks and reconnection do not read `meta_scopes`.
- Reported: callback page, `GET /integrations/meta/oauth/status` → `insights { available, reason }`, `GET /marketing/overview` → `integration.insightsAvailable` (true / false / null = not known), Flutter integration settings and the marketing dashboard.


## Pre-release readiness (2026-11-26) — documentation and verification only

Branch head checked: `feat/marketing-intelligence` @ `6a83b427cd04` (last code commit). `main` @ `98f9f69c940b`, `pending-build` @ `3d53986600680d` — unchanged by this work. No merge, deployment, migration, build or setting change was made.

### 1. CI evidence (GitHub Actions, completed runs on 6a83b42)
| Check | Status | Evidence |
|---|---|---|
| API tests — PostgreSQL 16 (`npm test`) | ✅ 629 pass / 0 fail / 2 skipped (role-only tests) | [run 45734761741](https://github.com/peterbakheetuae-svg/value-attendance/actions/runs/45734761741) · [job PG16](https://github.com/peterbakheetuae-svg/value-attendance/actions/runs/45734761741/job/139625196376) |
| API tests — PostgreSQL 18 | ✅ 629 / 0 / 2 | [job PG18](https://github.com/peterbakheetuae-svg/value-attendance/actions/runs/45734761741/job/139625195980) |
| Least-privilege runtime role (both PG versions) | ✅ 630 / 630 | same jobs, step «npm test (least-privilege runtime role)» |
| Production dependency audit (`npm audit --omit=dev --audit-level=high`) | ✅ 0 vulnerabilities | PG18 job only — by design (`if: matrix.pg == '18'`); skipped on PG16 |
| TypeScript typecheck (`npm run typecheck`) | ✅ | both API jobs |
| Flutter analyze (errors fail) | ✅ | [run 45734761776](https://github.com/peterbakheetuae-svg/value-attendance/actions/runs/45734761776) · [job](https://github.com/peterbakheetuae-svg/value-attendance/actions/runs/45734761776/job/139625196003) |
| Android build check (throwaway key, nothing published) | ✅ | same job |
| Web build check | ✅ | same job (web build kept 1 day as an Actions artifact) |
| Vercel on 6a83b42 | 0 deployment statuses | GitHub commit statuses |

Distinct from these: the agent's local runs (DB-free tests 66/66, typecheck without `nodemailer`, a stubbed-`curl` run of the `meta-sync.yml` script) are supporting evidence only. A documentation-only commit after 6a83b42 does not start either workflow (their `paths` are `api/**` / `db/**` and `app/**`); the code they test is unchanged.

### 2. Migration ordering — code inspection (verified)
- `api/src/migrate-core.ts`: lists `db/migrations/NNN_*.sql`, sorts by **filename**, skips every name already in `schema_migrations`, and applies **every other one**, each in its own transaction under one advisory lock (a concurrent runner re-checks and skips). There is **no ordering or gap check**: a lower-numbered file added later (090 after 091) is applied on the next run, after the higher one; a missing lower-numbered file is simply not applied, and nothing reports it. A file that fails rolls back alone and stops the run (the build fails).
- (Superseded: the production order 001–091 → 092 is now executed in CI by `data-reset-092-compat.test.ts`, see «Release candidate».) Correctness therefore depends on migrations being independent of one another. Objects each file creates or alters (read on 2026-11-26): 090 — `brokerage_deals` (column, index, trigger); 091 — `file_objects`, `file_purge_log`, `schema_migration_rollbacks` and file-reference triggers on 16 tables incl. `employees` and `lead_attachments`; 092 — `leads`, `integrations`, `kpi_definitions`, `kpi_results` and four new tables. No object is created or altered by two of them; 090 and 092 only *reference* `employees`, which 091 alters (triggers), and 092 does not touch `lead_attachments`.
- **What CI actually executed** (`api/test/helpers.ts`): the test template applies every migration except the release files (066, 083–089, 090, 091) — so 092 runs on a schema **without** 066 / 083–091; `release-migrations.test.ts` then applies those release files on top (after 092) and checks each is applied exactly once. The production order — everything through 091 already present, then 092 — has **not been executed** anywhere. Independence makes it very likely equivalent, but it is unverified. Recommended before applying 092: run it against a Neon branch copied from production (owner-authorised), or add a CI case that applies 092 after the full release chain.
- Two ways the production database is migrated: (a) `migrate-if-production.mjs` in the Vercel build command (both `vercel.json` files) — only for `VERCEL_ENV=production`, `VERCEL_GIT_COMMIT_REF=main` and the real project (deployment guard: the retired project and unidentified projects never migrate); (b) `db-migrate.yml` — manual dispatch, `main` only, GitHub environment `production-db`. **Contradiction in the repository:** `db-migrate.yml` says migrations never run at Vercel build time, while the Vercel build command does run the guard script. Which path is live depends on the database credential in Vercel's environment, which cannot be read from here.

### 3. Migration history in production — superseded: VERIFIED on 2026-11-26 (see «Release candidate» below)
- A read-only `SELECT` on `schema_migrations` through the session's Neon connection was refused by the session's permission control (2026-11-26); it was not retried by other means. The order 091 → 090 is therefore **only as recorded on 2026-11-25**, not re-verified.
- Indirect evidence (GitHub, read-only): `db-migrate.yml` has **0 runs**; 091 reached `main` at 09:04:19 UTC (bdfc2a8) and 090 at 14:39:10 UTC (5a47d2a), and each push got a successful Vercel production deployment — consistent with the recorded apply times and with the Vercel build migrating with a credential that can create tables. This is an inference, not a verification.
- Not assumed: that the recorded order is complete, that nothing else was applied by hand, or that the order is harmless beyond the shared-object check above.

### 4. Release configuration (inspected, unchanged)
- `vercel.json` and `api/vercel.json`: `git.deploymentEnabled["feat/marketing-intelligence"] = false` in both; build command `migrate-if-production.mjs && vercel-build.mjs`.
- `migrate-if-production.mjs`: migrates only on a Vercel production build of `main` of the identified real project (or `VA_ALLOW_MIGRATE=production` outside Vercel/Netlify). A feature-branch build — even if one ran — is a preview (`VERCEL_GIT_COMMIT_REF` ≠ `main`) and does not migrate.
- `deployment-guard.mjs`: the retired project `value-attendance-api` returns 410, never migrates; an unidentified production project returns 503, never migrates. Note: the retired project **still builds every push to `main`** (its statuses appear on main commits); its removal remains an owner action.
- `meta-sync.yml`: scheduled triggers run only from the default branch; the `knock` job also requires `github.ref == refs/heads/main`; a dispatch from the feature branch only prints a notice.
- `app.yml`: starts on a push to `main` touching `app/**` and publishes a release + live update — so merging this branch (it changes `app/`) **is** an app release.
- Conclusion: the feature branch cannot migrate or deploy production through these paths; a merge into `main` would do both (API deploy + possible migration + app release).

### 5. Release blockers and owner-only actions (nothing done here; no secret values recorded)
1. **Decide the migration path for 092** (Vercel build vs `db-migrate.yml` with approval) and make the repository's two statements agree; confirm which credential Vercel's `value-attendance` project uses.
2. **Neon**: take a snapshot / branch of production `main` immediately before applying 092; re-check `schema_migrations` read-only (091, 090 present; 092 absent). Optionally apply 092 first to a branch copied from production, to execute the real order (091, 090 present → 092), which CI has not run.
3. **Meta app**: Facebook Login redirect `https://<API host>/public/meta/oauth/callback`; Deauthorize `…/public/meta/deauthorize`; Data Deletion `…/public/meta/data-deletion`; Webhooks Page `leadgen` → `…/public/hooks/meta` with the verify token.
4. **Meta permissions / App Review (Advanced Access)**: required `pages_show_list`, `pages_read_engagement`, `pages_manage_metadata`, `pages_manage_ads`, `leads_retrieval`, `ads_management`; optional `business_management`, `ads_read` (Insights); Business Verification as Meta requires.
5. **Vercel environment** (`value-attendance`): `META_APP_ID`, `META_APP_SECRET`, `META_OAUTH_REDIRECT_URI`, `SECRETS_KEY`, existing `META_APP_SECRETS`, `BACKUP_TOKEN`; optional `META_GRAPH_VERSION`.
6. **GitHub secret** `BACKUP_TOKEN` (same value as the host) for `meta-sync.yml`.
7. **Vercel cleanup**: delete preview `2jCzuWMHPFB33nCUo2TeAKRVpLgv` (existence unverified); remove or disconnect the retired project `value-attendance-api`.
8. **Privacy / legal**: confirm the Data Deletion scope (token + pages deleted; Lead Ads lead records retained) against the published privacy policy.
9. **Business decisions** after release: who holds `leads.quality`; approval of each KPI formula.
10. **Release authorisation**: the merge publishes the app (`app.yml`); only with the owner's explicit approval.

### Verdict
**READY FOR FINAL OWNER REVIEW** — code complete on the branch and every listed check green on GitHub Actions. **Not ready for release** until blockers 1–8 are settled by the owner; production migration history remains unverified in this session.

## Release candidate (2026-11-26) — `feat/marketing-intelligence` after merging `main`

**Production (read-only, 2026-11-26):** `schema_migrations` holds exactly the 83 files of `db/migrations` on `main` (001–091; 091 applied 09:04 UTC, 090 14:39 UTC on 2026-11-25); **092 absent**. Vercel `value-attendance` production = `main` `c3635de` (the data-reset compatibility fix), `/readyz` ok with 83 migrations; no migration applied by that deploy. Neon: no snapshot, no snapshot schedule; point-in-time restore window 6 h; branch `restore-before-091-2026-11-25` predates 090/091 (not a valid recovery point now).

**Merge of `main` into this branch:** the `api/src/modules/data-reset.ts` conflict is resolved with main's unchanged `WIPE`; `lead_quality_events` and `lead_campaign_owners` (foreign keys into `leads` / `lead_campaigns` / `marketing_companies`) join the same `TRUNCATE` only when present (`WIPE_IF_PRESENT`); `meta_insights_daily` (no foreign key) is emptied as Marketing Intelligence activity when present (`WIPE_ACTIVITY_IF_PRESENT`); no `CASCADE`.

**Tests added:** `data-reset-092-compat.test.ts` builds its database from `db/migrations` without 092 — production's state — via the new optional `harness(…, { migrationsExcept })` (the shared template is unchanged), checks the reset there, then the real `migrate()` applies exactly `092` (and nothing on a second run), and the reset is checked again. This also executes the production order (001–091 → 092) for the first time.

**Scheduled jobs (not active until merged into `main`):** `meta-sync.yml` knocks `/integrations/meta/sync/run`, `/integrations/meta/insights/run` and (hourly / nightly) `/kpi/auto/scheduled` on `main` only. Without the GitHub secret `BACKUP_TOKEN` the job fails visibly (red) and calls nothing; without the API host's `BACKUP_TOKEN` (≥ 24 chars) the endpoints answer 401 and change nothing; without a Meta connection each pass answers `ran: false` (`off` / `not_connected` / `no_linked_campaigns`); with no approved KPI formula nothing is written.

**Release blockers (owner):**
1. A recorded recovery point before 092 (Neon branch from production `main`), or an explicit acceptance of the 6-hour restore window.
2. The migration path for 092: today the Vercel production build of `main` applies it automatically when this branch is merged (`migrate-if-production.mjs` with `DATABASE_URL`; no `MIGRATION_DATABASE_URL` exists) — accept that, or isolate migrations first (Release Safety Steps 2–7, not implemented).
3. The merge also publishes the web app automatically (`app.yml` → Hostinger) at the same time as the API build; the APK only with `[apk]` in the merge commit's first line.
4. GitHub secret `BACKUP_TOKEN` (same value as Vercel's) before the schedule becomes active on `main` — otherwise red runs every 15 minutes in working hours.
5. Meta app: callback URLs (OAuth redirect, deauthorize, data deletion, webhook), App Review / Advanced Access for the required scopes and `business_management` / `ads_read`, Vercel `META_APP_ID`, `META_APP_SECRET`, `META_OAUTH_REDIRECT_URI` (none set today).
6. Owner decisions: who holds `leads.quality`; approval of each KPI formula; Data Deletion scope vs the privacy policy.
7. Cleanup: previews `2jCzuWMHPFB33nCUo2TeAKRVpLgv` and `47EV1768c1ZocccHjBRqeeAZHKhG` (login-protected, no database credential); the retired project `value-attendance-api` is still connected to Git and holds e-mail / push credentials.

