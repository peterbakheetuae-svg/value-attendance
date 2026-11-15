-- Rollback of 066 (PROPOSED). Removes only what 066 added; the broad keys were never touched, and the application falls
-- back to them automatically when a fine key is missing (auth/context.ts: can()), so access returns to exactly the
-- pre-066 state. Grants / exceptions made on the fine keys AFTER 066 (on the «الصلاحيات» page) are lost by this rollback.
DELETE FROM employee_permissions WHERE perm_key IN ('employee.create','employee.edit','employee.deactivate','employee.reset_password',
  'employee.view_contact','data.reset','commission.void_approved');
DELETE FROM role_permissions WHERE perm_key IN ('employee.create','employee.edit','employee.deactivate','employee.reset_password',
  'employee.view_contact','data.reset','commission.void_approved');
DELETE FROM permissions WHERE key IN ('employee.create','employee.edit','employee.deactivate','employee.reset_password',
  'employee.view_contact','data.reset','commission.void_approved');
