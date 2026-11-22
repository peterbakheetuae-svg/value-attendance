# VALUNIVO — Speed / performance audit (read-only)

Branch `cloudflare/worker-migration` @ `67d8c4e` (no code changed; this report is the only addition). Date 2026-11-22.
This is one input to the release decision; it does **not** by itself declare VALUNIVO production-ready.

## 1. Executive summary

- **The method file `speed-engineer-SKILL.md` could not be read.** It sits on the owner's PC (`C:\Users\JPH_T\OneDrive\Documents`), and the
  session's permission check refused access to that folder. A standard performance method was applied instead (§2), and every
  item that depends on the file is marked BLOCKED.
- **The everyday app is fast.** Measured on a production-scale synthetic database (59 employees, one year of activity), 314 of
  328 route/role combinations answer in under 50 ms. The median route takes 2.4 ms in-process, and the screens staff poll most
  (`/notifications`, `/me`, `/attendance/today`, `/payouts`) take 2–8 ms with 2–5 queries.
- **The main problem is N+1 queries in the management reports (verified).** The payroll calculation runs about 15 queries per
  employee per month:
  - `/insights/employees`: 2,091 queries per request
  - `/finance/dashboard`: 1,644
  - `/payouts/salaries`: 874
  - `/dashboard/owner`: 829
  - `/dashboard`: 193; `/kpi/overview`: 176

  These take 0.2–1 s locally. With a realistic 2 ms database round trip they take 0.7–5 s, and at 10 ms they take 0.9–19 s (`/dashboard/owner` runs its queries in parallel, so it degrades least).
- **One owner-dashboard query is about 660× slower than it needs to be.** A per-day cash series runs 4 correlated full scans per day:
  362 ms, versus 0.55 ms for an equivalent grouped query.
- **Under load, the database is the bottleneck, not Node.** Throughput plateaus at about 100 requests/s on a 2-core test machine
  while Postgres uses about 1.4 cores. Real company peak demand is about 3–6 requests/s, so there is roughly 20× headroom on the
  ordinary paths.
- **Request volume, not CPU, is the infrastructure risk.** The 20-second alert poll alone produces about 95k requests/day if every
  employee keeps the app open for a 9-hour shift. That is close to the free Cloudflare Worker limit of 100k/day on the mirror path.
- **Client weight:**
  - The Android APK is 89 MB, a universal build with no per-ABI split.
  - The web build is 8.3 MB of JS plus 7.9 MB of WASM. It is served with deflate.
  - JSON responses are not compressed by the API itself; gzip would shrink them about 10×. Whether the platforms compress them
    in production is unverified.

## 2. Skill compliance checklist

