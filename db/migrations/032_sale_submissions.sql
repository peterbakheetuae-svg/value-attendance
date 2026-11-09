-- Unit sales submitted by the salesperson: the sale waits for the management's approval before any money can be
-- collected on it. HR / المدير record sales directly (as before) and may file the deal commission for the salesperson.
-- Additive only: existing sales stay 'active'.

INSERT INTO permissions (key, description) VALUES
  ('sales.approve', 'Approve / reject unit sales submitted by salespeople (never your own)')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('owner','sales.approve'), ('manager','sales.approve')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
SELECT r.key, rp.perm_key FROM roles r JOIN role_permissions rp ON rp.role_key = r.base_key
 WHERE r.base_key IS NOT NULL AND rp.perm_key = 'sales.approve'
ON CONFLICT DO NOTHING;

ALTER TABLE unit_sales DROP CONSTRAINT IF EXISTS unit_sales_status_check;
ALTER TABLE unit_sales ADD CONSTRAINT unit_sales_status_check CHECK (status IN ('pending','active','rejected','cancelled'));
ALTER TABLE unit_sales ADD COLUMN decided_by uuid REFERENCES employees(id);
ALTER TABLE unit_sales ADD COLUMN decided_at timestamptz;
ALTER TABLE unit_sales ADD COLUMN reject_reason text;
ALTER TABLE unit_sales ADD COLUMN commission_request_id uuid REFERENCES commission_requests(id);
ALTER TABLE unit_sales ADD CONSTRAINT unit_sales_four_eyes CHECK (decided_by IS NULL OR decided_by <> created_by);
ALTER TABLE unit_sales ADD CONSTRAINT unit_sales_reject_reason
  CHECK (status <> 'rejected' OR length(trim(COALESCE(reject_reason,''))) >= 3);

-- a unit waiting for approval is taken too
DROP INDEX unit_sales_one_active;
CREATE UNIQUE INDEX unit_sales_one_active ON unit_sales (project_id, lower(trim(unit_no))) WHERE status IN ('pending','active');

CREATE OR REPLACE FUNCTION unit_sales_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'unit sales are never deleted (cancel instead)'; END IF;
  IF OLD.status IN ('cancelled','rejected') THEN RAISE EXCEPTION 'a cancelled / rejected sale cannot be changed'; END IF;
  IF OLD.status = 'active' AND NEW.status NOT IN ('active','cancelled') THEN RAISE EXCEPTION 'an active sale can only be cancelled'; END IF;
  IF (NEW.project_id, NEW.unit_no, NEW.total_price, NEW.down_payment, NEW.installments_count, NEW.frequency, NEW.first_due_date,
      NEW.sale_date, NEW.created_by, NEW.ref_no) IS DISTINCT FROM
     (OLD.project_id, OLD.unit_no, OLD.total_price, OLD.down_payment, OLD.installments_count, OLD.frequency, OLD.first_due_date,
      OLD.sale_date, OLD.created_by, OLD.ref_no) THEN
    RAISE EXCEPTION 'the sale terms cannot be edited';
  END IF;
  RETURN NEW;
END $$;
