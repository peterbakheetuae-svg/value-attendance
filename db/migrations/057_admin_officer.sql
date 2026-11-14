-- «مسؤول إداري» (Administrative Officer): the accountant + HR in one position, with the sales manager's
-- permissions on top. It is the one that works the sales board (distributes the leads, sees them all, the
-- leads settings). The accountant alone and HR alone no longer see the sales board.

-- 1) the accountant alone: no leads (the positions based on the accountant / HR follow)
DELETE FROM role_permissions WHERE role_key = 'accountant' AND perm_key LIKE 'leads.%';
DELETE FROM role_permissions rp USING roles r
 WHERE rp.role_key = r.key AND NOT r.builtin AND r.base_key IN ('accountant', 'hr_manager') AND rp.perm_key LIKE 'leads.%';

-- 2) the «HR ومحاسب» position becomes «مسؤول إداري»; when there is none, it is created (based on the accountant)
DO $$
DECLARE k text;
BEGIN
  SELECT key INTO k FROM roles
   WHERE NOT builtin AND base_key = 'accountant'
     AND (name_ar ILIKE '%hr%' OR name_ar LIKE '%موارد%' OR name_ar LIKE '%اتش%')
     AND name_ar LIKE '%محاسب%'
   ORDER BY created_at LIMIT 1;
  IF k IS NULL THEN
    SELECT key INTO k FROM roles WHERE key = 'admin_officer';
  END IF;
  IF k IS NULL THEN
    INSERT INTO roles (key, name_ar, name_en, rank, base_key, builtin, description)
    VALUES ('admin_officer', 'مسؤول إداري', 'Administrative Officer', 70, 'accountant', false,
            'المحاسب + الموارد البشرية + صلاحيات مدير المبيعات (لوحة السيلز)');
    k := 'admin_officer';
  ELSE
    UPDATE roles SET name_ar = 'مسؤول إداري', name_en = 'Administrative Officer',
                     description = 'المحاسب + الموارد البشرية + صلاحيات مدير المبيعات (لوحة السيلز)'
     WHERE key = k;
  END IF;
  -- accountant + HR + sales manager, and the sales board as the distributor (all leads, settings)
  INSERT INTO role_permissions (role_key, perm_key)
    SELECT k, perm_key FROM role_permissions WHERE role_key IN ('accountant', 'hr_manager', 'sales_manager')
    ON CONFLICT DO NOTHING;
  INSERT INTO role_permissions (role_key, perm_key) VALUES
    (k, 'leads.read_all'), (k, 'leads.distribute'), (k, 'leads.config'), (k, 'leads.team'), (k, 'leads.own')
    ON CONFLICT DO NOTHING;
END $$;
