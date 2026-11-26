# Real-device test checklist — shift attendance policies (Android release 1.0.207)

Every test below is **PENDING USER REAL-DEVICE TEST**. Real employees and real phones only; no simulated GPS.
Server evidence: Neon SQL editor (production), read-only queries. The absence threshold, the exit tiers and the exit
deduction stay OFF until you set them; while OFF, incidents are recorded with **no amount**. Incident / preference tests
need migration 094 applied (it is applied by the production deploy of PR #23).

Common preconditions: the employee has a work schedule; the office location is correct; company tracking
(متابعة الموظفين أثناء الشيفت) is ON; the employee's own «تتبع أثناء العمل» is ON; Android location «Allow all the time»;
battery optimisation for the app «Unrestricted» unless the test says otherwise.

| # | Test | Phone actions | Expected app | Expected server / DB | Evidence | PASS when |
|---|---|---|---|---|---|---|
| 1 | Foreground tracking | Check in at the office during the shift; app open 15 min | «الحضور شغال» notification | `SELECT at, inside FROM tracking_pings WHERE employee_id='<id>' ORDER BY at DESC LIMIT 5` — a row each interval, inside = true | screenshot + query | a row every interval |
| 2 | Background | Home button; other apps 20 min | notification stays | pings continue | query | no gap > 2 intervals |
| 3 | App closed | Swipe the app out of recents, 20 min | notification stays (service) | pings continue | query | pings continue |
| 4 | Doze / battery | Battery «Optimised», screen off 60 min | — | note gaps | query + phone model / Android version | result recorded (device-dependent) |
| 5 | GPS off / on | Location off 10 min, then on | no crash | pings stop, then resume | query | resumes without signing in again |
| 6 | Permission changes | «Only while using» → «Deny» → «Allow all the time» while running | no tracking while denied | no pings while denied | query | tracking only with permission |
| 7 | Precise vs approximate | Turn «Use precise location» off | — | large accuracy_m; a fix weaker than 200 m never counts as leaving | `SELECT accuracy_m, inside …` | no false exit alarm |
| 8 | Secure storage | App info → Clear storage; reopen | sign-in screen | old token refused (401) | screenshot | signed out; no tracking until signed in |
| 9 | Shift start | Check in 15 min before the shift start; keep the app open | not followed before the start | `/tracking/config` = `before_shift`; first ping after the start | query | first ping ≥ start (≈30 s after it with the app open; at the next app open when closed) |
| 10 | Shift end | Stay checked in past the shift end | notification goes | pings refused `shift_ended`; an open incident closes at the shift end | query | no ping after the end |
| 11 | Approved outing | Request a visit, approve it, leave, return before its time | no alarm | `outing_requests.returned_at` set; no row in `unauthorized_exit_incidents` | query | no incident |
| 12 | Unauthorized exit | Leave with no permission ≥ 15 min, then return | alarm on the phone | one row: status closed, end_reason returned, amount_egp NULL (deduction OFF) | query + alarm screenshot | exactly one row, no amount |
| 13 | Expired outing | Approved visit; stay out past its return time; return | overdue alert | one row, permission_state expired, exit_at = first report after the time | query | one row, starting after the return time |
| 14 | Two devices | Same account on two phones; one at the desk, go out with the other | one alarm per exit | one incident; the desk phone never ends a visit | query | one incident |
| 15 | Update | Phone on 1.0.194: open the app → update prompt → install | installs over the old app; still signed in | — | screenshots of both versions | no uninstall, data kept |
| 16 | Routing | Team member sends a request while his manager is on approved leave | manager gets nothing; HR does | `SELECT recipient_id, type FROM notifications ORDER BY created_at DESC LIMIT 10` | query | routed to HR / next approver |
| 17 | Network loss | Airplane mode 10 min in the shift, then off | — | queued points arrive (offline = true); no alarm for old points | query | points arrive after reconnect |
| 18 | Restart / session | Restart the phone during the shift, open the app | still signed in | tracking resumes | query | resumes without signing in |
| 19 | Absence after check-in | After checking in, request a full-day absence for today | refused («attendance exists») | no request row | screenshot | refused |
| 20 | Older app | A phone still on 1.0.194 during the shift | works | pings refused outside the shift | query | stops outside the shift |
