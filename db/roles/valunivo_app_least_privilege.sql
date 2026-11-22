-- VALUNIVO — runtime role, FINAL least-privilege grants (PREPARED, NOT EXECUTED; run only with approval, as the owner,
-- after `db/checks/role_audit.sql` shows the current state). Replaces the temporary CREATE exception.
-- Verified outside production: the full API suite (389 tests) passes with exactly these grants (TEST_APP_ROLE=1, CI step
-- "least-privilege runtime role"); the only refused feature is the owner-only data reset (TRUNCATE) — by design.
-- Prerequisite: schema migrations no longer run with the runtime role (see .github/workflows/db-migrate.yml).
BEGIN;
REVOKE CREATE ON SCHEMA public FROM valunivo_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public FROM valunivo_app;
REVOKE DELETE ON ALL TABLES IN SCHEMA public FROM valunivo_app;
GRANT USAGE ON SCHEMA public TO valunivo_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO valunivo_app;
REVOKE UPDATE ON audit_log FROM valunivo_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO valunivo_app;
-- the only tables the API deletes from (src/**: "DELETE FROM ...")
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['web_push_subscriptions','role_permissions','push_tokens','holidays','employee_permissions',
    'employee_documents','notifications','employee_devices','deals','tracking_pings','payroll_batch_lines','meta_pages',
    'marketing_company_files','lead_targets','lead_routes','lead_attachments','ex_unit_files','evaluations','attendance_selfies',
    -- after proposed migration 086 (release branch) is applied: rerun this script so this grant is added too
    'expense_group_categories']
  LOOP IF to_regclass('public.' || t) IS NOT NULL THEN EXECUTE format('GRANT DELETE ON %I TO valunivo_app', t); END IF; END LOOP;
END $$;
ALTER DEFAULT PRIVILEGES FOR ROLE neondb_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE ON TABLES TO valunivo_app;
ALTER DEFAULT PRIVILEGES FOR ROLE neondb_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO valunivo_app;
COMMIT;
-- Verify afterwards: rerun db/checks/role_audit.sql (expect create_temporary_exception = false; DELETE only on the list above).
