-- The sales flow, one step after the other (حجز → تعاقد), done by the salesperson from «المبيعات»:
--   حجز:   the deposit (exclusive projects) goes into the cashbox at once; the commission is potential (محتملة).
--          A marketing project's reservation has no money of ours — only the potential commission.
--   تعاقد: the salesperson turns the reservation into a contract himself; the down payment (or the whole price,
--          cash) goes into the cashbox; the commission becomes receivable (واجبة التحصيل).
--   تم التحصيل: المالك / المدير العام marks a unit's commission collected → it enters the commissions (العمولات).
-- The staff commission (السيلز / مدير السيلز) still waits for المالك / المدير العام's approval as a normal request.
-- Each project carries the marketing companies' % (عمولة شركات التسويق); the unit's «مصدر العميل» is the office
-- (no marketing commission) or a marketing company paid by commission. Additive only.

ALTER TABLE commission_projects ADD COLUMN marketing_pct numeric(7,4) NOT NULL DEFAULT 0,
  ADD CONSTRAINT commission_projects_marketing_pct CHECK (marketing_pct >= 0 AND marketing_pct <= company_pct);

-- a marketing reservation holds no money of ours
ALTER TABLE ex_units DROP CONSTRAINT IF EXISTS ex_units_deposit_amount_check;
ALTER TABLE ex_units ADD CONSTRAINT ex_units_deposit_amount_check CHECK (deposit_amount >= 0);
-- the salesperson makes the contract himself now (the staff commission is what waits for approval)
ALTER TABLE ex_units DROP CONSTRAINT IF EXISTS ex_units_check;

-- «تم التحصيل» per unit: an exclusive unit's commission moves out of the owner's money; a marketing unit's
-- commission is a receipt from the developer
ALTER TABLE ex_commission_transfers ADD COLUMN unit_id uuid REFERENCES ex_units(id);
ALTER TABLE cash_receipts ADD COLUMN commission_unit_id uuid REFERENCES ex_units(id);
CREATE INDEX cash_receipts_commission_unit ON cash_receipts (commission_unit_id) WHERE commission_unit_id IS NOT NULL;
