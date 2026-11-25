-- 091_rollback.sql — PROPOSED v3.1. Run by the owner with psql, never by migrate-core:
--   psql -v ON_ERROR_STOP=1 -v reason='<why, 10-400 chars>' -v reconciliation='<sha256 of the signed bucket-wide
--        reconciliation report showing no object under prod/ or staging/>' -f 091_rollback.sql
-- One transaction, under migrate-core's own advisory lock (no build can migrate meanwhile).
-- Refuses unless no business row references R2 and EVERY file record is 'purged' AND its logged absence evidence still
-- holds (N2; files created in the last 48 hours are named separately). Keeps file_objects and file_purge_log (frozen) and
-- the schema_migrations row of 091 (so migrate-core does NOT re-apply it, N3); adds a tombstone. Nothing is deleted.
\if :{?reason}
\else
  \echo 'refused: pass -v reason=...'
  \quit
\endif
\if :{?reconciliation}
\else
  \echo 'refused: pass -v reconciliation=<sha256 of the reconciliation report>'
  \quit
\endif
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('valunivo:schema_migrations', 0));
SELECT set_config('va.rollback_reason', :'reason', true), set_config('va.rollback_reconciliation', :'reconciliation', true);
LOCK TABLE file_objects, file_purge_log IN ACCESS EXCLUSIVE MODE;
DO $$
DECLARE n bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = '091_r2_file_objects.sql') THEN
    RAISE EXCEPTION '091 rollback refused: 091_r2_file_objects.sql is not applied';
  END IF;
  IF EXISTS (SELECT 1 FROM schema_migration_rollbacks WHERE name = '091_r2_file_objects.sql' AND reinstated_at IS NULL) THEN
    RAISE EXCEPTION '091 rollback refused: already rolled back';
  END IF;
  IF length(coalesce(current_setting('va.rollback_reason', true), '')) NOT BETWEEN 10 AND 400 THEN
    RAISE EXCEPTION '091 rollback refused: the reason must be 10-400 characters';
  END IF;
  IF coalesce(current_setting('va.rollback_reconciliation', true), '') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION '091 rollback refused: the reconciliation report SHA-256 is required';
  END IF;
  SELECT count(*) INTO n FROM employees WHERE photo_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: employees.photo_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM employee_documents WHERE content_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: employee_documents.content_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM attendance_selfies WHERE image_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: attendance_selfies.image_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM advance_requests WHERE attachment_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: advance_requests.attachment_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM cash_receipts WHERE attachment_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: cash_receipts.attachment_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM cash_expenses WHERE attachment_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: cash_expenses.attachment_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM cash_attachments WHERE attachment_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: cash_attachments.attachment_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM salary_adjustments WHERE attachment_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: salary_adjustments.attachment_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM unit_sales WHERE attachment_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: unit_sales.attachment_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM lead_attachments WHERE data_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: lead_attachments.data_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM ex_unit_files WHERE data_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: ex_unit_files.data_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM marketing_company_files WHERE data_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: marketing_company_files.data_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM project_images WHERE data_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: project_images.data_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM developer_images WHERE data_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: developer_images.data_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM brokerage_listing_photos WHERE data_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: brokerage_listing_photos.data_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM company_assets WHERE data_file_id IS NOT NULL; IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: company_assets.data_file_id has % R2 reference(s)', n; END IF;
  SELECT count(*) INTO n FROM file_objects WHERE status <> 'purged' OR ref_count <> 0;
  IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: % file record(s) are not purged (their R2 object may still exist)', n; END IF;
  SELECT count(*) INTO n FROM file_objects WHERE created_at > now() - interval '48 hours' AND file_purge_evidence_gap(id, false) IS NOT NULL;
  IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: % file(s) created in the last 48 hours lack proven absence', n; END IF;
  SELECT count(*) INTO n FROM file_objects WHERE file_purge_evidence_gap(id, false) IS NOT NULL;
  IF n > 0 THEN RAISE EXCEPTION '091 rollback refused: % purged file(s) no longer have valid absence evidence', n; END IF;
