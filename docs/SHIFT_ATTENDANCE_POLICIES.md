# Shift-based tracking, manager absence, absence threshold, unauthorized-exit tiers, notification preferences

Branch `feat/shift-attendance-policies` (excluded from Vercel deployments). Proposed migration
`db/proposed/094_shift_attendance_policies.sql` (+ `094_rollback.sql`) — **not** in `db/migrations`, so no deploy applies
it. Every code path is schema-tolerant: without 094 the API behaves as today (no incidents, no preferences, policies off).

## 1. Current state before this branch (audit)
| Area | Found |
|---|---|
| Tracking | Followed between check-in and check-out only — no shift end, no leave / holiday check; the sweep's alerts ran past the shift end. Pending requests never authorized an exit (correct). |
| Unauthorized exit | Audit row + notifications only; no incident record, so no deduction could be traced or applied once. |
| Absence | A working day without a check-in = absence; lateness never became absence. No threshold setting existed. |
| Deductions | Late / early fixed tiers (`late_tiers`, `early_tiers`), per-minute or hourly modes; payroll computed live from stored data, frozen only in payroll-sheet snapshots. |
| Manager routing | Requests / outings snapshot the direct manager; "no manager" → general manager (leave) or HR — reused for an away manager. Watchers = HR + team managers. |
| Notifications | One `notify()`; the existing «إعدادات الإشعارات» page only stored push / sound / vibration on the phone (no categories, nothing on the server). |

## 2. Behaviour by feature
**Shift-based tracking** (`lib/attendance-policy.ts shiftEligibility`, `tracking.ts`): `/tracking/ping` and `/tracking/config`
answer `tracking:false` / `enabled:false` with a reason (`before_shift`, `shift_ended`, `on_leave`, `holiday`,
`not_working_day`) outside the scheduled shift of the day, on approved full-day leave and on holidays; check-in /
check-out keep their existing answers (409), so older APKs keep working and simply stop when told. The sweep's
follow-up alerts and phone calls run only inside the shift. `/tracking/config` also returns `endsInMinutes`.
Approved outings: an exit inside an approved, not-yet-returned, not-expired outing stays authorized (unchanged).
**Device compatibility gate:** the server rule is authoritative, but older APKs may still run their own local alarm
logic; keep company tracking OFF until updated phones are validated.

**Unauthorized exit incidents** (`exit-incidents.ts`, table `unauthorized_exit_incidents`): the first ping outside with no
approved permission opens one incident (`permission_state` none / pending / expired — a pending request is recorded,
never treated as approval). Unique indexes: one open incident per employee, one per exit instant (replays, a second
phone, parallel requests never open another). Closed once: back inside (no other phone outside), check-out, or the
shift end (sweep) — minutes = exit → earlier of return and shift end; the tier and the amount are frozen then. A later
approval of the request changes nothing; the only correction is `POST /attendance/exit-incidents/:id/reverse`
(payroll.approve, not one's own, reason ≥ 3, refused once that month's salary was received → use an approved bonus
adjustment). A trigger keeps the exit record and frozen figures immutable and forbids DELETE.

**Payroll exactly once** (`payroll-calc.ts`): the month's closed incidents with an amount are summed into the automatic
deductions (`unauthorizedExit: {incidents, amount}`), read-only; nothing is written to payroll, so recalculation never
adds it twice; payroll-sheet snapshots freeze it like every other figure. Subject to `payroll_auto_deductions` like the
late / early deductions.

**Sales manager leave / absence** (`presence.ts awaySet`): away = approved full-day absence today, or (only when the
absence threshold is configured) a working day past the threshold with no check-in. An away manager is skipped as a
request's first-stage approver (routed as when there is no manager: general manager for a leave, otherwise HR, who is
authorized), is not told about outings (HR still is; he stays the outing's manager), and is not a watcher (exit alarm,
late / absence / tracking alerts). The audit row of the request records `managerAway`. Restored automatically when he
is back. Nothing is approved or rejected for him.

**Absence threshold** (`attendance-calc.ts`): off by default; `fixed_hours` (needs its hours) or `half_shift` (half of
the day's own scheduled shift stored on the attendance row). A check-in at / after the threshold on a working day makes
the day an absence — the timestamps are kept, the day is not also counted as late (no double counting), an approved
hourly permission is used first. Before the threshold: never an absence. Absence requests keep their existing rules
(duplicate / overlap checks unchanged). Nothing creates or approves leave.

**«شرائح خروج بدون إذن»** (settings, `late_rules_page.dart`): a separate list `{fromMinutes, toMinutes|null, amount,
enabled}`, validated server-side (whole minutes, `to > from`, positive amount, ≤ 10 tiers, no overlap among enabled
tiers; priority = ascending start). The deduction switch is refused without an enabled tier. Existing late / early tiers
are untouched.

**«إعدادات الإشعارات»** (`notification-prefs.ts`, `notification_preferences_page.dart`): `GET/PUT /me/notification-preferences`.
Categories reuse the existing types: unauthorized_exit, outings, requests, lateness_absence, attendance, finance,
announcements. A preference only suppresses (in-app row and push together); it never adds a recipient. Always delivered
(not categories): security alerts, «إنت برة المكتب», the payment code, the follow-up calls, and every type outside the
categories. Locked: owners (everything), HR approvers (approvals and the exit alarm). The exit-alarm category is offered
only to people who follow others. No row = on. History is never deleted. Away-manager routing applies before preferences.

## 3. Migration 094 (proposed) — schema impact
* `company_settings`: `absence_threshold_mode text NULL`, `absence_threshold_hours numeric(4,2) NULL`,
  `unauthorized_exit_tiers jsonb NOT NULL DEFAULT '[]'`, `unauthorized_exit_deduction boolean NOT NULL DEFAULT false`
  (+ 2 CHECKs). All off / empty: nothing changes until the company sets them.
* new table `unauthorized_exit_incidents` (+ 2 indexes, guard trigger); new table `notification_preferences`.
* Additive; no existing row changed; re-runnable. Applied on a throwaway branch of production (`verify-093-2026-11-26`):
  clean, settings off. Rollback `094_rollback.sql` refuses once any incident carries an amount.

## 4. Settings and proposed defaults (owner decides)
| Setting | Default in 094 | Proposal for review |
|---|---|---|
| absence threshold mode | off | choose fixed hours or half shift |
| absence threshold hours | none | e.g. the owner's number (fixed mode only) |
| exit tiers | none | the owner's tiers and EGP amounts |
| exit deduction | off | on only after the tiers are approved |
| notification preferences | everything on | — |

## 5. Owner decisions still open
1. Exit duration rule: implemented as exit → earlier of return / check-out and shift end. Confirm (or: always exit → shift end).
2. Whether the exit deduction follows the global «تفعيل الخصم من المرتب» switch (implemented: yes, like late / early).
3. Away = approved leave, or no check-in past the absence threshold — confirm both count.
4. The threshold values, the exit tiers and their amounts; approval of migration 094.
5. Outing with the manager away and no HR approver configured: nobody is notified; confirm HR always exists (or name a fallback).
