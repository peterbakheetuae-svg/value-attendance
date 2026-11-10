-- استمارات: HR and المدير (and the owner) may delete an earlier form (custody receipts, client intros).
-- Every other employee document stays undeletable. A deleted form's number is never given again: numbering now
-- comes from a counter, started from the forms already saved.

INSERT INTO permissions (key, description) VALUES ('forms.delete', 'Delete earlier forms (استمارات)')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('owner','forms.delete'), ('hr_manager','forms.delete'), ('manager','forms.delete')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
SELECT r.key, 'forms.delete' FROM roles r WHERE r.base_key = 'hr_manager'
ON CONFLICT DO NOTHING;

CREATE TABLE form_counters (
  prefix text PRIMARY KEY,
  last   int  NOT NULL DEFAULT 0
);
INSERT INTO form_counters (prefix, last)
SELECT p, COALESCE((SELECT count(*) FROM employee_documents WHERE kind = 'other' AND file_name LIKE p || '%'), 0)
  FROM unnest(ARRAY['custody-receipt-','laptop-receipt-','client-intro-']) AS p;

CREATE OR REPLACE FUNCTION employee_documents_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.employee_id IS NULL THEN RETURN OLD; END IF;  -- abandoned staged upload
    -- a form (استمارة), deleted through the API by someone allowed to (it sets va.form_delete for that one statement)
    IF OLD.kind = 'other' AND current_setting('va.form_delete', true) = OLD.id::text
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
