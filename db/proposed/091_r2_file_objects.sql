-- 091_r2_file_objects.sql — PROPOSED v3.1 (not applied). migrate-core runs it in one transaction, under its advisory
-- lock; every statement is also safe to re-run (IF NOT EXISTS / CREATE OR REPLACE / guarded DO blocks). PostgreSQL 16 and 18.
-- v3.1 = v3 + N2 (upload window, purge log and evidence) + N5 (retention classes and policy, protected TRUNCATE).

-- 0. Ledger of intentional rollbacks (N3). A rolled-back 091 keeps its schema_migrations row (so migrate-core never
--    re-applies it); this tombstone records the rollback. Created here, never dropped, not even by the rollback.
CREATE TABLE IF NOT EXISTS schema_migration_rollbacks (
  name                    text NOT NULL CHECK (name ~ '^[0-9]{3}_.+\.sql$'),
  rolled_back_at          timestamptz NOT NULL DEFAULT now(),
  rolled_back_by          text NOT NULL DEFAULT current_user,
  reason                  text NOT NULL CHECK (length(reason) BETWEEN 10 AND 500),
  reinstated_at           timestamptz,
  reinstated_by_migration text CHECK (reinstated_by_migration IS NULL OR reinstated_by_migration ~ '^[0-9]{3}_.+\.sql$'),
  PRIMARY KEY (name, rolled_back_at),
  CONSTRAINT schema_migration_rollbacks_reinstated CHECK ((reinstated_at IS NULL) = (reinstated_by_migration IS NULL))
);
CREATE OR REPLACE FUNCTION schema_migration_rollbacks_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP IN ('DELETE', 'TRUNCATE') THEN RAISE EXCEPTION 'the rollback ledger is permanent' USING ERRCODE = '42501'; END IF;
  -- the only change ever allowed: a rollback is marked reinstated, once, by a later (approved) migration
  IF OLD.reinstated_at IS NOT NULL OR (NEW.name, NEW.rolled_back_at, NEW.rolled_back_by, NEW.reason)
       IS DISTINCT FROM (OLD.name, OLD.rolled_back_at, OLD.rolled_back_by, OLD.reason) THEN
    RAISE EXCEPTION 'the rollback ledger is permanent' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'schema_migration_rollbacks_guard' AND tgrelid = 'schema_migration_rollbacks'::regclass) THEN
    CREATE TRIGGER schema_migration_rollbacks_guard BEFORE UPDATE OR DELETE ON schema_migration_rollbacks
      FOR EACH ROW EXECUTE FUNCTION schema_migration_rollbacks_guard();
    CREATE TRIGGER schema_migration_rollbacks_no_truncate BEFORE TRUNCATE ON schema_migration_rollbacks
      FOR EACH STATEMENT EXECUTE FUNCTION schema_migration_rollbacks_guard();
  END IF;
END $$;

-- refuse to run again after an intentional rollback that was not reinstated (if someone deletes the schema_migrations
-- row, the next build fails loudly here instead of silently re-applying 091)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM schema_migration_rollbacks WHERE name = '091_r2_file_objects.sql' AND reinstated_at IS NULL) THEN
    RAISE EXCEPTION '091_r2_file_objects.sql was rolled back on purpose (schema_migration_rollbacks); only an approved reinstatement migration may re-apply it'
      USING ERRCODE = '55000';
  END IF;
END $$;

