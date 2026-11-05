-- Cash handed out (صرف): salary (قبض), advances, commissions, work-expense refunds — paid by HR from the
-- cash HR received from the manager / owner (صرف أموال = kind 'fund'). The recipient confirms "تم الاستلام".
INSERT INTO permissions (key, description) VALUES
  ('finance.disburse', 'Pay salaries / advances / commissions / work expenses to employees from the cash box'),
  ('finance.fund',     'Hand cash to HR for paying employees')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('owner','finance.disburse'), ('owner','finance.fund'),
  ('hr_manager','finance.disburse'),
  ('manager','finance.fund')
  ON CONFLICT DO NOTHING;

CREATE TABLE payouts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id   uuid NOT NULL REFERENCES employees(id),          -- who receives the money
  kind          text NOT NULL CHECK (kind IN ('salary','advance','commission','work_expense','fund')),
  amount_egp    numeric(12,2) NOT NULL CHECK (amount_egp > 0 AND amount_egp <= 10000000),
  period        date NOT NULL CHECK (extract(day FROM period) = 1),
  note          text NOT NULL DEFAULT '' CHECK (length(note) <= 1000),
  advance_id    uuid REFERENCES advance_requests(id),
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','received','cancelled')),
  created_by    uuid NOT NULL REFERENCES employees(id),          -- who hands it over
  created_at    timestamptz NOT NULL DEFAULT now(),
  received_at   timestamptz,
  cancelled_at  timestamptz,
  CHECK (created_by <> employee_id),
  CHECK ((status = 'received') = (received_at IS NOT NULL))
);
CREATE INDEX payouts_employee ON payouts (employee_id, period);
CREATE INDEX payouts_creator ON payouts (created_by);
