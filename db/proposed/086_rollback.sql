-- Rollback of 086 (PROPOSED). Removes only what 086 added: the two nullable classification columns on cash_expenses /
-- fixed_expenses and the three classification tables. No expense, amount, balance or approval changes.
-- Lost by a rollback: the classification itself (export expense_groups / expense_categories / the two columns first if needed).
BEGIN;
-- the two permission keys 086 added (their grants / exceptions are rows 086 created; the audit log keeps its rows)
DELETE FROM employee_permissions WHERE perm_key IN ('expense.classification_manage', 'expense.reclassify');
DELETE FROM role_permissions WHERE perm_key IN ('expense.classification_manage', 'expense.reclassify');
DELETE FROM permissions WHERE key IN ('expense.classification_manage', 'expense.reclassify');
DROP INDEX IF EXISTS cash_expenses_group;
DROP INDEX IF EXISTS cash_expenses_category;
ALTER TABLE cash_expenses DROP COLUMN IF EXISTS expense_group_id;
ALTER TABLE cash_expenses DROP COLUMN IF EXISTS expense_category_id;
ALTER TABLE fixed_expenses DROP COLUMN IF EXISTS expense_group_id;
ALTER TABLE fixed_expenses DROP COLUMN IF EXISTS expense_category_id;
DROP TABLE IF EXISTS expense_group_categories;
DROP TABLE IF EXISTS expense_groups, expense_categories;
DROP FUNCTION IF EXISTS expense_class_no_delete();
COMMIT;
