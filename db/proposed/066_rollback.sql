-- Rollback of 066 (PROPOSED). Removes only what 066 added. The broad keys were never touched, and the application falls
-- back to them whenever a fine key is missing (auth/context.ts: can() / canOwnerOnly()), so effective access returns to
-- exactly the pre-066 state.
-- Lost by a rollback: any grant / restriction made on the fine keys AFTER 066 (on the «الصلاحيات» page). E.g. someone
-- individually denied «عرض بيانات التواصل» sees contact details again if he holds employee.read_all; someone individually
-- given «إضافة موظف» without employee.manage loses it. The audit_log rows (066's and later ones) stay (append-only).
DELETE FROM employee_permissions WHERE perm_key IN ('employee.create','employee.edit','employee.deactivate','employee.reset_password',
  'employee.view_contact','attendance.view_location','report.export','request.create_for_others','data.reset','commission.void_approved');
DELETE FROM role_permissions WHERE perm_key IN ('employee.create','employee.edit','employee.deactivate','employee.reset_password',
  'employee.view_contact','attendance.view_location','report.export','request.create_for_others','data.reset','commission.void_approved');
DELETE FROM permissions WHERE key IN ('employee.create','employee.edit','employee.deactivate','employee.reset_password',
  'employee.view_contact','attendance.view_location','report.export','request.create_for_others','data.reset','commission.void_approved');