| Requirement (from the task brief; the skill file was unreadable) | Status | Evidence |
|---|---|---|
| Read `speed-engineer-SKILL.md` fully and use it as the method | **BLOCKED** | Folder-access request refused by the session's permission check. Needs the file attached to the chat or placed in the repo. |
| Skill-specific checklists, helper scripts, thresholds | **BLOCKED** | Same reason. Generic equivalents were applied below. |
| Flutter startup / first frame | **BLOCKED** | No Flutter SDK, device or emulator here. Web bundle size measured instead (§3). |
| Navigation / interaction responsiveness, frame times | **BLOCKED** | Needs Flutter DevTools on a device. |
| CPU / memory of the app | **BLOCKED** | Same. |
| Widget rebuilds | PASS (static) / potential | 1-second timers use a `ValueNotifier` on the dashboards; two small widgets call `setState` every second (§3). |
| Large images / assets / payloads | **FAIL** | 89 MB universal APK; 885 KB `logo.png`; responses up to 360 KB raw (§3, §6). |
| Background services / location / battery | potential | High-accuracy fix every minute during shift plus the alert poll while backgrounded (§3). Battery not measurable here. |
| Memory leaks / resource management | **FAIL** (minor) | Dialog-scoped `TextEditingController`s are never disposed (verified in `exclusive_projects_page.dart:229–231`). Timers are cancelled. |
| Endpoint latency | PASS (measured) | Every GET route × 4 roles; p50/p95 in §8. |
| Expensive / blocking operations | **FAIL** | N+1 reports; scrypt login 34–39 ms CPU (by design). |
| N+1 queries | **FAIL** | Query counts per route (§4). |
| Concurrent request handling | PASS | 10, 25 and 50 virtual users: 0 errors (§7). |
| CPU / memory under load | PASS (local) | Node 27–32 % CPU, RSS ≤ 220 MB (§7). |
| Caching opportunities | **FAIL** | Per-employee payroll is recomputed on every report request (§4). |
| Slow queries | **FAIL** | Per-day cash series 362 ms (§5). |
| Missing / redundant indexes | **FAIL** (minor) | Duplicate index `leads_created` / `leads_created_at`; no index for `tracking_pings` by time alone; `audit_log` scans (§5). |
| Query plans | PASS | `EXPLAIN ANALYZE` on hot queries (§5). |
| Pagination / large results | PASS with remarks | Lists are capped (500 or 1,000 rows), but a full page is 290–360 KB raw (§6). |
| Connection management / pool | PASS (analysed) | Pool of 3 per Vercel instance through the Neon pooler; pool size barely matters locally (§7). |
| Transaction duration / concurrency | potential | The minute sweep runs inside a user's request with up to 600 sequential writes (§4). |
| Payload sizes | PASS (measured) | §6. |
| Repeated requests | **FAIL** | 20-second polling (§6). |
| HTTP caching | PASS | API sends `no-store` (correct for personal data). Web static files carry cache headers. |
| Cloudflare / Vercel flow | potential | Extra mirror hop; free-plan daily request cap (§6). |
| Peak / normal bottlenecks | PASS (local) | DB-bound at about 100 req/s (§7). |
| Production latency, real volumes, cold starts | **BLOCKED** | Production calls need approval; Vercel Observability needs a paid plan. Cold module load measured locally: 73–84 ms. |

## 3. Flutter performance findings

| # | Component | Problem and cause | Evidence | Severity / impact | Minimal-risk fix | Verify by |
|---|---|---|---|---|---|---|
| F1 | Android release (`app.yml` `flutter build apk --release`) | Universal APK holding every CPU architecture | `value-attendance.apk` = 89,173,004 bytes (release v1.0.150) | Medium: every update downloads 89 MB on mobile data | Build `--split-per-abi` and serve the matching APK in `latest.json` (or an App Bundle) | APK size per ABI, about 30–40 MB expected |
| F2 | `jph/services/alert_center.dart:174` | 20-second `Timer.periodic` poll of `/notifications?unread=1`, with no foreground check in `poll()` | Code; `_foreground` only gates the UI | Medium: about 180 requests/hour per open app; battery and data use in the background where the OS lets it run | Poll only in the foreground (push already wakes the app); back off to 60 s when idle | Request counts per device; Android battery stats |
| F3 | `core/shift_tracker.dart` | `LocationAccuracy.high`, `distanceFilter: 0`, a 1-minute office check, plus a server ping every N minutes | Code lines 131–155 | Medium (unmeasured): GPS every minute for the whole shift | Balanced accuracy for the office check; high accuracy only when posting | Android battery historian on one device for one shift |
| F4 | Dialogs (e.g. `exclusive_projects_page.dart:229–231`, `admin_pages.dart`, `employee_details_page.dart`) | `TextEditingController`s created in dialog methods and never disposed | Static count: 26/21/13 controllers created with 0 dispose calls in those files | Low: small leak per dialog open | Dispose after `showDialog` returns | DevTools memory snapshot after 50 dialog opens |
| F5 | `assets/` (5.4 MB) | `logo.png` 885 KB, `avatar.png` 294 KB, two 0.6–0.7 MB sounds; only 8 `cacheWidth`/`cacheHeight` uses for 22 image widgets | `find assets -size +200k` | Low: larger APK/web, decode memory | Downscale or convert to WebP; set `cacheWidth` on large images | Asset sizes; DevTools image cache |
| F6 | Web (`jaurea.com/valunivo`) | 8.26 MB `main.dart.js` + 7.91 MB `main.dart.wasm` | Hostinger listing (read-only) | Medium on first load over mobile (deflate is on in `.htaccess`) | Keep the wasm build; enable long cache on hashed files; pre-compressed `.br` if the host supports it | Lighthouse on the web app |
| F7 | `stat_cards.dart:516`, `payment_code.dart:128` | `setState` every second while visible | Code | Low | Wrap the ticking text in a `ValueListenableBuilder` | DevTools rebuild counts |

