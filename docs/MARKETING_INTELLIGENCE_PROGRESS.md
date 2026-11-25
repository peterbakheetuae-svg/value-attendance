# Marketing Intelligence & Employee Performance — implementation progress

Specification: «VALUNIVO — Complete Remaining Marketing Intelligence & Employee Performance Implementation» (owner, 2026-11-25).
This file is the persistent checklist: each session continues from the first item that is not ✅.

## Baseline (verified 2026-11-25)

| Item | Verified state |
|---|---|
| `main` | `98f9f69` — PR #17 (revert of the Flutter dependency bumps). No later commits. |
| Working branch | `feat/marketing-intelligence`, from `98f9f69`. |
| Production database | Neon `valunivo-attendance-eu`, branch `main` (read-only inspection). `schema_migrations`: 091 applied 2026-11-25 09:04 UTC, **090 applied after it** (14:39 UTC) — both present; the order is out of sequence (owner to confirm the runner tolerates it). A branch `restore-before-091-2026-11-25` exists. |
| Production data relevant here | 0 `lead_campaigns`, 0 `leads`, 0 `meta_pages`, 1 `integrations` row for Meta, 2 `marketing_companies`, 12 `kpi_definitions`, 0 active `kpi_sets`, 0 `kpi_results`. No plain Meta token (`EAA…`) stored. |
| Graph API | Code pinned to **v21.0**; Meta removes v21.0 on **2027-01-21**; latest is v26.0 (2026-07-29). Now configurable (`META_GRAPH_VERSION`); upgrade only after a real-credential check. |

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
| Least-privilege permissions | see «Meta permissions» below — required, optional and future are separate lists; the login dialog asks for required + optional only | ✅ |
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

## Phases 4–10

| Phase | Status | Next step |
|---|---|---|
| 4 Attribution: ad account / ad set / ad, ownership history, office-direct campaigns, drill-down | ⬜ 🔒 | additive migration proposal (ERD, rollback) for owner approval |
| 5 Ads Insights: daily snapshots, spend, reach, CPL…, missing ≠ 0 | ⬜ 🔒 | snapshot table proposal; decide and verify the read permission (`ads_read`, future list) and its App Review then |
| 6 Lead quality classification (authority pending) | ⬜ 🔒 | proposal with a configurable permission and a pending state; **no authority assigned** |
| 7 Automatic KPIs (attendance, sales, manager) | ⬜ 🔒 | source mapping per KPI key; `kpi_results` needs source / calculated_at columns; **no new weights** |
| 8 Unified dashboard | ⬜ | after 4–7 |
| 9 Security / authorization validation | 🟡 | tests per phase; full review at the end |
| 10 Documentation / acceptance | 🟡 | this file |

## Meta permissions (`api/src/lib/meta-oauth.ts`)

| List | Permissions | Used for | Asked by the current OAuth |
|---|---|---|---|
| **Required** (`META_SCOPES_REQUIRED`) — a grant without any of them is not kept | `pages_show_list`, `pages_read_engagement` | list pages, read their lead forms | yes |
| | `pages_manage_metadata` | subscribe a page to the `leadgen` webhook | yes |
| | `pages_manage_ads` | Meta lists it for retrieving all lead and ad-level data | yes |
| | `leads_retrieval` | read leads (bulk + webhook) | yes |
| | `ads_management` | a lead's `campaign_id` / `ad_id` (attribution); Meta documents no read-only alternative | yes |
| **Optional** (`META_SCOPES_OPTIONAL`) — not blocking | `business_management` | pages owned through a business portfolio only | yes |
| **Future** (`META_SCOPES_LATER_INSIGHTS`) — not requested | `ads_read` | Ads Insights (Phase 5), when approved | **no** |

## External configuration still required (nothing set by this work)

1. **Meta app** (developers.facebook.com): product «Facebook Login» with the Valid OAuth Redirect URI `https://<API host>/public/meta/oauth/callback`; Webhooks product, object Page, field `leadgen`, callback `https://<API host>/public/hooks/meta` with the existing verify token.
2. **App Review / Advanced Access** for the permissions the current OAuth asks for — required: `pages_show_list`, `pages_read_engagement`, `pages_manage_metadata`, `pages_manage_ads`, `leads_retrieval`, `ads_management`; optional: `business_management` (only app roles can grant them before review); Business Verification as Meta requires. `ads_read` is **not** part of this review — it belongs to the later Ads Insights phase.
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

No migration was added. No production data, schema, environment or deployment was changed.

### Final correction pass (2026-11-25)

| Finding | Correction |
|---|---|
| `tokenIsOurs` accepted a missing type | `debug_token.data.type` must be exactly `USER` (missing / PAGE / APP / SYSTEM_USER refused) |
| Deadline checked only between page requests | `Budget` + `eachWithin` (`lib/meta-sync-limits.ts`): checked before every Meta request and every lead; no new database work after it; per-lead transaction + advisory lock unchanged |
| Checkpoint could advance after a cut-short pass | `syncMeta` returns `complete`; the checkpoint moves only after a complete pass (budget, the 20-page cap, or an unreadable page's forms make it incomplete) |
| Permissions list | required / optional / future separated (table above); `pages_manage_ads` in the App Review list; `ads_read` only in the future list |
| Flutter status | required missing (blocking, «إعادة ربط») vs optional missing (`business_management`, not blocking) — API status returns `missingRequired` and `missingOptional` |
| Workflow branch guard | the knock job runs only when `github.ref == refs/heads/main`; a dispatch from another branch only prints a notice. Endpoint and secrets unchanged |

| Kind | Result |
|---|---|
| Executed here: every DB-free test file (8 files) | **52 passed, 0 failed** |
| Workflow knock script against a fake API (9 scenarios) | exit codes as specified; secret never printed |
| Typecheck (strict, whole API) | 0 errors in project code; 2 = `nodemailer` absent here |
| Written, not executed (need `pg`) | `meta-oauth-routes.test.ts` (12), `meta-sync-run.test.ts` (5) — CI |
| Unavailable | Flutter analyse/compile (no SDK); the workflow `if:` branch guard (needs a GitHub Actions run) |
