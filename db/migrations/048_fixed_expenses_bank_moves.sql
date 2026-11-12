-- مصروفات ثابتة (الإيجار، الأوفيس بوي، الفواتير الثابتة …): a template paid once a month with «صرف» — it becomes a normal
-- expense of that month (printable voucher, the signed receipt's photo added after).
CREATE TABLE fixed_expenses (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 120),
  category       text NOT NULL CHECK (length(trim(category)) BETWEEN 2 AND 80),
  amount_egp     numeric(14,2) NOT NULL CHECK (amount_egp > 0),
  beneficiary    text NOT NULL CHECK (length(trim(beneficiary)) BETWEEN 2 AND 120),
  cashbox        text NOT NULL CHECK (cashbox IN ('office','hr')),
  payment_method text NOT NULL DEFAULT 'cash' CHECK (payment_method IN ('cash','bank')),
  notes          text NOT NULL DEFAULT '',
  active         boolean NOT NULL DEFAULT true,
  created_by     uuid NOT NULL REFERENCES employees(id),
  created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE cash_expenses ADD COLUMN fixed_expense_id uuid REFERENCES fixed_expenses(id),
                          ADD COLUMN fixed_period date;
CREATE UNIQUE INDEX cash_expenses_fixed_once ON cash_expenses (fixed_expense_id, fixed_period)
  WHERE fixed_expense_id IS NOT NULL AND status IN ('pending_approval','posted');

-- نقل أموال من البنك إلى خزنة المكتب: the box's total does not change — only its bank part becomes cash.
CREATE TABLE cash_bank_moves (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no      bigint NOT NULL UNIQUE DEFAULT nextval('cash_ref_seq'),
  cashbox     text NOT NULL DEFAULT 'office' CHECK (cashbox IN ('office','hr')),
  direction   text NOT NULL DEFAULT 'bank_to_cash' CHECK (direction IN ('bank_to_cash','cash_to_bank')),
  amount_egp  numeric(14,2) NOT NULL CHECK (amount_egp > 0),
  note        text NOT NULL DEFAULT '',
  created_by  uuid NOT NULL REFERENCES employees(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER cash_bank_moves_final BEFORE UPDATE OR DELETE ON cash_bank_moves FOR EACH ROW EXECUTE FUNCTION cash_no_delete();
