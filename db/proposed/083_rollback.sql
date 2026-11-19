BEGIN;
-- Rollback of 083 (PROPOSED). Removes only what 083 added: the closed-year guards on cash_receipts / cash_expenses and on the
-- employees' period tables (salary_adjustments, advance_requests, advance_deductions, commission_entitlements, payroll_batches), the five
-- closing tables. No existing table loses a row or a column. Lost by a rollback: the closing records themselves (export the
-- closing reports first if they are needed). The audit_log rows of the closings stay (append-only).
DROP TRIGGER IF EXISTS cash_receipts_closed_year ON cash_receipts;
DROP TRIGGER IF EXISTS cash_expenses_closed_year ON cash_expenses;
DROP FUNCTION IF EXISTS fy_closed_year_guard();
DROP TRIGGER IF EXISTS salary_adjustments_closed_period ON salary_adjustments;
DROP TRIGGER IF EXISTS advance_requests_closed_period ON advance_requests;
DROP TRIGGER IF EXISTS advance_deductions_closed_period ON advance_deductions;
DROP TRIGGER IF EXISTS commission_entitlements_closed_period ON commission_entitlements;
DROP TRIGGER IF EXISTS payroll_batches_closed_period ON payroll_batches;
DROP FUNCTION IF EXISTS fy_closed_period_guard();
DROP TABLE IF EXISTS fy_opening_balances, fy_reconciliations, fy_issues, fy_review_items, fy_closings;
DROP FUNCTION IF EXISTS fy_no_delete(), fy_closings_guard(), fy_work_guard(), fy_opening_guard();
COMMIT;
