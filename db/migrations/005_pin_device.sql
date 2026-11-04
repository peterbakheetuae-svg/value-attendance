-- Value HR login: mobile number + numeric PIN, account bound to the first device that signs in.
ALTER TABLE company_settings
  ADD COLUMN allow_pin       boolean NOT NULL DEFAULT true,   -- PIN (4–8 digits) for sales roles; admin roles keep passwords
  ADD COLUMN device_binding  boolean NOT NULL DEFAULT true;   -- owner is never bound (cannot lock themselves out)

ALTER TABLE employees
  ADD COLUMN device_id        text CHECK (device_id IS NULL OR length(device_id) BETWEEN 16 AND 100),
  ADD COLUMN device_label     text CHECK (device_label IS NULL OR length(device_label) <= 120),
  ADD COLUMN device_bound_at  timestamptz;
