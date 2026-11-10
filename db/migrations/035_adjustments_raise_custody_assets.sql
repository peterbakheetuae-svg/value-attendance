-- 1) علاوة / خصم (financial requests page): جزاء (deduction) | زيادة راتب (raise) | علاوة (bonus), with an optional photo.
--    A raise, once approved, is added to the employee's "الزيادة" and to his monthly salary (starting salary + raises).
ALTER TABLE salary_adjustments DROP CONSTRAINT IF EXISTS salary_adjustments_kind_check;
ALTER TABLE salary_adjustments ADD CONSTRAINT salary_adjustments_kind_check CHECK (kind IN ('deduction','bonus','raise'));
ALTER TABLE salary_adjustments ADD COLUMN attachment bytea CHECK (attachment IS NULL OR octet_length(attachment) <= 600000);
-- HR records them; المدير (and the owner) approve — like the other financial requests
INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('hr_manager','finance.manage'), ('manager','finance.approve'), ('manager','finance.manage')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
SELECT r.key, 'finance.manage' FROM roles r WHERE r.base_key = 'hr_manager'
ON CONFLICT DO NOTHING;

-- 2) "مستشار عقاري" is shown as "سيلز"
UPDATE roles SET name_ar = 'سيلز' WHERE key = 'sales_employee' OR name_ar = 'مستشار عقاري';
UPDATE employees SET job_title = 'سيلز' WHERE job_title = 'مستشار عقاري';

-- 3) العهدة: the company's own list of assets (mobiles, laptops) — added once in Settings → العهدة, then handed to
--    employees from that list (custody_items.asset_id). Nothing is deleted; an asset can be retired.
CREATE TABLE custody_assets (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_type  text NOT NULL CHECK (asset_type IN ('mobile','laptop')),
  name        text NOT NULL CHECK (length(trim(name)) >= 2),          -- brand / model
  serial_no   text,                                                    -- IMEI for a mobile, serial for a laptop
  line_number text,                                                    -- mobile line (optional)
  specs       text NOT NULL DEFAULT '',                                -- laptop: processor / RAM / storage …
  condition   text NOT NULL DEFAULT 'new' CHECK (condition IN ('new','used_good','other')),
  accessories text[] NOT NULL DEFAULT '{}',
  notes       text NOT NULL DEFAULT '',
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_by  uuid NOT NULL REFERENCES employees(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX custody_assets_serial ON custody_assets (asset_type, lower(trim(serial_no))) WHERE serial_no IS NOT NULL AND trim(serial_no) <> '';
ALTER TABLE custody_items ADD COLUMN asset_id uuid REFERENCES custody_assets(id);
-- an asset is with one employee at a time
CREATE UNIQUE INDEX custody_items_asset_once ON custody_items (asset_id) WHERE asset_id IS NOT NULL AND status = 'assigned';
