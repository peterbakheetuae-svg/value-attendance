-- JPH Real Estate HR — 001 core schema
-- Single company. All money is EGP. All business dates are Africa/Cairo local dates.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================ settings
CREATE TABLE company_settings (
  id                     boolean PRIMARY KEY DEFAULT true CHECK (id),
  company_name_ar        text NOT NULL DEFAULT 'JPH للتسويق العقاري',
  company_name_en        text NOT NULL DEFAULT 'JPH Real Estate',
  timezone               text NOT NULL DEFAULT 'Africa/Cairo',
  currency               text NOT NULL DEFAULT 'EGP' CHECK (currency = 'EGP'),
  gps_required           boolean NOT NULL DEFAULT false,
  -- what happens to a request when the employee has no sales manager
  no_manager_routing     text NOT NULL DEFAULT 'hr_only' CHECK (no_manager_routing IN ('hr_only')),
  request_backdate_days  int  NOT NULL DEFAULT 30 CHECK (request_backdate_days BETWEEN 0 AND 365),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
INSERT INTO company_settings DEFAULT VALUES;

-- ============================================================ roles & permissions
CREATE TABLE roles (
  key      text PRIMARY KEY,
  name_ar  text NOT NULL,
  name_en  text NOT NULL,
  rank     int  NOT NULL
);

CREATE TABLE permissions (
  key          text PRIMARY KEY,
  description  text NOT NULL
);

CREATE TABLE role_permissions (
  role_key  text NOT NULL REFERENCES roles(key) ON DELETE CASCADE,
  perm_key  text NOT NULL REFERENCES permissions(key) ON DELETE CASCADE,
  PRIMARY KEY (role_key, perm_key)
);

INSERT INTO roles (key, name_ar, name_en, rank) VALUES
  ('owner',          'المالك',            'Owner',          100),
  ('hr_manager',     'مدير الموارد البشرية', 'HR Manager',     80),
  ('accountant',     'المحاسب',           'Accountant',     60),
  ('sales_manager',  'مدير مبيعات',        'Sales Manager',  50),
  ('sales_employee', 'موظف مبيعات',        'Sales Employee', 10);

INSERT INTO permissions (key, description) VALUES
  ('employee.read_all',        'Read every employee profile'),
  ('employee.read_team',       'Read profiles of employees in own teams'),
  ('employee.manage',          'Create / edit / deactivate employees'),
  ('employee.salary_read',     'Read salary information'),
  ('employee.salary_manage',   'Change salary information'),
  ('org.manage',               'Manage departments and sales teams'),
  ('attendance.read_all',      'Read attendance of every employee'),
  ('attendance.read_team',     'Read attendance of own teams'),
  ('attendance.correct',       'Correct attendance records (audited)'),
  ('attendance.config',        'Manage schedules, holidays, work locations'),
  ('request.read_all',         'Read every request'),
  ('request.read_team',        'Read requests of own teams'),
  ('request.approve_manager',  'Approve at the sales-manager stage (own teams)'),
  ('request.approve_hr',       'Approve at the HR stage'),
  ('leave.manage_balances',    'Manage leave balances'),
  ('kpi.config',               'Configure KPI definitions and sets'),
  ('kpi.enter_all',            'Enter KPI actuals for anyone'),
  ('kpi.enter_team',           'Enter KPI actuals for own teams'),
  ('kpi.read_all',             'Read every KPI result'),
  ('kpi.read_team',            'Read KPI results of own teams'),
  ('evaluation.write_team',    'Evaluate employees in own teams'),
  ('evaluation.write_all',     'Evaluate any employee'),
  ('evaluation.read_all',      'Read every evaluation'),
  ('evaluation.read_team',     'Read evaluations of own teams'),
  ('report.read_all',          'Company-wide monthly reports'),
  ('report.read_team',         'Monthly reports for own teams'),
  ('report.payroll',           'Payroll-related attendance summaries'),
  ('finance.read',             'Read financial adjustments'),
  ('finance.manage',           'Create financial adjustments'),
  ('finance.approve',          'Approve financial adjustments (never own)'),
  ('settings.manage',          'Manage company settings'),
  ('roles.manage',             'Manage role permissions'),
  ('audit.read',               'Read the audit log');

-- owner: everything
INSERT INTO role_permissions (role_key, perm_key) SELECT 'owner', key FROM permissions;

INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('hr_manager','employee.read_all'), ('hr_manager','employee.manage'),
  ('hr_manager','org.manage'),
  ('hr_manager','attendance.read_all'), ('hr_manager','attendance.correct'), ('hr_manager','attendance.config'),
  ('hr_manager','request.read_all'), ('hr_manager','request.approve_hr'),
  ('hr_manager','leave.manage_balances'),
  ('hr_manager','kpi.config'), ('hr_manager','kpi.enter_all'), ('hr_manager','kpi.read_all'),
  ('hr_manager','evaluation.write_all'), ('hr_manager','evaluation.read_all'),
  ('hr_manager','report.read_all'), ('hr_manager','audit.read'),

  ('sales_manager','employee.read_team'),
  ('sales_manager','attendance.read_team'),
  ('sales_manager','request.read_team'), ('sales_manager','request.approve_manager'),
  ('sales_manager','kpi.enter_team'), ('sales_manager','kpi.read_team'),
  ('sales_manager','evaluation.write_team'), ('sales_manager','evaluation.read_team'),
  ('sales_manager','report.read_team'),

  ('accountant','employee.salary_read'),
  ('accountant','report.payroll'),
  ('accountant','finance.read'), ('accountant','finance.manage'), ('accountant','finance.approve');
-- sales_employee: self-service only (enforced by ownership checks, no extra permissions)

-- ============================================================ organisation
CREATE TABLE departments (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ar    text NOT NULL,
  name_en    text NOT NULL DEFAULT '',
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (name_ar)
);

CREATE TABLE work_schedules (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                 text NOT NULL UNIQUE,
  start_time           time NOT NULL,
  end_time             time NOT NULL CHECK (end_time > start_time),
  late_grace_minutes   int  NOT NULL DEFAULT 15 CHECK (late_grace_minutes BETWEEN 0 AND 240),
  early_grace_minutes  int  NOT NULL DEFAULT 0  CHECK (early_grace_minutes BETWEEN 0 AND 240),
  weekend_days         int[] NOT NULL DEFAULT '{5}', -- ISO dow: 1=Mon … 7=Sun; 5 = Friday
  overtime_enabled     boolean NOT NULL DEFAULT false,
  overtime_min_minutes int  NOT NULL DEFAULT 30 CHECK (overtime_min_minutes >= 0),
  is_default           boolean NOT NULL DEFAULT false,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (weekend_days <@ ARRAY[1,2,3,4,5,6,7])
);
CREATE UNIQUE INDEX work_schedules_one_default ON work_schedules (is_default) WHERE is_default;
INSERT INTO work_schedules (name, start_time, end_time, is_default)
VALUES ('الدوام الأساسي', '10:00', '18:00', true);

CREATE TABLE employees (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code                  text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9_-]{2,20}$'),
  full_name             text NOT NULL CHECK (length(trim(full_name)) >= 2),
  phone                 text,
  email                 text,
  address               text,
  job_title             text NOT NULL DEFAULT '',
  department_id         uuid REFERENCES departments(id),
  team_id               uuid,                 -- FK added after teams
  sales_manager_id      uuid REFERENCES employees(id),
  role_key              text NOT NULL REFERENCES roles(key),
  joining_date          date NOT NULL DEFAULT CURRENT_DATE,
  status                text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
  schedule_id           uuid REFERENCES work_schedules(id),
  emergency_contact_name  text,
  emergency_contact_phone text,
  notes                 text,
  photo                 bytea,
  photo_mime            text,
  password_hash         text NOT NULL,
  must_change_password  boolean NOT NULL DEFAULT true,
  failed_logins         int NOT NULL DEFAULT 0,
  locked_until          timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CHECK (sales_manager_id IS NULL OR sales_manager_id <> id)
);
CREATE UNIQUE INDEX employees_email_unique ON employees (lower(email)) WHERE email IS NOT NULL;
CREATE UNIQUE INDEX employees_phone_unique ON employees (phone) WHERE phone IS NOT NULL;

