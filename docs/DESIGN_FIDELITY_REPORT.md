# Design fidelity report

## Source-level fidelity (done)
Original files copied verbatim into `app/lib/design/` (colours, light/dark themes) and the original widgets reproduced
value-for-value: GlassCard blur 14/18 · radius 26 · white 30 % border · shadow 28/(0,14); PrimaryButton 52 px · radius 16;
GlassBottomNav radius 40 · 72 px · active pill; AppBackground images + overlay gradients; Cairo 400/600/700; original logo & avatar.
Locked by `test/widget_test.dart` (design tokens). Full table: `DESIGN_SYSTEM.md`.

## Visual comparison (NOT DONE)
Screenshot-by-screenshot comparison needs the app running (`flutter run -d chrome`). Not yet possible — see TEST_RESULTS.md.
Planned pairs: login (light/dark, AR/EN), employee dashboard, attendance, requests/approvals, employees, settings, mobile 390 px and desktop 1280 px.

## Value HR (gorgesaa70-boop.github.io/value-hr-web) — comparison
| | Value HR (deployed) | Value Attendance (this project) |
|---|---|---|
| Source | Built bundle only in `gorgesaa70-boop/value-hr-web` (3 commits, latest 2026-10-25, author "Gorg") — **no source code** in the repo | Full source, tests |
| Stack | React (Vite) PWA + **Supabase** (`xbstncayxxsitxpemquz.supabase.co`, publishable key in bundle) | Flutter + own API + PostgreSQL |
| Look | Own navy theme (#0B1F3A), Cairo | Original JPH Attendance design |
| Login | Mobile number + 4–8 digit PIN, account bound to first device | Employee code/email/mobile + password (≥8, letters+digits); **no device binding yet** |
| Check-in | Selfie + geofence + background tracking during shift (Android) | Optional geofence; **no selfie, no tracking** |
| Requests | Hourly permission, casual/annual/sick/unpaid leave, mission; single admin approval | 5 types + **dual approval** (sales manager → HR) |
| Payroll | Automatic late/early/absence deductions with tiers, bonuses | Manual adjustments (four-eyes); payroll summary + Excel |
| Roles | Admin / employee | 5 roles with team scoping |
| KPI / evaluations / monthly reports | No | Yes |

**Can the URL `gorgesaa70-boop.github.io/value-hr-web/` become the official one?** Not safely by me: it belongs to a
different GitHub account, is a live app with its own Supabase data, and replacing it would take that app offline. Needs the
owner's explicit decision **and** push access. Recommended: a new repo under your account (e.g. `value-attendance`).
