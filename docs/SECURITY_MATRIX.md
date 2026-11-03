# Security & role matrix

All rules are enforced in the API (`api/src`); the starred ones are enforced **again by PostgreSQL** so a bug in the API cannot bypass them.

## Roles → permissions (default; owner may edit except Owner and Sales Employee)

| Capability | Owner | HR Manager | Sales Manager | Accountant | Sales Employee |
|---|:-:|:-:|:-:|:-:|:-:|
| Own dashboard, check-in/out, own attendance, own requests, own KPI, own published evaluations, own monthly report | ✔ | ✔ | ✔ | ✔ | ✔ |
| Read employees | all | all | own teams (card only, no private contact) | — | self |
| Create / edit / deactivate employees | ✔ | ✔ (not Owner/HR/Accountant roles) | — | — | contact fields of self |
| Salary read / change | ✔ / ✔ | — | — | ✔ / — | — |
| Departments & teams | ✔ | ✔ | — | — | — |
| Attendance read | all | all | own teams | — (payroll summary only) | self |
| Attendance correction | ✔ | ✔ | — | — | via request |
| Schedules, holidays, office locations | ✔ | ✔ | — | — | — |
| Requests read | all | all | own teams + routed to them | — | self |
| Approve — manager stage | ✔ (if assigned) | — | ✔ own teams only | — | — |
| Approve — HR stage | ✔ | ✔ | — | — | — |
| Leave balances | ✔ | ✔ | — | — | read own |
| KPI configure | ✔ | ✔ | — | — | — |
| KPI enter actuals | ✔ | ✔ | own teams | — | — |
| Evaluations write | ✔ | ✔ | own teams | — | — |
| Monthly reports | company | company | own teams | payroll summary | self |
| Financial adjustments create / approve | ✔ / ✔ | — | — | ✔ / ✔ | — |
| Company settings, role permissions | ✔ | — | — | — | — |
| Audit log | ✔ | ✔ | — | — | — |

## Invariants
| Rule | Where |
|---|---|
| No one approves their own request (any stage) | API + `CHECK (manager_id <> employee_id)`* |
| Final approval only from the HR stage; terminal requests never change | trigger `requests_transition_guard`* |
| Request action history is append-only | trigger*|
| Rejection requires a reason | API + `CHECK` on `request_actions`* |
| Sales Manager acts only on requests routed to them (snapshot) | API |
| No one corrects their own attendance; originals write-once; attendance never deleted | API + `CHECK (approved_by <> employee_id)`* + triggers* |
| Duplicate check-in impossible | `UNIQUE (employee_id, work_date)`* + row lock |
| Team manager must be a Sales Manager | trigger* |
| KPI weights = 100 % per set; used sets frozen; missing ≠ zero | deferred constraint trigger*, trigger*, `CHECK`* |
| Published evaluations immutable; nobody evaluates themselves | trigger*, `CHECK`* |
| Finance: creator ≠ approver ≠ subject; EGP only | `CHECK`* |
| Audit log append-only | trigger* |
| Last active owner cannot be removed | API (row-locked) |
| Privileged roles (Owner/HR/Accountant) assignable only with `roles.manage` | API |
| Out-of-scope ids → 404 (no probing) | API |
| Passwords: scrypt (N=16384), ≥8 chars letters+digits, forced change of temporary passwords, 5 failures → 15 min lock, generic error | API |
| Sessions: random 256-bit token, only SHA-256 stored, 12 h sliding expiry, revoked on logout / password change / deactivation | API |
| CORS: exact allow-list | API |

## Test evidence
`api/test/security.test.ts` sweeps **every registered route** anonymously (expects 401 except `/healthz`, `/readyz`, `/auth/login`),
checks 30 management routes as a Sales Employee (expects 403/404), malformed input (never 500), CORS, and that no password hash is ever returned.
