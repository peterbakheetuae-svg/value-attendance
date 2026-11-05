-- "Forgot password": a 6-digit code emailed to the employee (10 minutes, 5 tries),
-- exchanged for a one-time reset token (15 minutes). Only hashes are stored.
CREATE TABLE password_otps (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id      uuid NOT NULL REFERENCES employees(id),
  code_hash        text NOT NULL,
  expires_at       timestamptz NOT NULL,
  attempts         int NOT NULL DEFAULT 0,
  verified_at      timestamptz,
  reset_token_hash text UNIQUE,
  reset_expires_at timestamptz,
  consumed_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX password_otps_employee ON password_otps (employee_id, created_at DESC);