CREATE TABLE teams (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL UNIQUE,
  department_id  uuid REFERENCES departments(id),
  manager_id     uuid REFERENCES employees(id),
  active         boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE employees ADD CONSTRAINT employees_team_fk FOREIGN KEY (team_id) REFERENCES teams(id);

-- A team manager must hold the sales_manager (or owner) role.
CREATE FUNCTION teams_manager_role_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  IF NEW.manager_id IS NOT NULL THEN
    SELECT role_key INTO r FROM employees WHERE id = NEW.manager_id;
    IF r NOT IN ('sales_manager','owner') THEN
      RAISE EXCEPTION 'team manager must be a sales manager' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER teams_manager_role BEFORE INSERT OR UPDATE ON teams
  FOR EACH ROW EXECUTE FUNCTION teams_manager_role_check();

-- Salary lives in its own table so it can never be selected by accident with a profile.
CREATE TABLE employee_salaries (
  employee_id   uuid PRIMARY KEY REFERENCES employees(id),
  base_salary   numeric(12,2) NOT NULL CHECK (base_salary >= 0),
  currency      text NOT NULL DEFAULT 'EGP' CHECK (currency = 'EGP'),
  updated_by    uuid NOT NULL REFERENCES employees(id),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE employee_documents (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id  uuid NOT NULL REFERENCES employees(id),
  title        text NOT NULL,
  file_name    text NOT NULL,
  mime         text NOT NULL,
  size_bytes   int  NOT NULL CHECK (size_bytes BETWEEN 1 AND 5242880),
  content      bytea NOT NULL,
  uploaded_by  uuid NOT NULL REFERENCES employees(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- ============================================================ sessions
CREATE TABLE sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash   bytea NOT NULL UNIQUE,
  employee_id  uuid NOT NULL REFERENCES employees(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  user_agent   text
);
CREATE INDEX sessions_employee ON sessions (employee_id);

-- ============================================================ audit (append-only)
CREATE TABLE audit_log (
  id          bigserial PRIMARY KEY,
  actor_id    uuid REFERENCES employees(id),
  action      text NOT NULL,
  entity      text NOT NULL,
  entity_id   text,
  before      jsonb,
  after       jsonb,
  at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_entity ON audit_log (entity, entity_id);

CREATE FUNCTION forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = '42501';
END $$;
CREATE TRIGGER audit_log_immutable BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- ============================================================ calendar & locations
CREATE TABLE holidays (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  day      date NOT NULL UNIQUE,
  name     text NOT NULL
);

CREATE TABLE work_locations (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name      text NOT NULL,
  lat       double precision NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lng       double precision NOT NULL CHECK (lng BETWEEN -180 AND 180),
  radius_m  int NOT NULL CHECK (radius_m BETWEEN 50 AND 5000),
  active    boolean NOT NULL DEFAULT true
);

-- ============================================================ attendance
CREATE TABLE attendance (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id             uuid NOT NULL REFERENCES employees(id),
  work_date               date NOT NULL,
  schedule_start          time NOT NULL,     -- snapshot of the schedule that applied
  schedule_end            time NOT NULL,
  late_grace_minutes      int  NOT NULL,
  early_grace_minutes     int  NOT NULL,
  overtime_enabled        boolean NOT NULL,
  overtime_min_minutes    int  NOT NULL,
  check_in_at             timestamptz NOT NULL,
  check_out_at            timestamptz,
  check_in_lat            double precision,
  check_in_lng            double precision,
  check_in_accuracy_m     double precision,
  check_out_lat           double precision,
  check_out_lng           double precision,
  check_out_accuracy_m    double precision,
  geofence_status         text NOT NULL DEFAULT 'not_required'
                            CHECK (geofence_status IN ('not_required','inside')),
  original_check_in_at    timestamptz NOT NULL,   -- written once, never changed
  original_check_out_at   timestamptz,            -- written once at first check-out
  corrected               boolean NOT NULL DEFAULT false,
  source                  text NOT NULL DEFAULT 'check_in' CHECK (source IN ('check_in','correction')),
  created_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, work_date),
  CHECK (check_out_at IS NULL OR check_out_at > check_in_at)
);

CREATE FUNCTION attendance_originals_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.original_check_in_at IS DISTINCT FROM OLD.original_check_in_at THEN
    RAISE EXCEPTION 'original_check_in_at is immutable' USING ERRCODE = '42501';
  END IF;
  IF OLD.original_check_out_at IS NOT NULL
     AND NEW.original_check_out_at IS DISTINCT FROM OLD.original_check_out_at THEN
    RAISE EXCEPTION 'original_check_out_at is immutable' USING ERRCODE = '42501';
  END IF;
  IF NEW.employee_id <> OLD.employee_id OR NEW.work_date <> OLD.work_date THEN
    RAISE EXCEPTION 'attendance owner/date are immutable' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER attendance_originals BEFORE UPDATE ON attendance
  FOR EACH ROW EXECUTE FUNCTION attendance_originals_guard();
CREATE TRIGGER attendance_no_delete BEFORE DELETE ON attendance
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

CREATE TABLE attendance_corrections (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  attendance_id    uuid REFERENCES attendance(id),
  employee_id      uuid NOT NULL REFERENCES employees(id),
  work_date        date NOT NULL,
  original_in      timestamptz,
  original_out     timestamptz,
  corrected_in     timestamptz NOT NULL,
  corrected_out    timestamptz,
  reason           text NOT NULL CHECK (length(trim(reason)) >= 3),
  requested_by     uuid NOT NULL REFERENCES employees(id),
  approved_by      uuid NOT NULL REFERENCES employees(id),
  request_id       uuid,
  at               timestamptz NOT NULL DEFAULT now(),
  CHECK (approved_by <> employee_id)
);
CREATE TRIGGER attendance_corrections_immutable BEFORE UPDATE OR DELETE ON attendance_corrections
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- ============================================================ requests & dual approval
CREATE TABLE requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id       uuid NOT NULL REFERENCES employees(id),
  type              text NOT NULL CHECK (type IN
                      ('hourly_permission','short_leave','full_day_absence',
                       'emergency_permission','attendance_correction')),
  -- hourly / short / emergency
  day               date,
  from_time         time,
  to_time           time,
  duration_minutes  int,
  -- full-day absence
  start_date        date,
  end_date          date,
  absence_type      text CHECK (absence_type IN ('annual','casual','sick','unpaid','mission')),
  days_count        int,
  -- attendance correction
  correction_date   date,
  correction_in     time,
  correction_out    time,
  reason            text NOT NULL CHECK (length(trim(reason)) >= 3),
  attachment_id     uuid REFERENCES employee_documents(id),
  route             text NOT NULL CHECK (route IN ('manager_then_hr','hr_only')),
  manager_id        uuid REFERENCES employees(id),   -- snapshot at submission
  status            text NOT NULL CHECK (status IN
                      ('pending_manager','pending_hr','approved','rejected','cancelled')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  decided_at        timestamptz,
  CHECK (route = 'hr_only' OR manager_id IS NOT NULL),
  CHECK (manager_id IS NULL OR manager_id <> employee_id),
  CHECK (type NOT IN ('hourly_permission','short_leave','emergency_permission')
         OR (day IS NOT NULL AND from_time IS NOT NULL AND to_time IS NOT NULL
             AND to_time > from_time AND duration_minutes > 0)),
  CHECK (type <> 'full_day_absence'
         OR (start_date IS NOT NULL AND end_date IS NOT NULL AND end_date >= start_date
             AND absence_type IS NOT NULL AND days_count > 0)),
  CHECK (type <> 'attendance_correction'
         OR (correction_date IS NOT NULL AND correction_in IS NOT NULL
             AND (correction_out IS NULL OR correction_out > correction_in)))
);
CREATE INDEX requests_employee ON requests (employee_id, created_at DESC);
CREATE INDEX requests_status ON requests (status);

CREATE TABLE request_actions (
  id          bigserial PRIMARY KEY,
  request_id  uuid NOT NULL REFERENCES requests(id),
  actor_id    uuid NOT NULL REFERENCES employees(id),
  stage       text NOT NULL CHECK (stage IN ('employee','manager','hr')),
  action      text NOT NULL CHECK (action IN ('submit','approve','reject','cancel')),
  comment     text,
  at          timestamptz NOT NULL DEFAULT now(),
  CHECK (action <> 'reject' OR length(trim(coalesce(comment,''))) >= 3)
);
CREATE TRIGGER request_actions_immutable BEFORE UPDATE OR DELETE ON request_actions
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- Status transitions are enforced in the database too: a terminal request never moves.
CREATE FUNCTION requests_transition_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IN ('approved','rejected','cancelled') THEN
    RAISE EXCEPTION 'request % is final', OLD.id USING ERRCODE = '42501';
  END IF;
  IF NEW.status = 'approved' AND OLD.status <> 'pending_hr' THEN
    RAISE EXCEPTION 'only the HR stage can approve finally' USING ERRCODE = '42501';
  END IF;
  IF NEW.status = 'pending_hr' AND OLD.status <> 'pending_manager' THEN
    RAISE EXCEPTION 'invalid transition' USING ERRCODE = '42501';
  END IF;
  IF NEW.employee_id <> OLD.employee_id OR NEW.type <> OLD.type THEN
    RAISE EXCEPTION 'request owner/type immutable' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER requests_transition BEFORE UPDATE ON requests
  FOR EACH ROW EXECUTE FUNCTION requests_transition_guard();
CREATE TRIGGER requests_no_delete BEFORE DELETE ON requests
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

CREATE TABLE leave_balances (
  employee_id   uuid NOT NULL REFERENCES employees(id),
  year          int  NOT NULL CHECK (year BETWEEN 2000 AND 2100),
  annual_days   numeric(5,1) NOT NULL DEFAULT 21 CHECK (annual_days >= 0),
  casual_days   numeric(5,1) NOT NULL DEFAULT 7  CHECK (casual_days >= 0),
  sick_days     numeric(5,1) NOT NULL DEFAULT 0  CHECK (sick_days >= 0),
  updated_by    uuid REFERENCES employees(id),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employee_id, year)
);

-- ============================================================ notifications
CREATE TABLE notifications (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id uuid NOT NULL REFERENCES employees(id),
  type         text NOT NULL,
  title        text NOT NULL,
  body         text NOT NULL DEFAULT '',
  entity       text,
  entity_id    text,
  dedupe_key   text NOT NULL,
  read_at      timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (recipient_id, dedupe_key)
);
CREATE INDEX notifications_recipient ON notifications (recipient_id, created_at DESC);
