-- ⚠ SUPERSEDED (2026-11-23): the owner narrowed the clean-up — use db/ops/2026-11-23-clear-attendance-finance-former-employees.sql.
--   Do NOT run this file.
-- VALUNIVO — one-time clean-up asked by the owner (2026-11-18):
--   KEEP   the employees on the job (status active, not «تم التصفيه») with their files, salaries, leave balances,
--          devices, permissions and custody; the marketing companies (accounts, files, sign-ins); the forms; the
--          settings (departments, teams, schedules, office, holidays, roles / permissions, lead stages / templates /
--          channels / routing rules, KPI definitions, integrations, Meta pages); the fixed expenses; the audit log.
--   DELETE every activity record (attendance, tracking, requests, outings, notifications, KPI results, evaluations,
--          leads / tasks / deals / campaigns, every financial record, sales, commissions, payroll), the projects / units
--          / developers, the company owners and assets, and the former employees.
-- A former employee is deleted with everything of his; when a record that is kept has to keep pointing at him (the
-- append-only audit log, a permanent custody record, a file he uploaded for someone still here …) he stays only as an
-- anonymous, signed-out «موظف سابق» with no personal data.
--
-- HOW TO RUN (Neon SQL editor, database neondb), only after a Neon branch (backup) was made:
--   dry run : BEGIN;  <this file>  SELECT * FROM c_report ORDER BY step, what;  ROLLBACK;
--   for real: BEGIN;  <this file>  SELECT * FROM c_report ORDER BY step, what;  COMMIT;
-- Everything happens in that one transaction: any error undoes all of it.

SET LOCAL lock_timeout = '15s';
CREATE TEMP TABLE c_keep ON COMMIT DROP AS
  SELECT id FROM employees WHERE status = 'active' AND COALESCE(legacy_fields->>'status', '') <> 'تم التصفيه';
CREATE TEMP TABLE c_gone ON COMMIT DROP AS SELECT id FROM employees WHERE id NOT IN (SELECT id FROM c_keep);
CREATE TEMP TABLE c_report (step int, what text, rows bigint) ON COMMIT DROP;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM employees e JOIN c_keep k USING (id) WHERE e.role_key = 'owner') THEN
    RAISE EXCEPTION 'stopped: no active owner would be kept';
  END IF;
END $$;
INSERT INTO c_report SELECT 0, 'employees kept (on the job)', count(*) FROM c_keep;
INSERT INTO c_report SELECT 0, 'former employees', count(*) FROM c_gone;

-- 1) every activity record (TRUNCATE: whole tables; no kept table points at any of them)
DO $$
DECLARE t text; n bigint;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'cash_attachments','deals','lead_whatsapp','lead_exports','lead_targets','lead_checkins','lead_requests','lead_attachments',
    'tasks','lead_referrals','lead_logs','lead_actions','leads','lead_campaigns',
    'attendance_breaks','attendance_corrections','attendance_selfies','attendance','tracking_pings','tracking_state',
    'request_actions','requests','outing_requests','notifications','kpi_results','evaluations',
    'salary_adjustments','advance_deductions','payouts','advance_requests','payroll_batch_lines','payroll_batches',
    'commission_entitlements','cash_receipts','cash_expenses','cash_transfers','cash_adjustments','cash_bank_moves',
    'sale_installments','unit_sales','commission_requests','commission_projects',
    'project_images','ex_inventory','developer_images','partner_units','partner_projects',
    'ex_payments','ex_installments','ex_commission_transfers','ex_unit_files','ex_units','developers',
    'company_owners','company_assets',
    'action_otps','partner_email_otps','partner_notifications','meta_seen_campaigns','password_otps']
  LOOP
    IF to_regclass(t) IS NULL THEN CONTINUE; END IF;
    EXECUTE format('SELECT count(*) FROM %I', t) INTO n;
    INSERT INTO c_report VALUES (1, t, n);
  END LOOP;
END $$;
UPDATE integrations SET campaign_id = NULL WHERE campaign_id IS NOT NULL;  -- the campaigns go; the integrations' keys stay
TRUNCATE cash_attachments, deals, lead_whatsapp, lead_exports, lead_targets, lead_checkins, lead_requests, lead_attachments,
  tasks, lead_referrals, lead_logs, lead_actions, leads, lead_campaigns,
  attendance_breaks, attendance_corrections, attendance_selfies, attendance, tracking_pings, tracking_state,
  request_actions, requests, outing_requests, notifications, kpi_results, evaluations,
  salary_adjustments, advance_deductions, payouts, advance_requests, payroll_batch_lines, payroll_batches,
  commission_entitlements, cash_receipts, cash_expenses, cash_transfers, cash_adjustments, cash_bank_moves,
  sale_installments, unit_sales, commission_requests, commission_projects,
  project_images, ex_inventory, developer_images, partner_units, partner_projects,
  ex_payments, ex_installments, ex_commission_transfers, ex_unit_files, ex_units, developers,
  company_owners, company_assets,
  action_otps, partner_email_otps, partner_notifications, meta_seen_campaigns, password_otps;

