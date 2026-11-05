-- Late deductions were not applied:
--  1) salaries typed with commas / Arabic digits / "جنيه" were skipped by 023 → the employee had no salary;
--  2) the deduction switch was still off (and the mode was not the one the app edits).
CREATE OR REPLACE FUNCTION va_money_of(t text) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE v text := regexp_replace(translate(COALESCE(t, ''), '٠١٢٣٤٥٦٧٨٩٫', '0123456789.'), '[^0-9.]', '', 'g');
BEGIN
  IF v !~ '^[0-9]+(\.[0-9]+)?$' THEN RETURN NULL; END IF;
  RETURN v::numeric;
END $$;

INSERT INTO employee_salaries (employee_id, base_salary, updated_by)
SELECT x.id, x.sal, (SELECT id FROM employees WHERE role_key = 'owner' ORDER BY created_at LIMIT 1)
  FROM (
    SELECT e.id,
           COALESCE(
             va_money_of(e.legacy_fields->>'salary'),
             va_money_of(e.legacy_fields->>'startSalary')
               + COALESCE(va_money_of(e.legacy_fields->>'increase'), 0)
           ) AS sal
      FROM employees e
     WHERE NOT EXISTS (SELECT 1 FROM employee_salaries s WHERE s.employee_id = e.id)
  ) x
 WHERE x.sal > 0 AND x.sal < 10000000
   AND EXISTS (SELECT 1 FROM employees WHERE role_key = 'owner');

UPDATE company_settings SET payroll_auto_deductions = true, deduction_mode = 'hourly';
DROP FUNCTION va_money_of(text);
