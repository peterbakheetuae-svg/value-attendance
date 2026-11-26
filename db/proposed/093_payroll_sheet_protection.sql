-- 093 — owner decisions F-2 and F-1 (2026-11-26), enforced by the database itself (not only by the API / app).
--
-- F-2: a payroll sheet (payroll_batches) and its lines (payroll_batch_lines):
--   * a sheet starts as a draft; it moves only along the approved workflow
--       draft / returned → pending_approval | cancelled,  pending_approval → approved | returned
--     approved and cancelled are final; its identity (id, ref_no, period, prepared_by, prepared_at) never changes;
--     approval needs its approver and time; a sheet is never deleted (a draft is cancelled instead)
--   * its lines are written (recalculated, removed) only while the sheet is a draft or returned — never once it is
--     waiting for approval, approved or cancelled; a line never moves to another sheet
--   Paying an approved line is unchanged: that writes a payout (payouts_guard, 031/085) and never touches the line.
-- F-1: an advance / work-expense payout is created only against its approved request: same employee, same kind, request
--   confirmed and not handed over outside the cashbox (one live payout per request: payouts_one_per_advance, 085).
--   INSERT only — existing payouts are never re-checked or changed (payouts_guard already freezes advance_id).
--
-- Additive: two functions, three triggers. No table, column or row is changed; nothing existing is re-validated.
-- TRUNCATE (the owner's data reset) and the backup restore tool (which disables user triggers on an empty database)
-- are not affected. Locking: CREATE TRIGGER takes a SHARE ROW EXCLUSIVE lock on the three tables for milliseconds.
-- Safe to re-run. PostgreSQL 16 and 18. Rollback: 093_rollback.sql.

CREATE OR REPLACE FUNCTION payroll_batches_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'a payroll sheet is never deleted (a draft is cancelled)' USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' OR NEW.submitted_at IS NOT NULL OR NEW.decided_by IS NOT NULL OR NEW.decided_at IS NOT NULL THEN
      RAISE EXCEPTION 'a payroll sheet starts as a draft' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.id, NEW.ref_no, NEW.period, NEW.prepared_by, NEW.prepared_at)
     IS DISTINCT FROM (OLD.id, OLD.ref_no, OLD.period, OLD.prepared_by, OLD.prepared_at) THEN
    RAISE EXCEPTION 'a payroll sheet''s month, number and preparer never change' USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.status IN ('approved', 'cancelled') THEN
    RAISE EXCEPTION 'an % payroll sheet is final', OLD.status USING ERRCODE = 'check_violation';
  END IF;
  IF NOT ((OLD.status IN ('draft', 'returned') AND NEW.status IN (OLD.status, 'pending_approval', 'cancelled'))
       OR (OLD.status = 'pending_approval' AND NEW.status IN ('approved', 'returned'))) THEN
    RAISE EXCEPTION 'a payroll sheet cannot go from % to %', OLD.status, NEW.status USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status = 'approved' AND (NEW.decided_by IS NULL OR NEW.decided_at IS NULL) THEN
    RAISE EXCEPTION 'an approval records its approver and time' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS payroll_batches_guard ON payroll_batches;
CREATE TRIGGER payroll_batches_guard BEFORE INSERT OR UPDATE OR DELETE ON payroll_batches
  FOR EACH ROW EXECUTE FUNCTION payroll_batches_guard();

CREATE OR REPLACE FUNCTION payroll_batch_lines_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.batch_id IS DISTINCT FROM OLD.batch_id THEN
    RAISE EXCEPTION 'a payroll line never moves to another sheet' USING ERRCODE = 'check_violation';
  END IF;
  -- the sheet's status, locked against a concurrent submit / approval until this statement's transaction ends
  SELECT status INTO s FROM payroll_batches WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.batch_id ELSE NEW.batch_id END FOR SHARE;
  IF s IS NULL OR s NOT IN ('draft', 'returned') THEN
    RAISE EXCEPTION 'the lines of a % payroll sheet cannot be changed', COALESCE(s, 'missing') USING ERRCODE = 'check_violation';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

DROP TRIGGER IF EXISTS payroll_batch_lines_guard ON payroll_batch_lines;
CREATE TRIGGER payroll_batch_lines_guard BEFORE INSERT OR UPDATE OR DELETE ON payroll_batch_lines
  FOR EACH ROW EXECUTE FUNCTION payroll_batch_lines_guard();

CREATE OR REPLACE FUNCTION payouts_request_link() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  IF NEW.kind IN ('advance', 'work_expense') THEN
    IF NEW.advance_id IS NULL THEN
      RAISE EXCEPTION 'an advance or work expense is paid only against its approved request' USING ERRCODE = 'check_violation';
    END IF;
    SELECT employee_id, kind, status, paid_outside INTO r FROM advance_requests WHERE id = NEW.advance_id FOR SHARE;
    IF NOT FOUND OR r.employee_id <> NEW.employee_id OR r.kind <> NEW.kind OR r.status <> 'confirmed' OR r.paid_outside THEN
      RAISE EXCEPTION 'the request is not an approved % of this employee waiting for payment', NEW.kind USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.advance_id IS NOT NULL THEN
    RAISE EXCEPTION 'a request is linked only to an advance or work-expense payment' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS payouts_request_link ON payouts;
CREATE TRIGGER payouts_request_link BEFORE INSERT ON payouts
  FOR EACH ROW EXECUTE FUNCTION payouts_request_link();
