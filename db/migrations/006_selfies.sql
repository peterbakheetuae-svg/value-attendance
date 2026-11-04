-- Value HR: selfie at check-in, deleted automatically after the retention period.
ALTER TABLE company_settings
  ADD COLUMN selfie_required        boolean NOT NULL DEFAULT false,
  ADD COLUMN selfie_retention_days  int NOT NULL DEFAULT 30 CHECK (selfie_retention_days BETWEEN 1 AND 365);

CREATE TABLE attendance_selfies (
  attendance_id  uuid PRIMARY KEY REFERENCES attendance(id),
  employee_id    uuid NOT NULL REFERENCES employees(id),
  image          bytea NOT NULL CHECK (octet_length(image) <= 400000),
  mime           text NOT NULL CHECK (mime IN ('image/jpeg', 'image/png', 'image/webp')),
  taken_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX attendance_selfies_taken ON attendance_selfies (taken_at);
