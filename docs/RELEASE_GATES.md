# Release completion gates (added 2026-11-26)

A green CI run or a signed APK is **not** an approved release. A release is approved only when every gate below is
PASS or has been explicitly accepted by the owner. Order: 1 → 2 → 3 → 4 → 6 → 7 → 5 (devices last, on the final build).

Status as of 2026-11-26, source `main` @ `a9043b2` (production API, web) plus release-gate checks on
`feat/marketing-intelligence` (test and workflow changes only).

| # | Gate | Status | Owner action |
|---|---|---|---|
| 1 | Security remediation | **BLOCKED (owner)** | Decide on the paused remediation (see 1a) |
| 2 | Centralized permissions, backend enforcement | PASS (code), P-1 open | Policy decision P-1 |
| 3 | Finance and payroll integrity | PASS (tests); production has no financial records yet | F-1, F-2 decisions |
| 4 | Backup and restore | **BLOCKED (owner)** | Set the GitHub BACKUP_TOKEN secret; provide one encrypted export for a restore drill |
| 5 | Real Android device acceptance | **NOT STARTED (owner, physical devices)** | Device test on the final build |
| 6 | Operational workflows | Implemented and tested; **production is not configured** | Office locations, teams, tracking switch |
| 7 | Web and Windows artifacts | PASS (web live; Windows 1.0.46 built and update-tested, not published) | — |

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

## 2. Centralized permissions
- `api/test/zero-permission-sweep.test.ts` (CI 45782791359: PostgreSQL 16 / 18 647 pass 0 fail, least-privilege 647): an active employee with every permission individually denied calls every
  registered route directly (unknown ids and other people's real ids). Result: no 500, no record of another employee
  returned, 44–45 self-service routes answer 2xx (own profile, own attendance, own requests, company info, pickers).
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
requires it OFF until devices are validated — switch it off from Company info so the change is audited). The overdue
and reminder sweeps run on the owner's minute heartbeat (Apps Script → `/backup/sweep`), last seen 2026-11-26.

## 7. Artifacts
| Artifact | Version | Source | SHA-256 |
|---|---|---|---|
| Web (jaurea.com/valunivo) | web-1.0.196 | `a9043b2` (run 45745747425) | release zip `bf28951b…de57a` |
| Android candidate (NOT approved) | 1.0.197 (197) | `a9043b2` (run 45746471417) | APK `87d89289…3ec755d` |
| Android published | v1.0.194 | — | (unchanged) |
| Windows published | windows-v1.0.44 | `0d23322` (2026-11-23) | installer `e0ffca6d…64901` |
| Windows verification build (not published) | 1.0.46 | `a9043b2` (run 45781834226: build, smoke, install/uninstall, update end-to-end all passed) | artifact windows-out `e3b44b51…ad938b2` |
