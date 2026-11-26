# Release completion gates (added 2026-11-26)

A green CI run or a signed APK is **not** an approved release. A release is approved only when every gate below is
PASS or has been explicitly accepted by the owner. Order: 1 → 2 → 3 → 4 → 6 → 7 → 5 (devices last, on the final build).

Status as of 2026-11-26 (second pass). Evidence: API CI 45787702396 (PostgreSQL 16 / 18 and least-privilege: 649 pass,
0 fail, installed with `npm ci` from the committed lockfile), app CI 45785434987 (analyze, 83 Flutter tests, web build),
app-check 45785421233 (Android release build check), Windows 45785439879 (build with the locked dependencies).

| # | Gate | Status | Owner action |
|---|---|---|---|
| 1 | Security remediation | Engineering checks PASS; **acceptance BLOCKED (owner)** | Accept the security gate (1a) |
| 2 | Centralized permissions, backend enforcement | PASS; P-1, P-2 policy open | Policy decisions P-1, P-2 |
| 3 | Finance and payroll integrity | PASS (tests); production has no financial records yet | F-1, F-2 decisions |
| 4 | Backup and restore | **BLOCKED (owner)** | Set the GitHub BACKUP_TOKEN secret; provide one encrypted export for a restore drill |
| 5 | Real Android device acceptance | **NOT STARTED (owner, physical devices)** | Device test on the final build |
| 6 | Operational workflows | Implemented and tested; **production is not configured** | Tracking OFF, office locations, teams |
| 7 | Web and Windows artifacts | PASS (web live; Windows 1.0.46 built and update-tested, not published) | — |

## Independent verification of the two original NO-GO findings (2026-11-26, third pass)
**NO-GO 1 — Android token falling back to plain SharedPreferences.** Every token path traced (`TokenStore.read/write/clear`,
`Session.restore/login/logout/_clear`, the background isolate in `shift_service.dart`, `SessionService.logout`):
- new session: written to Keystore-backed storage and read back; on failure memory-only, plain key removed;
- older plain session: removed from disk in every case (memory-only if the secure storage refuses) — fixed in `684b392`;
- sign-out whose secure delete fails (found in this pass): a «signed out» mark now prevents restoring the left-over
  encrypted copy at the next start, and survives the screen-session prefs wipe — fixed in `6a0b90b`;
- no other code writes the session token to SharedPreferences (only `fcm_token`, screen-session fields, `me_cache`);
- residual, by design: the background isolate cannot read a memory-only session, so in-shift tracking stops (fails
  closed) on a phone whose Keystore refuses; the web build keeps its token in browser storage.
Tests (Flutter, 84 pass, run 45790382971): legacy session with a refusing storage, new session with a refusing storage,
sign-out whose delete fails then restart.

**NO-GO 2 — permission-check failures read as grants.** Server: `has()` needs a registered key held by the account;
`can()` fell back to the pre-migration rule (open to everyone for 5 keys) whenever a fine key was absent from the table.
Fixed in `5a7983e`: no key list → deny; a key absent while its migration is recorded in `schema_migrations` (or that
record is unreadable) → deny; only a database where the migration genuinely has not run keeps the old rule. A database
error is a 500, never a grant. App: permissions start empty and stay empty when `/me` fails; a 401 clears the session.
Tests (API, PostgreSQL 16 / 18 + least-privilege, 656 pass 0 fail, run 45792196968): pure rules, and the real export
route on production's schema with `report.export` removed → 403 for owner / HR / employee and absent from `/me`.

