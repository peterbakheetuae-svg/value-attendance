# Design fidelity report

## Source-level fidelity (done)
Original files copied verbatim into `app/lib/design/` (colours, light/dark themes) and the original widgets reproduced
value-for-value: GlassCard blur 14/18 · radius 26 · white 30 % border · shadow 28/(0,14); PrimaryButton 52 px · radius 16;
GlassBottomNav radius 40 · 72 px · active pill; AppBackground images + overlay gradients; Cairo 400/600/700; original logo & avatar.
Locked by `test/widget_test.dart` (design tokens). Full table: `DESIGN_SYSTEM.md`.

## Visual comparison (NOT DONE)
Screenshot-by-screenshot comparison needs the app running (`flutter run -d chrome`). Not yet possible — see TEST_RESULTS.md.
Planned pairs: login (light/dark, AR/EN), employee dashboard, attendance, requests/approvals, employees, settings, mobile 390 px and desktop 1280 px.

## Value HR feature parity (2026-11-04) — design stays the original JPH app
| Value HR capability | Value Attendance |
|---|---|
| Mobile + numeric PIN login | ✅ sales roles (4–8 digits); owner/HR/accountant keep passwords |
| Account bound to first phone, admin unlinks | ✅ owner exempt; HR unlinks from the employee profile |
| New PIN sent on WhatsApp | ✅ opens wa.me with the ready message, or copy |
| Selfie at check-in, auto-delete after N days | ✅ setting; compressed front camera; HR/manager view in the attendance log |
| Several offices with a radius | ✅ (+ "use my current location") |
| Check-in / check-out reminders, alerts to management | ✅ throttled sweep on normal traffic (no paid scheduler) |
| In-shift location follow-up (Android), left/returned/stopped alerts | ✅ foreground service; web only while the page is open |
| Payroll: day divisor 26/30, per-minute or tiered late/early, absence penalty, bonuses/admin deductions, net to date, Excel | ✅ off until enabled in “قواعد المرتبات” |
| Break (start/end, overrun alert) | ✅ (original JPH feature, now server-backed) |
| Extra in Value Attendance | 5 roles, dual approval, KPI, evaluations, monthly reports/PDF |

Home screen = the original employee dashboard: long-press animated fingerprint, attendance/break/leave tabs, glass right card, today log, this month.
