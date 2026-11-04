-- Hourly permission (إذن ساعات) / external visit (زيارة) during a working day — replaces the break.
-- A separate table because the lifecycle differs from leave requests: single decision by the
-- team's sales manager OR HR, an expected return time that is monitored, extensions, actual return.
CREATE TABLE outing_requests (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id         uuid NOT NULL REFERENCES employees(id),
  kind                text NOT NULL CHECK (kind IN ('permission','visit')),
  parent_id           uuid REFERENCES outing_requests(id),          -- set for extension requests
  work_date           date NOT NULL,
  requested_at        timestamptz NOT NULL DEFAULT now(),
  expected_return_at  timestamptz NOT NULL,
  reason              text NOT NULL CHECK (length(trim(reason)) >= 3 AND length(reason) <= 1000),
  manager_id          uuid REFERENCES employees(id),                -- snapshot at submission
  status              text NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','approved','rejected','cancelled','superseded')),
  decided_by          uuid REFERENCES employees(id),
  decided_at          timestamptz,
  decision_note       text,
  returned_at         timestamptz,
  overdue_alerted_at  timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (expected_return_at > requested_at),
  CHECK (decided_by IS NULL OR decided_by <> employee_id),
  CHECK (manager_id IS NULL OR manager_id <> employee_id)
);
CREATE INDEX outing_requests_emp_day ON outing_requests (employee_id, work_date);
CREATE INDEX outing_requests_open ON outing_requests (status) WHERE returned_at IS NULL;

-- approval history is immutable: a decided request never changes decision or owner
CREATE FUNCTION outing_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'outing requests are never deleted' USING ERRCODE = '42501'; END IF;
  IF NEW.employee_id <> OLD.employee_id OR NEW.kind <> OLD.kind OR NEW.expected_return_at <> OLD.expected_return_at
     OR NEW.requested_at <> OLD.requested_at OR NEW.reason <> OLD.reason THEN
    RAISE EXCEPTION 'outing request content is immutable' USING ERRCODE = '42501';
  END IF;
  IF OLD.status IN ('rejected','cancelled') AND NEW.status <> OLD.status THEN
    RAISE EXCEPTION 'outing request % is final', OLD.id USING ERRCODE = '42501';
  END IF;
  IF OLD.status = 'approved' AND NEW.status NOT IN ('approved','superseded') THEN
    RAISE EXCEPTION 'an approved outing can only be superseded by an extension' USING ERRCODE = '42501';
  END IF;
  IF OLD.decided_by IS NOT NULL AND NEW.decided_by IS DISTINCT FROM OLD.decided_by THEN
    RAISE EXCEPTION 'decision is immutable' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER outing_guard BEFORE UPDATE OR DELETE ON outing_requests FOR EACH ROW EXECUTE FUNCTION outing_guard();
