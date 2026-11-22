-- Rollback of 085 (PROPOSED). Removes only what 085 added. No existing table loses a row or a column.
-- Lost by a rollback: the ownership-share history (company_owners keeps today's shares, as before 085; export
-- company_owner_shares first if the history is needed).
BEGIN;
DROP TRIGGER IF EXISTS payouts_guard ON payouts;
DROP FUNCTION IF EXISTS payouts_guard();
DROP INDEX IF EXISTS payouts_one_per_advance;
DROP TABLE IF EXISTS company_owner_shares;
COMMIT;