END $$;
DROP TRIGGER IF EXISTS employees_file_ref_truncate ON employees;
DROP TRIGGER IF EXISTS employees_file_protect ON employees;
DROP TRIGGER IF EXISTS employees_file_ref ON employees;
ALTER TABLE employees DROP CONSTRAINT IF EXISTS employees_file_source;
DROP INDEX IF EXISTS employees_photo_file_id_one;
ALTER TABLE employees DROP COLUMN IF EXISTS photo_file_id;
DROP TRIGGER IF EXISTS employee_documents_file_ref_truncate ON employee_documents;
DROP TRIGGER IF EXISTS employee_documents_file_protect ON employee_documents;
DROP TRIGGER IF EXISTS employee_documents_file_ref ON employee_documents;
ALTER TABLE employee_documents DROP CONSTRAINT IF EXISTS employee_documents_file_source;
DROP INDEX IF EXISTS employee_documents_content_file_id_one;
ALTER TABLE employee_documents DROP COLUMN IF EXISTS content_file_id;
ALTER TABLE employee_documents ALTER COLUMN content SET NOT NULL;
DROP TRIGGER IF EXISTS attendance_selfies_file_ref_truncate ON attendance_selfies;
DROP TRIGGER IF EXISTS attendance_selfies_file_protect ON attendance_selfies;
DROP TRIGGER IF EXISTS attendance_selfies_file_ref ON attendance_selfies;
ALTER TABLE attendance_selfies DROP CONSTRAINT IF EXISTS attendance_selfies_file_source;
DROP INDEX IF EXISTS attendance_selfies_image_file_id_one;
ALTER TABLE attendance_selfies DROP COLUMN IF EXISTS image_file_id;
ALTER TABLE attendance_selfies ALTER COLUMN image SET NOT NULL;
DROP TRIGGER IF EXISTS advance_requests_file_ref_truncate ON advance_requests;
DROP TRIGGER IF EXISTS advance_requests_file_protect ON advance_requests;
DROP TRIGGER IF EXISTS advance_requests_file_ref ON advance_requests;
ALTER TABLE advance_requests DROP CONSTRAINT IF EXISTS advance_requests_file_source;
DROP INDEX IF EXISTS advance_requests_attachment_file_id_one;
ALTER TABLE advance_requests DROP COLUMN IF EXISTS attachment_file_id;
DROP TRIGGER IF EXISTS cash_receipts_file_ref_truncate ON cash_receipts;
DROP TRIGGER IF EXISTS cash_receipts_file_protect ON cash_receipts;
DROP TRIGGER IF EXISTS cash_receipts_file_ref ON cash_receipts;
ALTER TABLE cash_receipts DROP CONSTRAINT IF EXISTS cash_receipts_file_source;
DROP INDEX IF EXISTS cash_receipts_attachment_file_id_one;
ALTER TABLE cash_receipts DROP COLUMN IF EXISTS attachment_file_id;
DROP TRIGGER IF EXISTS cash_expenses_file_ref_truncate ON cash_expenses;
DROP TRIGGER IF EXISTS cash_expenses_file_protect ON cash_expenses;
DROP TRIGGER IF EXISTS cash_expenses_file_ref ON cash_expenses;
ALTER TABLE cash_expenses DROP CONSTRAINT IF EXISTS cash_expenses_file_source;
DROP INDEX IF EXISTS cash_expenses_attachment_file_id_one;
ALTER TABLE cash_expenses DROP COLUMN IF EXISTS attachment_file_id;
DROP TRIGGER IF EXISTS cash_attachments_file_ref_truncate ON cash_attachments;
DROP TRIGGER IF EXISTS cash_attachments_file_protect ON cash_attachments;
DROP TRIGGER IF EXISTS cash_attachments_file_ref ON cash_attachments;
ALTER TABLE cash_attachments DROP CONSTRAINT IF EXISTS cash_attachments_file_source;
DROP INDEX IF EXISTS cash_attachments_attachment_file_id_one;
ALTER TABLE cash_attachments DROP COLUMN IF EXISTS attachment_file_id;
ALTER TABLE cash_attachments ALTER COLUMN attachment SET NOT NULL;
DROP TRIGGER IF EXISTS salary_adjustments_file_ref_truncate ON salary_adjustments;
DROP TRIGGER IF EXISTS salary_adjustments_file_protect ON salary_adjustments;
DROP TRIGGER IF EXISTS salary_adjustments_file_ref ON salary_adjustments;
ALTER TABLE salary_adjustments DROP CONSTRAINT IF EXISTS salary_adjustments_file_source;
DROP INDEX IF EXISTS salary_adjustments_attachment_file_id_one;
ALTER TABLE salary_adjustments DROP COLUMN IF EXISTS attachment_file_id;
DROP TRIGGER IF EXISTS unit_sales_file_ref_truncate ON unit_sales;
DROP TRIGGER IF EXISTS unit_sales_file_protect ON unit_sales;
DROP TRIGGER IF EXISTS unit_sales_file_ref ON unit_sales;
ALTER TABLE unit_sales DROP CONSTRAINT IF EXISTS unit_sales_file_source;
DROP INDEX IF EXISTS unit_sales_attachment_file_id_one;
ALTER TABLE unit_sales DROP COLUMN IF EXISTS attachment_file_id;
DROP TRIGGER IF EXISTS lead_attachments_file_ref_truncate ON lead_attachments;
DROP TRIGGER IF EXISTS lead_attachments_file_protect ON lead_attachments;
DROP TRIGGER IF EXISTS lead_attachments_file_ref ON lead_attachments;
ALTER TABLE lead_attachments DROP CONSTRAINT IF EXISTS lead_attachments_file_source;
DROP INDEX IF EXISTS lead_attachments_data_file_id_one;
ALTER TABLE lead_attachments DROP COLUMN IF EXISTS data_file_id;
ALTER TABLE lead_attachments ALTER COLUMN data SET NOT NULL;
DROP TRIGGER IF EXISTS ex_unit_files_file_ref_truncate ON ex_unit_files;
DROP TRIGGER IF EXISTS ex_unit_files_file_protect ON ex_unit_files;
DROP TRIGGER IF EXISTS ex_unit_files_file_ref ON ex_unit_files;
ALTER TABLE ex_unit_files DROP CONSTRAINT IF EXISTS ex_unit_files_file_source;
DROP INDEX IF EXISTS ex_unit_files_data_file_id_one;
ALTER TABLE ex_unit_files DROP COLUMN IF EXISTS data_file_id;
ALTER TABLE ex_unit_files ALTER COLUMN data SET NOT NULL;
DROP TRIGGER IF EXISTS marketing_company_files_file_ref_truncate ON marketing_company_files;
DROP TRIGGER IF EXISTS marketing_company_files_file_protect ON marketing_company_files;
DROP TRIGGER IF EXISTS marketing_company_files_file_ref ON marketing_company_files;
ALTER TABLE marketing_company_files DROP CONSTRAINT IF EXISTS marketing_company_files_file_source;
DROP INDEX IF EXISTS marketing_company_files_data_file_id_one;
ALTER TABLE marketing_company_files DROP COLUMN IF EXISTS data_file_id;
ALTER TABLE marketing_company_files ALTER COLUMN data SET NOT NULL;
DROP TRIGGER IF EXISTS project_images_file_ref_truncate ON project_images;
DROP TRIGGER IF EXISTS project_images_file_protect ON project_images;
DROP TRIGGER IF EXISTS project_images_file_ref ON project_images;
ALTER TABLE project_images DROP CONSTRAINT IF EXISTS project_images_file_source;
DROP INDEX IF EXISTS project_images_data_file_id_one;
ALTER TABLE project_images DROP COLUMN IF EXISTS data_file_id;
ALTER TABLE project_images ALTER COLUMN data SET NOT NULL;
DROP TRIGGER IF EXISTS developer_images_file_ref_truncate ON developer_images;
DROP TRIGGER IF EXISTS developer_images_file_protect ON developer_images;
DROP TRIGGER IF EXISTS developer_images_file_ref ON developer_images;
ALTER TABLE developer_images DROP CONSTRAINT IF EXISTS developer_images_file_source;
DROP INDEX IF EXISTS developer_images_data_file_id_one;
ALTER TABLE developer_images DROP COLUMN IF EXISTS data_file_id;
ALTER TABLE developer_images ALTER COLUMN data SET NOT NULL;
DROP TRIGGER IF EXISTS brokerage_listing_photos_file_ref_truncate ON brokerage_listing_photos;
DROP TRIGGER IF EXISTS brokerage_listing_photos_file_protect ON brokerage_listing_photos;
DROP TRIGGER IF EXISTS brokerage_listing_photos_file_ref ON brokerage_listing_photos;
ALTER TABLE brokerage_listing_photos DROP CONSTRAINT IF EXISTS brokerage_listing_photos_file_source;
DROP INDEX IF EXISTS brokerage_listing_photos_data_file_id_one;
ALTER TABLE brokerage_listing_photos DROP COLUMN IF EXISTS data_file_id;
ALTER TABLE brokerage_listing_photos ALTER COLUMN data SET NOT NULL;
DROP TRIGGER IF EXISTS company_assets_file_ref_truncate ON company_assets;
DROP TRIGGER IF EXISTS company_assets_file_protect ON company_assets;
DROP TRIGGER IF EXISTS company_assets_file_ref ON company_assets;
ALTER TABLE company_assets DROP CONSTRAINT IF EXISTS company_assets_file_source;
DROP INDEX IF EXISTS company_assets_data_file_id_one;
ALTER TABLE company_assets DROP COLUMN IF EXISTS data_file_id;
ALTER TABLE company_assets ALTER COLUMN data SET NOT NULL;

