-- Rollback of 083 (PROPOSED). Removes only what 083 added: the two guards on cash_receipts / cash_expenses and the five
-- closing tables. No existing table loses a row or a column. Lost by a rollback: the closing records themselves (export the
-- closing reports first if they are needed). The audit_log rows of the closings stay (append-only).
DROP TRIGGER IF EXISTS cash_receipts_closed_year ON cash_receipts;
DROP TRIGGER IF EXISTS cash_expenses_closed_year ON cash_expenses;
DROP FUNCTION IF EXISTS fy_closed_year_guard();
DROP TABLE IF EXISTS fy_opening_balances, fy_reconciliations, fy_issues, fy_review_items, fy_closings;
DROP FUNCTION IF EXISTS fy_no_delete(), fy_closings_guard(), fy_work_guard(), fy_opening_guard();
