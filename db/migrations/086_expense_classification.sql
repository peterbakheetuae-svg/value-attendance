-- Applied by the release of 2026-11-23 (owner-approved): copied unchanged from db/proposed/086_expense_classification.sql below this header.

-- 086 (PROPOSED — not in db/migrations, so no build runs it; it needs the owner's approval first). Run after 084 and 085.
-- Expense groups and categories: CLASSIFICATION METADATA ONLY. Additive: new tables + nullable columns; nothing existing is
-- changed, dropped or back-filled. Rollback: 086_rollback.sql. Applied by the runner (one transaction); by hand: BEGIN; … COMMIT;
--
--  • expense_groups (level 1) and expense_categories (level 2); a category is ONE row reused by any number of groups
--    (expense_group_categories), never duplicated. Archive = is_active false; nothing is deleted. One ACTIVE name each
--    (case-insensitive, trimmed).
--  • cash_expenses.expense_group_id / expense_category_id: nullable — every existing expense stays valid and reads «غير مصنف».
--    The text column «category» (البند) is untouched and still required, so every existing report keeps working.
--    The existing cash_doc_guard trigger keeps amount, cashbox, date and recorder immutable: a (re)classification can change
--    the two references only — never the money, a balance, an approval or a payment.
--  • fixed_expenses: the same two nullable references, carried into each month's expense when it is paid.
--  • two permission keys (registry, since 86): expense.classification_manage and expense.reclassify, split from cash.office
--    the way 066 splits its keys — every job title and every individual exception keeps EXACTLY its effective access.

CREATE TABLE IF NOT EXISTS expense_groups (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 80),
  description  text NOT NULL DEFAULT '' CHECK (length(description) <= 500),
  is_active    boolean NOT NULL DEFAULT true,
  created_by   uuid NOT NULL REFERENCES employees(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid REFERENCES employees(id),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS expense_groups_active_name ON expense_groups (lower(trim(name))) WHERE is_active;

CREATE TABLE IF NOT EXISTS expense_categories (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 80),
  description  text NOT NULL DEFAULT '' CHECK (length(description) <= 500),
  is_active    boolean NOT NULL DEFAULT true,
  created_by   uuid NOT NULL REFERENCES employees(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid REFERENCES employees(id),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS expense_categories_active_name ON expense_categories (lower(trim(name))) WHERE is_active;

CREATE TABLE IF NOT EXISTS expense_group_categories (
  group_id     uuid NOT NULL REFERENCES expense_groups(id),
  category_id  uuid NOT NULL REFERENCES expense_categories(id),
  created_by   uuid NOT NULL REFERENCES employees(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, category_id)
);
CREATE INDEX IF NOT EXISTS expense_group_categories_cat ON expense_group_categories (category_id);

ALTER TABLE cash_expenses ADD COLUMN IF NOT EXISTS expense_group_id uuid REFERENCES expense_groups(id);
ALTER TABLE cash_expenses ADD COLUMN IF NOT EXISTS expense_category_id uuid REFERENCES expense_categories(id);
CREATE INDEX IF NOT EXISTS cash_expenses_group ON cash_expenses (expense_group_id) WHERE expense_group_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS cash_expenses_category ON cash_expenses (expense_category_id) WHERE expense_category_id IS NOT NULL;

ALTER TABLE fixed_expenses ADD COLUMN IF NOT EXISTS expense_group_id uuid REFERENCES expense_groups(id);
ALTER TABLE fixed_expenses ADD COLUMN IF NOT EXISTS expense_category_id uuid REFERENCES expense_categories(id);

-- groups / categories are never deleted (a referenced one keeps the history readable)
CREATE OR REPLACE FUNCTION expense_class_no_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'expense groups / categories are archived, never deleted'; END $$;
DROP TRIGGER IF EXISTS expense_groups_no_delete ON expense_groups;
CREATE TRIGGER expense_groups_no_delete BEFORE DELETE ON expense_groups FOR EACH ROW EXECUTE FUNCTION expense_class_no_delete();
DROP TRIGGER IF EXISTS expense_categories_no_delete ON expense_categories;
CREATE TRIGGER expense_categories_no_delete BEFORE DELETE ON expense_categories FOR EACH ROW EXECUTE FUNCTION expense_class_no_delete();

-- permissions (the same split mechanics as 066): fine key ← cash.office
INSERT INTO permissions (key, description) VALUES
  ('expense.classification_manage', 'Manage expense groups / categories (classification only)'),
  ('expense.reclassify', 'Change the group / category of a recorded expense (metadata only, audited)')
  ON CONFLICT (key) DO NOTHING;
CREATE TEMP TABLE m086 (fine text NOT NULL, broad text NOT NULL) ON COMMIT DROP;
INSERT INTO m086 VALUES ('expense.classification_manage', 'cash.office'), ('expense.reclassify', 'cash.office');
-- 1. job titles that hold cash.office get the fine keys
INSERT INTO role_permissions (role_key, perm_key)
  SELECT DISTINCT rp.role_key, m.fine FROM role_permissions rp JOIN m086 m ON m.broad = rp.perm_key
  ON CONFLICT DO NOTHING;
-- 2. individual exceptions on cash.office carry over (an employee allowed / denied cash.office alone keeps that)
CREATE TEMP TABLE x086 ON COMMIT DROP AS
WITH pre AS (
  SELECT e.id, m.fine,
         ((EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_key = COALESCE(e.position_key, e.role_key) AND rp.perm_key = m.broad)
           AND NOT EXISTS (SELECT 1 FROM employee_permissions ep WHERE ep.employee_id = e.id AND ep.perm_key = m.broad AND NOT ep.allow))
          OR EXISTS (SELECT 1 FROM employee_permissions ep WHERE ep.employee_id = e.id AND ep.perm_key = m.broad AND ep.allow)) AS v
    FROM employees e CROSS JOIN m086 m
), post AS (
  SELECT p.id, p.fine, p.v, EXISTS (SELECT 1 FROM employees e JOIN role_permissions rp ON rp.role_key = COALESCE(e.position_key, e.role_key)
                                     WHERE e.id = p.id AND rp.perm_key = p.fine) AS granted
    FROM pre p
)
SELECT id, fine, v FROM post WHERE v <> granted;
INSERT INTO employee_permissions (employee_id, perm_key, allow, by_id, updated_at)
  SELECT id, fine, v, NULL, now() FROM x086
  ON CONFLICT (employee_id, perm_key) DO NOTHING;
INSERT INTO audit_log (actor_id, action, entity, entity_id, before, after)
  SELECT NULL, 'permission.employee', 'employee', id::text, jsonb_build_object('perm', fine, 'value', 'inherit'),
         jsonb_build_object('perm', fine, 'value', CASE WHEN v THEN 'allow' ELSE 'deny' END, 'source', 'migration_086')
    FROM x086;
