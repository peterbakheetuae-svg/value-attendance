-- 087 rollback — for a failed install on a TEST copy only; never executed by tests or release validation.
-- ⚠ On a live database it deletes every resale / rental deal, its approved distribution and the link of its receipts and
-- commission entitlements (the receipts and entitlements themselves stay). Back up first; owner's explicit decision only.
BEGIN;
DELETE FROM role_permissions WHERE perm_key IN ('brokerage.propose', 'brokerage.approve', 'brokerage.view_all');
DELETE FROM employee_permissions WHERE perm_key IN ('brokerage.propose', 'brokerage.approve', 'brokerage.view_all');
DELETE FROM permissions WHERE key IN ('brokerage.propose', 'brokerage.approve', 'brokerage.view_all');
ALTER TABLE commission_entitlements DROP CONSTRAINT IF EXISTS commission_entitlements_one_source;
ALTER TABLE commission_entitlements DROP COLUMN IF EXISTS brokerage_share_id;
DROP INDEX IF EXISTS cash_expenses_brokerage_share_live;
ALTER TABLE cash_expenses DROP COLUMN IF EXISTS brokerage_share_id;
ALTER TABLE cash_receipts DROP CONSTRAINT IF EXISTS cash_receipts_brokerage_side;
DROP INDEX IF EXISTS cash_receipts_brokerage;
ALTER TABLE cash_receipts DROP COLUMN IF EXISTS brokerage_side;
ALTER TABLE cash_receipts DROP COLUMN IF EXISTS brokerage_deal_id;
DROP TRIGGER IF EXISTS brokerage_shares_guard ON brokerage_shares;
DROP TRIGGER IF EXISTS brokerage_deals_guard ON brokerage_deals;
DROP FUNCTION IF EXISTS brokerage_guard();
DROP TABLE IF EXISTS brokerage_shares;
DROP TABLE IF EXISTS brokerage_deals;
COMMIT;
