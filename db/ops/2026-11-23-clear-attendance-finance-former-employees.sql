-- VALUNIVO — clean-up asked by the owner (2026-11-23). Replaces db/ops/2026-11-18-keep-active-employees.sql.
-- It deletes ONLY these three things — nothing else:
--   1. every attendance record of every employee (check-in / check-out, breaks, corrections, selfies);
--   2. every financial transaction: the cash book (receipts, expenses, transfers, adjustments / opening balances, bank
--      moves, their photos), payouts, advances and their deductions, salary adjustments (bonuses / deductions), payroll
--      sheets, commission requests and entitlements, unit sales and their installments, exclusive-unit payments /
--      installments / commission transfers, resale / rental deals (087) and the year-closing records (083) when present;
--   3. the employees whose status is «تم التصفيه» or «غير نشط» (inactive).
-- KEPT: the active employees and all their data (files, salaries, leave balances, devices, permissions, custody, KPIs,
-- requests, outings, notifications, tracking), leads / tasks / deals / campaigns, projects / units / developers /
-- reservations, marketing companies, company owners and their shares, fixed expenses (the monthly templates), expense
-- groups / categories, settings, forms, the audit log.
--
-- A removed employee is deleted with what is only his (sign-ins, devices, push, permissions, salary, leave balance, KPIs,
-- evaluations of him, requests, outings, notifications, tracking, documents, codes). Kept records that merely mention him
-- (leads he created, a team he managed …) lose the mention. When a kept record must keep pointing at him (the append-only
-- audit log, a custody record, a lead he still owns, an owner share …) he stays only as an anonymous, signed-out
-- «موظف سابق» with no personal data.
--
-- Run ONLY after a Neon backup branch, as the database owner (Neon SQL editor, database neondb):
--   dry run : BEGIN;  <this file>  SELECT * FROM c_report ORDER BY step, what;  ROLLBACK;
--   for real: BEGIN;  <this file>  SELECT * FROM c_report ORDER BY step, what;  COMMIT;
-- Everything happens in that one transaction: any error undoes all of it.

SET LOCAL lock_timeout = '15s';
CREATE TEMP TABLE c_gone ON COMMIT DROP AS
  SELECT id FROM employees
   WHERE status = 'inactive' OR COALESCE(legacy_fields->>'status', '') IN ('تم التصفيه', 'تم التصفية');
CREATE TEMP TABLE c_report (step int, what text, rows bigint) ON COMMIT DROP;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM employees WHERE role_key = 'owner' AND id NOT IN (SELECT id FROM c_gone)) THEN
    RAISE EXCEPTION 'stopped: no active owner would be left';
  END IF;
END $$;
INSERT INTO c_report SELECT 0, 'employees kept (active, not «تم التصفيه»)', count(*) FROM employees WHERE id NOT IN (SELECT id FROM c_gone);
INSERT INTO c_report SELECT 0, 'employees to remove («تم التصفيه» / inactive)', count(*) FROM c_gone;

-- 1 + 2) attendance and every financial transaction — whole tables. Their «never deleted / final» row guards exist for the
-- app; this is the owner's explicit clean-up, so they are switched off for this transaction only (foreign keys stay on:
-- a table still pointed at by something kept is never emptied — the run stops instead). Tables that do not exist yet
-- (proposed migrations) are skipped.
CREATE TEMP TABLE c_wipe (step int, t text) ON COMMIT DROP;
INSERT INTO c_wipe SELECT 1, t FROM unnest(ARRAY['attendance_breaks','attendance_corrections','attendance_selfies','attendance']) t;
INSERT INTO c_wipe SELECT 2, t FROM unnest(ARRAY[
  'cash_attachments','cash_receipts','cash_expenses','cash_transfers','cash_adjustments','cash_bank_moves',
  'payouts','advance_deductions','advance_requests','salary_adjustments','payroll_batch_lines','payroll_batches',
  'commission_entitlements','commission_requests','sale_installments','unit_sales',
  'ex_payments','ex_installments','ex_commission_transfers',
  'brokerage_shares','brokerage_deals',
  'fy_review_items','fy_reconciliations','fy_issues','fy_opening_balances','fy_closings']) t;
DELETE FROM c_wipe WHERE to_regclass('public.' || t) IS NULL;
DO $$
DECLARE r record; n bigint;
BEGIN
  FOR r IN SELECT * FROM c_wipe LOOP
    EXECUTE format('SELECT count(*) FROM %I', r.t) INTO n;
    INSERT INTO c_report VALUES (r.step, r.t, n);
  END LOOP;