-- 037's guard restored verbatim
CREATE OR REPLACE FUNCTION employee_documents_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.employee_id IS NULL THEN RETURN OLD; END IF;  -- abandoned staged upload
    -- a form (استمارة), deleted through the API by someone allowed to (va.form_delete = that form's id, or '*' for the reset)
    IF OLD.kind = 'other' AND current_setting('va.form_delete', true) IN (OLD.id::text, '*')
       AND (OLD.file_name LIKE 'custody-receipt-%' OR OLD.file_name LIKE 'laptop-receipt-%' OR OLD.file_name LIKE 'client-intro-%') THEN
      RETURN OLD;
    END IF;
    RAISE EXCEPTION 'Employee documents are never deleted; replace them instead' USING ERRCODE = '42501';
  END IF;
  IF NEW.content IS DISTINCT FROM OLD.content OR NEW.mime <> OLD.mime OR NEW.kind <> OLD.kind
     OR NEW.file_name <> OLD.file_name OR NEW.uploaded_by <> OLD.uploaded_by OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'Uploaded documents are preserved exactly as uploaded' USING ERRCODE = '42501';
  END IF;
  IF OLD.employee_id IS NOT NULL AND NEW.employee_id IS DISTINCT FROM OLD.employee_id THEN
    RAISE EXCEPTION 'A document cannot move to another employee' USING ERRCODE = '42501';
  END IF;
  IF OLD.replaced_at IS NOT NULL AND (NEW.replaced_at IS DISTINCT FROM OLD.replaced_at
       OR (OLD.replaced_by IS NOT NULL AND NEW.replaced_by IS DISTINCT FROM OLD.replaced_by)) THEN
    RAISE EXCEPTION 'Document history is permanent' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
DROP FUNCTION IF EXISTS file_ref_truncate();
DROP FUNCTION IF EXISTS file_protect_truncate();
DROP FUNCTION IF EXISTS file_ref_sync();
-- file_objects and file_purge_log stay as a frozen archive: every file is 'purged' (final), the log is append-only and
-- accepts nothing for purged files; new files are refused
CREATE OR REPLACE FUNCTION file_objects_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'file_objects is archived: 091_r2_file_objects.sql was rolled back (schema_migration_rollbacks)' USING ERRCODE = '42501'; END $$;
CREATE TRIGGER file_objects_archived BEFORE INSERT ON file_objects FOR EACH ROW EXECUTE FUNCTION file_objects_guard();
DROP FUNCTION IF EXISTS file_is_referenced(uuid, text);
INSERT INTO schema_migration_rollbacks (name, reason)
VALUES ('091_r2_file_objects.sql', current_setting('va.rollback_reason') || ' [reconciliation ' || current_setting('va.rollback_reconciliation') || ']');
-- the schema_migrations row of 091 is KEPT on purpose
COMMIT;
