-- Employee documents (acknowledgment PDF, job description PDF, national ID image) with replace-history,
-- and employee custody (company assets) with history. Nothing here is ever silently deleted.

-- ------------------------------------------------------------ documents
ALTER TABLE employee_documents
  ADD COLUMN kind        text NOT NULL DEFAULT 'other'
                           CHECK (kind IN ('acknowledgment','job_description','national_id','other')),
  ADD COLUMN replaced_at timestamptz,
  ADD COLUMN replaced_by uuid REFERENCES employee_documents(id),
  ADD COLUMN staged_by   uuid REFERENCES employees(id);

-- A required document can be uploaded *before* the employee exists (staged), then claimed by the
-- employee-creation transaction. Only staged files have no employee.
ALTER TABLE employee_documents ALTER COLUMN employee_id DROP NOT NULL;
ALTER TABLE employee_documents ADD CONSTRAINT employee_documents_staged_check
  CHECK (employee_id IS NOT NULL OR (staged_by IS NOT NULL AND kind <> 'other'));
ALTER TABLE employee_documents ADD CONSTRAINT employee_documents_kind_mime CHECK (
     (kind IN ('acknowledgment','job_description') AND mime = 'application/pdf')
  OR (kind = 'national_id' AND mime IN ('image/jpeg','image/png','image/webp'))
  OR kind = 'other');

-- one current document per required kind; replaced ones stay as history
CREATE UNIQUE INDEX employee_documents_current ON employee_documents (employee_id, kind)
  WHERE kind <> 'other' AND replaced_at IS NULL AND employee_id IS NOT NULL;

CREATE FUNCTION employee_documents_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.employee_id IS NULL THEN RETURN OLD; END IF;  -- abandoned staged upload
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
CREATE TRIGGER employee_documents_guard BEFORE UPDATE OR DELETE ON employee_documents
  FOR EACH ROW EXECUTE FUNCTION employee_documents_guard();

ALTER TABLE company_settings ADD COLUMN require_employee_documents boolean NOT NULL DEFAULT true;

-- ------------------------------------------------------------ custody / company assets
CREATE TABLE custody_items (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id        uuid NOT NULL REFERENCES employees(id),
  asset_name         text NOT NULL CHECK (length(trim(asset_name)) BETWEEN 2 AND 120),
  asset_type         text NOT NULL CHECK (asset_type IN ('laptop','mobile','sim','keys','equipment','car','other')),
  description        text NOT NULL DEFAULT '' CHECK (length(description) <= 1000),
  serial_no          text CHECK (length(serial_no) <= 120),
  assigned_on        date NOT NULL,
  assigned_by        uuid NOT NULL REFERENCES employees(id),
  condition_out      text NOT NULL CHECK (condition_out IN ('new','good','fair','damaged')),
  status             text NOT NULL DEFAULT 'assigned' CHECK (status IN ('assigned','returned','lost')),
  returned_on        date,
  condition_in       text CHECK (condition_in IN ('new','good','fair','damaged')),
  received_by        uuid REFERENCES employees(id),
  notes              text NOT NULL DEFAULT '' CHECK (length(notes) <= 2000),
  created_at         timestamptz NOT NULL DEFAULT now(),
  closed_at          timestamptz,
  CHECK ((status = 'assigned' AND returned_on IS NULL AND closed_at IS NULL)
      OR (status = 'returned' AND returned_on IS NOT NULL AND condition_in IS NOT NULL AND received_by IS NOT NULL AND closed_at IS NOT NULL)
      OR (status = 'lost' AND received_by IS NOT NULL AND closed_at IS NOT NULL)),
  CHECK (returned_on IS NULL OR returned_on >= assigned_on)
);
CREATE INDEX custody_items_employee ON custody_items (employee_id, status);

CREATE FUNCTION custody_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Custody history is never deleted' USING ERRCODE = '42501';
  END IF;
  IF OLD.status <> 'assigned' THEN
    RAISE EXCEPTION 'A closed custody record is permanent' USING ERRCODE = '42501';
  END IF;
  IF NEW.employee_id <> OLD.employee_id OR NEW.assigned_by <> OLD.assigned_by OR NEW.assigned_on <> OLD.assigned_on
     OR NEW.created_at <> OLD.created_at OR NEW.condition_out <> OLD.condition_out THEN
    RAISE EXCEPTION 'Assignment facts cannot be rewritten; return it and assign again' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER custody_guard BEFORE UPDATE OR DELETE ON custody_items FOR EACH ROW EXECUTE FUNCTION custody_guard();