END $$;
-- the only kept record that points at a financial one: a reservation's link to its commission request
UPDATE ex_units SET commission_request_id = NULL WHERE commission_request_id IS NOT NULL;
DO $$
DECLARE t text; has boolean; progress boolean; still text;
BEGIN
  FOR t IN SELECT w.t FROM c_wipe w LOOP EXECUTE format('ALTER TABLE %I DISABLE TRIGGER USER', t); END LOOP;
  LOOP  -- empty them in whatever order their links allow
    progress := false; still := NULL;
    FOR t IN SELECT w.t FROM c_wipe w LOOP
      EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I)', t) INTO has;
      CONTINUE WHEN NOT has;
      BEGIN
        EXECUTE format('DELETE FROM %I', t);
        progress := true;
      EXCEPTION WHEN foreign_key_violation THEN still := concat_ws(', ', still, t);
      END;
    END LOOP;
    EXIT WHEN still IS NULL;
    IF NOT progress THEN RAISE EXCEPTION 'stopped: % still referenced by a kept record (nothing was changed)', still; END IF;
  END LOOP;
  FOR t IN SELECT w.t FROM c_wipe w LOOP EXECUTE format('ALTER TABLE %I ENABLE TRIGGER USER', t); END LOOP;
END $$;

-- a listed property (088) whose sale was waiting on a deal that is gone is offered again (a sold one stays sold)
DO $$ BEGIN
  IF to_regclass('public.brokerage_listings') IS NOT NULL THEN
    UPDATE brokerage_listings SET status = 'available', updated_at = now() WHERE status = 'pending';
  END IF;
END $$;

-- 3) the removed employees: what is only theirs
DO $$
DECLARE t text; c text; n bigint;
BEGIN
  FOR t, c IN SELECT * FROM (VALUES
      ('sessions','employee_id'),('push_tokens','employee_id'),('web_push_subscriptions','employee_id'),
      ('employee_devices','employee_id'),('employee_permissions','employee_id'),('employee_salaries','employee_id'),
      ('leave_balances','employee_id'),('password_otps','employee_id'),('action_otps','employee_id'),
      ('tracking_pings','employee_id'),('tracking_state','employee_id'),('notifications','recipient_id'),
      ('kpi_results','employee_id'),('evaluations','employee_id'),('outing_requests','employee_id'),
      ('lead_targets','employee_id'),('lead_checkins','employee_id'),('lead_referrals','employee_id')) v(t, c)
  LOOP
    IF to_regclass('public.' || t) IS NULL THEN CONTINUE; END IF;
    -- a removed person's own records go with him: their «never deleted» guards are paused for this statement only
    EXECUTE format('ALTER TABLE %I DISABLE TRIGGER USER', t);
    EXECUTE format('DELETE FROM %I WHERE %I IN (SELECT id FROM c_gone)', t, c);
    GET DIAGNOSTICS n = ROW_COUNT;
    EXECUTE format('ALTER TABLE %I ENABLE TRIGGER USER', t);
    INSERT INTO c_report VALUES (3, 'removed employees: ' || t, n);
  END LOOP;
END $$;
-- their requests (leave, permission …) with the steps taken on them
ALTER TABLE request_actions DISABLE TRIGGER USER; ALTER TABLE requests DISABLE TRIGGER USER;
DELETE FROM request_actions WHERE request_id IN (SELECT id FROM requests WHERE employee_id IN (SELECT id FROM c_gone));
WITH d AS (DELETE FROM requests WHERE employee_id IN (SELECT id FROM c_gone) RETURNING 1)
INSERT INTO c_report SELECT 3, 'removed employees: requests', count(*) FROM d;
ALTER TABLE request_actions ENABLE TRIGGER USER; ALTER TABLE requests ENABLE TRIGGER USER;
-- their own KPI plans
ALTER TABLE kpi_set_items DISABLE TRIGGER USER; ALTER TABLE kpi_sets DISABLE TRIGGER USER;
DELETE FROM kpi_set_items WHERE set_id IN (SELECT id FROM kpi_sets WHERE employee_id IN (SELECT id FROM c_gone));
WITH d AS (DELETE FROM kpi_sets WHERE employee_id IN (SELECT id FROM c_gone) RETURNING 1)
INSERT INTO c_report SELECT 3, 'removed employees: kpi_sets', count(*) FROM d;
ALTER TABLE kpi_set_items ENABLE TRIGGER USER; ALTER TABLE kpi_sets ENABLE TRIGGER USER;
-- their documents (ID cards, contracts …) and forms: the «never deleted» guard is lifted for this transaction only
ALTER TABLE employee_documents DISABLE TRIGGER employee_documents_guard;
UPDATE employee_documents SET replaced_by = NULL WHERE replaced_by IN (SELECT id FROM employee_documents WHERE employee_id IN (SELECT id FROM c_gone));
WITH d AS (DELETE FROM employee_documents WHERE employee_id IN (SELECT id FROM c_gone) RETURNING 1)
INSERT INTO c_report SELECT 3, 'removed employees: employee_documents', count(*) FROM d;
ALTER TABLE employee_documents ENABLE TRIGGER employee_documents_guard;