-- 1. File records
CREATE TABLE IF NOT EXISTS file_objects (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_ref             uuid NOT NULL,
  bucket                 text NOT NULL CHECK (bucket = 'valunivo-files'),
  object_key             text NOT NULL CHECK (object_key ~ '^(prod|staging)/[a-z_]+/[0-9]{4}/[0-9]{2}/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'),
  -- the only other key this file may ever occupy (presigned uploads land here); bound to the row's environment and id
  quarantine_key         text GENERATED ALWAYS AS (split_part(object_key, '/', 1) || '/quarantine/' || id::text) STORED,
  category               text NOT NULL CHECK (category IN ('employee_photo', 'employee_document', 'attendance_selfie', 'advance_attachment', 'receipt_attachment', 'expense_attachment', 'cash_attachment', 'adjustment_attachment', 'unit_sale_attachment', 'lead_attachment', 'unit_file', 'marketing_company_file', 'project_image', 'developer_image', 'listing_photo', 'company_logo')),
  access_class           text GENERATED ALWAYS AS (
    CASE category
      WHEN 'employee_photo' THEN 'hr'
      WHEN 'employee_document' THEN 'hr'
      WHEN 'attendance_selfie' THEN 'attendance'
      WHEN 'advance_attachment' THEN 'payroll'
      WHEN 'receipt_attachment' THEN 'finance'
      WHEN 'expense_attachment' THEN 'finance'
      WHEN 'cash_attachment' THEN 'finance'
      WHEN 'adjustment_attachment' THEN 'payroll'
      WHEN 'unit_sale_attachment' THEN 'contract'
      WHEN 'lead_attachment' THEN 'crm'
      WHEN 'unit_file' THEN 'contract'
      WHEN 'marketing_company_file' THEN 'contract'
      WHEN 'project_image' THEN 'business'
      WHEN 'developer_image' THEN 'business'
      WHEN 'listing_photo' THEN 'business'
      WHEN 'company_logo' THEN 'internal'
    END) STORED,
  original_name          text NOT NULL CHECK (length(original_name) BETWEEN 1 AND 200),
  mime                   text NOT NULL CHECK (mime IN ('image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'application/msword',
                           'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                           'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')),
  size_bytes             integer NOT NULL CHECK (size_bytes BETWEEN 1 AND 20971520),
  sha256                 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  status                 text NOT NULL DEFAULT 'pending'
                           CHECK (status IN ('pending', 'stored', 'verified', 'detached', 'orphan', 'purge_pending', 'purged')),
  -- N2: every write credential for this file (presigned PUT, server PUT/COPY) expires by upload_expires_at, at most
  -- 15 minutes after creation (file_objects_insert_guard). The write window closes 20 minutes later (15 min longest
  -- server request + 5 min clock skew), see file_write_window_closes().
  upload_expires_at      timestamptz NOT NULL,
  -- live business references (0 or 1); written ONLY by the business-table triggers, under this row's lock (N1)
  ref_count              integer NOT NULL DEFAULT 0 CHECK (ref_count BETWEEN 0 AND 1),
  -- N5: decided by file_retention_class() from the business row when linked; kept after release for the purge decision
  retention_class        text CHECK (retention_class IN ('protected', 'crm', 'form', 'image', 'selfie', 'temporary')),
  released_at            timestamptz,
  release_reason         text CHECK (release_reason IN ('unlinked', 'row_deleted', 'truncate')),
  quarantine_used        boolean NOT NULL DEFAULT false,
  quarantine_cleared_at  timestamptz,
  verified_size          integer,
  verified_sha256        text CHECK (verified_sha256 IS NULL OR verified_sha256 ~ '^[0-9a-f]{64}$'),
  verified_at            timestamptz,
  detached_at            timestamptz,
  purge_requested_at     timestamptz,
  purge_authorized_by    uuid REFERENCES employees(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  purge_reason           text CHECK (purge_reason IS NULL OR length(purge_reason) BETWEEN 10 AND 500),
  -- maintained only by file_purge_log (one increment per recorded DELETE attempt)
  purge_attempts         integer NOT NULL DEFAULT 0 CHECK (purge_attempts >= 0),
  purge_last_attempt_at  timestamptz,
  purged_at              timestamptz,
  purge_evidence         jsonb,
  created_by             uuid REFERENCES employees(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT file_objects_client_ref UNIQUE (client_ref),
  CONSTRAINT file_objects_key UNIQUE (bucket, object_key),
  CONSTRAINT file_objects_key_category CHECK (split_part(object_key, '/', 2) = category),
  -- one private EU bucket (valunivo-files); the environment is the first key segment
  CONSTRAINT file_objects_key_env CHECK (split_part(object_key, '/', 1) IN ('prod', 'staging')),
  CONSTRAINT file_objects_measured CHECK (status NOT IN ('verified', 'detached')
    OR (verified_at IS NOT NULL AND verified_size = size_bytes AND verified_sha256 = sha256)),
  CONSTRAINT file_objects_ref_verified CHECK (ref_count = 0 OR status = 'verified'),
  CONSTRAINT file_objects_linked_class CHECK (ref_count = 0 OR retention_class IS NOT NULL),
  CONSTRAINT file_objects_quarantine CHECK (status NOT IN ('verified', 'detached', 'purged')
    OR NOT quarantine_used OR quarantine_cleared_at IS NOT NULL),
  CONSTRAINT file_objects_quarantine_used CHECK (quarantine_used OR quarantine_cleared_at IS NULL),
  CONSTRAINT file_objects_detached_at CHECK (status <> 'detached' OR detached_at IS NOT NULL),
  CONSTRAINT file_objects_purge_requested CHECK ((status IN ('purge_pending', 'purged')) = (purge_requested_at IS NOT NULL)),
  CONSTRAINT file_objects_purged CHECK ((status = 'purged') = (purged_at IS NOT NULL)
    AND (status <> 'purged' OR purge_evidence IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS file_objects_created_by ON file_objects (created_by);
CREATE INDEX IF NOT EXISTS file_objects_purge_authorized_by ON file_objects (purge_authorized_by);
CREATE INDEX IF NOT EXISTS file_objects_sweep ON file_objects (status, created_at)
  WHERE status IN ('pending', 'stored', 'orphan', 'purge_pending');
CREATE INDEX IF NOT EXISTS file_objects_unlinked ON file_objects (verified_at) WHERE status = 'verified' AND ref_count = 0;
CREATE INDEX IF NOT EXISTS file_objects_retention ON file_objects (retention_class, detached_at) WHERE status = 'detached';
DROP TRIGGER IF EXISTS file_objects_archived ON file_objects;   -- left by a rollback; reached only after reinstatement

-- 2. Append-only purge log: every R2 DELETE attempt and every absence check, bound to this file's bucket and key (N2)
CREATE TABLE IF NOT EXISTS file_purge_log (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  file_id      uuid NOT NULL REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  target       text NOT NULL CHECK (target IN ('final', 'quarantine')),
  action       text NOT NULL CHECK (action IN ('delete', 'confirm')),
  -- 'reconciler' = the separate nightly job with its own read-only R2 token (independent check)
  source       text NOT NULL CHECK (source IN ('api', 'reconciler')),
  bucket       text NOT NULL,
  object_key   text NOT NULL,
  http_status  integer CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599),
  list_count   integer CHECK (list_count IS NULL OR list_count >= 0),
  request_id   text CHECK (request_id IS NULL OR length(request_id) <= 200),
  error        text CHECK (error IS NULL OR length(error) <= 500),
  logged_by    text NOT NULL DEFAULT current_user,
  CONSTRAINT file_purge_log_confirm CHECK (action <> 'confirm' OR (http_status IS NOT NULL AND list_count IS NOT NULL)),
  CONSTRAINT file_purge_log_delete_source CHECK (action <> 'delete' OR source = 'api')
);
CREATE INDEX IF NOT EXISTS file_purge_log_file ON file_purge_log (file_id, target, action, at);

CREATE OR REPLACE FUNCTION file_write_window_closes(f file_objects) RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT f.upload_expires_at + interval '20 minutes'
$$;

-- 3. Retention (N5) — owner decision D1 (2026-11-25): protected never purged; CRM 90 days, images 30 days, selfies 30 days
--    after detachment; generated forms 30 days; never-attached temporary uploads 1 day. One fixed classification and one fixed policy; changing either needs a new migration.
CREATE OR REPLACE FUNCTION file_retention_class(cat text, r jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE cat
    WHEN 'employee_document' THEN CASE
      WHEN r ->> 'employee_id' IS NULL THEN 'temporary'                       -- staged upload, never attached
      WHEN r ->> 'kind' = 'other' AND (r ->> 'file_name' LIKE 'custody-receipt-%' OR r ->> 'file_name' LIKE 'laptop-receipt-%' OR r ->> 'file_name' LIKE 'client-intro-%') THEN 'form'              -- generated form (forms.ts)
      ELSE 'protected' END
    WHEN 'marketing_company_file' THEN CASE WHEN r ->> 'kind' = 'logo' THEN 'image' ELSE 'protected' END
    WHEN 'lead_attachment'   THEN 'crm'
    WHEN 'attendance_selfie' THEN 'selfie'
    WHEN 'project_image'     THEN 'image'
    WHEN 'developer_image'   THEN 'image'
    WHEN 'listing_photo'     THEN 'image'
    WHEN 'company_logo'      THEN 'image'
    ELSE 'protected' END                                                      -- HR, payroll, finance, contracts
$$;
-- purgeable?  minimum time detached before a purge may be requested;  needs a named authorizer and reason?
CREATE OR REPLACE FUNCTION file_retention_policy(cls text, OUT purgeable boolean, OUT min_detached interval,
                                                 OUT needs_authorization boolean) LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE cls WHEN 'protected' THEN false ELSE cls IN ('crm', 'form', 'image', 'selfie', 'temporary') END,
         CASE cls WHEN 'crm' THEN interval '90 days' WHEN 'form' THEN interval '30 days' WHEN 'image' THEN interval '30 days'
                  WHEN 'selfie' THEN interval '30 days' WHEN 'temporary' THEN interval '1 day' END,
         cls IN ('crm', 'form')
$$;

-- 4. Does any business row point at <fid>? Every non-NULL reference counts, removed listing photos included (N4).
--    VOLATILE on purpose (N1): in READ COMMITTED each query inside takes a fresh snapshot.
CREATE OR REPLACE FUNCTION file_is_referenced(fid uuid, cat text) RETURNS boolean LANGUAGE plpgsql VOLATILE AS $$
DECLARE tbl text; col text; hit boolean;
BEGIN
  CASE cat
    WHEN 'employee_photo' THEN tbl := 'employees'; col := 'photo_file_id';
    WHEN 'employee_document' THEN tbl := 'employee_documents'; col := 'content_file_id';
    WHEN 'attendance_selfie' THEN tbl := 'attendance_selfies'; col := 'image_file_id';
    WHEN 'advance_attachment' THEN tbl := 'advance_requests'; col := 'attachment_file_id';
    WHEN 'receipt_attachment' THEN tbl := 'cash_receipts'; col := 'attachment_file_id';
    WHEN 'expense_attachment' THEN tbl := 'cash_expenses'; col := 'attachment_file_id';
    WHEN 'cash_attachment' THEN tbl := 'cash_attachments'; col := 'attachment_file_id';
    WHEN 'adjustment_attachment' THEN tbl := 'salary_adjustments'; col := 'attachment_file_id';
    WHEN 'unit_sale_attachment' THEN tbl := 'unit_sales'; col := 'attachment_file_id';
    WHEN 'lead_attachment' THEN tbl := 'lead_attachments'; col := 'data_file_id';
    WHEN 'unit_file' THEN tbl := 'ex_unit_files'; col := 'data_file_id';
    WHEN 'marketing_company_file' THEN tbl := 'marketing_company_files'; col := 'data_file_id';
    WHEN 'project_image' THEN tbl := 'project_images'; col := 'data_file_id';
    WHEN 'developer_image' THEN tbl := 'developer_images'; col := 'data_file_id';
    WHEN 'listing_photo' THEN tbl := 'brokerage_listing_photos'; col := 'data_file_id';
    WHEN 'company_logo' THEN tbl := 'company_assets'; col := 'data_file_id';
    ELSE RAISE EXCEPTION 'unknown file category %', cat;
  END CASE;
  EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I WHERE %I = $1)', tbl, col) INTO hit USING fid;
  RETURN hit;
END $$;

-- 5. Physical-absence evidence (N2). NULL = sufficient; otherwise the reason it is not. For each key the file may occupy
--    (final; quarantine if used): at least one recorded DELETE; no later sighting of the object; two absence checks
--    (HEAD 404 and LIST of the exact key = 0) after the last DELETE AND after the write window closed, at least 60 s apart,
--    at least one of them by the independent reconciler; with fresh = true the newest check is at most 15 minutes old.
CREATE OR REPLACE FUNCTION file_purge_evidence_gap(fid uuid, fresh boolean) RETURNS text LANGUAGE plpgsql VOLATILE AS $$
DECLARE f file_objects; t text; last_del timestamptz; n int; first_ok timestamptz; last_ok timestamptz; indep boolean;
BEGIN
  SELECT * INTO f FROM file_objects WHERE id = fid;
  IF NOT FOUND THEN RETURN 'no such file'; END IF;
  FOREACH t IN ARRAY CASE WHEN f.quarantine_used THEN ARRAY['final', 'quarantine'] ELSE ARRAY['final'] END LOOP
    SELECT max(at) INTO last_del FROM file_purge_log WHERE file_id = fid AND target = t AND action = 'delete';
    IF last_del IS NULL THEN RETURN format('no recorded DELETE of the %s key', t); END IF;
    IF EXISTS (SELECT 1 FROM file_purge_log WHERE file_id = fid AND target = t AND action = 'confirm' AND at > last_del
                 AND (http_status <> 404 OR list_count <> 0)) THEN
      RETURN format('the %s object was seen after the last DELETE', t);
    END IF;
    SELECT count(*), min(at), max(at), bool_or(source = 'reconciler') INTO n, first_ok, last_ok, indep
      FROM file_purge_log
     WHERE file_id = fid AND target = t AND action = 'confirm' AND http_status = 404 AND list_count = 0
       AND at > last_del AND at >= file_write_window_closes(f);
    IF n < 2 OR last_ok - first_ok < interval '60 seconds' THEN
      RETURN format('need two absence checks of the %s key, 60 s apart, after the last DELETE and the write window', t);
    END IF;
    IF NOT indep THEN RETURN format('need an independent (reconciler) absence check of the %s key', t); END IF;
    IF fresh AND last_ok < now() - interval '15 minutes' THEN RETURN format('absence evidence of the %s key is stale', t); END IF;
  END LOOP;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION file_objects_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- a new file starts empty and pending; the server clock decides creation; the write credential lives at most 15 min
  NEW.created_at := now();
  IF NEW.status IS DISTINCT FROM 'pending' OR NEW.ref_count <> 0 OR NEW.purge_attempts <> 0
     OR num_nonnulls(NEW.retention_class, NEW.released_at, NEW.release_reason, NEW.quarantine_cleared_at, NEW.verified_size,
                     NEW.verified_sha256, NEW.verified_at, NEW.detached_at, NEW.purge_requested_at, NEW.purge_authorized_by,
                     NEW.purge_reason, NEW.purge_last_attempt_at, NEW.purged_at, NEW.purge_evidence) > 0 THEN
    RAISE EXCEPTION 'a new file record starts pending and empty' USING ERRCODE = '42501';
  END IF;
  IF NEW.upload_expires_at IS NULL OR NEW.upload_expires_at <= NEW.created_at
     OR NEW.upload_expires_at > NEW.created_at + interval '15 minutes' THEN
    RAISE EXCEPTION 'upload_expires_at must be within 15 minutes of creation' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION file_objects_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pol record; gap text; trig boolean := pg_trigger_depth() >= 2;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'file records are never deleted' USING ERRCODE = '42501'; END IF;
  IF OLD.status = 'purged' THEN RAISE EXCEPTION 'a purged file record is final' USING ERRCODE = '42501'; END IF;
  -- identity is frozen; measured values, quarantine clearance, purge request / authorization, once set, are frozen too
  IF (NEW.client_ref, NEW.bucket, NEW.object_key, NEW.category, NEW.original_name, NEW.mime, NEW.size_bytes, NEW.sha256,
      NEW.quarantine_used, NEW.upload_expires_at, NEW.created_by, NEW.created_at) IS DISTINCT FROM
     (OLD.client_ref, OLD.bucket, OLD.object_key, OLD.category, OLD.original_name, OLD.mime, OLD.size_bytes, OLD.sha256,
      OLD.quarantine_used, OLD.upload_expires_at, OLD.created_by, OLD.created_at)
     OR (OLD.verified_at IS NOT NULL AND (NEW.verified_size, NEW.verified_sha256, NEW.verified_at)
                                         IS DISTINCT FROM (OLD.verified_size, OLD.verified_sha256, OLD.verified_at))
     OR (OLD.quarantine_cleared_at IS NOT NULL AND NEW.quarantine_cleared_at IS DISTINCT FROM OLD.quarantine_cleared_at)
     OR (OLD.purge_requested_at IS NOT NULL AND (NEW.purge_requested_at, NEW.purge_authorized_by, NEW.purge_reason)
                                                IS DISTINCT FROM (OLD.purge_requested_at, OLD.purge_authorized_by, OLD.purge_reason))
     OR NEW.purged_at IS DISTINCT FROM OLD.purged_at OR NEW.purge_evidence IS DISTINCT FROM OLD.purge_evidence THEN
    RAISE EXCEPTION 'a stored file is preserved exactly as stored' USING ERRCODE = '42501';
  END IF;
  -- fields owned by triggers (depth >= 2): references, retention class, release, purge attempts
  IF NOT trig AND ((NEW.ref_count, NEW.retention_class, NEW.released_at, NEW.release_reason, NEW.purge_attempts, NEW.purge_last_attempt_at)
       IS DISTINCT FROM (OLD.ref_count, OLD.retention_class, OLD.released_at, OLD.release_reason, OLD.purge_attempts, OLD.purge_last_attempt_at)) THEN
    RAISE EXCEPTION 'references, retention class and purge attempts are maintained by triggers only' USING ERRCODE = '42501';
  END IF;
  IF NEW.ref_count IS DISTINCT FROM OLD.ref_count AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'ref_count and status never change in one update' USING ERRCODE = '42501';
  END IF;
  IF OLD.retention_class = 'protected' AND NEW.retention_class IS DISTINCT FROM 'protected' THEN
    RAISE EXCEPTION 'a protected file never loses its protection' USING ERRCODE = '42501';
  END IF;
  IF (NEW.purge_authorized_by, NEW.purge_reason) IS DISTINCT FROM (OLD.purge_authorized_by, OLD.purge_reason)
     AND NOT (OLD.status = 'detached' AND NEW.status = 'purge_pending') THEN
    RAISE EXCEPTION 'purge authorization is given only when the purge is requested' USING ERRCODE = '42501';
  END IF;
  IF NEW.purge_attempts < OLD.purge_attempts THEN
    RAISE EXCEPTION 'purge attempts only grow' USING ERRCODE = '42501';
  END IF;
  -- N2-7: the quarantine copy may be declared gone only after the upload finished and only with logged evidence
  IF OLD.quarantine_cleared_at IS NULL AND NEW.quarantine_cleared_at IS NOT NULL THEN
    IF NOT OLD.quarantine_used OR OLD.status NOT IN ('stored', 'orphan', 'purge_pending') THEN
      RAISE EXCEPTION 'the quarantine copy cannot be cleared in status %', OLD.status USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM file_purge_log c WHERE c.file_id = OLD.id AND c.target = 'quarantine' AND c.action = 'confirm'
                     AND c.http_status = 404 AND c.list_count = 0
                     AND c.at > (SELECT max(d.at) FROM file_purge_log d WHERE d.file_id = OLD.id AND d.target = 'quarantine' AND d.action = 'delete')) THEN
      RAISE EXCEPTION 'no logged DELETE and absence check of the quarantine copy' USING ERRCODE = '23514';
    END IF;
    NEW.quarantine_cleared_at := now();
  END IF;
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF NOT (
       (OLD.status = 'pending'       AND NEW.status IN ('stored', 'orphan'))
    OR (OLD.status = 'stored'        AND NEW.status IN ('verified', 'orphan'))
    OR (OLD.status = 'verified'      AND NEW.status = 'detached')
    OR (OLD.status = 'detached'      AND NEW.status IN ('verified', 'purge_pending'))
    OR (OLD.status = 'orphan'        AND NEW.status = 'purge_pending')
    OR (OLD.status = 'purge_pending' AND NEW.status = 'purged')) THEN
    RAISE EXCEPTION 'file status % -> % is not allowed', OLD.status, NEW.status USING ERRCODE = '42501';
  END IF;
  -- N2-1: an upload is accepted as stored only inside its write window
  IF OLD.status = 'pending' AND NEW.status = 'stored' AND now() > file_write_window_closes(OLD) THEN
    RAISE EXCEPTION 'the upload window of file % has closed', OLD.id USING ERRCODE = '42501';
  END IF;
  -- leaving «verified»: OLD.ref_count is exact on the locked newest version (N1); the VOLATILE re-scan is defence in depth
  IF NEW.status IN ('detached', 'purge_pending') AND (OLD.ref_count <> 0 OR file_is_referenced(OLD.id, OLD.category)) THEN
    RAISE EXCEPTION 'file % is still referenced', OLD.id USING ERRCODE = '42501';
  END IF;
  -- N5: a detached file is purged only if its class allows it, after the class's minimum time, with a named authorizer
  -- where required. Never-linked orphans may always be purged.
  IF OLD.status = 'detached' AND NEW.status = 'purge_pending' THEN
    SELECT * INTO pol FROM file_retention_policy(OLD.retention_class);
    IF OLD.retention_class IS NULL OR NOT pol.purgeable THEN
      RAISE EXCEPTION 'files of class % are never purged', coalesce(OLD.retention_class, '(none)') USING ERRCODE = '42501';
    END IF;
    IF now() < OLD.detached_at + pol.min_detached THEN
      RAISE EXCEPTION 'class % files are kept at least % after detach', OLD.retention_class, pol.min_detached USING ERRCODE = '42501';
    END IF;
    IF pol.needs_authorization AND (NEW.purge_authorized_by IS NULL OR NEW.purge_reason IS NULL) THEN
      RAISE EXCEPTION 'class % purges need purge_authorized_by and purge_reason', OLD.retention_class USING ERRCODE = '23514';
    END IF;
  END IF;
  IF NEW.status = 'purge_pending' THEN
    NEW.purge_requested_at := now();
    IF OLD.status = 'orphan' OR NOT (file_retention_policy(OLD.retention_class)).needs_authorization THEN
      NEW.purge_authorized_by := NULL; NEW.purge_reason := NULL;
    END IF;
  END IF;
  -- N2: «purged» only after the write window closed, >= 30 min after creation, >= 1 logged DELETE, >= 60 s after the last
  -- one, and with fresh, independent, logged absence evidence for every key the file may occupy
  IF NEW.status = 'purged' THEN
    IF now() < OLD.created_at + interval '30 minutes' OR now() < file_write_window_closes(OLD) THEN
      RAISE EXCEPTION 'file % may still be written; purge is confirmed after its write window', OLD.id USING ERRCODE = '42501';
    END IF;
    IF OLD.purge_attempts < 1 OR now() < OLD.purge_last_attempt_at + interval '60 seconds' THEN
      RAISE EXCEPTION 'purge of % needs a logged DELETE at least 60 s ago', OLD.id USING ERRCODE = '42501';
    END IF;
    gap := file_purge_evidence_gap(OLD.id, true);
    IF gap IS NOT NULL THEN RAISE EXCEPTION 'purge of % not proven: %', OLD.id, gap USING ERRCODE = '23514'; END IF;
    IF OLD.quarantine_used AND OLD.quarantine_cleared_at IS NULL THEN NEW.quarantine_cleared_at := now(); END IF;
    NEW.purged_at := now();
    NEW.purge_evidence := (SELECT jsonb_build_object('bucket', OLD.bucket, 'keys',
        jsonb_agg(jsonb_build_object('target', l.target, 'object_key', l.object_key, 'action', l.action, 'source', l.source,
                                     'at', l.at, 'http_status', l.http_status, 'list_count', l.list_count, 'request_id', l.request_id)
                  ORDER BY l.at))
      FROM file_purge_log l WHERE l.file_id = OLD.id);
  END IF;
  IF NEW.status = 'detached' THEN NEW.detached_at := now(); END IF;
  IF NEW.status = 'verified' AND OLD.status = 'detached' THEN NEW.detached_at := NULL; END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION file_objects_no_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'file records are never truncated' USING ERRCODE = '42501'; END $$;

-- the purge log is append-only; a row is bound to its file's bucket and key, stamped with the server clock, and allowed
-- only while that key may legitimately be deleted
CREATE OR REPLACE FUNCTION file_purge_log_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE f file_objects;
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'the purge log is append-only' USING ERRCODE = '42501'; END IF;
  SELECT * INTO f FROM file_objects WHERE id = NEW.file_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'no such file %', NEW.file_id USING ERRCODE = '23503'; END IF;
  IF NEW.target = 'quarantine' AND NOT f.quarantine_used THEN
    RAISE EXCEPTION 'file % never used a quarantine copy', f.id USING ERRCODE = '23514';
  END IF;
  IF (NEW.target = 'final' AND f.status <> 'purge_pending')
     OR (NEW.target = 'quarantine' AND f.status NOT IN ('stored', 'orphan', 'purge_pending')) THEN
    RAISE EXCEPTION 'the % key of file % cannot be deleted in status %', NEW.target, f.id, f.status USING ERRCODE = '42501';
  END IF;
  IF NEW.bucket IS DISTINCT FROM f.bucket
     OR NEW.object_key IS DISTINCT FROM (CASE NEW.target WHEN 'final' THEN f.object_key ELSE f.quarantine_key END) THEN
    RAISE EXCEPTION 'purge log entry does not match file %', f.id USING ERRCODE = '23514';
  END IF;
  NEW.at := clock_timestamp();
  NEW.logged_by := current_user;
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION file_purge_log_count() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.action = 'delete' THEN
    UPDATE file_objects SET purge_attempts = purge_attempts + 1, purge_last_attempt_at = NEW.at WHERE id = NEW.file_id;
  END IF;
  RETURN NULL;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'file_objects_guard' AND tgrelid = 'file_objects'::regclass) THEN
    CREATE TRIGGER file_objects_guard BEFORE UPDATE OR DELETE ON file_objects FOR EACH ROW EXECUTE FUNCTION file_objects_guard();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'file_objects_insert_guard' AND tgrelid = 'file_objects'::regclass) THEN
    CREATE TRIGGER file_objects_insert_guard BEFORE INSERT ON file_objects FOR EACH ROW EXECUTE FUNCTION file_objects_insert_guard();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'file_objects_no_truncate' AND tgrelid = 'file_objects'::regclass) THEN
    CREATE TRIGGER file_objects_no_truncate BEFORE TRUNCATE ON file_objects FOR EACH STATEMENT EXECUTE FUNCTION file_objects_no_truncate();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'file_purge_log_guard' AND tgrelid = 'file_purge_log'::regclass) THEN
    CREATE TRIGGER file_purge_log_guard BEFORE INSERT OR UPDATE OR DELETE ON file_purge_log FOR EACH ROW EXECUTE FUNCTION file_purge_log_guard();
    CREATE TRIGGER file_purge_log_count AFTER INSERT ON file_purge_log FOR EACH ROW EXECUTE FUNCTION file_purge_log_count();
    CREATE TRIGGER file_purge_log_no_truncate BEFORE TRUNCATE ON file_purge_log FOR EACH STATEMENT EXECUTE FUNCTION file_objects_no_truncate();
  END IF;
END $$;

-- 6. Business-row references. AFTER INSERT / UPDATE OF (file id, size, MIME, class columns) / DELETE, per row.
--    Linking UPDATEs the file row (ref_count 0 -> 1) WHERE status = 'verified' under its row lock (N1), and records the
--    retention class decided by the row (N5). Unlinking (new id, NULL, or the row deleted) releases it (1 -> 0).
CREATE OR REPLACE FUNCTION file_ref_sync() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  cat    text := TG_ARGV[0];
  col    text := TG_ARGV[1];
  szc    text := TG_ARGV[2];
  mmc    text := TG_ARGV[3];
  new_id uuid;
  old_id uuid;
  nj     jsonb;
  f      record;
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') THEN nj := to_jsonb(NEW); new_id := (nj ->> col)::uuid; END IF;
  IF TG_OP IN ('UPDATE', 'DELETE') THEN old_id := (to_jsonb(OLD) ->> col)::uuid; END IF;
  IF old_id IS NOT NULL AND old_id IS DISTINCT FROM new_id THEN
    UPDATE file_objects SET ref_count = 0, released_at = now(),
           release_reason = CASE TG_OP WHEN 'DELETE' THEN 'row_deleted' ELSE 'unlinked' END
     WHERE id = old_id AND ref_count = 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'reference count of file % is inconsistent', old_id USING ERRCODE = '55000'; END IF;
  END IF;
  IF new_id IS NULL THEN RETURN NULL; END IF;
  IF new_id IS DISTINCT FROM old_id THEN
    UPDATE file_objects SET ref_count = 1, retention_class = file_retention_class(cat, nj), released_at = NULL, release_reason = NULL
     WHERE id = new_id AND status = 'verified' AND category = cat AND ref_count = 0
     RETURNING size_bytes, mime INTO f;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'file % is not a verified, unlinked % file', new_id, cat USING ERRCODE = '23514';
    END IF;
  ELSE
    -- same file; the row's size, MIME or class columns changed: re-check and re-classify under the row lock
    UPDATE file_objects SET retention_class = file_retention_class(cat, nj)
     WHERE id = new_id AND ref_count = 1
     RETURNING size_bytes, mime INTO f;
    IF NOT FOUND THEN RAISE EXCEPTION 'reference count of file % is inconsistent', new_id USING ERRCODE = '55000'; END IF;
  END IF;
  IF szc <> '' AND (nj ->> szc)::bigint IS DISTINCT FROM f.size_bytes THEN
    RAISE EXCEPTION 'size of the row and of file % differ', new_id USING ERRCODE = '23514';
  END IF;
  IF mmc <> '' AND (nj ->> mmc) IS DISTINCT FROM f.mime THEN
    RAISE EXCEPTION 'MIME of the row and of file % differ', new_id USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END $$;

-- N5: TRUNCATE (data-reset.ts:153) may not take protected files with it. Refused while the table references any.
CREATE OR REPLACE FUNCTION file_protect_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE hit boolean;
BEGIN
  EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I t JOIN file_objects f ON f.id = t.%I WHERE f.retention_class = %L)',
                 TG_TABLE_NAME, TG_ARGV[0], 'protected') INTO hit;
  IF hit THEN
    RAISE EXCEPTION 'TRUNCATE of % refused: it references protected files (HR / payroll / finance / contracts)', TG_TABLE_NAME
      USING ERRCODE = '42501';
  END IF;
  RETURN NULL;
