-- a sensitive change (a new Meta «Verify token») is made only after the 4-digit code e-mailed to the person making it
CREATE TABLE action_otps (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  action      text NOT NULL,
  code_hash   text NOT NULL,
  attempts    int NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL,
  used_at     timestamptz
);
CREATE INDEX action_otps_employee ON action_otps (employee_id, action, created_at DESC);