## 4. API performance findings

| # | Endpoint / file | Problem and cause | Evidence (synthetic production-scale DB) | Severity | Minimal-risk fix | Verify by |
|---|---|---|---|---|---|---|
| A1 | `/insights/employees`, `/finance/dashboard`, `/payouts/salaries`, `/dashboard/owner` (payroll calculation, `modules/payroll-calc.ts`) | N+1: per employee per month it runs `employee_salaries`, `employees.attendance_exempt`, schedule, joining/weekend, attendance (+ selfie EXISTS), requests ×2 … | 2,091 / 1,644 / 874 / 829 queries; 116 calls of each per-employee query (58 employees × 2 months) | **High**: management screens 0.7–5 s at 2 ms RTT, 0.9–19 s at 10 ms; risk of function timeouts | Load each input once for all employees (`WHERE employee_id = ANY($1)`) and compute in memory. Same formulas, same results; prove with the existing payroll tests plus a golden comparison | Query count drops to about 15; latency at the simulated RTT |
| A2 | `/dashboard`, `/kpi/overview` (KPI per employee) | N+1 on `kpi_results` / `kpi_sets` / results per employee | 193 and 176 queries, 88–127 ms | Medium | Batch the three per-employee queries | Query count |
| A3 | Minute sweep inside user requests (`tracking.ts sweep` → `leads.ts:1265 leadsSweep`) | Up to 300 sequential `UPDATE leads` + 300 notification inserts, run inside whichever request claims the minute (`/dashboard`, pings) | 600 writes seen in one `/dashboard` call; under load `/dashboard` max 7.2 s | Medium: an unlucky user waits | Batch (`UPDATE … RETURNING` + one multi-row insert), or rely on the Apps Script `/backup/sweep` call only | Latency of the claiming request |
| A4 | `/leads/dashboard` | 19–22 queries with heavy aggregates (per-day series with correlated subqueries) | 90–173 ms alone; p50 941 ms at 25 users | Medium: polled by sales and managers | Rewrite the series as grouped scans (see D1) | `EXPLAIN`, p95 under load |
| A5 | `POST /auth/login` | scrypt (N=16384) costs 34–39 ms CPU | Measured | Low (by design; security parameters must not change) | none | — |
| A6 | Cold start | Bundle 1.27 MB; module import 73–84 ms | Measured locally | Low | none | — |

## 5. Database performance findings

| # | Object | Problem | Evidence | Severity | Fix | Verify |
|---|---|---|---|---|---|---|
| D1 | `owner-dashboard.ts:84–90` per-day cash series | 4 correlated subqueries per day, each a seq scan of `cash_receipts`; `(occurred_at AT TIME ZONE …)::date = d` cannot use an index | `EXPLAIN ANALYZE`: 362 ms, loops=14, 5,982 rows removed per loop. Equivalent `GROUP BY day` over a range: **0.55 ms** | High (owner dashboard) | One grouped query, then fill empty days in code | `EXPLAIN`, same totals |
| D2 | Seq-scan pressure | `cash_receipts` 607 seq scans / 3.6M tuples read; `lead_stages` 257,808 scans (a 10-row table joined per row); `employee_salaries` 3,882 | `pg_stat_user_tables` after one sweep of all routes | Medium (mostly the N+1 paths) | Fixed by A1/D1 | Re-read the statistics |
| D3 | `leads` | Duplicate indexes `leads_created (created_at DESC)` and `leads_created_at (created_at)` | `pg_indexes` | Low (extra write cost) | Drop one (a migration; needs approval) | — |
| D4 | `tracking_pings` | No index on `at` alone; the retention `DELETE … WHERE at < now()-14 days` and time-only reads do parallel seq scans | 194 ms on 1.6M rows; small at the real 14-day volume (51,628 rows) | Low | `(at)` index only if volume grows | `EXPLAIN` |
| D5 | `audit_log` (`/permissions/audit`) | Scans about 250k rows | 47 ms mean | Low (owner-only, rare) | Index on `(action, id)` if it grows | `EXPLAIN` |
| D6 | Hot paths | Fine: `notifications(recipient_id, created_at DESC)` index scan 0.44 ms; `attendance(employee_id, work_date)`; `sessions(token_hash)` | `EXPLAIN` | — | — | — |

