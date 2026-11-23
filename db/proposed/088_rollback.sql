-- 088 rollback — for a failed install on a TEST copy only; never executed by tests or release validation.
-- ⚠ It refuses to run while any deal came from a listing (those deals carry a fixed resale commission the 087 rule rejects);
-- otherwise it drops every listing and its photos. Back up first; owner's explicit decision only.
BEGIN;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM brokerage_deals WHERE listing_id IS NOT NULL) THEN
    RAISE EXCEPTION 'deals were made from listings — keep 088';
  END IF;
END $$;
ALTER TABLE brokerage_deals DROP CONSTRAINT IF EXISTS brokerage_deals_resale_terms;
ALTER TABLE brokerage_deals ADD CONSTRAINT brokerage_deals_check1 CHECK (kind <> 'resale' OR (rate_pct IS NOT NULL AND arrangement = 'percent'));
DROP INDEX IF EXISTS brokerage_deals_listing;
ALTER TABLE brokerage_deals DROP COLUMN IF EXISTS listing_id;
DROP TABLE IF EXISTS brokerage_listing_photos;
DROP TABLE IF EXISTS brokerage_listings;
DELETE FROM schema_migrations WHERE name = '088_brokerage_listings.sql';
COMMIT;