-- 4) kept records that only mention a removed employee lose the mention (every nullable link to employees, except the
-- append-only audit log); a record whose own rules refuse the change keeps it — that employee then stays as a stub
UPDATE lead_routes SET assignees = ARRAY(SELECT x FROM unnest(assignees) x WHERE x NOT IN (SELECT id FROM c_gone))
 WHERE assignees && ARRAY(SELECT id FROM c_gone);
DO $$
DECLARE r record; n bigint; total bigint := 0; kept int := 0;
BEGIN
  FOR r IN
    SELECT c.conrelid::regclass::text AS t, a.attname AS col
      FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
     WHERE c.contype = 'f' AND c.confrelid = 'employees'::regclass AND NOT a.attnotnull
       AND c.conrelid::regclass::text <> 'audit_log'
  LOOP
    BEGIN
      EXECUTE format('UPDATE %s SET %I = NULL WHERE %I IN (SELECT id FROM c_gone)', r.t, r.col, r.col);
      GET DIAGNOSTICS n = ROW_COUNT; total := total + n;
    EXCEPTION WHEN OTHERS THEN kept := kept + 1;  -- that table refuses the change (its own guard): the mention stays
    END;
  END LOOP;
  INSERT INTO c_report VALUES (4, 'kept records: mentions of removed employees cleared', total),
                              (4, 'kept tables whose rules keep the mention', kept);
END $$;

-- 5) each removed employee: deleted; or, when a kept record must keep pointing at him, an anonymous stub
DO $$
DECLARE g uuid; deleted int := 0; stubs int := 0;
BEGIN
  FOR g IN SELECT id FROM c_gone LOOP
    BEGIN
      DELETE FROM employees WHERE id = g;
      deleted := deleted + 1;
    EXCEPTION WHEN foreign_key_violation THEN
      UPDATE employees SET
        full_name = 'موظف سابق', job_title = 'موظف سابق', code = 'EX' || upper(substr(md5(id::text), 1, 8)),
        phone = NULL, email = NULL, address = NULL, emergency_contact_name = NULL, emergency_contact_phone = NULL, notes = NULL,
        photo = NULL, photo_mime = NULL, bank_name = NULL, account_holder = NULL, iban = NULL, account_number = NULL,
        device_id = NULL, device_label = NULL, device_bound_at = NULL, device_lock = false,
        password_hash = '!removed', must_change_password = true, status = 'inactive',
        department_id = NULL, team_id = NULL, sales_manager_id = NULL, general_manager_id = NULL,
        legacy_fields = jsonb_build_object('status', 'تم التصفيه', 'removed', true), updated_at = now()
      WHERE id = g;
      stubs := stubs + 1;
    END;
  END LOOP;
  INSERT INTO c_report VALUES (5, 'removed employees deleted', deleted), (5, 'removed employees left as anonymous «موظف سابق»', stubs);
END $$;

-- 6) what stays (for the report)
INSERT INTO c_report SELECT 6, 'kept: active employees', count(*) FROM employees WHERE status = 'active' AND COALESCE(legacy_fields->>'status', '') NOT IN ('تم التصفيه', 'تم التصفية');
INSERT INTO c_report SELECT 6, 'kept: leads', count(*) FROM leads;
INSERT INTO c_report SELECT 6, 'kept: custody records', count(*) FROM custody_items;
INSERT INTO c_report SELECT 6, 'kept: fixed expenses', count(*) FROM fixed_expenses;
INSERT INTO c_report SELECT 6, 'kept: company owners', count(*) FROM company_owners;
INSERT INTO c_report SELECT 6, 'kept: audit log entries', count(*) FROM audit_log;
