-- 1) a project's picture (shown on its card), kept apart so the project lists stay light
CREATE TABLE project_images (
  project_id uuid PRIMARY KEY REFERENCES commission_projects(id),
  mime       text NOT NULL CHECK (mime IN ('image/jpeg','image/png','image/webp')),
  data       text NOT NULL,                       -- base64
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES employees(id)
);

-- 2) the project's units (المخزون): entered once by the office, picked when reserving — the form fills itself
CREATE TABLE ex_inventory (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL REFERENCES commission_projects(id),
  unit_no      text NOT NULL CHECK (length(trim(unit_no)) BETWEEN 1 AND 60),
  unit_type    text NOT NULL DEFAULT '',
  floor        text NOT NULL DEFAULT '',
  net_area_m2  numeric(12,4) CHECK (net_area_m2 IS NULL OR net_area_m2 > 0),     -- المساحة الصافية
  area_m2      numeric(12,4) CHECK (area_m2 IS NULL OR area_m2 > 0),             -- المساحة بالتحميل (× سعر المتر)
  meter_price  numeric(16,2) CHECK (meter_price IS NULL OR meter_price > 0),
  unit_price   numeric(16,2) CHECK (unit_price IS NULL OR unit_price > 0),       -- إجمالي سعر الوحدة
  activity     text NOT NULL DEFAULT '',
  notes        text NOT NULL DEFAULT '',
  active       boolean NOT NULL DEFAULT true,
  created_by   uuid REFERENCES employees(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ex_inventory_unit ON ex_inventory (project_id, lower(trim(unit_no)));

-- 3) the reservation form: net + loaded area, the meter price, and the maintenance deposit / agreed down payment as a % or an amount
ALTER TABLE ex_units
  ADD COLUMN net_area_m2       numeric(12,4) CHECK (net_area_m2 IS NULL OR net_area_m2 > 0),
  ADD COLUMN meter_price       numeric(16,2) CHECK (meter_price IS NULL OR meter_price > 0),
  ADD COLUMN maintenance_pct   numeric(7,4)  CHECK (maintenance_pct IS NULL OR maintenance_pct BETWEEN 0 AND 100),
  ADD COLUMN planned_down_pct  numeric(7,4)  CHECK (planned_down_pct IS NULL OR planned_down_pct BETWEEN 0 AND 100),
  ADD COLUMN inventory_id      uuid REFERENCES ex_inventory(id);
