# VALUNIVO — Speed Engineer audit (Audit mode, read-only) — revision 3 (remediation prepared)

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
| Error state | Corrected in revision 3 (§7 R7): 31 / 36 show the error. 4 show "no data" on failure (`commissions_page.dart:122`, `leads_calendar_page.dart:42`, `leads_list_page.dart:55`, `marketing_companies_page.dart:36`) and 1 hides silently (`cash_overview.dart:86`) | FAIL (5 screens) |
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

## 7. Remediation plan — revision 3, ordered by user impact (prepared and verified; nothing applied)

The method limitation still applies: the speed-engineer skill text is not in this session or the repository. The audit is not
claimed to be skill-compliant. Evidence files are in `docs/remediation/evidence/`. They are reproductions only and are
not built into the app.

### R1 — Offline data isolation between users · **REPRODUCED** · priority 1 (privacy and data integrity)

**Reproduction.** Done with the real `ApiClient` and `Session` code, Flutter 3.38.10, in an isolated copy of the app with a fake server.
The test is `evidence/repro_offline_isolation_test.dart.txt`; 5 of 5 tests pass, which means the problem is present.
- **Expired or revoked session, then switching account offline.** User A (an accountant) is signed out by a 401. User B (no
  cash permission) signs in on the same phone, then the phone goes offline.
  - B's `/cash/summary` returns `{balance: 123456.78, owner: A-PRIVATE, _offline: true}`.
  - B's `/payouts` returns A's payouts (`amount 9999`).
- **Offline queue.** A's check-out, queued while offline, is later sent with B's token. The server records
  `B|/attendance/check-out`, so A's action is credited to B.
- **Controls (no leak):** a normal **logout** clears the offline copy, and the in-memory cache is keyed by token.

**Root cause (lifecycle trace).**
- The 401 handler `session.dart:21-23` calls `_clear()` (`session.dart:126-137`). That clears the token and `me_cache` but
  **not** the offline copies. Only `logout()` calls `ApiClient.clearOffline()` (`session.dart:118-122`).
- Offline copies are stored under a key built from the URL only, `apicache:<url>` (`api.dart:100-112`, put at `:114`). They
  sit in plain `SharedPreferences` with no owner.
- The queue (`offline_queue`, `api.dart:153-170`) and the separate attendance punch (`offline_punch`,
  `jph/services/api_service.dart:907-918`) have no owner either. `flushQueue()` (`api.dart:178`; called from
  `session.dart:120`, `alert_center.dart:277`, `shift_tracker.dart:168`) sends with whoever is signed in now.
- The UI login (`api_service.dart:690-696` → `session.dart:87-93`) does not clear anything.
- The full wipe (`SessionService.logout`, `session_service.dart:76-85`) only runs at the **next app start** (`main.dart:95-101`).

**Impact.**
- Privacy: another user's cash, payroll, employee and CRM data is shown on a shared device. The server's permission
  checks are bypassed because the data never comes from the server.
- Integrity: attendance and other queued writes are recorded under the wrong employee.
- B also sees A's offline punch on B's own attendance screen (`_todayMerged`, `api_service.dart:921-941`) and can be told
  "you already checked out".

**Smallest safe fix (no API, UI or business change).**
1. `ApiClient` gets an `owner` (the signed-in employee id), set by `Session._apply`.
   - Offline keys become `apicache:<owner>:<url>`.
   - Queue items carry `owner`, and `flushQueue()` sends only the current owner's items. Other owners' items stay
     untouched until that person signs in again; they are not lost.
2. `Session._clear()` also removes the offline read copies, every owner's (privacy first), and clears the in-memory cache.
   The queue is kept but is owner-filtered.
3. `offline_punch` is stored per owner (`offline_punch:<owner>`).
4. On first start after the update, items with no owner are dropped from the read cache. Unowned queue items move to
   the existing "failed" list with a clear reason, so nothing is sent under a guessed identity.

**Regression tests (Flutter unit tests, real code).**
- The 4 failing scenarios above must fail to leak:
  - B offline after A's 401 gets a network error, not A's data.
  - A's queue is never sent with B's token.
  - A's items are sent when A signs in again.
  - B's attendance screen never shows A's punch.
