-- المشاريع الحصري (exclusive projects): the office takes all the money (reservation → contract → installments)
-- into the accountant's cashbox, holds it for the project's owner (أمانة), and earns its commission in stages:
--   cash sale: the whole commission (default 5%) at the contract;
--   installments: contract_pct (default 3%) at the contract, then installment_pct (agreed per unit, e.g. 0.5% / 1%)
--   with every installment fully collected, until the total is reached.
-- All percentages are of the unit's total price. The salesperson (0.2%) and his sales manager (0.1%) earn at the
-- contract, cash or installments. The commission stays inside the owner's money until المالك / المدير العام
-- transfers it (ex_commission_transfers). Money to the owner leaves the office cashbox by an approved expense.

ALTER TABLE commission_projects
  ADD COLUMN kind            text NOT NULL DEFAULT 'marketing' CHECK (kind IN ('marketing','exclusive')),
  ADD COLUMN owner_name      text,
  ADD COLUMN owner_phone     text NOT NULL DEFAULT '',
  ADD COLUMN contract_pct    numeric(7,4) CHECK (contract_pct IS NULL OR (contract_pct >= 0 AND contract_pct <= 100)),
  ADD COLUMN installment_pct numeric(7,4) CHECK (installment_pct IS NULL OR (installment_pct >= 0 AND installment_pct <= 100)),
  ADD CONSTRAINT commission_projects_exclusive CHECK (kind = 'marketing' OR
    (owner_name IS NOT NULL AND length(trim(owner_name)) >= 2 AND contract_pct IS NOT NULL AND installment_pct IS NOT NULL
     AND contract_pct <= total_pct));

CREATE TABLE ex_units (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no             bigint NOT NULL UNIQUE DEFAULT nextval('cash_ref_seq'),
  project_id         uuid NOT NULL REFERENCES commission_projects(id),
  unit_no            text NOT NULL CHECK (length(trim(unit_no)) BETWEEN 1 AND 60),
  client_name        text NOT NULL CHECK (length(trim(client_name)) >= 2),
  client_phone       text NOT NULL DEFAULT '',
  unit_price         numeric(16,2) NOT NULL CHECK (unit_price > 0),
  deposit_amount     numeric(16,2) NOT NULL CHECK (deposit_amount > 0),
  sales_id           uuid NOT NULL REFERENCES employees(id),
  -- percentages frozen from the project when the unit is reserved (the contract may set its own installment_pct)
  total_pct          numeric(7,4) NOT NULL,
  contract_pct       numeric(7,4) NOT NULL,
  sales_pct          numeric(7,4) NOT NULL,
  manager_pct        numeric(7,4) NOT NULL,
  status             text NOT NULL DEFAULT 'reserving'
                     CHECK (status IN ('reserving','reserved','contract_pending','contracted','cancel_pending','cancelled')),
  -- the contract terms (sent by the salesperson, approved by المالك / المدير العام)
  payment_type       text CHECK (payment_type IN ('cash','installments')),
  down_payment       numeric(16,2) CHECK (down_payment IS NULL OR down_payment >= 0),
  installments_count int CHECK (installments_count IS NULL OR installments_count BETWEEN 1 AND 240),
  every_months       int CHECK (every_months IS NULL OR every_months BETWEEN 1 AND 12),
  first_due_date     date,
  installment_pct    numeric(7,4) CHECK (installment_pct IS NULL OR installment_pct >= 0),
  contract_note      text NOT NULL DEFAULT '',
  contract_requested_at timestamptz,
  contracted_by      uuid REFERENCES employees(id),
  contracted_at      timestamptz,
  commission_request_id uuid REFERENCES commission_requests(id),
  reject_reason      text,
  -- cancelling (the deposit goes back to the client)
  previous_status    text,
  cancel_reason      text,
  cancel_requested_by uuid REFERENCES employees(id),
  cancelled_by       uuid REFERENCES employees(id),
  cancelled_at       timestamptz,
  notes              text NOT NULL DEFAULT '',
  created_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (contracted_by IS NULL OR contracted_by <> sales_id),
  CHECK (status <> 'contracted' OR (payment_type IS NOT NULL AND down_payment IS NOT NULL AND contracted_by IS NOT NULL)),
  CHECK (payment_type IS DISTINCT FROM 'installments' OR (installments_count IS NOT NULL AND every_months IS NOT NULL
         AND first_due_date IS NOT NULL AND installment_pct IS NOT NULL))
);
CREATE UNIQUE INDEX ex_units_open ON ex_units (project_id, lower(trim(unit_no))) WHERE status <> 'cancelled';
CREATE INDEX ex_units_project ON ex_units (project_id, status);

CREATE TABLE ex_installments (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id    uuid NOT NULL REFERENCES ex_units(id),
  seq        int NOT NULL CHECK (seq >= 1),
  due_date   date NOT NULL,
  amount_egp numeric(16,2) NOT NULL CHECK (amount_egp > 0),
  UNIQUE (unit_id, seq)
);
CREATE INDEX ex_installments_due ON ex_installments (due_date);

-- the money: receipts in, the refund of a cancelled reservation / the owner's payouts out (all real cash records)
ALTER TABLE cash_receipts ADD COLUMN ex_unit_id uuid REFERENCES ex_units(id),
                          ADD COLUMN ex_installment_id uuid REFERENCES ex_installments(id);
CREATE INDEX cash_receipts_ex_unit ON cash_receipts (ex_unit_id) WHERE ex_unit_id IS NOT NULL;
ALTER TABLE cash_expenses ADD COLUMN ex_unit_id uuid REFERENCES ex_units(id),
                          ADD COLUMN ex_project_id uuid REFERENCES commission_projects(id),
                          ADD COLUMN ex_kind text CHECK (ex_kind IN ('refund','owner_payout'));
CREATE INDEX cash_expenses_ex_project ON cash_expenses (ex_project_id) WHERE ex_project_id IS NOT NULL;

-- the commission moving out of the owner's money into the office's own (no cash moves: same cashbox)
CREATE TABLE ex_commission_transfers (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no      bigint NOT NULL UNIQUE DEFAULT nextval('cash_ref_seq'),
  project_id  uuid NOT NULL REFERENCES commission_projects(id),
  amount_egp  numeric(16,2) NOT NULL CHECK (amount_egp > 0),
  note        text NOT NULL DEFAULT '',
  created_by  uuid NOT NULL REFERENCES employees(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ex_commission_transfers_project ON ex_commission_transfers (project_id);
CREATE FUNCTION ex_no_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'commission transfers are final'; END $$;
CREATE TRIGGER ex_commission_transfers_final BEFORE UPDATE OR DELETE ON ex_commission_transfers FOR EACH ROW EXECUTE FUNCTION ex_no_change();
CREATE TRIGGER ex_installments_final BEFORE UPDATE OR DELETE ON ex_installments FOR EACH ROW EXECUTE FUNCTION ex_no_change();

-- a contract's staff commission is a normal commission request (approved at once) — keep exclusive ones apart
ALTER TABLE commission_requests ADD COLUMN ex_unit_id uuid REFERENCES ex_units(id);

-- reserving a unit: the sales team + المالك / المدير العام
INSERT INTO permissions (key, description) VALUES ('exclusive.reserve', 'Reserve units in exclusive projects (حجز وحدة)')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('owner','exclusive.reserve'), ('manager','exclusive.reserve'), ('sales_manager','exclusive.reserve'), ('sales_employee','exclusive.reserve')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
SELECT r.key, 'exclusive.reserve' FROM roles r WHERE r.base_key IN ('sales_manager','sales_employee','manager')
ON CONFLICT DO NOTHING;