**Scheduled jobs:** GitHub runs this repository's schedules hours late or not at all (meta-sync: no run since it
reached main; files-health: one run in 14 h). Failure visibility only exists when a run happens; the attendance sweeps
do not depend on GitHub (owner's Apps Script heartbeat, seen in production logs 2026-11-26).

## 1. Security remediation
- `pending-build` is fully contained in `main` (0 ahead / 132 behind). It was not modified.
- **1a — material finding.** The paused remediation commits from `security/reverify-2026-11-24` (G1 device-authorised
  punches, G2 weak GPS, T2 never-pinged alert, L1/L2, Meta webhook fail-closed, C1 retired-project guard, migration lock)
  were landed on `main` on 2026-11-25 09:04 UTC (`1d2ed28`, `6fb8fa8`, `4378b56`, `47369b6`, `b2bdfb9`, before this
  release) and are therefore already in production, in published Android v1.0.194, and in candidate 1.0.197.
  The owner must either ratify them (gate closes) or name the NO-GO reasons to address. Nothing was reverted: a revert
  would be a production change.
- Verified in code: Android session token in Keystore-backed secure storage, never written in plain text (fail closed to
  memory-only); Windows DPAPI; release manifest forbids cleartext / backups / debuggable (build-time guard); session =
  random 256-bit token, SHA-256 stored, revoked on logout / password change / deactivation; unregistered permission keys
  are denied; owner-only keys are never held by non-owners; settled accounts hold nothing.
- Production permission registry = code registry exactly (110 keys, no drift), so no fine-grained check falls back to
  an open pre-066 rule.
- Open, low: Dependabot alert 1 — `esbuild` < 0.25.0 (GHSA-67mh-4wv8-2f99, dev-server only, medium); web session token
  lives in browser storage (XSS exposure inherent to the web build).
- **Candidate APK 1.0.197 (run 45746471417) is a verification build only — not an approved release** while 1a is open.
  No further APK will be built or signed until the owner closes gate 1.

- **Second pass (2026-11-26):**
  - Android: an older plain-text session is now removed from disk in every case; if the Keystore-backed storage refuses
    it, it lives in memory for this run only (before, the plain copy stayed on disk). Tests for a refusing storage.
  - App permission checks fail closed: the permission set starts empty and stays empty when `/me` fails; the server
    decides every request anyway.
  - The 2026-11-24 re-verification findings (G1 device-authorised punches, G2 weak GPS, T2 never-pinged alert, L1/L2
    token-protected scheduler routes, Meta webhook fail-closed, C1 retired project returns 410, migration lock) are in
    `main` with their regression tests (device-punch 7, tracking-health 6, migrate-guard 3, migrate-concurrency 1,
    leads-daily 3, meta_sync 5, security-rules-unit 11) — all passing. No separate NO-GO list exists in the repository
    or the project files; if the owner's NO-GO had other reasons, they must be named.
  - Supply chain: `api/package-lock.json` and `app/pubspec.lock` are now committed; Vercel and CI install with
    `npm ci`, every Flutter build with `--enforce-lockfile` (before, each deploy and APK resolved versions afresh).
    Dependabot GHSA-67mh-4wv8-2f99 closed by the `esbuild >= 0.25.0` floor (locked 0.28.2).
  - Residual (by design, documented): device authorisation is the server's record of an approved device, not hardware
    attestation (no Play Integrity); one active sales employee has device lock off in production (owner's setting).

## 2. Centralized permissions
- `api/test/zero-permission-sweep.test.ts` (CI 45782791359: PostgreSQL 16 / 18 647 pass 0 fail, least-privilege 647): an active employee with every permission individually denied calls every
  registered route directly (unknown ids and other people's real ids). Result: no 500, no record of another employee
  returned, 44–45 self-service routes answer 2xx (own profile, own attendance, own requests, company info, pickers).
- Cross-team IDOR (same test file): a team-B sales employee and team B's manager, with their default permissions, call
  every route with team A's real ids — no team A record comes back. By-design company-wide lists are checked by content:
  «الأفضل» ranking (names only, another team's numbers hidden), the brokerage colleague picker (id / name only).
- **P-2 (policy):** the leads dashboard's online list (owner decision 2026-11-23) shows a sales manager every lead
  worker online in the last 10 minutes company-wide (id / name / last seen). Owner decides whether it should be his team.
- **P-1 (policy):** `GET /teams` (org chart: team, department, manager name/id, member count) is readable by every
  signed-in employee. Not contact or salary data. Owner decides whether the org chart is company-wide.

## 3. Finance and payroll
- Covered by CI (PostgreSQL 16 and 18, least-privilege role): parallel / double-tap tests for opening balance, receipts,
  expenses, approvals, reversals, transfers, payout codes, sales and installments, payroll sheet creation / approval /
  line payment; F1–F7 integrity tests; closed-year guards.
- Database-level immutability triggers present in production on audit log, cash receipts / expenses / transfers /
  adjustments / bank moves, payouts, commission requests, sale installments, unit sales, brokerage, closed periods.
- Production reconciliation (read-only, 2026-11-26): 0 payouts, receipts, expenses, advances, entitlements, payroll
  batches, sales — no duplicates possible to find yet. Re-run after the first real month.
- **F-1 (owner rule):** an advance / work-expense payout not linked to a request is accepted and never deducted from
  payroll (documented in FINANCIAL_INTEGRITY_2026-11-22.md).
- **F-2 (defence in depth, needs a migration → owner approval):** `payroll_batch_lines` has no database guard; an
  approved sheet's lines are protected by the API only. Proposed: a trigger refusing UPDATE/DELETE of lines whose batch
  is not draft / returned.

## 4. Backup and restore
- **Minimum owner action:** (1) GitHub → Settings → Secrets and variables → Actions → New repository secret
  `BACKUP_TOKEN` = the same value as the Vercel production `BACKUP_TOKEN` (this environment cannot read or create
  secrets); (2) for the restore drill, attach one encrypted export file from Google Drive and run `tools/backup-decrypt.mjs`
  locally with the backup key (the key never leaves your machine) — or authorise a session to receive both.
- The restore procedure itself is proven in CI on every run: «backup (encrypted, as on Drive) → restore into a new
  database: every table, same rows, same content».
- API host: `BACKUP_TOKEN` and `BACKUP_ENCRYPTION_KEY` are set (Production). Exports are refused without the key.
- **GitHub repository secret `BACKUP_TOKEN` is NOT set** (proved by the leads-report and files-health run logs). Until
  now those runs passed with a warning — a false success. Fixed: they now FAIL when the secret is missing, the API does
  not answer, or the health endpoint is absent. `meta-sync.yml` already failed.
- Neon recovery point `pre-092-2026-11-26` compared with production table by table: all 113 business tables identical;
  the only differences are 092's four new tables, +1 permission, +1 role grant, +1 migration row.
- **Not done (owner):** an application-level restore drill needs one real encrypted export (owner's Google Drive) and
  the backup key, which are not available to this environment. Procedure: restore into a new Neon branch with
  `tools/backup-decrypt.mjs`, compare per-table counts and FK checks with production. Never against production.

## 5. Real Android device acceptance (owner, physical devices)
Install v1.0.194 → upgrade to the final build (same certificate SHA-256 `212e2a9b…7e2c54`, package
`com.jph.valueattendance`, versionCode increases); then OTP, session persistence after restart, notifications
(foreground / background / killed), runtime permissions, background execution, GPS, geofence enter/exit, check-in /
check-out / permission-hours / «I'm back». No simulated location or emulator substitutes this gate.

## 6. Operational workflows
Implemented with server-side tests: attendance and departure (device-authorised), permission hours / visits with an
expected return time, approval, overdue alert to the employee and watchers, manager / HR / owner notifications,
employees and permissions, finance / commissions / advances / expenses / payouts, KPI dashboards, audit and protected
records. Production configuration gaps (owner): **0 office locations** (geofence cannot work), **0 teams / departments**
(no manager routing beyond HR), **company tracking is ON** (switched on by the owner 2026-11-25 10:36 UTC; this gate
requires it OFF until devices are validated). It could not be switched off from here: no signed-in session exists in
the connected browser and signing in needs your password. Action: sign in as owner → بيانات الشركة (Company info) →
turn off «متابعة الموظفين أثناء الشيفت» (company tracking) → save; the change is audited (`settings.update`). The overdue
and reminder sweeps run on the owner's minute heartbeat (Apps Script → `/backup/sweep`), last seen 2026-11-26.

## Android release configuration (verified in `app/tool/patch_android.dart` and the release workflow)
Package `com.jph.valueattendance`; release signed only with the repository key (the candidate workflow refuses a
debug-signed build and checks the certificate equals the published one); manifest guard refuses cleartext, backups and
debuggable; location in a foreground service of type `location` (no background-location permission — the service
starts at check-in from the foreground; behaviour after a phone restart is a device-test item); OTA updates via
`REQUEST_INSTALL_PACKAGES` (side-loaded distribution, not Play). Dependencies now locked. No release-blocking defect
found in configuration; physical-device behaviour is NOT verified.

## 7. Artifacts
| Artifact | Version | Source | SHA-256 |
|---|---|---|---|
| Web (jaurea.com/valunivo) | web-1.0.196 | `a9043b2` (run 45745747425) | release zip `bf28951b…de57a` |
| Android candidate (NOT approved) | 1.0.197 (197) | `a9043b2` (run 45746471417) | APK `87d89289…3ec755d` |
| Android published | v1.0.194 | — | (unchanged) |
| Windows published | windows-v1.0.44 | `0d23322` (2026-11-23) | installer `e0ffca6d…64901` |
| Windows verification build (not published) | 1.0.46 | `a9043b2` (run 45781834226: build, smoke, install/uninstall, update end-to-end all passed) | artifact windows-out `e3b44b51…ad938b2` |