## 6. Network and infrastructure findings

- **N1: no compression from the API.**
  - Raw vs gzip: `/cash/ledger` 360 KB → 36 KB; `/cash/receipts` 328 → 21 KB; `/cash/expenses` 292 → 19 KB; `/employees` 64 → 4 KB; `/leads/dashboard` 54 → 7 KB.
  - The API sends no `content-encoding`. Vercel's CDN and Cloudflare normally compress, but that is **not verified in production** (blocked).
  - Fix if missing: compress in the router when `accept-encoding` allows.
- **N2: request volume.**
  - The alert poll gives 180 requests/hour per open app; 59 users × 9 h ≈ **95,580/day** from polling alone.
  - Pings, screens and the 45-second projects refresh come on top.
  - The free mirror Worker allows 100k/day; above it, the app falls back to Vercel directly.
  - Measured mirror traffic is blocked until a Cloudflare analytics token exists. Fix: F2.
- **N3: request path.** App → mirror Worker (Cloudflare) → Vercel function → Neon pooler. That is one extra edge hop.
  - Vercel picks a function region next to the database (`vercel-build.mjs` `regionFor`).
  - The per-request cost is dominated by the number of DB round trips (A1), not by the hop.
- **N4: HTTP caching.** The API sends `no-store` on every response, which is correct for personal and financial data. Web static
  files have `.htaccess` cache rules, with mixed `no-cache` and 7-day entries.

## 7. Load and concurrency findings (isolated scratch DB, local 2-vCPU machine, one API process with pool 10)

| Scenario | Requests (20 s) | Throughput | p50 | p95 | p99 | max | errors | Node CPU / RSS |
|---|---|---|---|---|---|---|---|---|
| 10 users, staff mix | 2,077 | 103.8/s | 44 ms | 358 | 471 | 5,057 | 0 | 32 % / 183 MB |
| 25 users, staff mix | 2,076 | 103.8/s | 140 | 831 | 1,064 | 5,722 | 0 | 28 % / 195 MB |
| 50 users, staff mix | 2,056 | 102.8/s | 300 | 1,637 | 1,940 | 13,238 | 0 | 27 % / 214 MB |
| 5 owners, heavy reports | 52 | 2.6/s | 2,173 | 3,924 | 4,426 | 4,426 | 0 | 30 % / 220 MB |

- **Throughput is flat at about 103 requests/s while Node uses about 30 % CPU and Postgres about 144 % of the 2 cores.** The
  database is the bottleneck on this machine.
- **Per endpoint at 25 users:**
  - `/leads/dashboard` p50 941 ms (the heaviest polled endpoint)
  - `/dashboard` p50 2.4 s, max 7.2 s (includes the minute sweep)
  - `/notifications` p50 152 ms
- **Pool size has little effect locally.** The heavy reports took 606–977 ms across pools of 1, 3 and 10, because the cost is
  database CPU. In production the database round trip dominates instead. Simulated: at 2 ms RTT `/finance/dashboard` takes
  3.6 s; at 10 ms it takes 13.5 s.
