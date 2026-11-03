# Test results

| Suite | Where | Result | Date |
|---|---|---|---|
| API typecheck (`tsc --noEmit`) | cloud workspace, Node 22.23 | **0 errors** | 2026-11-04 00:35 |
| API integration (`npm test`, real PostgreSQL 16.15) | cloud workspace | **49 / 49 pass** (auth 9, attendance 7, requests 10, employees 7, KPI/eval/reports/finance/dashboard/notifications 11, security 5) | 2026-11-04 00:35 |
| Migrate empty DB + seed; second seed refused | cloud | pass | 2026-11-03 |
| `flutter analyze` | PC, Flutter 3.38 | **NOT RUN** — PC screen was locked/dark; script ready: `tools\pc\1-check-and-test.cmd` | — |
| `flutter test` (i18n parity, format, API client, widgets) | PC | **NOT RUN** | — |
| `flutter build web --release` | PC or GitHub Actions | **NOT RUN** | — |
| `flutter build apk --release` | PC or GitHub Actions | **NOT RUN** | — |
| End-to-end (app → API → PostgreSQL) per role | — | **NOT RUN** | — |
