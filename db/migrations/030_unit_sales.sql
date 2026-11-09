-- Financial system, phase 2: unit sales, reservation → down payment → installments. Additive only.
-- A sale points at an existing project (commission_projects) and the unit number written the same way as in the
-- commissions system (project + trimmed, case-insensitive unit number = the link between the two).
-- Money received is always a numbered receipt in cash_receipts (phase 1) linked to the sale and the installment,
-- so the cashboxes, the receipts and the installments can never disagree.

INSERT INTO permissions (key, description) VALUES
  ('sales.view',   'See unit sales and the installments due page'),
  ('sales.manage', 'Register unit sales and collect down payments / installments'),
  ('sales.cancel', 'Cancel a unit sale (full refund of what was collected)')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('owner','sales.view'), ('owner','sales.manage'), ('owner','sales.cancel'),
  ('manager','sales.view'), ('manager','sales.manage'), ('manager','sales.cancel'),
  ('hr_manager','sales.view'), ('hr_manager','sales.manage')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
SELECT r.key, rp.perm_key FROM roles r JOIN role_permissions rp ON rp.role_key = r.base_key
 WHERE r.base_key IS NOT NULL AND rp.perm_key LIKE 'sales.%'
ON CONFLICT DO NOTHING;

CREATE TABLE unit_sales (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no                bigint NOT NULL UNIQUE DEFAULT nextval('cash_ref_seq'),
  project_id            uuid NOT NULL REFERENCES commission_projects(id),
  unit_no               text NOT NULL CHECK (length(trim(unit_no)) BETWEEN 1 AND 60),
  buyer_name            text NOT NULL CHECK (length(trim(buyer_name)) >= 2),
  buyer_phone           text NOT NULL DEFAULT '',
  buyer_contact         text NOT NULL DEFAULT '',             -- address / national id / other basic contact
  total_price           numeric(16,2) NOT NULL CHECK (total_price > 0),
  down_payment          numeric(16,2) NOT NULL CHECK (down_payment >= 0),
  sale_date             date NOT NULL,
  down_payment_due_date date NOT NULL,
  frequency             text CHECK (frequency IN ('monthly','quarterly','semiannual','annual')),
  installments_count    int NOT NULL DEFAULT 0 CHECK (installments_count BETWEEN 0 AND 600),
  first_due_date        date,
  notes                 text NOT NULL DEFAULT '',
  attachment            bytea CHECK (attachment IS NULL OR octet_length(attachment) <= 600000),
  status                text NOT NULL DEFAULT 'active' CHECK (status IN ('active','cancelled')),
  created_by            uuid NOT NULL REFERENCES employees(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  cancelled_by          uuid REFERENCES employees(id),
  cancelled_at          timestamptz,
  cancel_reason         text,
  CHECK (down_payment <= total_price),
  CHECK (installments_count = 0 OR (frequency IS NOT NULL AND first_due_date IS NOT NULL)),
  CHECK (installments_count > 0 OR down_payment = total_price),
  CHECK (status <> 'cancelled' OR (cancelled_by IS NOT NULL AND length(trim(COALESCE(cancel_reason,''))) >= 3))
);
-- one buyer per unit: no second live sale of the same unit in the same project
CREATE UNIQUE INDEX unit_sales_one_active ON unit_sales (project_id, lower(trim(unit_no))) WHERE status = 'active';
CREATE INDEX unit_sales_buyer ON unit_sales (lower(buyer_name));

-- the schedule: seq 0 = the down payment (the reservation counts toward it), seq 1.. = installments
CREATE TABLE sale_installments (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id    uuid NOT NULL REFERENCES unit_sales(id),
  seq        int NOT NULL CHECK (seq >= 0),
  due_date   date NOT NULL,
  amount_egp numeric(16,2) NOT NULL CHECK (amount_egp >= 0),
  UNIQUE (sale_id, seq)
);
CREATE INDEX sale_installments_due ON sale_installments (due_date);

ALTER TABLE cash_receipts ADD CONSTRAINT cash_receipts_sale_fk FOREIGN KEY (sale_id) REFERENCES unit_sales(id);
ALTER TABLE cash_receipts ADD CONSTRAINT cash_receipts_installment_fk FOREIGN KEY (installment_id) REFERENCES sale_installments(id);
CREATE INDEX cash_receipts_installment ON cash_receipts (installment_id) WHERE installment_id IS NOT NULL;
-- refunds of a cancelled sale are expenses linked to it
ALTER TABLE cash_expenses ADD COLUMN sale_id uuid REFERENCES unit_sales(id);

-- a sale and its schedule are never deleted; amounts never edited (only the cancellation fields may be set)
CREATE FUNCTION unit_sales_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'unit sales are never deleted (cancel instead)'; END IF;
  IF OLD.status = 'cancelled' THEN RAISE EXCEPTION 'a cancelled sale cannot be changed'; END IF;
  IF (NEW.project_id, NEW.unit_no, NEW.total_price, NEW.down_payment, NEW.installments_count, NEW.frequency, NEW.first_due_date,
      NEW.sale_date, NEW.created_by, NEW.ref_no) IS DISTINCT FROM
     (OLD.project_id, OLD.unit_no, OLD.total_price, OLD.down_payment, OLD.installments_count, OLD.frequency, OLD.first_due_date,
      OLD.sale_date, OLD.created_by, OLD.ref_no) THEN
    RAISE EXCEPTION 'the sale terms cannot be edited';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER unit_sales_immutable BEFORE UPDATE OR DELETE ON unit_sales FOR EACH ROW EXECUTE FUNCTION unit_sales_guard();
CREATE FUNCTION sale_installments_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'the installment schedule cannot be edited or deleted';
END $$;
CREATE TRIGGER sale_installments_immutable BEFORE UPDATE OR DELETE ON sale_installments FOR EACH ROW EXECUTE FUNCTION sale_installments_guard();