- **Real peak is far lower than the test load.** 59 users × (1 poll / 20 s + screens) ≈ 3–6 requests/s, about 20× below the
  local ceiling on ordinary paths. The real risk is the management reports (A1, D1), not volume.

## 8. Evidence and measurements

- **Dataset (synthetic, no real person).**

  | Table | Rows |
  |---|---|
  | employees | 59 |
  | attendance | 16,877 (one year) |
  | tracking_pings | 1,634,580, trimmed to 51,628 to match the 14-day retention in `tracking.ts:307` |
  | notifications | 129,800 |
  | audit_log | 250,000 |
  | leads | 8,000 |
  | lead_logs | 40,000 |
  | cash_receipts | 6,000 |
  | cash_expenses | 2,000 |

  Database size: 368 MB.
- **Route sweep:** 672 route × role combinations (owner, HR, sales manager, employee). Status mix: 328 × 200, 167 × 403
  (role-correct refusals), 116 × 404 (placeholder IDs), 32 × 401, 29 × 400. Results only count 200 responses. Hot routes:

  | Route (employee unless noted) | p50 | Queries |
  |---|---|---|
  | `/me` | 4.2 ms | 4 |
  | `/notifications` | 6.3 ms | 4 |
  | `/attendance/today` | 3.4 ms | 5 |
  | `/leads` | 19 ms | 7 |
  | `/leads/dashboard` | 90 ms | 19 |
  | `/cash/ledger` (owner) | 20.6 ms, 360 KB | 2 |

- **Statement statistics** (`pg_stat_statements`): top mean is 563 ms for the per-day cash series; next are leads-dashboard
  series of 30–47 ms.
- **Tools:** Node in-process handler with a query-counting wrapper, a closed-loop HTTP load generator, `pg_stat_statements`,
  `pg_stat_user_tables`, `EXPLAIN (ANALYZE, BUFFERS)`, esbuild bundle timing, and a read-only Hostinger listing.
- **Not committed:** the scripts live outside the repository (`/home/claude/audit`); none modify code.

## 9. Prioritized remediation plan (each a separate, approved change; results must be re-measured)

1. **A1:** batch the payroll inputs for all employees, without changing a formula. Golden test: identical payroll for every
   employee and month before and after. Target: about 15 queries, under 300 ms at 2 ms RTT.
2. **D1 / A4:** rewrite the per-day series in `owner-dashboard.ts` and the leads dashboard as grouped scans. Identical totals test.
3. **F2:** foreground-only alert polling with back-off. Halves the request volume and the mirror free-plan risk.
4. **A3:** batch the minute sweep's writes.
5. **F1:** split APKs per ABI.
6. **N1:** verify production compression; add router compression only if missing.
7. **A2, D3, F3–F7:** batch KPI queries, drop the duplicate index (migration), tune GPS accuracy, dispose controllers, shrink assets.

## 10. Blocked checks and required access

| Check | Needs | Entry in FINAL_USER_ACTIONS |
|---|---|---|
| Use the speed-engineer skill file | Attach `speed-engineer-SKILL.md` to the chat (or commit it); then re-run this checklist | new |
| Production latency, DB round trip, cold starts | Approval to call `valunivo.vercel.app/healthz/latency` a few times, or Vercel Observability (paid; not authorised) | new |
| Mirror traffic per day | Cloudflare analytics token (already step 3) | 3 |
| Production compression | Approval for 3 read-only requests with `accept-encoding` | new |
| Flutter runtime (startup, frames, memory, battery) | An Android device with a profile build plus Flutter DevTools (owner's PC) | new |
| Real data volumes | Read-only row counts from Neon (with the role audit, step 2) | 2 |

## 11. Confirmation

- No production change.
- No code modification on any branch; the only commit adds this report.
- No production data access beyond one read-only listing of web bundle sizes on Hostinger.
- No credential, DNS, routing, billing or database-permission change.
- All load ran against an isolated local database with synthetic data. The production endpoint request needed approval and was
  **not** made.