-- 2) former employees: what is only theirs
INSERT INTO c_report SELECT 2, 'former: sign-ins / phones / push', (SELECT count(*) FROM sessions WHERE employee_id IN (SELECT id FROM c_gone))
  + (SELECT count(*) FROM push_tokens WHERE employee_id IN (SELECT id FROM c_gone))
  + (SELECT count(*) FROM web_push_subscriptions WHERE employee_id IN (SELECT id FROM c_gone))
  + (SELECT count(*) FROM employee_devices WHERE employee_id IN (SELECT id FROM c_gone));
INSERT INTO c_report SELECT 2, 'former: salaries / leave balances / own permissions',
  (SELECT count(*) FROM employee_salaries WHERE employee_id IN (SELECT id FROM c_gone))
  + (SELECT count(*) FROM leave_balances WHERE employee_id IN (SELECT id FROM c_gone))
  + (SELECT count(*) FROM employee_permissions WHERE employee_id IN (SELECT id FROM c_gone));
INSERT INTO c_report SELECT 2, 'former: documents and forms', count(*) FROM employee_documents WHERE employee_id IN (SELECT id FROM c_gone);
DELETE FROM sessions WHERE employee_id IN (SELECT id FROM c_gone);
DELETE FROM push_tokens WHERE employee_id IN (SELECT id FROM c_gone);
DELETE FROM web_push_subscriptions WHERE employee_id IN (SELECT id FROM c_gone);
DELETE FROM employee_devices WHERE employee_id IN (SELECT id FROM c_gone);
DELETE FROM employee_permissions WHERE employee_id IN (SELECT id FROM c_gone);
DELETE FROM employee_salaries WHERE employee_id IN (SELECT id FROM c_gone);
DELETE FROM leave_balances WHERE employee_id IN (SELECT id FROM c_gone);
-- their documents (ID cards, contracts …) and forms: the «never deleted» guard is lifted for this transaction only
ALTER TABLE employee_documents DISABLE TRIGGER employee_documents_guard;
UPDATE employee_documents SET replaced_by = NULL WHERE replaced_by IN (SELECT id FROM employee_documents WHERE employee_id IN (SELECT id FROM c_gone));
DELETE FROM employee_documents WHERE employee_id IN (SELECT id FROM c_gone);
ALTER TABLE employee_documents ENABLE TRIGGER employee_documents_guard;

-- 3) kept records that only mention a former employee lose the mention
UPDATE employees SET sales_manager_id = NULL WHERE sales_manager_id IN (SELECT id FROM c_gone);
UPDATE employees SET general_manager_id = NULL WHERE general_manager_id IN (SELECT id FROM c_gone);
UPDATE teams SET manager_id = NULL WHERE manager_id IN (SELECT id FROM c_gone);
UPDATE company_settings SET updated_by = NULL WHERE updated_by IN (SELECT id FROM c_gone);
UPDATE roles SET created_by = NULL WHERE created_by IN (SELECT id FROM c_gone);
UPDATE kpi_definitions SET created_by = NULL WHERE created_by IN (SELECT id FROM c_gone);
UPDATE leave_balances SET updated_by = NULL WHERE updated_by IN (SELECT id FROM c_gone);
UPDATE integrations SET updated_by = NULL WHERE updated_by IN (SELECT id FROM c_gone);
UPDATE lead_routes SET updated_by = NULL WHERE updated_by IN (SELECT id FROM c_gone);
UPDATE lead_routes SET assignees = ARRAY(SELECT x FROM unnest(assignees) x WHERE x NOT IN (SELECT id FROM c_gone))
 WHERE assignees && ARRAY(SELECT id FROM c_gone);
UPDATE marketing_companies SET general_manager_id = NULL WHERE general_manager_id IN (SELECT id FROM c_gone);
UPDATE marketing_companies SET manager_id = NULL WHERE manager_id IN (SELECT id FROM c_gone);
UPDATE marketing_company_files SET uploaded_by = NULL WHERE uploaded_by IN (SELECT id FROM c_gone);
UPDATE employee_permissions SET by_id = NULL WHERE by_id IN (SELECT id FROM c_gone);
UPDATE employee_devices SET decided_by = NULL WHERE decided_by IN (SELECT id FROM c_gone);
UPDATE employee_documents SET staged_by = NULL WHERE staged_by IN (SELECT id FROM c_gone);
UPDATE meta_pages SET added_by = NULL WHERE added_by IN (SELECT id FROM c_gone);

-- 4) each former employee: deleted; or, when a kept record must keep pointing at him, an anonymous stub
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
  INSERT INTO c_report VALUES (4, 'former employees deleted', deleted), (4, 'former employees left as anonymous «موظف سابق»', stubs);
END $$;

-- 5) what stays (for the report)
INSERT INTO c_report SELECT 5, 'kept: employees on the job', count(*) FROM employees WHERE id IN (SELECT id FROM c_keep);
INSERT INTO c_report SELECT 5, 'kept: their documents and forms', count(*) FROM employee_documents WHERE employee_id IN (SELECT id FROM c_keep);
INSERT INTO c_report SELECT 5, 'kept: custody records', count(*) FROM custody_items;
INSERT INTO c_report SELECT 5, 'kept: custody assets', count(*) FROM custody_assets;
INSERT INTO c_report SELECT 5, 'kept: marketing companies', count(*) FROM marketing_companies;
INSERT INTO c_report SELECT 5, 'kept: salaries', count(*) FROM employee_salaries;
INSERT INTO c_report SELECT 5, 'kept: fixed expenses', count(*) FROM fixed_expenses;
