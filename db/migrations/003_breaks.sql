-- One break per working day (same rule as the original JPH app: start → end, then the break is finished).
ALTER TABLE company_settings
  ADD COLUMN break_minutes int NOT NULL DEFAULT 60 CHECK (break_minutes BETWEEN 0 AND 240);

CREATE TABLE attendance_breaks (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  attendance_id  uuid NOT NULL UNIQUE REFERENCES attendance(id),
  employee_id    uuid NOT NULL REFERENCES employees(id),
  started_at     timestamptz NOT NULL,
  ended_at       timestamptz,
  allowed_minutes int NOT NULL,
  CHECK (ended_at IS NULL OR ended_at > started_at)
);
CREATE INDEX attendance_breaks_employee ON attendance_breaks (employee_id, started_at);

-- the break times employees record cannot be rewritten afterwards
CREATE FUNCTION attendance_breaks_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'attendance breaks are append-only' USING ERRCODE = 'P0001'; END IF;
  IF NEW.started_at <> OLD.started_at OR (OLD.ended_at IS NOT NULL AND NEW.ended_at IS DISTINCT FROM OLD.ended_at) THEN
    RAISE EXCEPTION 'recorded break times cannot be changed' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER attendance_breaks_guard BEFORE UPDATE OR DELETE ON attendance_breaks
  FOR EACH ROW EXECUTE FUNCTION attendance_breaks_guard();
