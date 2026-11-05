-- 018: "المدير" system role, general manager per employee, attendance-exempt flag (owner-only),
-- personal work hours, financial requests approved by the general manager first and then HR,
-- salary visibility limited to HR / the manager / the accountant (and the owner), documents optional.

-- ------------------------------------------------------------------ the "manager" (المدير) system role
INSERT INTO roles (key, name_ar, name_en, rank, builtin) VALUES ('manager', 'المدير', 'Manager', 90, true)
  ON CONFLICT (key) DO NOTHING;

ALTER TABLE roles DROP CONSTRAINT roles_base_rule;
ALTER TABLE roles ADD CONSTRAINT roles_base_rule CHECK (
  (builtin AND base_key IS NULL) OR
  (NOT builtin AND base_key IN ('manager','hr_manager','accountant','sales_manager','sales_employee')));

INSERT INTO permissions (key, description) VALUES
  ('employee.attendance_exempt', 'Mark an employee as not required to check in / out')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) SELECT 'owner', key FROM permissions ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('manager','employee.read_all'), ('manager','employee.salary_read'),
  ('manager','attendance.read_all'),
  ('manager','request.read_all'), ('manager','request.approve_manager'),
  ('manager','kpi.read_all'), ('manager','kpi.enter_all'),
  ('manager','evaluation.write_all'), ('manager','evaluation.read_all'),
  ('manager','report.read_all'), ('manager','report.payroll'),
  ('manager','finance.read'),
  ('manager','custody.read_all'), ('manager','documents.read'),
  ('manager','notification.send'),
  -- the HR manager sees and manages salaries (with the manager and the accountant)
  ('hr_manager','employee.salary_read'), ('hr_manager','employee.salary_manage'), ('hr_manager','finance.read')
  ON CONFLICT DO NOTHING;

-- a sales team may be led by a sales manager, the manager or the owner
CREATE OR REPLACE FUNCTION teams_manager_role_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  IF NEW.manager_id IS NOT NULL THEN
    SELECT role_key INTO r FROM employees WHERE id = NEW.manager_id;
    IF r NOT IN ('sales_manager','manager','owner') THEN
      RAISE EXCEPTION 'team manager must be a manager' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ------------------------------------------------------------------ employee fields
ALTER TABLE employees
  ADD COLUMN general_manager_id uuid REFERENCES employees(id),
  ADD COLUMN attendance_exempt  boolean NOT NULL DEFAULT false,
  ADD COLUMN work_start         time,
  ADD COLUMN work_end           time,
  ADD CONSTRAINT employees_gm_not_self CHECK (general_manager_id IS NULL OR general_manager_id <> id),
  ADD CONSTRAINT employees_work_hours CHECK (
    (work_start IS NULL AND work_end IS NULL) OR (work_start IS NOT NULL AND work_end IS NOT NULL AND work_end > work_start));

-- owners never punched in so far: keep that behaviour until the owner turns it off
UPDATE employees SET attendance_exempt = true WHERE role_key = 'owner';
CREATE FUNCTION employees_owner_exempt() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.role_key = 'owner' THEN NEW.attendance_exempt := true; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER employees_owner_exempt BEFORE INSERT ON employees FOR EACH ROW EXECUTE FUNCTION employees_owner_exempt();

-- ------------------------------------------------------------------ financial requests: general manager, then HR
ALTER TABLE advance_requests
  ADD COLUMN gm_id          uuid REFERENCES employees(id),
  ADD COLUMN gm_approved_by uuid REFERENCES employees(id),
  ADD COLUMN gm_approved_at timestamptz,
  ADD CONSTRAINT advance_gm_not_self CHECK (gm_approved_by IS NULL OR gm_approved_by <> employee_id);

-- the three onboarding documents are optional from now on (still uploadable at any time)
UPDATE company_settings SET require_employee_documents = false;
