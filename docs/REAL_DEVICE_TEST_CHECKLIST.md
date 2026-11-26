# Real-device test checklist — shift attendance policies

Production state for these tests: migration 094 is **not** applied. So the absence threshold, the exit tiers / deduction,
the incident records and the notification-preference screen are not active (the app shows «not available yet» / hides
those sections). Tests marked *(after 094)* can only be done after section A of `MIGRATION_094_DEPLOYMENT.md`.

| # | Test | Expected |
|---|------|----------|
| 1 | Update the installed app from the in-app update prompt (no uninstall) | New version installs over the old one; data and login kept |
| 2 | Login, close the app, reopen; restart the phone | Still signed in; logout signs out everywhere it should |
| 3 | Check in before the shift start, keep the app open past the start | Not followed before the start; followed shortly after it (the open app re-checks ~30 s after the start). With the app closed: starts at the next app open (Android gives no guaranteed wake-up) |
| 4 | Check out; also stay past the shift end without checking out | Following stops (server says not eligible); the notification disappears |
| 5 | Approved visit / hourly permission: leave, come back before the time | No unauthorized-exit alarm; the return is recorded |
| 5b | Same, but stay out past the return time | «Outing overdue» alerts; *(after 094)* one incident from the first report after the time |
| 6 | Leave the office with no permission | Alarm on the phone, HR / managers alerted; *(after 094)* one incident, closed on return / check-out / shift end |
| 7 | Deny location permission (and «only while using») | No tracking starts; nothing crashes; attendance still works |
| 8 | Clear the app's storage / secure storage while signed in | Asked to sign in again; background tracking stops; no plaintext token fallback |
| 9 | Two phones on one account, one left at the desk | One alarm per exit; a phone at the desk never ends a visit |
| 10 | Swipe the app away during the shift | Android: the background service keeps reporting (visible notification) |
| 11 | Battery optimisation on / Doze overnight / power saver | Note any gaps in reports; record the phone model and Android version |
| 12 | Manager on approved leave: a team member sends a request / leaves without permission | The manager gets nothing; HR / next approver gets it. *(after 094)* preferences screen: switch a category off and on |
| 13 | Full-day absence for today after already checking in | Refused («attendance exists»); the attendance stays as it was. *(after 094, threshold set)* before the threshold refused, after it allowed |
| 14 | Payroll view for a month with exits | No unauthorized-exit deduction: the deduction is off and has no tiers until the company sets them |
| 15 | An employee still on the previous app version | Works; tracking stops when the server says outside the shift |
