-- «الإعدادات / التحكم في الوصول / صلاحيات الأدوار» for the sales board (like Elite): finer leads permissions a role can
-- be given or not, and per-employee exceptions (allow / deny) on top of his role.
INSERT INTO permissions (key, description) VALUES
  ('leads.create',  'Add leads'),
  ('leads.edit',    'Edit a lead''s data'),
  ('leads.import',  'Import leads from Excel'),
  ('leads.export',  'Export leads to Excel'),
  ('leads.reports', 'Open the leads reports'),
  ('leads.tasks',   'Give tasks to others')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) SELECT 'owner', key FROM permissions ON CONFLICT DO NOTHING;

-- nothing changes for anyone today: every role keeps what it could already do
INSERT INTO role_permissions (role_key, perm_key)
  SELECT DISTINCT rp.role_key, p.k FROM role_permissions rp
    CROSS JOIN (VALUES ('leads.create'), ('leads.edit')) p(k)
   WHERE rp.perm_key IN ('leads.own', 'leads.distribute')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
  SELECT DISTINCT rp.role_key, 'leads.import' FROM role_permissions rp WHERE rp.perm_key = 'leads.distribute'
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
  SELECT DISTINCT rp.role_key, p.k FROM role_permissions rp
    CROSS JOIN (VALUES ('leads.export'), ('leads.reports'), ('leads.tasks')) p(k)
   WHERE rp.perm_key IN ('leads.distribute', 'leads.read_all', 'leads.team')
  ON CONFLICT DO NOTHING;

-- an employee's own exceptions: allow = has it even if his role doesn't; deny = hasn't it even if his role does
CREATE TABLE employee_permissions (
  employee_id uuid NOT NULL REFERENCES employees(id),
  perm_key    text NOT NULL REFERENCES permissions(key),
  allow       boolean NOT NULL,
  by_id       uuid REFERENCES employees(id),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employee_id, perm_key)
);
