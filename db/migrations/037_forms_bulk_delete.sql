-- 036 reached the database in its first form (a form could be deleted only one at a time). This adds the owner's
-- one-time data reset ('*'), same rules otherwise.
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
