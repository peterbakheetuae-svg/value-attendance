-- 084 (PROPOSED — not in db/migrations, no build runs it; it needs the owner's approval first).
-- The disbursement code for the marketing companies' money. A payment to a company is an expense of a cashbox (as today);
-- with this it first waits for the company's 4-digit code («awaiting_otp»: out of the cashbox only once the code is
-- entered — cash_ledger counts posted / reversed only). Additive: no row changes, nothing dropped. Rollback: 084_rollback.sql.
--  • cash_expenses.status gains 'awaiting_otp';
--  • cash_expenses.mk_period: the month a fixed company's fee is for (its salary month) — NULL for anything else;
--  • action_otps can belong to a company (company_id) instead of an employee — exactly one of the two;
--  • marketing_companies.payment_day: the day of the month a commission company is paid (NULL = no fixed day).
-- Applied by the migration runner (one transaction); by hand: BEGIN; … COMMIT;

ALTER TABLE cash_expenses DROP CONSTRAINT IF EXISTS cash_expenses_status_check;
ALTER TABLE cash_expenses ADD CONSTRAINT cash_expenses_status_check
  CHECK (status IN ('pending_approval','posted','rejected','reversed','awaiting_otp'));
ALTER TABLE cash_expenses ADD COLUMN mk_period date CHECK (mk_period IS NULL OR extract(day FROM mk_period) = 1);
CREATE INDEX cash_expenses_mk ON cash_expenses (marketing_company_id, mk_period) WHERE marketing_company_id IS NOT NULL;

ALTER TABLE action_otps ALTER COLUMN employee_id DROP NOT NULL;
ALTER TABLE action_otps ADD COLUMN company_id uuid REFERENCES marketing_companies(id) ON DELETE CASCADE;
ALTER TABLE action_otps ADD CONSTRAINT action_otps_one_owner CHECK ((employee_id IS NULL) <> (company_id IS NULL));
CREATE INDEX action_otps_company ON action_otps (company_id, action, created_at DESC) WHERE company_id IS NOT NULL;

ALTER TABLE marketing_companies ADD COLUMN payment_day smallint CHECK (payment_day IS NULL OR payment_day BETWEEN 1 AND 28);