END $$;
-- after an allowed TRUNCATE every reference of that table's one category is gone; release them in the same transaction
CREATE OR REPLACE FUNCTION file_ref_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE file_objects SET ref_count = 0, released_at = now(), release_reason = 'truncate'
   WHERE category = TG_ARGV[0] AND ref_count = 1;
  RETURN NULL;
END $$;

-- employees.photo -> photo_file_id (employee_photo)
ALTER TABLE employees ADD COLUMN IF NOT EXISTS photo_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS employees_photo_file_id_one ON employees (photo_file_id) WHERE photo_file_id IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'employees_file_source') THEN
    ALTER TABLE employees ADD CONSTRAINT employees_file_source CHECK (num_nonnulls(photo, photo_file_id) <= 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'employees_file_ref' AND tgrelid = 'employees'::regclass) THEN
    CREATE TRIGGER employees_file_ref AFTER INSERT OR UPDATE OF photo_file_id, photo_mime OR DELETE ON employees
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('employee_photo', 'photo_file_id', '', 'photo_mime');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'employees_file_protect' AND tgrelid = 'employees'::regclass) THEN
    CREATE TRIGGER employees_file_protect BEFORE TRUNCATE ON employees
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('photo_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'employees_file_ref_truncate' AND tgrelid = 'employees'::regclass) THEN
    CREATE TRIGGER employees_file_ref_truncate AFTER TRUNCATE ON employees
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('employee_photo');
  END IF;
END $$;

-- employee_documents.content -> content_file_id (employee_document)
ALTER TABLE employee_documents ADD COLUMN IF NOT EXISTS content_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS employee_documents_content_file_id_one ON employee_documents (content_file_id) WHERE content_file_id IS NOT NULL;
ALTER TABLE employee_documents ALTER COLUMN content DROP NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'employee_documents_file_source') THEN
    ALTER TABLE employee_documents ADD CONSTRAINT employee_documents_file_source CHECK (num_nonnulls(content, content_file_id) = 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'employee_documents_file_ref' AND tgrelid = 'employee_documents'::regclass) THEN
    CREATE TRIGGER employee_documents_file_ref AFTER INSERT OR UPDATE OF content_file_id, size_bytes, mime, employee_id, kind, file_name OR DELETE ON employee_documents
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('employee_document', 'content_file_id', 'size_bytes', 'mime');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'employee_documents_file_protect' AND tgrelid = 'employee_documents'::regclass) THEN
    CREATE TRIGGER employee_documents_file_protect BEFORE TRUNCATE ON employee_documents
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('content_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'employee_documents_file_ref_truncate' AND tgrelid = 'employee_documents'::regclass) THEN
    CREATE TRIGGER employee_documents_file_ref_truncate AFTER TRUNCATE ON employee_documents
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('employee_document');
  END IF;
END $$;

-- attendance_selfies.image -> image_file_id (attendance_selfie)
ALTER TABLE attendance_selfies ADD COLUMN IF NOT EXISTS image_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS attendance_selfies_image_file_id_one ON attendance_selfies (image_file_id) WHERE image_file_id IS NOT NULL;
ALTER TABLE attendance_selfies ALTER COLUMN image DROP NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'attendance_selfies_file_source') THEN
    ALTER TABLE attendance_selfies ADD CONSTRAINT attendance_selfies_file_source CHECK (num_nonnulls(image, image_file_id) = 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'attendance_selfies_file_ref' AND tgrelid = 'attendance_selfies'::regclass) THEN
    CREATE TRIGGER attendance_selfies_file_ref AFTER INSERT OR UPDATE OF image_file_id, mime OR DELETE ON attendance_selfies
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('attendance_selfie', 'image_file_id', '', 'mime');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'attendance_selfies_file_protect' AND tgrelid = 'attendance_selfies'::regclass) THEN
    CREATE TRIGGER attendance_selfies_file_protect BEFORE TRUNCATE ON attendance_selfies
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('image_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'attendance_selfies_file_ref_truncate' AND tgrelid = 'attendance_selfies'::regclass) THEN
    CREATE TRIGGER attendance_selfies_file_ref_truncate AFTER TRUNCATE ON attendance_selfies
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('attendance_selfie');
  END IF;
END $$;

-- advance_requests.attachment -> attachment_file_id (advance_attachment)
ALTER TABLE advance_requests ADD COLUMN IF NOT EXISTS attachment_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS advance_requests_attachment_file_id_one ON advance_requests (attachment_file_id) WHERE attachment_file_id IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'advance_requests_file_source') THEN
    ALTER TABLE advance_requests ADD CONSTRAINT advance_requests_file_source CHECK (num_nonnulls(attachment, attachment_file_id) <= 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'advance_requests_file_ref' AND tgrelid = 'advance_requests'::regclass) THEN
    CREATE TRIGGER advance_requests_file_ref AFTER INSERT OR UPDATE OF attachment_file_id OR DELETE ON advance_requests
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('advance_attachment', 'attachment_file_id', '', '');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'advance_requests_file_protect' AND tgrelid = 'advance_requests'::regclass) THEN
    CREATE TRIGGER advance_requests_file_protect BEFORE TRUNCATE ON advance_requests
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('attachment_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'advance_requests_file_ref_truncate' AND tgrelid = 'advance_requests'::regclass) THEN
    CREATE TRIGGER advance_requests_file_ref_truncate AFTER TRUNCATE ON advance_requests
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('advance_attachment');
  END IF;
END $$;

-- cash_receipts.attachment -> attachment_file_id (receipt_attachment)
ALTER TABLE cash_receipts ADD COLUMN IF NOT EXISTS attachment_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS cash_receipts_attachment_file_id_one ON cash_receipts (attachment_file_id) WHERE attachment_file_id IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cash_receipts_file_source') THEN
    ALTER TABLE cash_receipts ADD CONSTRAINT cash_receipts_file_source CHECK (num_nonnulls(attachment, attachment_file_id) <= 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cash_receipts_file_ref' AND tgrelid = 'cash_receipts'::regclass) THEN
    CREATE TRIGGER cash_receipts_file_ref AFTER INSERT OR UPDATE OF attachment_file_id OR DELETE ON cash_receipts
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('receipt_attachment', 'attachment_file_id', '', '');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cash_receipts_file_protect' AND tgrelid = 'cash_receipts'::regclass) THEN
    CREATE TRIGGER cash_receipts_file_protect BEFORE TRUNCATE ON cash_receipts
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('attachment_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cash_receipts_file_ref_truncate' AND tgrelid = 'cash_receipts'::regclass) THEN
    CREATE TRIGGER cash_receipts_file_ref_truncate AFTER TRUNCATE ON cash_receipts
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('receipt_attachment');
  END IF;
END $$;

-- cash_expenses.attachment -> attachment_file_id (expense_attachment)
ALTER TABLE cash_expenses ADD COLUMN IF NOT EXISTS attachment_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS cash_expenses_attachment_file_id_one ON cash_expenses (attachment_file_id) WHERE attachment_file_id IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cash_expenses_file_source') THEN
    ALTER TABLE cash_expenses ADD CONSTRAINT cash_expenses_file_source CHECK (num_nonnulls(attachment, attachment_file_id) <= 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cash_expenses_file_ref' AND tgrelid = 'cash_expenses'::regclass) THEN
    CREATE TRIGGER cash_expenses_file_ref AFTER INSERT OR UPDATE OF attachment_file_id OR DELETE ON cash_expenses
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('expense_attachment', 'attachment_file_id', '', '');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cash_expenses_file_protect' AND tgrelid = 'cash_expenses'::regclass) THEN
    CREATE TRIGGER cash_expenses_file_protect BEFORE TRUNCATE ON cash_expenses
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('attachment_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cash_expenses_file_ref_truncate' AND tgrelid = 'cash_expenses'::regclass) THEN
    CREATE TRIGGER cash_expenses_file_ref_truncate AFTER TRUNCATE ON cash_expenses
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('expense_attachment');
  END IF;
END $$;

-- cash_attachments.attachment -> attachment_file_id (cash_attachment)
ALTER TABLE cash_attachments ADD COLUMN IF NOT EXISTS attachment_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS cash_attachments_attachment_file_id_one ON cash_attachments (attachment_file_id) WHERE attachment_file_id IS NOT NULL;
ALTER TABLE cash_attachments ALTER COLUMN attachment DROP NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cash_attachments_file_source') THEN
    ALTER TABLE cash_attachments ADD CONSTRAINT cash_attachments_file_source CHECK (num_nonnulls(attachment, attachment_file_id) = 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cash_attachments_file_ref' AND tgrelid = 'cash_attachments'::regclass) THEN
    CREATE TRIGGER cash_attachments_file_ref AFTER INSERT OR UPDATE OF attachment_file_id OR DELETE ON cash_attachments
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('cash_attachment', 'attachment_file_id', '', '');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cash_attachments_file_protect' AND tgrelid = 'cash_attachments'::regclass) THEN
    CREATE TRIGGER cash_attachments_file_protect BEFORE TRUNCATE ON cash_attachments
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('attachment_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'cash_attachments_file_ref_truncate' AND tgrelid = 'cash_attachments'::regclass) THEN
    CREATE TRIGGER cash_attachments_file_ref_truncate AFTER TRUNCATE ON cash_attachments
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('cash_attachment');
  END IF;
END $$;

-- salary_adjustments.attachment -> attachment_file_id (adjustment_attachment)
ALTER TABLE salary_adjustments ADD COLUMN IF NOT EXISTS attachment_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS salary_adjustments_attachment_file_id_one ON salary_adjustments (attachment_file_id) WHERE attachment_file_id IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'salary_adjustments_file_source') THEN
    ALTER TABLE salary_adjustments ADD CONSTRAINT salary_adjustments_file_source CHECK (num_nonnulls(attachment, attachment_file_id) <= 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'salary_adjustments_file_ref' AND tgrelid = 'salary_adjustments'::regclass) THEN
    CREATE TRIGGER salary_adjustments_file_ref AFTER INSERT OR UPDATE OF attachment_file_id OR DELETE ON salary_adjustments
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('adjustment_attachment', 'attachment_file_id', '', '');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'salary_adjustments_file_protect' AND tgrelid = 'salary_adjustments'::regclass) THEN
    CREATE TRIGGER salary_adjustments_file_protect BEFORE TRUNCATE ON salary_adjustments
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('attachment_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'salary_adjustments_file_ref_truncate' AND tgrelid = 'salary_adjustments'::regclass) THEN
    CREATE TRIGGER salary_adjustments_file_ref_truncate AFTER TRUNCATE ON salary_adjustments
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('adjustment_attachment');
  END IF;
END $$;

-- unit_sales.attachment -> attachment_file_id (unit_sale_attachment)
ALTER TABLE unit_sales ADD COLUMN IF NOT EXISTS attachment_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS unit_sales_attachment_file_id_one ON unit_sales (attachment_file_id) WHERE attachment_file_id IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'unit_sales_file_source') THEN
    ALTER TABLE unit_sales ADD CONSTRAINT unit_sales_file_source CHECK (num_nonnulls(attachment, attachment_file_id) <= 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'unit_sales_file_ref' AND tgrelid = 'unit_sales'::regclass) THEN
    CREATE TRIGGER unit_sales_file_ref AFTER INSERT OR UPDATE OF attachment_file_id OR DELETE ON unit_sales
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('unit_sale_attachment', 'attachment_file_id', '', '');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'unit_sales_file_protect' AND tgrelid = 'unit_sales'::regclass) THEN
    CREATE TRIGGER unit_sales_file_protect BEFORE TRUNCATE ON unit_sales
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('attachment_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'unit_sales_file_ref_truncate' AND tgrelid = 'unit_sales'::regclass) THEN
    CREATE TRIGGER unit_sales_file_ref_truncate AFTER TRUNCATE ON unit_sales
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('unit_sale_attachment');
  END IF;
END $$;

-- lead_attachments.data -> data_file_id (lead_attachment)
ALTER TABLE lead_attachments ADD COLUMN IF NOT EXISTS data_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS lead_attachments_data_file_id_one ON lead_attachments (data_file_id) WHERE data_file_id IS NOT NULL;
ALTER TABLE lead_attachments ALTER COLUMN data DROP NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lead_attachments_file_source') THEN
    ALTER TABLE lead_attachments ADD CONSTRAINT lead_attachments_file_source CHECK (num_nonnulls(data, data_file_id) = 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'lead_attachments_file_ref' AND tgrelid = 'lead_attachments'::regclass) THEN
    CREATE TRIGGER lead_attachments_file_ref AFTER INSERT OR UPDATE OF data_file_id, size_bytes, mime OR DELETE ON lead_attachments
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('lead_attachment', 'data_file_id', 'size_bytes', 'mime');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'lead_attachments_file_protect' AND tgrelid = 'lead_attachments'::regclass) THEN
    CREATE TRIGGER lead_attachments_file_protect BEFORE TRUNCATE ON lead_attachments
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('data_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'lead_attachments_file_ref_truncate' AND tgrelid = 'lead_attachments'::regclass) THEN
    CREATE TRIGGER lead_attachments_file_ref_truncate AFTER TRUNCATE ON lead_attachments
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('lead_attachment');
  END IF;
END $$;

-- ex_unit_files.data -> data_file_id (unit_file)
ALTER TABLE ex_unit_files ADD COLUMN IF NOT EXISTS data_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS ex_unit_files_data_file_id_one ON ex_unit_files (data_file_id) WHERE data_file_id IS NOT NULL;
ALTER TABLE ex_unit_files ALTER COLUMN data DROP NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ex_unit_files_file_source') THEN
    ALTER TABLE ex_unit_files ADD CONSTRAINT ex_unit_files_file_source CHECK (num_nonnulls(data, data_file_id) = 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ex_unit_files_file_ref' AND tgrelid = 'ex_unit_files'::regclass) THEN
    CREATE TRIGGER ex_unit_files_file_ref AFTER INSERT OR UPDATE OF data_file_id, size_bytes, mime OR DELETE ON ex_unit_files
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('unit_file', 'data_file_id', 'size_bytes', 'mime');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ex_unit_files_file_protect' AND tgrelid = 'ex_unit_files'::regclass) THEN
    CREATE TRIGGER ex_unit_files_file_protect BEFORE TRUNCATE ON ex_unit_files
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('data_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ex_unit_files_file_ref_truncate' AND tgrelid = 'ex_unit_files'::regclass) THEN
    CREATE TRIGGER ex_unit_files_file_ref_truncate AFTER TRUNCATE ON ex_unit_files
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('unit_file');
  END IF;
END $$;

-- marketing_company_files.data -> data_file_id (marketing_company_file)
ALTER TABLE marketing_company_files ADD COLUMN IF NOT EXISTS data_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS marketing_company_files_data_file_id_one ON marketing_company_files (data_file_id) WHERE data_file_id IS NOT NULL;
ALTER TABLE marketing_company_files ALTER COLUMN data DROP NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'marketing_company_files_file_source') THEN
    ALTER TABLE marketing_company_files ADD CONSTRAINT marketing_company_files_file_source CHECK (num_nonnulls(data, data_file_id) = 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'marketing_company_files_file_ref' AND tgrelid = 'marketing_company_files'::regclass) THEN
    CREATE TRIGGER marketing_company_files_file_ref AFTER INSERT OR UPDATE OF data_file_id, mime, kind OR DELETE ON marketing_company_files
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('marketing_company_file', 'data_file_id', '', 'mime');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'marketing_company_files_file_protect' AND tgrelid = 'marketing_company_files'::regclass) THEN
    CREATE TRIGGER marketing_company_files_file_protect BEFORE TRUNCATE ON marketing_company_files
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('data_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'marketing_company_files_file_ref_truncate' AND tgrelid = 'marketing_company_files'::regclass) THEN
    CREATE TRIGGER marketing_company_files_file_ref_truncate AFTER TRUNCATE ON marketing_company_files
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('marketing_company_file');
  END IF;
END $$;

-- project_images.data -> data_file_id (project_image)
ALTER TABLE project_images ADD COLUMN IF NOT EXISTS data_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS project_images_data_file_id_one ON project_images (data_file_id) WHERE data_file_id IS NOT NULL;
ALTER TABLE project_images ALTER COLUMN data DROP NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'project_images_file_source') THEN
    ALTER TABLE project_images ADD CONSTRAINT project_images_file_source CHECK (num_nonnulls(data, data_file_id) = 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'project_images_file_ref' AND tgrelid = 'project_images'::regclass) THEN
    CREATE TRIGGER project_images_file_ref AFTER INSERT OR UPDATE OF data_file_id, mime OR DELETE ON project_images
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('project_image', 'data_file_id', '', 'mime');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'project_images_file_protect' AND tgrelid = 'project_images'::regclass) THEN
    CREATE TRIGGER project_images_file_protect BEFORE TRUNCATE ON project_images
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('data_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'project_images_file_ref_truncate' AND tgrelid = 'project_images'::regclass) THEN
    CREATE TRIGGER project_images_file_ref_truncate AFTER TRUNCATE ON project_images
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('project_image');
  END IF;
END $$;

-- developer_images.data -> data_file_id (developer_image)
ALTER TABLE developer_images ADD COLUMN IF NOT EXISTS data_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS developer_images_data_file_id_one ON developer_images (data_file_id) WHERE data_file_id IS NOT NULL;
ALTER TABLE developer_images ALTER COLUMN data DROP NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'developer_images_file_source') THEN
    ALTER TABLE developer_images ADD CONSTRAINT developer_images_file_source CHECK (num_nonnulls(data, data_file_id) = 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'developer_images_file_ref' AND tgrelid = 'developer_images'::regclass) THEN
    CREATE TRIGGER developer_images_file_ref AFTER INSERT OR UPDATE OF data_file_id, mime OR DELETE ON developer_images
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('developer_image', 'data_file_id', '', 'mime');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'developer_images_file_protect' AND tgrelid = 'developer_images'::regclass) THEN
    CREATE TRIGGER developer_images_file_protect BEFORE TRUNCATE ON developer_images
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('data_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'developer_images_file_ref_truncate' AND tgrelid = 'developer_images'::regclass) THEN
    CREATE TRIGGER developer_images_file_ref_truncate AFTER TRUNCATE ON developer_images
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('developer_image');
  END IF;
END $$;

-- brokerage_listing_photos.data -> data_file_id (listing_photo)
ALTER TABLE brokerage_listing_photos ADD COLUMN IF NOT EXISTS data_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS brokerage_listing_photos_data_file_id_one ON brokerage_listing_photos (data_file_id) WHERE data_file_id IS NOT NULL;
ALTER TABLE brokerage_listing_photos ALTER COLUMN data DROP NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'brokerage_listing_photos_file_source') THEN
    ALTER TABLE brokerage_listing_photos ADD CONSTRAINT brokerage_listing_photos_file_source CHECK (num_nonnulls(data, data_file_id) = 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'brokerage_listing_photos_file_ref' AND tgrelid = 'brokerage_listing_photos'::regclass) THEN
    CREATE TRIGGER brokerage_listing_photos_file_ref AFTER INSERT OR UPDATE OF data_file_id, mime OR DELETE ON brokerage_listing_photos
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('listing_photo', 'data_file_id', '', 'mime');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'brokerage_listing_photos_file_protect' AND tgrelid = 'brokerage_listing_photos'::regclass) THEN
    CREATE TRIGGER brokerage_listing_photos_file_protect BEFORE TRUNCATE ON brokerage_listing_photos
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('data_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'brokerage_listing_photos_file_ref_truncate' AND tgrelid = 'brokerage_listing_photos'::regclass) THEN
    CREATE TRIGGER brokerage_listing_photos_file_ref_truncate AFTER TRUNCATE ON brokerage_listing_photos
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('listing_photo');
  END IF;
END $$;

-- company_assets.data -> data_file_id (company_logo)
ALTER TABLE company_assets ADD COLUMN IF NOT EXISTS data_file_id uuid REFERENCES file_objects(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS company_assets_data_file_id_one ON company_assets (data_file_id) WHERE data_file_id IS NOT NULL;
ALTER TABLE company_assets ALTER COLUMN data DROP NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'company_assets_file_source') THEN
    ALTER TABLE company_assets ADD CONSTRAINT company_assets_file_source CHECK (num_nonnulls(data, data_file_id) = 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'company_assets_file_ref' AND tgrelid = 'company_assets'::regclass) THEN
    CREATE TRIGGER company_assets_file_ref AFTER INSERT OR UPDATE OF data_file_id, mime OR DELETE ON company_assets
      FOR EACH ROW EXECUTE FUNCTION file_ref_sync('company_logo', 'data_file_id', '', 'mime');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'company_assets_file_protect' AND tgrelid = 'company_assets'::regclass) THEN
    CREATE TRIGGER company_assets_file_protect BEFORE TRUNCATE ON company_assets
      FOR EACH STATEMENT EXECUTE FUNCTION file_protect_truncate('data_file_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'company_assets_file_ref_truncate' AND tgrelid = 'company_assets'::regclass) THEN
    CREATE TRIGGER company_assets_file_ref_truncate AFTER TRUNCATE ON company_assets
      FOR EACH STATEMENT EXECUTE FUNCTION file_ref_truncate('company_logo');
  END IF;
END $$;

-- 037's guard, verbatim, plus content_file_id (a document's file is as permanent as its content)
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
  IF NEW.content IS DISTINCT FROM OLD.content OR NEW.content_file_id IS DISTINCT FROM OLD.content_file_id OR NEW.mime <> OLD.mime OR NEW.kind <> OLD.kind
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
