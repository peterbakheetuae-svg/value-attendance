# Value Attendance

*(project folder: `jph_real_estate_hr`)*

Independent, single-company HR & sales-team management system for a real-estate brokerage office.
**Web (Flutter Web) + Android (Flutter) + one shared API and PostgreSQL database.**
Visual identity is the original JPH Attendance design system (colours, Cairo font, background
images, glass cards, buttons, bottom navigation), copied into `app/lib/design/`.

This project is **separate** from JPH Attendance. Nothing in `D:\JPH\jph_attendance\` is modified,
and this project never touches its database, Firebase project, API or deployment.

```
jph_real_estate_hr/
├── api/          Node 22 + TypeScript HTTP API (no framework; only dependency: pg)
│   ├── src/      modules: auth, employees, org, attendance, requests, kpi, evaluations,
│   │             reports (+ .xlsx), finance, dashboard, notifications
│   └── test/     49 integration tests against a real PostgreSQL
├── db/migrations 001_core.sql, 002_kpi_evaluations_finance.sql
├── app/          Flutter app (Android + Web), Arabic-first RTL, English
│   ├── lib/design/  original JPH design system (AppColors, themes, GlassCard, PrimaryButton, GlassBottomNav…)
│   ├── lib/core/    API client, session, i18n, formatting
│   ├── lib/pages/   all screens
│   └── assets/      original backgrounds, logo, Cairo fonts; l10n ar/en
└── docs/         task board, completion log, security matrix, run guide
```

## Run locally (Windows)

### 1. Database (PostgreSQL 14+)
Create an **empty, dedicated** database — never reuse the JPH Attendance database:
```powershell
createdb -U postgres jph_real_estate_hr
```

### 2. API
```powershell
cd api
npm install
$env:DATABASE_URL = "postgres://postgres:<password>@localhost:5432/jph_real_estate_hr"
$env:EXPECT_DATABASE = "jph_real_estate_hr"
npm run migrate
npm run seed:dev          # creates the first owner (prints a one-time password) + demo org (optional --demo)
$env:CORS_ORIGINS = "http://localhost:8096"
npm run dev               # http://127.0.0.1:8095  (HOST=0.0.0.0 to reach it from a phone on the LAN)
```
Tests (need a PostgreSQL user that may CREATE DATABASE; they create and drop `hr_t_*` databases):
```powershell
$env:TEST_PG_URL = "postgres://postgres:<password>@localhost:5432/postgres"
npm test
npm run typecheck
```

### 3. App (Flutter ≥ 3.27, Dart ≥ 3.5)
The platform folders are generated once on your machine:
```powershell
cd app
flutter create --platforms=android,web --org com.jph.realestatehr --project-name jph_real_estate_hr .
dart run tool/patch_android.dart
flutter pub get
flutter analyze
flutter test
```
Web:
```powershell
flutter run -d chrome --web-port 8096 --dart-define=API_BASE_URL=http://localhost:8095
flutter build web --release --dart-define=API_BASE_URL=https://<your-api-host>
```
Android (phone on the same Wi-Fi; API started with `HOST=0.0.0.0`):
```powershell
flutter build apk --release --dart-define=API_BASE_URL=http://<PC-LAN-IP>:8095
```

## Roles
Owner · HR Manager · Sales Manager · Accountant · Sales Employee — see `docs/SECURITY_MATRIX.md`.
Every permission is enforced by the API (and the key invariants again by database triggers);
the app only hides what the API would refuse anyway.
