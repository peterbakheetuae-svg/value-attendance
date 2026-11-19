-- Rollback of 084 (PROPOSED). Run only when no company payment is still waiting for its code (it would no longer fit the
-- status rule): the first statement refuses otherwise. Removes only what 084 added.
BEGIN;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM cash_expenses WHERE status = 'awaiting_otp') THEN
    RAISE EXCEPTION 'company payments are still waiting for their code — confirm or cancel them first';
  END IF;
END $$;
DELETE FROM action_otps WHERE company_id IS NOT NULL;
ALTER TABLE action_otps DROP CONSTRAINT IF EXISTS action_otps_one_owner;
DROP INDEX IF EXISTS action_otps_company;
ALTER TABLE action_otps DROP COLUMN IF EXISTS company_id;
ALTER TABLE action_otps ALTER COLUMN employee_id SET NOT NULL;
ALTER TABLE marketing_companies DROP COLUMN IF EXISTS payment_day;
DROP INDEX IF EXISTS cash_expenses_mk;
ALTER TABLE cash_expenses DROP COLUMN IF EXISTS mk_period;
ALTER TABLE cash_expenses DROP CONSTRAINT IF EXISTS cash_expenses_status_check;
ALTER TABLE cash_expenses ADD CONSTRAINT cash_expenses_status_check CHECK (status IN ('pending_approval','posted','rejected','reversed'));
COMMIT;
