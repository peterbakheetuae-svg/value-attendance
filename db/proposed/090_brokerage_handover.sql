-- 090 — The commission of a resale / rental handed over against the recipient's code (OTP) — PROPOSED, apply only with
-- the owner's approval. Additive, one transaction, safe to re-run. Until it runs the API keeps today's flow
-- (handoverInstalled:false): the commission is an amount and «استلام وتقسيم» records it.
--
--  • brokerage_deals.commission_basis / commission_pct: the seller states the commission as a percentage of the sale price /
--    the monthly rent, or as an amount; the amount (client_commission_egp) is always stored, the percentage only as stated.
--  • brokerage_deals.handover_to: the person the seller hands the commission to — the general manager, the accountant or an
--    administrative officer holding the office cashbox (checked by the API).
--  • brokerage_deals.handover_at: set once, when the seller entered the code the recipient's app showed; the same transaction
--    records the commission as a numbered receipt in the recipient's name (cash_receipts.brokerage_deal_id). The split is set
--    afterwards (POST /brokerage/deals/:id/receive). The recipient and the moment never change after the handover.
-- Rollback: 090_rollback.sql (refuses while any deal carries a handover).

ALTER TABLE brokerage_deals ADD COLUMN IF NOT EXISTS commission_basis text;
ALTER TABLE brokerage_deals ADD COLUMN IF NOT EXISTS commission_pct numeric(6,3);
ALTER TABLE brokerage_deals ADD COLUMN IF NOT EXISTS handover_to uuid REFERENCES employees(id);
ALTER TABLE brokerage_deals ADD COLUMN IF NOT EXISTS handover_at timestamptz;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'brokerage_deals_commission_basis') THEN
    ALTER TABLE brokerage_deals ADD CONSTRAINT brokerage_deals_commission_basis CHECK (
      (commission_basis IS NULL AND commission_pct IS NULL)
      OR (commission_basis = 'amount' AND commission_pct IS NULL)
      OR (commission_basis = 'percent' AND commission_pct > 0 AND commission_pct <= 100));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'brokerage_deals_handover') THEN
    ALTER TABLE brokerage_deals ADD CONSTRAINT brokerage_deals_handover CHECK (handover_at IS NULL OR handover_to IS NOT NULL);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS brokerage_deals_handover_to ON brokerage_deals (handover_to) WHERE handover_to IS NOT NULL;

-- the handover is written once: after it, the recipient, its moment and the stated basis never change
CREATE OR REPLACE FUNCTION brokerage_handover_once() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.handover_at IS NOT NULL AND (NEW.handover_to, NEW.handover_at, NEW.commission_basis, NEW.commission_pct)
       IS DISTINCT FROM (OLD.handover_to, OLD.handover_at, OLD.commission_basis, OLD.commission_pct) THEN
    RAISE EXCEPTION 'a handed-over commission cannot be changed';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS brokerage_handover_once ON brokerage_deals;
CREATE TRIGGER brokerage_handover_once BEFORE UPDATE ON brokerage_deals FOR EACH ROW EXECUTE FUNCTION brokerage_handover_once();
