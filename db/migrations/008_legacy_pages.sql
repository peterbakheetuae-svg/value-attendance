-- Backing data for the original JPH pages: advances / work expenses, holiday periods,
-- admin-sent notifications, and employee bank details.

CREATE TABLE advance_requests (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id  uuid NOT NULL REFERENCES employees(id),
  kind         text NOT NULL CHECK (kind IN ('advance', 'work_expense')),   -- سلفة / مصاريف عمل
  period       date NOT NULL CHECK (extract(day FROM period) = 1),          -- the payroll month it belongs to
  amount_egp   numeric(12,2) NOT NULL CHECK (amount_egp > 0 AND amount_egp <= 1000000),
  note         text NOT NULL DEFAULT '',
  attachment   bytea CHECK (attachment IS NULL OR octet_length(attachment) <= 600000),
  status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'rejected', 'cancelled')),
  created_by   uuid NOT NULL REFERENCES employees(id),
  decided_by   uuid REFERENCES employees(id),
  decided_at   timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  -- four eyes: nobody confirms their own advance
  CHECK (decided_by IS NULL OR decided_by <> employee_id)
);
CREATE INDEX advance_requests_emp ON advance_requests (employee_id, period);

-- a public holiday period is several days sharing one group
ALTER TABLE holidays
  ADD COLUMN group_id     uuid,
  ADD COLUMN holiday_type text NOT NULL DEFAULT 'عطلة رسمية',
  ADD COLUMN description  text NOT NULL DEFAULT '';
UPDATE holidays SET group_id = id WHERE group_id IS NULL;
ALTER TABLE holidays ALTER COLUMN group_id SET NOT NULL, ALTER COLUMN group_id SET DEFAULT gen_random_uuid();

ALTER TABLE notifications
  ADD COLUMN sender_id uuid REFERENCES employees(id),
  ADD COLUMN category  text;
CREATE INDEX notifications_sender ON notifications (sender_id, created_at) WHERE sender_id IS NOT NULL;

ALTER TABLE employees
  ADD COLUMN bank_name       text CHECK (bank_name IS NULL OR length(bank_name) <= 120),
  ADD COLUMN account_holder  text CHECK (account_holder IS NULL OR length(account_holder) <= 120),
  ADD COLUMN iban            text CHECK (iban IS NULL OR length(iban) <= 40),
  ADD COLUMN account_number  text CHECK (account_number IS NULL OR length(account_number) <= 40);
