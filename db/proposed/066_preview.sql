-- READ-ONLY preview for 066 (changes nothing): per job title and per employee, what 066 would give and which individual
-- exceptions it would write. Run before approving the migration.
WITH m0(fine, broad) AS (VALUES
  ('employee.create','employee.manage'),('employee.edit','employee.manage'),('employee.deactivate','employee.manage'),
  ('employee.reset_password','employee.manage'),('employee.view_contact','employee.read_all'),
  ('attendance.view_location','attendance.read_all'),('attendance.view_location','attendance.read_team'),
  ('report.export','*'),('request.create_for_others','request.approve_hr'),('cash.approve','cash.office'),('cash.reverse','cash.office'),('cash.bank_view','cash.office'),('cash.bank_transfer','cash.office'),('cash.owner_funds','cash.office'),('finance.dashboard_view','cash.hr_view'),('finance.dashboard_view','cash.office'),('data.reset','owner'),('commission.void_approved','owner'),('exclusive.view_finance','cash.office'),('exclusive.view_client','*'),('sales.read_team','commission.read_team'),('commission.create_for_others','sales.manage'),('cash.receipt_print','*'),('cash.attachment_view','*'),('cash.attachment_upload','*'),('advance.create_for_others','finance.manage'),('advance.create_for_others','employee.manage'),('advance.approve_all','owner')),
m(fine, broad, need) AS (SELECT fine, broad, 'any' FROM m0
  UNION ALL VALUES ('finance.company_income','cash.office','all'),('finance.company_income','commission.company_view','all')),
-- effective broad keys today (job title, then individual allow / deny)
eff AS (
  SELECT e.id, e.code, e.full_name, p.key,
         (EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_key = COALESCE(e.position_key, e.role_key) AND rp.perm_key = p.key)
          AND NOT EXISTS (SELECT 1 FROM employee_permissions ep WHERE ep.employee_id = e.id AND ep.perm_key = p.key AND NOT ep.allow))
         OR EXISTS (SELECT 1 FROM employee_permissions ep WHERE ep.employee_id = e.id AND ep.perm_key = p.key AND ep.allow) AS v
    FROM employees e CROSS JOIN (VALUES ('cash.office'), ('commission.company_view')) p(key)
   WHERE e.status = 'active')
SELECT 'role' AS kind, r.key AS id, r.name_ar AS name, string_agg(DISTINCT m.fine, ', ' ORDER BY m.fine) AS gets
  FROM roles r JOIN m ON (m.broad = '*' OR (m.broad = 'owner' AND r.key = 'owner')
    OR EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_key = r.key AND rp.perm_key = m.broad))
   AND (m.need = 'any' OR NOT EXISTS (SELECT 1 FROM m m2 WHERE m2.fine = m.fine
          AND NOT EXISTS (SELECT 1 FROM role_permissions rp2 WHERE rp2.role_key = r.key AND rp2.perm_key = m2.broad)))
 GROUP BY r.key, r.name_ar
UNION ALL
SELECT 'exception', e.code, e.full_name, string_agg(m.fine || CASE WHEN ep.allow THEN ' (allow, from ' ELSE ' (deny, from ' END || ep.perm_key || ')', ', ')
  FROM employee_permissions ep JOIN employees e ON e.id = ep.employee_id JOIN m ON m.broad = ep.perm_key
 GROUP BY e.code, e.full_name
UNION ALL
-- the approved separation: who sees the office's income today (cash.office) and would stop (no commission.company_view)
SELECT 'loses finance.company_income', o.code, o.full_name, 'cash.office without commission.company_view'
  FROM eff o JOIN eff c ON c.id = o.id AND c.key = 'commission.company_view'
 WHERE o.key = 'cash.office' AND o.v AND NOT c.v
ORDER BY 1, 2;
