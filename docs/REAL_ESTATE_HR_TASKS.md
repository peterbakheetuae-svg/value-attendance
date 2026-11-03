# Value Attendance — Task Board

Status legend: **VERIFIED** (tests/evidence run) · **WRITTEN** (code complete, not yet executed) · **BLOCKED** (external blocker) · **TODO**

## ▶ Resume checkpoint (2026-11-04 00:50)
- Brief v2 ("Value Attendance"): audit done — API 49/49 + typecheck re-verified; claims of **device-bound login, selfie, deduction tiers are NOT implemented** (see SECURITY_AUDIT S1–S3).
- Renamed to Value Attendance (app name, web title, Android label, API name). Deployment config added: `render.yaml`, `.github/workflows/{api-ci,app}.yml`, `docs/DEPLOYMENT.md`.
- Flutter 3.38 found at `D:\dev\flutter-3.38` (+ android-sdk, jdk-17). Script `tools\pc\1-check-and-test.cmd` writes logs to `build-logs\`. **Not yet run** (PC screen locked; terminals can't be typed into by screen control).
- Blocked on owner: run the script / unlock PC; GitHub repo with push access; Neon project; Render account (may require card verification → fallback Cloudflare Workers); decision on S1–S3 and on the value-hr-web URL.

### Earlier checkpoint
- Backend (Phases 0–13) **VERIFIED**: `api` typecheck 0 errors; **49/49** integration tests on real PostgreSQL 16; 80 routes, every non-public route returns 401 anonymously (test-enforced).
- Flutter app (Phases 14–15) **WRITTEN**, never compiled yet: no Dart/Flutter SDK was available in the build workspace.
- **Next exact step:** on the dev PC with Flutter ≥ 3.27 → `cd app` → `flutter create --platforms=android,web --org com.jph.realestatehr --project-name jph_real_estate_hr .` → `dart run tool/patch_android.dart` → `flutter pub get` → `flutter analyze` → fix → `flutter test` → T16.3 / T17.x.

| ID | Task | Depends | Acceptance criteria | Tests | Status | Evidence |
|---|---|---|---|---|---|---|
| T0.1 | Record original project state | — | Original repo identified, untouched | — | VERIFIED | HEAD ref `master`, last commit msg "chore: confirm Neon rotation…"; newest file mtime 2026-11-02 16:22 UTC; only read access used |
| T0.2 | Extract design system | — | Colours, themes, background, glass, button, nav, fonts, logo documented & copied | widget_test design tokens | VERIFIED (copy) | `docs/DESIGN_SYSTEM.md`; files under `app/lib/design`, `app/assets` |
| T0.3 | Functional audit of Value HR (Reference B) | — | Workflows mapped | — | VERIFIED | Site is login-gated; UI strings extracted from its bundle: phone+PIN login with device binding, selfie+geofence check-in, request types (hourly/casual/annual/sick/unpaid/mission), deduction tiers, audit log, holidays |
| T1.1 | Independent project + git | T0.1 | Separate folder & repo | — | VERIFIED | `D:\JPH\jph_real_estate_hr`, own git history |
| T2.1 | Core schema | T1.1 | Single company, roles/permissions, org, attendance, requests, notifications, append-only audit | migrations apply on PG16 | VERIFIED | `db/migrations/001_core.sql` |
| T2.2 | KPI/evaluations/finance schema | T2.1 | 100% weight at COMMIT; missing≠zero; published evals immutable; four-eyes finance | DB-level assertions in tests | VERIFIED | `002_kpi_evaluations_finance.sql` |
| T3.1 | Auth (scrypt, sessions, lockout, forced password change) | T2.1 | 5 fails → 15 min lock; generic errors; logout/deactivate revoke | auth.test.ts (9) | VERIFIED | |
| T3.2 | Central permission model + scoping | T3.1 | Backend-enforced; out-of-scope ids → 404 | security.test.ts (5) | VERIFIED | route sweep: 0 unprotected |
| T4.1 | Employees & departments | T3.2 | CRUD, deactivate (no delete), salary isolated, docs/photo, history | employees.test.ts (7) | VERIFIED | |
| T5.1 | Sales teams & manager assignment | T4.1 | Team manager must be Sales Manager (trigger) | employees.test.ts | VERIFIED | |
| T6.1 | Attendance | T5.1 | Check-in/out, no duplicates (row lock), late/early/overtime from schedule snapshot, geofence optional, monthly calendar | attendance.test.ts (7) | VERIFIED | |
| T6.2 | Corrections with full history | T6.1 | Originals immutable (trigger), reason, requester, approver, timestamp | attendance.test.ts | VERIFIED | |
| T7.1 | Requests (5 types) | T6.1 | Duration/working-days computed server-side; backdate limit; duplicates refused | requests.test.ts (10) | VERIFIED | |
| T8.1 | Dual approval Sales Manager → HR | T7.1 | Both required; reject needs reason; no self-approval; no-manager → HR; DB transition guard; immutable action log; notifications | requests.test.ts | VERIFIED | |
| T9.1 | KPI engine | T5.1 | Configurable defs; versioned sets; weights=100; snapshots; target/actual/achievement/weighted/prev/trend; states | kpi-eval-reports.test.ts | VERIFIED | |
| T10.1 | Evaluations | T5.1 | 8 dimensions; manager(team)/HR/owner; publish freezes + notifies; employee sees published only | kpi-eval-reports.test.ts | VERIFIED | |
| T11.1 | Monthly reports | T6–T10 | Employee & team reports from stored data; filters; incomplete period labelled; EGP only, money separate | kpi-eval-reports.test.ts | VERIFIED | |
| T11.2 | Excel export | T11.1 | Real .xlsx (RTL sheet) monthly + payroll | xlsx asserted (PK zip, mime) | VERIFIED (API) | |
| T11.3 | PDF / print | T11.1 | Arabic RTL PDF with Cairo font | — | WRITTEN | client-side `pdf`+`printing` in `reports_page.dart`; verify on device |
| T12.1 | Role dashboards | T6–T11 | Owner/HR/Sales Manager/Accountant/Employee shaped by permission | kpi-eval-reports.test.ts | VERIFIED (API) | |
| T13.1 | Notifications | T8–T10 | De-duplicated, private, read/unread | tests | VERIFIED (API) | |
| T14.1 | Flutter Web screens | T0.2, T3–T13 | All modules reachable per role, responsive ≤1100 px | widget tests | WRITTEN | 19 Dart files in `app/lib` |
| T14.2 | Flutter analyze + tests | T14.1 | 0 errors | `flutter analyze`, `flutter test` | BLOCKED here → run on PC | No Dart SDK in workspace (Google download hosts not reachable) |
| T15.1 | Android build | T14.2 | APK builds and runs; location only when GPS enabled | `flutter build apk` | TODO (PC) | |
| T16.1 | Security & regression suite | all API | All routes protected; role leaks; malformed input; CORS | security.test.ts | VERIFIED | |
| T16.2 | Security matrix doc | T16.1 | | | VERIFIED | `docs/SECURITY_MATRIX.md` |
| T16.3 | Real end-to-end (app ↔ API ↔ PG) | T14.2 | Login, check-in, request → manager → HR | manual + screenshots | TODO (PC) | |
| T17.1 | Screenshots from running app | T16.3 | Every role's main screens, AR + EN, light + dark | | TODO (PC) | |
| T17.2 | Final docs | all | README, run guide, limitations | | WRITTEN | README.md |
