# Security audit — 2026-11-04

Detailed role matrix and DB-level invariants: `SECURITY_MATRIX.md`.

## Verified by tests (49/49)
- Every non-public route rejects anonymous calls (route sweep over all 80 routes).
- Sales Employee is refused on 30 management routes; never sees another employee's profile, attendance, requests, KPI or evaluations (404, no id probing).
- Sales Manager limited to own teams; no HR or finance rights. Accountant cannot approve HR requests; sees payroll view only.
- Self-approval impossible at every stage (API + DB CHECK); final approval only at HR stage (DB trigger); approval history append-only.
- Attendance originals immutable, rows undeletable, corrections fully recorded; nobody corrects own attendance.
- Salary never returned to readers without `employee.salary_read`, including history/audit; never on employee-facing screens.
- Passwords scrypt-hashed, never returned; lockout after 5 failures; forced change of temporary passwords; sessions revoked on logout/deactivation/password change.
- CORS exact allow-list; malformed input → 4xx, never 500.

## Findings / gaps (honest)
| # | Item | Severity | Status |
|---|---|---|---|
| S1 | **Device-bound login is NOT implemented** (the new brief lists it as existing; it is a Value HR feature only) | Medium | Open — needs your decision |
| S2 | **Selfie at check-in is NOT implemented** (geofence is) | Low/Medium | Open — needs your decision; adds photo storage + retention |
| S3 | **Automatic late/absence deduction tiers are NOT implemented** — finance is manual adjustments with four-eyes approval | Medium (business) | Open — needs your rules |
| S4 | Android patch enables cleartext HTTP for LAN testing; production must use the https API URL | Low | Documented; disable for store builds |
| S5 | No rate limiting beyond login lockout (Render free has no WAF) | Low | Open |
| S6 | Production DB permissions: app should use a non-owner Neon role | Medium | To do at deployment |
| S7 | `pg` sslmode=require with Neon's public CA chain | Info | To verify on first connect |

No secrets exist in the repository (`.gitignore` covers `.env*`, keystores).
