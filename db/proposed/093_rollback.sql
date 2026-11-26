-- Rollback of 093_payroll_sheet_protection.sql: removes the three database guards (API checks stay). Changes no data.
BEGIN;
DROP TRIGGER IF EXISTS payouts_request_link ON payouts;
DROP FUNCTION IF EXISTS payouts_request_link();
DROP TRIGGER IF EXISTS payroll_batch_lines_guard ON payroll_batch_lines;
DROP FUNCTION IF EXISTS payroll_batch_lines_guard();
DROP TRIGGER IF EXISTS payroll_batches_guard ON payroll_batches;
DROP FUNCTION IF EXISTS payroll_batches_guard();
DELETE FROM schema_migrations WHERE name = '093_payroll_sheet_protection.sql';
COMMIT;
