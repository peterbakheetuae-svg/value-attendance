-- 066 — fine-grained permissions (PROPOSED: kept outside db/migrations, so it runs nowhere until approved and moved there).
--
-- Adds permission keys only (no table / column change) and preserves every employee's effective access exactly:
--   1. each fine key goes to every job title that holds one of the broad keys it is split from (same as the code's
--      fallback before this migration: auth/context.ts can());
--   2. then, for each employee, the effective value of the fine key BEFORE (resolved from his broad keys, with his
--      individual grants / restrictions; for an 'all' key: every one of them) is compared with AFTER (his job title's grant of the fine key); wherever they
--      differ an individual exception is written so the result is identical — and each one is recorded in audit_log.
--
--   employee.create / .edit / .deactivate / .reset_password  ← employee.manage
--   employee.view_contact                                    ← employee.read_all
--   attendance.view_location                                 ← attendance.read_all OR attendance.read_team
--   report.export                                            ← everyone (the export had no separate check)
--   request.create_for_others                                ← request.approve_hr
--   cash.approve / .reverse / .bank_view / .bank_transfer / .owner_funds  ← cash.office
--   finance.dashboard_view                                   ← cash.hr_view OR cash.office
--   data.reset, commission.void_approved                     ← the owner role (was checked by role name)
--   exclusive.view_finance                                   ← cash.office
--   exclusive.view_client                                    ← everyone (client details had no separate check)
--   sales.read_team                                          ← commission.read_team (a team's sales, the record only)
--   commission.create_for_others                             ← sales.manage
--   cash.receipt_print, cash.attachment_view / _upload       ← everyone (no separate check before; the cashbox checks stay)
--   finance.company_income                                   ← cash.office AND commission.company_view (owner decision,
--        16 Nov 2026: an approved access separation — whoever runs the office cashbox without «عرض أرباح الشركة» stops
--        seeing the office's income / split / net; the code also requires both keys with it: permission-registry requiresAll)
--   advance.create_for_others                                ← finance.manage OR employee.manage
--   advance.approve_all                                      ← the owner role (was checked by role name)
-- The broad keys are not touched (other modules still use them).

INSERT INTO permissions (key, description) VALUES
  ('employee.create',          'Create an employee account'),
  ('employee.edit',            'Edit an employee profile, position, team and settings'),
  ('employee.deactivate',      'Deactivate / reactivate an employee account'),
  ('employee.reset_password',  'Issue a temporary password / PIN for an employee'),
  ('employee.view_contact',    'See another employee''s phone, email, address, emergency contact, national id and birth date'),
  ('attendance.view_location', 'See employees'' locations (tracking map, location points, check-in place) within scope'),
  ('report.export',            'Download the monthly attendance report / payroll summary as Excel (within scope)'),
  ('request.create_for_others', 'Record a leave / permission for another employee (approved on entry)'),
  ('cash.approve',             'Approve / reject large expenses and transfer requests, mark expenses reviewed (never own)'),
  ('cash.reverse',             'Reverse a posted receipt or expense (with a reason, audited)'),
  ('cash.bank_view',           'See the moves between the office cashbox and the bank'),
  ('cash.bank_transfer',       'Record a deposit to / withdrawal from the bank'),
  ('cash.owner_funds',         'Owners'' injections, profit draws and shares'),
  ('finance.dashboard_view',   'The finance dashboard and its details (within the cashboxes he may see)'),
  ('data.reset',               'Import old data or wipe company data (was the owner by name)'),
  ('commission.void_approved', 'Cancel an approved commission (was the owner by name)'),
  ('exclusive.view_finance',   'Exclusive projects'' money: owner trust / dues, office, staff and marketing commission, project statement'),
  ('exclusive.view_client',    'Client phone, national id, address and contact on the units / sales / installments he may see'),
  ('sales.read_team',          'The sales registered by the members of his teams (no client contact, collections or commission)'),
  ('commission.create_for_others', 'File a commission request for another salesperson'),
  ('cash.receipt_print',       'Print the payment / receipt voucher of the moves he sees'),
  ('cash.attachment_view',     'See the signed receipt photo of receipts, expenses, transfers and payouts he sees'),
  ('cash.attachment_upload',   'Add or replace the signed receipt photo (in the cashboxes he operates)'),
  ('finance.company_income',   'The office''s commission income, the commission split and the office''s net / profit on the dashboards'),
  ('advance.create_for_others', 'Record an advance / work-expense request for another employee (still needs the general manager)'),
  ('advance.approve_all',      'Approve advances / work expenses instead of / when there is no general manager (was the owner by name)')
  ON CONFLICT (key) DO NOTHING;

-- the split: fine key ← broad key(s); '*' = everyone, 'owner' = the owner role;
-- need 'any' = holding one of its broad keys gave it, 'all' = it needs every one of its broad keys (an intersection)
CREATE TEMP TABLE m066 (fine text NOT NULL, broad text NOT NULL, need text NOT NULL DEFAULT 'any') ON COMMIT DROP;
INSERT INTO m066 (fine, broad) VALUES
  ('employee.create', 'employee.manage'), ('employee.edit', 'employee.manage'), ('employee.deactivate', 'employee.manage'),
  ('employee.reset_password', 'employee.manage'),
  ('employee.view_contact', 'employee.read_all'),
  ('attendance.view_location', 'attendance.read_all'), ('attendance.view_location', 'attendance.read_team'),
  ('report.export', '*'),
  ('request.create_for_others', 'request.approve_hr'),
  ('cash.approve', 'cash.office'), ('cash.reverse', 'cash.office'), ('cash.bank_view', 'cash.office'),
  ('cash.bank_transfer', 'cash.office'), ('cash.owner_funds', 'cash.office'),
  ('finance.dashboard_view', 'cash.hr_view'), ('finance.dashboard_view', 'cash.office'),
  ('data.reset', 'owner'), ('commission.void_approved', 'owner'),
  ('exclusive.view_finance', 'cash.office'), ('exclusive.view_client', '*'),
  ('sales.read_team', 'commission.read_team'), ('commission.create_for_others', 'sales.manage'),
  ('cash.receipt_print', '*'), ('cash.attachment_view', '*'), ('cash.attachment_upload', '*'),
  ('advance.create_for_others', 'finance.manage'), ('advance.create_for_others', 'employee.manage'),
  ('advance.approve_all', 'owner');
INSERT INTO m066 (fine, broad, need) VALUES
  ('finance.company_income', 'cash.office', 'all'), ('finance.company_income', 'commission.company_view', 'all');

-- 1. job titles
INSERT INTO role_permissions (role_key, perm_key)
  SELECT DISTINCT rp.role_key, m.fine FROM role_permissions rp JOIN m066 m ON m.broad = rp.perm_key AND m.need = 'any'
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
  SELECT rp.role_key, m.fine FROM role_permissions rp JOIN m066 m ON m.broad = rp.perm_key AND m.need = 'all'
   GROUP BY rp.role_key, m.fine
  HAVING count(DISTINCT m.broad) = (SELECT count(*) FROM m066 x WHERE x.fine = m.fine)
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
  SELECT r.key, m.fine FROM roles r JOIN m066 m ON m.broad = '*'
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
  SELECT 'owner', m.fine FROM m066 m WHERE m.broad = 'owner'
  ON CONFLICT DO NOTHING;

-- 2. employees: keep each one's effective value exactly
CREATE TEMP TABLE x066 ON COMMIT DROP AS
WITH each_broad AS (
  SELECT e.id, m.fine, m.need, (CASE
           WHEN m.broad = '*' THEN true
           WHEN m.broad = 'owner' THEN e.role_key = 'owner'
           ELSE (EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_key = COALESCE(e.position_key, e.role_key) AND rp.perm_key = m.broad)
                 AND NOT EXISTS (SELECT 1 FROM employee_permissions ep WHERE ep.employee_id = e.id AND ep.perm_key = m.broad AND NOT ep.allow))
                OR EXISTS (SELECT 1 FROM employee_permissions ep WHERE ep.employee_id = e.id AND ep.perm_key = m.broad AND ep.allow)
         END) AS v
    FROM employees e CROSS JOIN m066 m
), pre AS (
  SELECT id, fine, CASE WHEN bool_and(need = 'all') THEN bool_and(v) ELSE bool_or(v) END AS v
    FROM each_broad GROUP BY id, fine
), post AS (
  SELECT p.id, p.fine, p.v,
         EXISTS (SELECT 1 FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
                  WHERE e.id = p.id AND rp.perm_key = p.fine) AS granted
    FROM pre p
)
SELECT id, fine, v FROM post WHERE v <> granted;

INSERT INTO employee_permissions (employee_id, perm_key, allow, by_id, updated_at)
  SELECT id, fine, v, NULL, now() FROM x066
  ON CONFLICT (employee_id, perm_key) DO NOTHING;
INSERT INTO audit_log (actor_id, action, entity, entity_id, before, after)
  SELECT NULL, 'permission.employee', 'employee', id::text, jsonb_build_object('perm', fine, 'value', 'inherit'),
         jsonb_build_object('perm', fine, 'value', CASE WHEN v THEN 'allow' ELSE 'deny' END, 'source', 'migration_066')
    FROM x066;
