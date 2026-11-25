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
| Minimum permissions | `META_SCOPES` (documented per Meta's Lead Ads guides) | ✅ |
| State validation / CSRF, redirect URI validation | HMAC-signed state bound to the person, 10-minute expiry; one fixed `META_OAUTH_REDIRECT_URI`, https only | ✅ tested here |
| Permission checks | start/status: `leads.config`, never a marketing company; callback re-checks the person who started | ✅ CI |
| Token stored only on the server, sealed | long-lived token sealed in `integrations.access_token`; OAuth refuses to run without `SECRETS_KEY` | ✅ CI |
| No secrets in responses / errors | `safeMetaError` redacts tokens / secrets / codes; landing page has none | ✅ tested here + CI |
| Token lifecycle, reconnection, revoked permissions | long-lived exchange; `auth_type=rerequest`; status via `debug_token` (validity, expiry, scopes); «إعادة الربط» | ✅ code · ⛔ real check |
| Connection status, missing permissions, last sync, errors | `GET /integrations/meta/oauth/status`; Flutter section in `leads_integrations.dart` | ✅ API (CI) · 🟡 Flutter not compiled here |
| Pages / ad accounts / campaigns / forms discovery | pages reuse the existing discovery (`connectPages`); campaigns via existing `/integrations/meta/campaigns` | 🟡 ad sets, ads, business-level asset selection → Phase 4 |
| Manual token kept for compatibility | unchanged, relabelled «ربط بتوكن (متقدم)» | ✅ |

## Phase 3 — Reliable synchronization

| Requirement (spec §3) | Implementation | Status |
|---|---|---|
| Webhook ingestion | existing, signed (fail-closed in production) | ✅ existing |
| Independent scheduler (no app open) | `POST /integrations/meta/sync/run` (X-Backup-Token or `leads.config`) + `.github/workflows/meta-sync.yml` | ✅ CI · ⛔ needs `BACKUP_TOKEN` repo secret |
| One run at a time, idempotent with the webhook | claims `integrations.meta_sync_at`; `leads.meta_lead_id` unique | ✅ CI |
| Historical sync | existing: 90 days on first link, then from `meta_synced_at` − 1 h | ✅ existing |
| Per-source checkpoints, retry/backoff, dead-letter, counters (processed / added / duplicates / rejected) | — needs storage → migration proposal | ⬜ 🔒 schema approval |
| Admin retry / resync | existing «اسحب الليدز دلوقتي»; per-campaign resync on link | 🟡 |

## Phases 4–10

| Phase | Status | Next step |
|---|---|---|
| 4 Attribution: ad account / ad set / ad, ownership history, office-direct campaigns, drill-down | ⬜ 🔒 | additive migration proposal (ERD, rollback) for owner approval |
| 5 Ads Insights: daily snapshots, spend, reach, CPL…, missing ≠ 0 | ⬜ 🔒 | snapshot table proposal; `ads_read` needs App Review |
| 6 Lead quality classification (authority pending) | ⬜ 🔒 | proposal with a configurable permission and a pending state; **no authority assigned** |
| 7 Automatic KPIs (attendance, sales, manager) | ⬜ 🔒 | source mapping per KPI key; `kpi_results` needs source / calculated_at columns; **no new weights** |
| 8 Unified dashboard | ⬜ | after 4–7 |
| 9 Security / authorization validation | 🟡 | tests per phase; full review at the end |
| 10 Documentation / acceptance | 🟡 | this file |

## External configuration still required (nothing set by this work)

1. **Meta app** (developers.facebook.com): product «Facebook Login» with the Valid OAuth Redirect URI `https://<API host>/public/meta/oauth/callback`; Webhooks product, object Page, field `leadgen`, callback `https://<API host>/public/hooks/meta` with the existing verify token.
2. **App Review / Advanced Access** for `leads_retrieval`, `pages_manage_metadata`, `pages_read_engagement`, `pages_show_list`, `ads_read`, `ads_management`, `business_management` (only app roles can grant them before review); Business Verification as Meta requires.
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
| `api/test/meta-oauth-routes.test.ts`, `api/test/meta-sync-run.test.ts` | new Postgres tests (CI) |

No migration was added. No production data, schema, environment or deployment was changed.