- The controls must still pass. Offline mode must still work for the same user: offline reads, queue send-later,
  restart while offline.

**Measurements.** Before and after: number of `apicache:*` keys after a 401, and a test transcript of the 4 scenarios.

**Dependencies.** Ships only in a new app build (APK/web/Windows); old installs stay affected until they update.

### R2 — Balance freshness · **REPRODUCED** · priority 2 (financial correctness)

**Reproduction** (same test file): first read 1000; the server changes to 500 (another person's expense); reopening the
screen shows **1000**. Live paths bypass the cache and show 500.

**Root cause.**
- `_live` (`api.dart:67`) excludes every money path.
- `get()` (`api.dart:79-98`) returns the memory copy for 5 minutes, and only refreshes it in the background after 15 s.
- Every money screen reads through the cached bridge `cash_get` (`api_service.dart:415-419`).
- Money read paths affected (27): `/cash/summary`, `/cash/overview`, `/cash/ledger`, `/cash/receipts`, `/cash/expenses`,
  `/cash/transfers`, `/cash/bank-moves`, `/cash/fixed-expenses`, `/payouts`, `/payouts/cashiers`, `/finance/dashboard(/details)`,
  `/finance/employee-account/…`, `/finance/adjustments`, `/payroll/employee/…`, `/payroll-batches…`, `/advances(/open)`,
  `/sales…`, `/sales/installments/due`, `/commissions/entitlements|requests|projects`, `/insights/employees`, `/custody`.
- Offline copies of these are also shown with no "offline" marker on any screen. `_offline` is checked only in
  `api_service.dart:929`.

**Impact.** Cashiers and managers can act on a balance up to 5 minutes old. A person's own writes do clear the cache
(`api.dart:215-240`), but other people's do not.

**Smallest safe fix.**
- Treat money paths as live. Prefixes added to `_live`: `/cash`, `/payouts`, `/finance`, `/payroll`, `/advances`, `/sales`,
  `/commissions`, `/insights`, `/custody`.
- Request-sharing for identical reads in flight stays (`_inflight`), so double opens cost one request.
- Where `_offline == true` arrives on a money screen, show a small "offline — last known" label (text only, no layout change).

**Cost.** About one extra request per money-screen open, at roughly 4–20 ms server time each (measured route p50s). Money screens are not polled.

**Regression tests.** The freshness test must read 500. A same-user write still refreshes. Non-money screens keep the
5-minute cache. Offline money reads are marked.

**Dependencies.** None (app build).

### R3 — Attachments pulled by list queries · **MEASURED** · priority 3

**Root cause.**
- `RECEIPT_SELECT` and `EXPENSE_SELECT` use `r.*` / `x.*` (`api/src/modules/cash.ts:458-463`), which includes the
  `attachment` bytea.
- They are used in lists at `cash.ts:732` (receipts, ≤ 500), `cash.ts:813` (expenses, ≤ 500) and `sales.ts:422`
  (receipts of a sale). The fixed-expenses lateral `cash.ts:834` does the same per fixed item.
- List responses only send `hasAttachment` (`cash.ts:402,411`); the bytes are thrown away.

**Detail access that must stay as is.**
- `GET /cash/expenses/:id/attachment` (`cash.ts:938-945`: `canSee` + `canAttachmentView`).
- `GET /cash/attachments/:entity/:id` (`cash.ts:1071-1077`: `attachmentAccess`).
- Single-row reads `cash.ts:716`, `sales.ts:606`.

**Measurement** (synthetic 200 KB attachment on the 500 newest rows):

| List | Without attachments | With attachments | Payload |
|---|---|---|---|
| receipts | 16 ms | 457–588 ms, +133 MB RSS | unchanged 327 KB |
| expenses | 14 ms | 493–535 ms, +112 MB RSS | unchanged 292 KB |

**Impact.** Slow cash lists and big memory spikes once real photos exist. Each list view moves up to 500 × 0.6 MB from
the database, which counts against Neon free-plan egress.

**Smallest safe fix.**
- List queries select explicit columns without `attachment`, keeping `(attachment IS NOT NULL) AS has_attachment`.
- The single-row `RECEIPT_SELECT WHERE r.id = …` stays full.
- Same for the fixed-expense lateral.

**Regression tests.**
- List JSON is byte-identical before and after on the synthetic DB.
- Detail and attachment routes return the same bytes with the same permission results (existing cash permission tests
  plus one new list-vs-detail test).

**Measurements.** List latency and RSS with 0 KB and 200 KB attachments, before and after.

**Dependencies.** Apply on top of the release branch, which has the same code at `cash.ts:665`, `:956`, `:1053`.

### R4 — KPI N+1 on `/dashboard` and `/kpi/overview` · **MEASURED** · priority 4

**Root cause.**
- `/dashboard` makes 203 queries in total, of which 171 are KPI: 57 employees × 3. The loop is `dashboard.ts:147-149`
  (`ensurePeriod` + `loadPeriod`).
- `/kpi/overview` makes 176 queries, from the loop at `kpi.ts:221-224`.
- Per employee: `SELECT 1 FROM kpi_results` (`kpi.ts:52`), `activeSetFor` (`kpi.ts:40-47`), and the `loadPeriod`
  results query (`kpi.ts:62-…`).
- `ensurePeriod` may **insert** snapshot rows during a GET, which is existing behaviour and is kept.

**Impact.** Manager and owner dashboard 2.1 s at 10 ms RTT (still on the release branch).

**Smallest safe fix.** Batch versions with the same semantics, reusing the same pure `summarize()`:
- `ensurePeriods(q, ids, period)`: one query for ids without results; one `DISTINCT ON (e.id)` set query with the same
  priority order; one `INSERT … SELECT` over `unnest(ids, set_ids)` with the same `ON CONFLICT DO NOTHING`.
- `loadPeriods(q, ids, period)`: one query `WHERE employee_id = ANY($1)`, grouped in memory.
- Result: about 5 queries.

**Regression tests.** Per-employee output identical for employee-, position- and title-scoped sets, partly and fully
evaluated, no set, and concurrent first-of-month snapshotting (idempotent).

**Measurements.** Query count 203 → ~35 and 176 → ~8; latency at 0/2/10 ms RTT.

**Dependencies.** Apply on top of the release branch.

### R5 — Daily cash series · **PROVEN IDENTICAL** · priority 5

**Root cause.** Four correlated full scans of `cash_receipts` per day (`owner-dashboard.ts:84-90`). The release branch has
the same query at `:90`.

**Prepared replacement.** A single grouped query over a sargable Cairo-local range (`evidence/cash_series_equivalence.sql`):
- `generate_series` of days, `LEFT JOIN` per-day sums with `FILTER` per kind.
- `occurred_at >= (from::timestamp AT TIME ZONE 'Africa/Cairo')` and `< ((to+1)::timestamp AT TIME ZONE 'Africa/Cairo')`.
- `COALESCE(…, 0)` and `ORDER BY day`.

**Proof** (synthetic DB, rolled back):
- **261 ranges** compared (1 to 389 days, including whole-year and DST-start/DST-end windows).
- 70 edge receipts across all 7 kinds, 10 of them reversed, at 23:59:59 / 00:00:00 Cairo boundaries and on Egypt DST change days.
- **0 differing rows**: same dates, same order, same totals, same numeric type.

**Timing.**

| Range | Before | After |
|---|---|---|
| 14 days | 531.6 ms | 0.93 ms |
| 90 days | 1,006.5 ms | 1.77 ms |

**Regression tests.** Add the equivalence script as an API test: old vs new over the edge data, plus an owner-dashboard
snapshot test.

**Dependencies.** Apply on top of the release version of `owner-dashboard.ts`.

### R6 — Pagination and backup consistency · **REPRODUCED** · priority 6

**Leads paging** (`leads.ts:366-372`, OFFSET with no unique tie-breaker). Paging all 8,000 synthetic leads at 200 per
page (`evidence/leads_paging_check.mts.txt`):

| Sort | Leads repeated | Leads never shown |
|---|---|---|
| `created` (default) | 42 | 42 |
| `action` | 619 | 619 |
| `next` | 31 | 31 |
| `name` | 0 | 0 (unique synthetic names) |

The Excel export uses the same paging (`leads_list_page.dart:422-428`). Cash lists order by `occurred_at` only (`cash.ts:732,813`).

**Fix:** append `, l.id` (and `, r.id` / `, x.id`). The order stays the same except among ties.

**Backup paging** (`backup.ts:72`, `ORDER BY ctid OFFSET`). With the app editing 25 and deleting 10 already-exported rows
during an export:

| Paging method | Rows exported twice | Live rows missing |
|---|---|---|
| ctid offset (current) | 4 | 14 |
| primary key + offset | 0 | 10 |
| primary-key keyset | 0 | 0 |

Evidence: `evidence/backup_paging_repro.sql` and `backup_paging_keyset.sql`.

**Fix.**
- Order by the table's primary key. All 97 tables have one: 87 single-column, 10 composite.
- Accept an optional `after` cursor (the last key) alongside `offset`, so the current Apps Script keeps working.
- Update `backup/google-drive-backup.gs` to send the cursor. Restore is unchanged (same row JSON).
- **Snapshot consistency across tables is not achievable** with paged serverless calls; one transaction cannot span HTTP
  requests. Keyset paging guarantees every row present at the start is exported exactly once per table. For a true
  point-in-time copy, Neon's own history/branching is the reference. The JSON export is the off-site copy.

**Regression tests.** Paging test with tied timestamps (no duplicates or gaps); backup test with concurrent edits and
deletes (0 duplicates, 0 missing); the existing restore test.

**Dependencies.** The Apps Script change is entered in Apps Script by the owner (FINAL_USER_ACTIONS #14).

### R7 — Loading, error and empty states (corrected) · priority 7

Revision 2's "16 screens without error state" came from a word search. Checked against what each screen does with the
bridge's `success:false` reply:
- **12 of those 16 do show or handle the error.** Examples: `finance_dashboard_page.dart:125`, `leads_dashboard_page.dart:88`,
  `deals_page.dart:73`, `projects_hub.dart:171`.
- **4 show "no data" or an empty list on failure, with no message or retry:**
  - `commissions/commissions_page.dart:122`
  - `leads/leads_calendar_page.dart:42`
  - `leads/leads_list_page.dart:55`
  - `projects/marketing_companies_page.dart:36`
- **1 hides silently:** `cash/cash_overview.dart:86` returns an empty box when the read fails.
- **Possible missing empty state, 6 screens** (to confirm at runtime): `multi_company/positions_page.dart:91`,
  `leads/leads_stages.dart:50`, `leads/leads_permissions.dart:30`, `pages/attendance_page.dart:49`,
  `pages/fingerprint_home.dart:61`, `pages/common.dart:79`.

**Fix.** Show the existing message widget plus a retry button where `success == false`. Wording follows the existing
pattern; nothing else in the UI changes.

**Tests.** Widget tests per screen with a failing bridge reply.

### R8 — Payroll N+1 · **already solved on the release branch; do not duplicate**

- The fix is in commit `ddd65da` on `release-prep/final-business-model` (PR #9). It changes `payroll-calc.ts`,
  `payouts.ts`, `finance-dashboard.ts` and `owner-dashboard.ts`, bundled with the Phase 6 financial-integrity changes,
  so it cannot be cherry-picked alone.
- This branch changes **none** of those files, and the earlier merge dry-run had conflicts only in `vercel.json`.
- On the synthetic DB, `/payouts/salaries` and `/insights/employees` return **identical JSON** on both branches.
  `/payroll/employee/:id` on the release branch only **adds** `payroll.components` (Phase 6).
- Query counts drop from 874/2,091 to 19/40.
- **Action:** deliver through the approved PR #9 merge (FINAL_USER_ACTIONS #8). R3–R5 should be implemented on top of the
  release code.

### Implementation order once approved

R1 → R2 (app build) and R3 → R5 → R4 → R6 (API, on the release base) → R7. Each change comes with its tests and
before/after numbers. PR #9 is merged first (R8).

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
