# VALUNIVO — Speed Engineer audit (Audit mode, read-only) — revision 2

Branch `cloudflare/worker-migration` (code = production `main` @ `cbd00b3` plus gateway work). The release candidate on
`release-prep/final-business-model` (PR #9, @ `31c1800`) was measured as well, because it changes the hottest code
(payroll). No application code, schema, index or production system was changed. This revision supersedes revision 1 (`e491315`).

**About the method.** The brief says the full speed-engineer skill was provided in the conversation. It was not: its text
appears in no message and in none of the 19 uploaded files (all searched). This revision therefore follows the Audit-mode
structure and self-check items exactly as the brief lists them: stack map, scale, S/M/L tier, five mandatory areas,
self-check. Anything that needs the skill's own text — tier thresholds, extra checklist lines — is marked **BLOCKED**.
The audit is **not** declared fully compliant.

## 1. Project map and exact stack versions

| Layer | Version / facts (source) |
|---|---|
| App | Flutter 3.38.10 stable, Dart SDK `>=3.5.0 <4.0.0` (`.github/workflows/app.yml:16`, `app/pubspec.yaml:6-8`). Key packages: http 1.2, geolocator 13, flutter_background_service 5.1, image_picker 1.1, flutter_image_compress 2.4, camera 0.11, firebase_messaging 15, shared_preferences 2.3. Android project generated in CI (`flutter create`, `app.yml:42`); release = universal APK (`app.yml:141`). Web = wasm + JS build on Hostinger. |
| API | Node.js 22, TypeScript 5.6, `pg` ^8.13 (resolves 8.23), one dependency. 413 routes. Vercel function: pool **3** connections, Neon **pooler** host, function region pinned to the DB region (`api/vercel/entry.ts`, `api/scripts/vercel-build.mjs`). Every response `Cache-Control: no-store` (`api/src/http/router.ts:88`). Body limit 8 MiB (`router.ts:58`). |
| Gateway | Cloudflare Worker mirror (`api/cloudflare-proxy/worker.js`), the app's first address; Vercel is its fallback. |
| Database | Neon PostgreSQL (production version not visible without access; test DB 16.15). 97 tables, 226 foreign keys, 237 indexes (migrations 001–082). |
| Growing tables | `audit_log` (every action plus every failed sign-in), `notifications`, `attendance` (~59 rows/working day), `tracking_pings` (kept 14 days, `tracking.ts:307`), `leads`/`lead_logs`, `cash_receipts`/`cash_expenses` (with image blobs), `employee_documents`, `attendance_selfies` (image blobs). |
| Existing performance mechanisms | Client: 5-minute in-memory read cache with a 15-second background refresh, shared in-flight reads, offline copy of reads (`app/lib/core/api.dart:60-120`). Server: list caps (66 `LIMIT`s), minute sweep throttled to once a minute (`tracking.ts` `SWEEP_EVERY_MS`), batched photo-link endpoint (`/media/links`), DB-backed rate limits. Infra: keep-warm cron (`.github/workflows/keep-warm.yml`). |

## 2. Performance tier — **S (small)**, with justification

- **Users:** 59 employees, one company, single region. Measured peak demand ≈ 3–6 requests/s (§5.5).
- **Largest growing tables** (estimates; production counts are BLOCKED):
  - `audit_log`: the most rows, likely 10⁵ per year.
  - `notifications`: 10⁵ per year.
  - `attendance`: about 17k per year.
  - `tracking_pings`: capped at about 80k rows by the 14-day retention.

  Every table is below 10⁶ rows in the first years.
- **Freshness:** money, balances, attendance and permissions must be exact and current. Reports may be computed on request.
- **Budget:** free services only.
- **What S implies:**
  - Correct indexes, no N+1, bounded lists and lean payloads are required.
  - Server caches, keyset pagination, read replicas, queues and materialised views would be over-engineering now.
  - Numeric tier thresholds come from the skill and are unavailable (BLOCKED). The tier is chosen from the evidence above.

## 3. Expected scale profile and assumptions

| Item | Value | Basis |
|---|---|---|
| Employees | 59 now | owner |
| Growth (employees, leads/month, branches) | **unknown** | not established; needs the owner (FINAL_USER_ACTIONS #13) |
| App usage | open most of a 9-hour shift | assumption |
| Requests/day | 60k–120k (alert poll alone ≈ 95,580 at a full 9 h) | `alert_center.dart:174`; measured mirror traffic BLOCKED (#3) |
| DB round trip in production | 1–3 ms if same region via pooler | assumption; production measurement BLOCKED (#11) |
| Neon compute | free tier (small, shared) | budget; likely weaker than the 2-vCPU test box |

## 4. The five mandatory areas

### 4.1 Database indexes and N+1

| # | Finding | Evidence (file:line, measurement) | Applies to | Status |
|---|---|---|---|---|
| I1 | **Payroll N+1 in reports**: about 15 queries per employee per month | `payroll-calc.ts:53…` called per employee. Queries per request: `/insights/employees` 2,091; `/finance/dashboard` 1,644; `/payouts/salaries` 874; `/dashboard/owner` 829. At 10 ms RTT: 19.1 s, 13.6 s, 2.5 s and 0.9 s | **main / this branch only** | FAIL here. **Already fixed in the release candidate**: same payloads (identical byte sizes), 40 / 48 / 19 / 31 queries, 176 / 326 / 109 / 509 ms at 10 ms RTT. Re-measured on `31c1800`. |
| I2 | KPI N+1 on `/dashboard` and `/kpi/overview` | `kpi.ts:221` (`for (const e of emps.rows)`), `dashboard.ts:147` → `ensurePeriod`/set/results per employee (`kpi.ts:40-52`). 194 and 176 queries. `/dashboard` (manager/owner): 2.1 s at 10 ms RTT, still the same on the release branch | both | FAIL |
| I3 | Minute sweep inside a user request | `dashboard.ts:76` → `tracking.ts sweep` → `leads.ts:1265-1275`: up to 300 × (UPDATE + INSERT) one by one. 600 writes seen in one `/dashboard` call; max 7.2 s under load | both | FAIL (medium) |
| I4 | Unindexed foreign keys | 148 of 226 FKs have no leading index. Mostly audit columns (`created_by`, `decided_by` …) that are never filtered. Filtered ones: `salary_adjustments(employee_id)` (`payroll-calc.ts`, `reports.ts:141`), `cash_receipts(sale_id)` (`sales.ts:111,422`), `payouts(batch_line_id)` (`payroll-batches.ts:150,310`), `payroll_batch_lines(employee_id)`, `attendance_corrections(attendance_id)` (`attendance.ts:130`), `tasks(lead_id)` (`leads.ts:1157`) | both | PASS for tier S today (tables small); add an index when a table passes about 10k rows |
| I5 | Duplicate index | `leads_created (created_at DESC)` and `leads_created_at (created_at)` | both | FAIL (minor) |
| I6 | Hot paths indexed | `notifications(recipient_id, created_at DESC)`: 0.44 ms; `attendance(employee_id, work_date)`; `sessions(token_hash)` | both | PASS |
| I7 | Client N+1 | Photos fetched as one batched `/media/links` call (`api_service.dart:158`). No per-row request loops found. The leads Excel export pages through `/leads` 25 × 200 (`leads_list_page.dart:422-428`), which is acceptable | both | PASS |

### 4.2 Pagination and server-side filtering

| # | Finding | Evidence | Status |
|---|---|---|---|
| P1 | Lists are bounded on the server | 66 `LIMIT`s; e.g. `cash.ts:653` (1000), `:732`/`:813` (500), `employees.ts:181` (500), `leads.ts:363` (size ≤ 200) | PASS |
| P2 | Filtering is server-side | Leads, cash, attendance, reports take query filters; no whole-table download for client filtering found | PASS |
| P3 | **Stable ordering** | Leads OFFSET pagination orders by `created_at DESC`, `last_action_at`, or `full_name` with no unique tie-breaker (`leads.ts:366-375`). Ties (bulk imports, same name) can repeat or skip rows between pages and in the export. Cash lists order by `occurred_at` only (`cash.ts:732,813`) | FAIL (minor; add `, l.id` / `, r.id`) |
| P4 | Keyset pagination | Not needed at tier S (largest paged list: leads, thousands) | NOT APPLICABLE (S) |
| P5 | **Backup export paging** | `backup.ts:72` `ORDER BY ctid OFFSET … LIMIT 2000`. ctid changes when a row is updated, so a row updated during a backup can be exported twice or missed. OFFSET also rescans earlier pages. | FAIL (correctness of backups; switch to primary-key order) |
| P6 | **Select only needed columns** | Receipt and expense lists use `r.*` / `x.*` (`cash.ts:458-463`, used at `:732`, `:813`, `sales.ts:422`), which pull the `attachment` bytea (≤ 600 KB each) for up to 500 rows, then drop it. Measured with a 200 KB synthetic attachment on 500 receipts: **16 ms → 457–588 ms, +133 MB RSS**, payload unchanged (327 KB). Same on the release branch (`cash.ts:665`, `:956`, `:1053`) | FAIL (high once receipts carry real photos; also Neon egress on the free plan) |

### 4.3 Image optimisation

| # | Finding | Evidence | Status |
|---|---|---|---|
| IM1 | Upload resizing | All 15 `ImagePicker.pickImage` calls set `maxWidth`/`imageQuality`; selfies compressed (`camera_service.dart:123`). Documents picked with `pickDocument` are not resized, only size-capped (e.g. national ID ≤ 3 MB, `marketing_company_form_page.dart:115-118`). Server caps: photo 2 MB (`employees.ts:515`), cash image 600 KB (`cash.ts:61`), files 3–5 MB | PASS (documents: size cap only) |
| IM2 | Serving | `/media/:kind/:id` returns the stored image at full size (`legacy.ts:310-329`); no thumbnails. Lists show photos through batched signed links | FAIL (minor at S): full-size photos for small avatars |
| IM3 | HTTP caching of images | Router forces `no-store` on every response, media included (`router.ts:88`), so signed photo links are fetched again on each app start (Flutter's memory cache covers one session) | Potential; a `private, max-age` on signed media links is allowed (per-user capability URL) |
| IM4 | Decode dimensions | Only 8 `cacheWidth`/`cacheHeight` uses for 22 image widgets; e.g. selfie cards `attendance_expandable_cards.dart:175` | FAIL (minor; memory) |
| IM5 | Bundled assets | `logo.png` 885 KB, `avatar.png` 294 KB, sounds 0.6–0.7 MB; assets 5.4 MB | FAIL (minor) |
| IM6 | Formats / lazy loading | JPEG/PNG only; lists are lazily built (`ListView.builder`); no WebP | Potential |

### 4.4 Caching and invalidation

| # | Finding | Evidence | Status |
|---|---|---|---|
| C1 | No public / shared caching of private data on the server or CDN | `no-store` everywhere (`router.ts:88`); gateway forces `no-store`; Vercel CDN does not cache them | PASS |
| C2 | **Financial balances served stale on the client** | The client read cache (`api.dart:64-66, 79-92`) serves non-"live" GETs from memory for up to 5 minutes and only refreshes in the background after 15 s. `/cash/summary`, `/cash/ledger`, `/finance/*`, `/payouts/*` are not in `_live` (`api.dart:66`). A cashier opening the cash screen sees the balance from up to 5 minutes ago (another person's movement is not shown) until the next open. Own writes clear the cache (`api.dart:216`) | **FAIL**: exact real-time values are cached. Smallest fix: add the money paths to `_live` |
| C3 | **Offline copy not separated by user** | Every successful GET up to 300 KB is stored in `SharedPreferences` (unencrypted, `api.dart:110-120`) under a key made from the URL only. It is cleared on **logout** (`session.dart:118-122`) but **not** when the session expires or is revoked (`session.dart:21-23` → `_clear` without `clearOffline`). If another person signs in on that device while offline, the first person's cached responses (cash, employees, payroll) can be shown | **FAIL** (privacy plus invalidation). Smallest fix: clear offline data in `_clear()` and key by user |
| C4 | Unnecessary repeated work | Reports recompute payroll per request (fixed by I1 on the release branch); no server cache needed at S | PASS (release) |
| C5 | Compression | API sends uncompressed JSON (local check). **Vercel's CDN compresses responses with gzip/brotli when the client sends `Accept-Encoding`** ([Vercel docs](https://vercel.com/docs/how-vercel-cdn-works/compression)); Dart's HTTP client and browsers send it. Revision 1's "add compression in the router" is **withdrawn**; only a production header check remains (BLOCKED #11) | Likely PASS (unverified) |

### 4.5 Loading UX (skeleton / empty / error / retry)

Static sweep of the 36 screens that have a `_load()`:

| State | Screens with it | Status |
|---|---|---|
| Loading indicator | 35 / 36 (spinner) | PASS |
| Skeleton | 0 | NOT REQUIRED at S (spinners exist); optional |
| Empty state | 30 / 36. Missing in `multi_company/positions_page.dart`, `leads/leads_stages.dart`, `leads/leads_permissions.dart`, `pages/attendance_page.dart`, `pages/fingerprint_home.dart`, `pages/common.dart` | FAIL (minor) |
| Error state | 20 / 36 handle errors explicitly. 16 rely on the bridge returning an error map, e.g. `finance/finance_dashboard_page.dart:112-119` sets `_loading=false` and renders whatever came back. Others: `commissions_page`, `projects_hub`, `marketing_companies_page`, `leads_*` (6), `partner_*` (2), `cash_overview`, `deals_page`, `commission_project_page` | FAIL: needs a runtime check of what is shown on error |
| Retry / refresh | 29 / 36 (pull-to-refresh or a button) | Mostly PASS |
| Parallel requests | 24 `Future.wait` uses. Sequential first loads of 2–3 requests: `marketing_company_form_page.dart:69`, `year_closing_page.dart:1158,1549`, `permissions_page.dart:54`, `commissions_page.dart:506`, `cash_page.dart:706` | Minor waterfalls |

## 5. Earlier broader findings: reassessed

| Earlier claim | Re-check | Verdict |
|---|---|---|
| Salary/finance N+1 | Re-measured on both branches (§4.1 I1) | **Valid for main; already solved in the release candidate.** The priority moves to I2 (KPI). |
| Owner-dashboard daily cash series | Query still present on the release branch (`owner-dashboard.ts:90`); `EXPLAIN ANALYZE` 362 ms vs 0.55 ms grouped | **Valid** (both branches) |
| Alert poll every 20 s, also in background | `alert_center.dart:174` timer; `poll()` (`:213`) has no foreground check; `_foreground` only gates UI (`:239,246`). On Android the shift-tracking foreground service keeps the process alive, so the poll continues during shifts (behaviour on a device unverified); browsers throttle background timers | **Valid** (runtime unverified) |
| APK 89 MB universal | `app.yml:141` (no `--split-per-abi`); release asset 89,173,004 bytes | **Valid.** A per-ABI split also needs the in-app updater (`latest.json` + `ota_update`) to pick the right file, so it is not a one-line change |
| Web 8.26 MB JS + 7.91 MB WASM | Hostinger listing; deflate on (`.htaccess`) | **Valid**; only one of the two is loaded per browser |
| API compression missing | Vercel CDN compresses (§4.4 C5) | **Withdrawn**, pending a header check |
| DB is the bottleneck under load | Local: about 103 req/s flat, Postgres about 1.4 of 2 cores, Node 30 %. Neon's free compute is likely smaller | **Valid** as a direction; production capacity unmeasured |

### 5.5 Load and concurrency (unchanged measurements, synthetic data)

| Scenario | Throughput | p50 | p95 | p99 | Errors |
|---|---|---|---|---|---|
| 10 users | 103.8 req/s | 44 ms | 358 ms | 471 ms | 0 |
| 25 users | 103.8 req/s | 140 ms | 831 ms | 1,064 ms | 0 |
| 50 users | 102.8 req/s | 300 ms | 1,637 ms | 1,940 ms | 0 |
| 5 owners on heavy reports | 2.6 req/s | 2.2 s | 3.9 s | — | 0 |

Server memory stayed at or below 220 MB RSS. The heavy-report run used the old code; on the release branch those reports
take 0.1–0.5 s each.

## 6. Self-check (from the brief's list)

| Item | Status |
|---|---|
| Index coverage for FKs and filtered/sorted columns | PASS for S (I4, I6); duplicate I5 FAIL |
| Zero N+1, server | **FAIL** (I2, I3; I1 only on main) |
| Zero N+1, client | PASS (I7) |
| Only required columns selected | **FAIL** (P6) |
| Server-enforced limits | PASS (P1) |
| Stable ordering | **FAIL** (P3, P5) |
| Keyset pagination where justified | NOT APPLICABLE (S) |
| No whole-table downloads for client filtering | PASS (P2) |
| Image resizing / compression / formats / lazy / dimensions | Partial: upload PASS (IM1); serving and decode FAIL minor (IM2, IM4) |
| Correct caching classification and invalidation | **FAIL** (C2, C3) |
| No public caching of private data | PASS on server/CDN (C1); **FAIL** on shared devices (C3) |
| No caching of balances / exact values | **FAIL** (C2) |
| Loading / empty / error / retry | Partial (§4.5) |
| Parallel requests, no waterfalls | Mostly PASS (6 small waterfalls) |
| No over-engineering beyond tier | PASS (no recommendation adds infrastructure) |
| Unchanged behaviour and permissions | PASS (read-only audit) |
| Skill-specific thresholds / extra items | **BLOCKED** (skill text not provided) |
| Production verification | **BLOCKED** (§8) |

## 7. Smallest safe fixes, in priority order (none applied; each needs approval)

| # | Fix | Files | Expected impact | Verify by |
|---|---|---|---|---|
| 1 | Ship the release candidate's payroll batching (already written and tested) | PR #9 | Reports from 0.9–19 s to 0.1–0.5 s at 10 ms RTT | Rerun of `qprof` / RTT scripts (§9) |
| 2 | Receipt/expense lists: replace `r.*`/`x.*` with explicit columns (no `attachment`) | `cash.ts:458-463` | 500-row list stays about 16 ms with real photos (instead of about 0.5 s and up to 300 MB pulled from the DB) | Same synthetic-attachment test; identical JSON |
| 3 | Money screens always fresh: add `/cash`, `/finance`, `/payouts`, `/payroll`, `/sales`, `/insights` to `_live` | `app/lib/core/api.dart:66` | Balances never shown stale; adds about 1 request per screen open | Manual test with two accounts |
| 4 | Clear the offline copy when a session ends for any reason; key it per user | `session.dart:126` (`_clear`), `api.dart:110-120` | No cross-user data on shared devices | Expire session, sign in as another user offline |
| 5 | Daily cash series as one grouped query | `owner-dashboard.ts:84-90` | 362 ms → about 1 ms | `EXPLAIN ANALYZE`; identical totals for 90 days |
| 6 | Batch the KPI lookups for all employees | `kpi.ts:40-52, 221`, `dashboard.ts:147` | `/dashboard` 194 → about 10 queries; 2.1 s → about 0.2 s at 10 ms RTT | Query counter; identical KPI output |
| 7 | Batch the minute sweep's writes | `leads.ts:1265-1275` | No 2–7 s spikes for the user who triggers it | Latency of the claiming request |
| 8 | Alert poll only in the foreground, with back-off | `alert_center.dart:174,213` | Up to about −50 % requests/day; mirror stays under the free limit | Request counts per device |
| 9 | Tie-breakers (`, id`) on OFFSET lists; backup paging by primary key | `leads.ts:366-375`, `cash.ts:732,813`, `backup.ts:72` | No duplicate/missing rows in pages, exports and backups | Paging test with tied timestamps |
| 10 | Minor: drop duplicate index (migration); `cacheWidth` on large images; shrink logo/avatar; explicit error states on 16 screens; per-ABI APK with updater support | various | memory / size / UX | as listed |

## 8. Missing measurements and access needed

| Missing | Needs |
|---|---|
| Skill text (thresholds, any further checklist items) | Paste `speed-engineer-SKILL.md` into the chat or commit it (FINAL_USER_ACTIONS #10) |
| Production round trip, compression header, cold starts | Approval for a few read-only production requests (#11) |
| Real traffic per day | Cloudflare analytics token (#3) |
| Real table sizes and growth | Read-only counts in Neon (with #2), plus the growth expectations (#13) |
| Flutter runtime (startup, frames, memory, battery, background poll) | Profile build on one Android phone + DevTools (#12) |

## 9. Evidence index

- **Synthetic database `va_perf`:** 59 employees; one year of attendance (16,877 rows); 129,800 notifications; 250,000 audit rows;
  8,000 leads; 40,000 lead logs; 6,000 receipts; 2,000 expenses; tracking pings at the 14-day retention (51,628).
- **Scripts** (outside the repo, `/home/claude/audit`):
  - `routes.mts`: every GET route × 4 roles.
  - `qprof.mts` / `qprof_rel.mts`: queries per request, on both branches.
  - `rtt.mts` / `rtt_rel.mts`: simulated database round trip.
  - `load.mts`: load test.
  - `att.mts`: receipt lists with attachments.
  - `gz.mts`: payload sizes and compression.
  - `pool.mts`: pool sizes.
- **Other tools:** `pg_stat_statements`, `pg_stat_user_tables`, an FK-index query, `EXPLAIN ANALYZE`, static greps (line
  numbers above), a read-only Hostinger listing, and the GitHub release API for the APK size.

## 10. Statement

Read-only audit. No application code, schema, index, migration, permission, credential, DNS, routing, deployment or
production data was changed or accessed. The only production touch was one read-only listing of web bundle sizes. All load
ran on an isolated local database with synthetic data. The synthetic attachment test was reverted inside that test database.
This audit alone does not make VALUNIVO production-ready.
