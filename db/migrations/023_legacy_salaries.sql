-- Salaries typed in the original JPH form were kept only in legacy_fields (HR could not store a salary),
-- so payroll saw "no salary" and deducted nothing. Move them into employee_salaries once.
INSERT INTO employee_salaries (employee_id, base_salary, updated_by)
SELECT e.id,
       (CASE WHEN (e.legacy_fields->>'salary') ~ '^[0-9]+(\.[0-9]+)?$' AND (e.legacy_fields->>'salary')::numeric > 0
             THEN (e.legacy_fields->>'salary')::numeric
             ELSE (e.legacy_fields->>'startSalary')::numeric END),
       (SELECT id FROM employees WHERE role_key = 'owner' ORDER BY created_at LIMIT 1)
  FROM employees e
 WHERE NOT EXISTS (SELECT 1 FROM employee_salaries s WHERE s.employee_id = e.id)
   AND (((e.legacy_fields->>'salary') ~ '^[0-9]+(\.[0-9]+)?$' AND (e.legacy_fields->>'salary')::numeric > 0)
     OR ((e.legacy_fields->>'startSalary') ~ '^[0-9]+(\.[0-9]+)?$' AND (e.legacy_fields->>'startSalary')::numeric > 0))
   AND EXISTS (SELECT 1 FROM employees WHERE role_key = 'owner');
