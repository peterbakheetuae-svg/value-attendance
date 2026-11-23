-- 089 rollback — for a failed install on a TEST copy only. Drops only the link (the deals and the leads stay).
BEGIN;
DROP INDEX IF EXISTS brokerage_deals_lead;
ALTER TABLE brokerage_deals DROP COLUMN IF EXISTS lead_id;
DELETE FROM schema_migrations WHERE name = '089_brokerage_deal_lead.sql';
COMMIT;
