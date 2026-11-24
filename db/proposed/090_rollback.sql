-- Rollback of 090_brokerage_handover.sql. Refuses (changes nothing) while any deal carries a handover: those commissions
-- are receipts in someone's cashbox and their record must not lose who received them.
BEGIN;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM brokerage_deals WHERE handover_to IS NOT NULL OR commission_basis IS NOT NULL) THEN
    RAISE EXCEPTION '090 rollback refused: deals already carry a commission basis or a handover';
  END IF;
END $$;
DROP TRIGGER IF EXISTS brokerage_handover_once ON brokerage_deals;
DROP FUNCTION IF EXISTS brokerage_handover_once();
DROP INDEX IF EXISTS brokerage_deals_handover_to;
ALTER TABLE brokerage_deals DROP CONSTRAINT IF EXISTS brokerage_deals_handover;
ALTER TABLE brokerage_deals DROP CONSTRAINT IF EXISTS brokerage_deals_commission_basis;
ALTER TABLE brokerage_deals DROP COLUMN IF EXISTS handover_at;
ALTER TABLE brokerage_deals DROP COLUMN IF EXISTS handover_to;
ALTER TABLE brokerage_deals DROP COLUMN IF EXISTS commission_pct;
ALTER TABLE brokerage_deals DROP COLUMN IF EXISTS commission_basis;
COMMIT;
