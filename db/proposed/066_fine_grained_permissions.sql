-- 066 — fine-grained permissions (PROPOSED: not in db/migrations yet, so it runs nowhere until approved and moved there).
--
-- Adds permission keys only (no table / column change). Every key is given to exactly the job titles — and the
-- individual exceptions — that hold the broad permission it is split from today, so nobody gains or loses anything:
--   employee.create / employee.edit / employee.deactivate / employee.reset_password  ← employee.manage
--   employee.view_contact                                                              ← employee.read_all
--   data.reset, commission.void_approved                                               ← the owner role (was checked by name)
-- The broad keys stay (other modules still use them) until every module has moved to the fine ones.

INSERT INTO permissions (key, description) VALUES
  ('employee.create',          'Create an employee account'),
  ('employee.edit',            'Edit an employee profile, position, team and settings'),
  ('employee.deactivate',      'Deactivate / reactivate an employee account'),
  ('employee.reset_password',  'Issue a temporary password / PIN for an employee'),
  ('employee.view_contact',    'See another employee''s phone, email, address, emergency contact, national id and birth date'),
  ('data.reset',               'Import old data or wipe company data (was the owner by name)'),
  ('commission.void_approved', 'Cancel an approved commission (was the owner by name)')
  ON CONFLICT (key) DO NOTHING;

-- job titles: the fine key wherever the broad one is
INSERT INTO role_permissions (role_key, perm_key)
  SELECT rp.role_key, f.k FROM role_permissions rp
    CROSS JOIN (VALUES ('employee.create'), ('employee.edit'), ('employee.deactivate'), ('employee.reset_password')) f(k)
   WHERE rp.perm_key = 'employee.manage'
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
  SELECT rp.role_key, 'employee.view_contact' FROM role_permissions rp WHERE rp.perm_key = 'employee.read_all'
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) VALUES ('owner', 'data.reset'), ('owner', 'commission.void_approved')
  ON CONFLICT DO NOTHING;

-- individual exceptions: an allow / deny on the broad key becomes the same on its fine keys
INSERT INTO employee_permissions (employee_id, perm_key, allow, by_id, updated_at)
  SELECT ep.employee_id, f.k, ep.allow, ep.by_id, ep.updated_at FROM employee_permissions ep
    CROSS JOIN (VALUES ('employee.create'), ('employee.edit'), ('employee.deactivate'), ('employee.reset_password')) f(k)
   WHERE ep.perm_key = 'employee.manage'
  ON CONFLICT (employee_id, perm_key) DO NOTHING;
INSERT INTO employee_permissions (employee_id, perm_key, allow, by_id, updated_at)
  SELECT ep.employee_id, 'employee.view_contact', ep.allow, ep.by_id, ep.updated_at FROM employee_permissions ep
   WHERE ep.perm_key = 'employee.read_all'
  ON CONFLICT (employee_id, perm_key) DO NOTHING;
