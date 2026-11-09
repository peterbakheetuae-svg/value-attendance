-- Financial system, phase 3: monthly payroll batches with review / approval, manual advance deductions,
-- employee receipt confirmation and disputes. Additive only; past months keep computing exactly as before.

INSERT INTO permissions (key, description) VALUES
  ('payroll.prepare', 'Prepare the monthly payroll batch, set advance deductions, pay approved salaries'),
  ('payroll.approve', 'Approve the monthly payroll batch (never one you prepared)')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('owner','payroll.prepare'), ('owner','payroll.approve'),
  ('manager','payroll.approve'),
  ('hr_manager','payroll.prepare')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
SELECT r.key, rp.perm_key FROM roles r JOIN role_permissions rp ON rp.role_key = r.base_key
 WHERE r.base_key IS NOT NULL AND rp.perm_key LIKE 'payroll.%'
ON CONFLICT DO NOTHING;

-- Advance repayment (approved policy: the amount deducted each month is set by hand, at most two stages).
-- An advance with deduction rows is deducted only by those rows; an advance without any keeps the old rule
-- (deducted in full in its own month) so historic payroll never changes.
CREATE TABLE advance_deductions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  advance_id  uuid NOT NULL REFERENCES advance_requests(id),
  employee_id uuid NOT NULL REFERENCES employees(id),
  period      date NOT NULL CHECK (extract(day FROM period) = 1),
  amount_egp  numeric(12,2) NOT NULL CHECK (amount_egp > 0),
  note        text NOT NULL DEFAULT '',
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','cancelled')),
  created_by  uuid NOT NULL REFERENCES employees(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  cancelled_by uuid REFERENCES employees(id),
  cancelled_at timestamptz
);
-- the same advance is never deducted twice in one month
CREATE UNIQUE INDEX advance_deductions_once ON advance_deductions (advance_id, period) WHERE status = 'active';
CREATE INDEX advance_deductions_payroll ON advance_deductions (employee_id, period) WHERE status = 'active';

CREATE TABLE payroll_batches (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no        bigint NOT NULL UNIQUE DEFAULT nextval('cash_ref_seq'),
  period        date NOT NULL CHECK (extract(day FROM period) = 1),
  status        text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','pending_approval','approved','returned','cancelled')),
  prepared_by   uuid NOT NULL REFERENCES employees(id),
  prepared_at   timestamptz NOT NULL DEFAULT now(),
  submitted_at  timestamptz,
  decided_by    uuid REFERENCES employees(id),
  decided_at    timestamptz,
  return_reason text,
  CHECK (decided_by IS NULL OR decided_by <> prepared_by)            -- separation of duties
);
-- one live batch per month
CREATE UNIQUE INDEX payroll_batches_one_per_month ON payroll_batches (period) WHERE status <> 'cancelled';

CREATE TABLE payroll_batch_lines (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id    uuid NOT NULL REFERENCES payroll_batches(id),
  employee_id uuid NOT NULL REFERENCES employees(id),
  snapshot    jsonb NOT NULL,                         -- the full calculation (salary, deductions, commissions, advances, net) at preparation
  net_egp     numeric(14,2) NOT NULL,
  UNIQUE (batch_id, employee_id)
);

-- the employee can report a problem with a payment instead of confirming it
ALTER TABLE payouts DROP CONSTRAINT IF EXISTS payouts_status_check;
ALTER TABLE payouts ADD CONSTRAINT payouts_status_check CHECK (status IN ('pending','received','cancelled','disputed'));
ALTER TABLE payouts ADD COLUMN dispute_reason text;
ALTER TABLE payouts ADD COLUMN disputed_at timestamptz;
ALTER TABLE payouts ADD COLUMN batch_line_id uuid REFERENCES payroll_batch_lines(id);
