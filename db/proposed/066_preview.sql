-- READ-ONLY preview for 066 (changes nothing): per job title and per employee, what 066 would give and which individual
-- exceptions it would write. Run before approving the migration.
WITH m(fine, broad) AS (VALUES
  ('employee.create','employee.manage'),('employee.edit','employee.manage'),('employee.deactivate','employee.manage'),
  ('employee.reset_password','employee.manage'),('employee.view_contact','employee.read_all'),
  ('attendance.view_location','attendance.read_all'),('attendance.view_location','attendance.read_team'),
  ('report.export','*'),('request.create_for_others','request.approve_hr'),('cash.approve','cash.office'),('cash.reverse','cash.office'),('cash.bank_view','cash.office'),('cash.bank_transfer','cash.office'),('cash.owner_funds','cash.office'),('finance.dashboard_view','cash.hr_view'),('finance.dashboard_view','cash.office'),('data.reset','owner'),('commission.void_approved','owner'))
SELECT 'role' AS kind, r.key AS id, r.name_ar AS name, string_agg(DISTINCT m.fine, ', ' ORDER BY m.fine) AS gets
  FROM roles r JOIN m ON m.broad = '*' OR (m.broad = 'owner' AND r.key = 'owner')
    OR EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_key = r.key AND rp.perm_key = m.broad)
 GROUP BY r.key, r.name_ar
UNION ALL
SELECT 'exception', e.code, e.full_name, string_agg(m.fine || CASE WHEN ep.allow THEN ' (allow, from ' ELSE ' (deny, from ' END || ep.perm_key || ')', ', ')
  FROM employee_permissions ep JOIN employees e ON e.id = ep.employee_id JOIN m ON m.broad = ep.perm_key
 GROUP BY e.code, e.full_name
ORDER BY 1, 2;
