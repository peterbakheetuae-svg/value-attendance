-- ربط الحساب بأكتر من جهاز: the first phone an employee signs in from is linked by itself (as before); every
-- other phone waits for the general manager / the administrative officer (or the owner) to approve it.
-- Only approved phones can sign in. Each session remembers its phone, so the in-shift tracking knows which
-- phone left the office.
CREATE TABLE employee_devices (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id   uuid NOT NULL REFERENCES employees(id),
  device_id     text NOT NULL CHECK (length(device_id) BETWEEN 16 AND 100),
  label         text CHECK (label IS NULL OR length(label) <= 120),
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  requested_at  timestamptz NOT NULL DEFAULT now(),
  decided_at    timestamptz,
  decided_by    uuid REFERENCES employees(id),
  last_login_at timestamptz,
  UNIQUE (employee_id, device_id)
);
CREATE INDEX employee_devices_pending ON employee_devices (status) WHERE status = 'pending';

-- the phone each account is already linked to stays linked (approved)
INSERT INTO employee_devices (employee_id, device_id, label, status, requested_at, decided_at, last_login_at)
  SELECT id, device_id, device_label, 'approved', COALESCE(device_bound_at, now()), device_bound_at, device_bound_at
    FROM employees WHERE device_id IS NOT NULL
  ON CONFLICT DO NOTHING;

ALTER TABLE sessions ADD COLUMN device_id text CHECK (device_id IS NULL OR length(device_id) BETWEEN 16 AND 100);

-- who may approve another phone: the owner and the «مسؤول إداري» position (the employee's general manager
-- may also approve his own people — checked in the API)
INSERT INTO permissions (key, description) VALUES ('devices.approve', 'Approve an extra phone for an account')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) VALUES ('owner', 'devices.approve') ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
  SELECT key, 'devices.approve' FROM roles WHERE key = 'admin_officer' OR name_ar = 'مسؤول إداري'
  ON CONFLICT DO NOTHING;

-- in-shift tracking: one state per phone (any phone that leaves the office raises the alert)
ALTER TABLE tracking_state ADD COLUMN device_key text NOT NULL DEFAULT '';
ALTER TABLE tracking_state ADD COLUMN device_label text;
ALTER TABLE tracking_state DROP CONSTRAINT tracking_state_pkey;
ALTER TABLE tracking_state ADD PRIMARY KEY (employee_id, device_key);
ALTER TABLE tracking_pings ADD COLUMN device_key text NOT NULL DEFAULT '';
