-- Dynamic job positions linked to permissions + position-based KPI sets + granular permissions.
-- Positions are rows of `roles`: the 5 built-in system roles stay as they are (no permission changes),
-- and a new position always follows ("is based on") one system role for its built-in behaviour
-- (owner checks, team manager, PIN login...). Its permissions start as an exact copy of the base role,
-- so creating a position never grants anything new.

ALTER TABLE roles
  ADD COLUMN description text NOT NULL DEFAULT '' CHECK (length(description) <= 500),
  ADD COLUMN base_key    text REFERENCES roles(key),
  ADD COLUMN builtin     boolean NOT NULL DEFAULT false,
  ADD COLUMN active      boolean NOT NULL DEFAULT true,
  ADD COLUMN created_by  uuid REFERENCES employees(id),
  ADD COLUMN created_at  timestamptz NOT NULL DEFAULT now();

UPDATE roles SET builtin = true WHERE key IN ('owner','hr_manager','accountant','sales_manager','sales_employee');

ALTER TABLE roles ADD CONSTRAINT roles_base_rule CHECK (
  (builtin AND base_key IS NULL) OR
  (NOT builtin AND base_key IN ('hr_manager','accountant','sales_manager','sales_employee')));

-- Built-in roles can never be disabled or have their key changed.
CREATE FUNCTION roles_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Positions are never deleted; disable them instead' USING ERRCODE = '42501';
  END IF;
  IF OLD.builtin AND (NOT NEW.active OR NEW.base_key IS DISTINCT FROM OLD.base_key OR NOT NEW.builtin) THEN
    RAISE EXCEPTION 'Built-in roles cannot be disabled or re-based' USING ERRCODE = '42501';
  END IF;
  IF NEW.key <> OLD.key OR NEW.base_key IS DISTINCT FROM OLD.base_key THEN
    RAISE EXCEPTION 'A position key and base role are fixed' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER roles_guard BEFORE UPDATE OR DELETE ON roles FOR EACH ROW EXECUTE FUNCTION roles_guard();

-- The employee's position (NULL = the system role itself). role_key keeps the system role (behaviour).
ALTER TABLE employees ADD COLUMN position_key text REFERENCES roles(key);

CREATE FUNCTION employees_position_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p record;
BEGIN
  IF NEW.position_key IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO p FROM roles WHERE key = NEW.position_key;
  IF p.builtin THEN
    NEW.role_key := p.key; NEW.position_key := NULL;  -- a built-in role is its own position
  ELSIF NEW.role_key IS DISTINCT FROM p.base_key THEN
    RAISE EXCEPTION 'Position % follows role %, not %', p.key, p.base_key, NEW.role_key USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER employees_position BEFORE INSERT OR UPDATE OF position_key, role_key ON employees
  FOR EACH ROW EXECUTE FUNCTION employees_position_check();

-- KPI sets can now target a job position (in addition to free-text job title / single employee).
ALTER TABLE kpi_sets DROP CONSTRAINT kpi_sets_check;
ALTER TABLE kpi_sets DROP CONSTRAINT kpi_sets_scope_type_check;
ALTER TABLE kpi_sets ADD COLUMN position_key text REFERENCES roles(key);
ALTER TABLE kpi_sets ADD CONSTRAINT kpi_sets_scope_type_check CHECK (scope_type IN ('job_title','employee','position'));
ALTER TABLE kpi_sets ADD CONSTRAINT kpi_sets_scope_check CHECK (
     (scope_type = 'job_title' AND job_title IS NOT NULL AND employee_id IS NULL AND position_key IS NULL)
  OR (scope_type = 'employee'  AND employee_id IS NOT NULL AND job_title IS NULL AND position_key IS NULL)
  OR (scope_type = 'position'  AND position_key IS NOT NULL AND job_title IS NULL AND employee_id IS NULL));
CREATE UNIQUE INDEX kpi_sets_one_active_position ON kpi_sets (position_key) WHERE active AND scope_type = 'position';

-- Granular permissions for the new areas. Owner gets everything; HR gets what the spec gives HR.
INSERT INTO permissions (key, description) VALUES
  ('custody.manage',     'Assign / return company assets (custody)'),
  ('custody.read_all',   'View custody of every employee'),
  ('custody.read_team',  'View custody of own teams'),
  ('documents.manage',   'Upload / replace employee documents'),
  ('documents.read',     'View private employee documents'),
  ('notification.send',  'Send notifications to employees'),
  ('positions.manage',   'Create / edit / disable job positions');

INSERT INTO role_permissions (role_key, perm_key)
  SELECT 'owner', key FROM permissions ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('hr_manager','custody.manage'), ('hr_manager','custody.read_all'),
  ('hr_manager','documents.manage'), ('hr_manager','documents.read'),
  ('hr_manager','notification.send'), ('hr_manager','positions.manage')
ON CONFLICT DO NOTHING;
