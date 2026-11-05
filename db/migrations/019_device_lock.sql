-- Per-employee "lock the account to one phone" (ربط الحساب بالجهاز). The company-wide switch now
-- sets it for everyone at once; HR can then turn it on/off per employee. Owners are never locked
-- (they could lock themselves out).
ALTER TABLE employees ADD COLUMN device_lock boolean NOT NULL DEFAULT false;
UPDATE employees SET device_lock = (SELECT device_binding FROM company_settings LIMIT 1) WHERE role_key <> 'owner';
ALTER TABLE employees ADD CONSTRAINT employees_owner_not_locked CHECK (NOT (device_lock AND role_key = 'owner'));
