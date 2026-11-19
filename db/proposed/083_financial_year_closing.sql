-- 083 (PROPOSED — not in db/migrations, so no build runs it; it needs the owner's approval first).
-- تقفيل السنة المالية: a review / closing layer OVER the existing financial records. It adds five tables of its own and
-- never changes a row of any existing table. Nothing existing is altered or dropped; the only effect on the existing
-- tables is one guard: once a year is CLOSED, a new receipt / expense dated inside that year is refused (a back-dated
-- entry would change a closed year's figures). Rollback: 083_rollback.sql.
--
--  fy_closings          one row per closing attempt of a year (version 1, 2… after a reopening). The closing snapshot (the
--                       figures, checklist, issues, reconciliations, approvals, carry-forward) is frozen here at closing.
--  fy_review_items      the checklist decisions of a closing (who reviewed what, when, the note, a counted amount).
--  fy_issues            problems found (by the system's rules or by a reviewer) and how each was resolved — never deleted.
--  fy_reconciliations   documented explanations of a difference; they never touch the source transactions.
--  fy_opening_balances  the balances carried from a closed year to the next one, each traceable to its closing.

CREATE TABLE fy_closings (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fiscal_year     int  NOT NULL CHECK (fiscal_year BETWEEN 2000 AND 2100),
  version         int  NOT NULL CHECK (version >= 1),
  status          text NOT NULL DEFAULT 'in_review' CHECK (status IN ('in_review','approved','closed','reopened')),
  started_by      uuid NOT NULL REFERENCES employees(id),
  started_at      timestamptz NOT NULL DEFAULT now(),
  approved_by     uuid REFERENCES employees(id),
  approved_at     timestamptz,
  approval_notes  text CHECK (length(approval_notes) <= 2000),
  approved_hash   text,                       -- the figures the approver saw; closing refuses if they changed since
  closed_by       uuid REFERENCES employees(id),
  closed_at       timestamptz,
  snapshot        jsonb,
  snapshot_hash   text,
  reopened_by     uuid REFERENCES employees(id),
  reopened_at     timestamptz,
  reopen_reason   text,
  UNIQUE (fiscal_year, version),
  CHECK (status <> 'approved' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL AND approved_hash IS NOT NULL)),
  CHECK (status <> 'closed' OR (closed_by IS NOT NULL AND closed_at IS NOT NULL AND snapshot IS NOT NULL AND snapshot_hash IS NOT NULL)),
  CHECK (status <> 'reopened' OR (reopened_by IS NOT NULL AND reopened_at IS NOT NULL AND length(trim(COALESCE(reopen_reason, ''))) >= 10))
);
-- one live closing per year: a second «start» / «close» of the same year is impossible, even in parallel
CREATE UNIQUE INDEX fy_closings_one_live ON fy_closings (fiscal_year) WHERE status IN ('in_review','approved','closed');

CREATE TABLE fy_review_items (
  closing_id      uuid NOT NULL REFERENCES fy_closings(id),
  item_key        text NOT NULL CHECK (item_key ~ '^[a-z_]+\.[a-z0-9_.]+$'),
  status          text NOT NULL CHECK (status IN ('not_reviewed','reviewed','needs_attention','blocking','resolved','exception')),
  note            text NOT NULL DEFAULT '' CHECK (length(note) <= 2000),
  verified_amount numeric(14,2),
  reviewed_by     uuid NOT NULL REFERENCES employees(id),
  reviewed_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (closing_id, item_key)
);

CREATE TABLE fy_issues (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no          bigserial UNIQUE,
  closing_id      uuid NOT NULL REFERENCES fy_closings(id),
  issue_key       text NOT NULL,              -- the rule + source record (one issue per problem, found again = same row)
  category        text NOT NULL,
  source_module   text NOT NULL,
  source_id       text,
  description     text NOT NULL CHECK (length(trim(description)) >= 3),
  amount          numeric(14,2),
  severity        text NOT NULL CHECK (severity IN ('info','review','blocking')),
  status          text NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','exception')),
  detected_by     uuid REFERENCES employees(id),   -- NULL = found by the system's rules
  detected_at     timestamptz NOT NULL DEFAULT now(),
  resolution_note text NOT NULL DEFAULT '' CHECK (length(resolution_note) <= 2000),
  resolution_ref  text CHECK (length(resolution_ref) <= 200),
  resolved_by     uuid REFERENCES employees(id),
  resolved_at     timestamptz,
  exception_by    uuid REFERENCES employees(id),
  exception_at    timestamptz,
  UNIQUE (closing_id, issue_key),
  CHECK (status <> 'exception' OR (exception_by IS NOT NULL AND exception_at IS NOT NULL AND length(trim(resolution_note)) >= 5))
);

CREATE TABLE fy_reconciliations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no          bigserial UNIQUE,
  closing_id      uuid NOT NULL REFERENCES fy_closings(id),
  rec_type        text NOT NULL CHECK (rec_type IN ('treasury','bank','employee','partner','project','receivable','payable','asset','other')),
  source_module   text NOT NULL CHECK (length(trim(source_module)) >= 2),
  source_id       text CHECK (length(source_id) <= 200),
  amount          numeric(14,2) NOT NULL,
  reason          text NOT NULL CHECK (length(trim(reason)) >= 5),
  notes           text NOT NULL DEFAULT '' CHECK (length(notes) <= 2000),
  created_by      uuid NOT NULL REFERENCES employees(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  decided_by      uuid REFERENCES employees(id),
  decided_at      timestamptz,
  decision_note   text NOT NULL DEFAULT '' CHECK (length(decision_note) <= 2000),
  CHECK (decided_by IS NULL OR decided_by <> created_by),           -- nobody approves his own explanation
  CHECK ((status = 'pending') = (decided_by IS NULL))
);

CREATE TABLE fy_opening_balances (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  closing_id      uuid NOT NULL REFERENCES fy_closings(id),
  from_year       int  NOT NULL,
  to_year         int  NOT NULL CHECK (to_year = from_year + 1),
  entity_type     text NOT NULL,
  entity_id       text NOT NULL,
  label           text NOT NULL DEFAULT '',
  source_balance  numeric(14,2) NOT NULL,
  carry_balance   numeric(14,2) NOT NULL,
  classification  text NOT NULL,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','superseded')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (closing_id, entity_type, entity_id)                       -- carried once per closing
);
CREATE INDEX fy_opening_balances_to ON fy_opening_balances (to_year) WHERE status = 'active';
CREATE INDEX fy_issues_closing ON fy_issues (closing_id, status);
CREATE INDEX fy_reconciliations_closing ON fy_reconciliations (closing_id, status);

-- ------------------------------------------------------------------ integrity, enforced by the database itself
-- nothing of a closing is ever deleted
CREATE FUNCTION fy_no_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'سجلات تقفيل السنة لا تُحذف' USING ERRCODE = '42501'; END $$;
CREATE TRIGGER fy_closings_no_delete BEFORE DELETE ON fy_closings FOR EACH ROW EXECUTE FUNCTION fy_no_delete();
CREATE TRIGGER fy_review_items_no_delete BEFORE DELETE ON fy_review_items FOR EACH ROW EXECUTE FUNCTION fy_no_delete();
CREATE TRIGGER fy_issues_no_delete BEFORE DELETE ON fy_issues FOR EACH ROW EXECUTE FUNCTION fy_no_delete();
CREATE TRIGGER fy_reconciliations_no_delete BEFORE DELETE ON fy_reconciliations FOR EACH ROW EXECUTE FUNCTION fy_no_delete();
CREATE TRIGGER fy_opening_balances_no_delete BEFORE DELETE ON fy_opening_balances FOR EACH ROW EXECUTE FUNCTION fy_no_delete();

-- a closed snapshot is frozen: the only change to a closed closing is «reopened» (by whom, when, why) — the snapshot stays
CREATE FUNCTION fy_closings_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.id <> OLD.id OR NEW.fiscal_year <> OLD.fiscal_year OR NEW.version <> OLD.version
     OR NEW.started_by <> OLD.started_by OR NEW.started_at <> OLD.started_at THEN
    RAISE EXCEPTION 'بيانات التقفيل الأساسية لا تتغير' USING ERRCODE = '42501';
  END IF;
  IF OLD.status = 'reopened' THEN
    RAISE EXCEPTION 'تقفيل اتفتح تاني محفوظ كما هو ولا يتغير' USING ERRCODE = '42501';
  END IF;
  IF OLD.status = 'closed' THEN
    IF NEW.status <> 'reopened'
       OR (NEW.snapshot, NEW.snapshot_hash, NEW.closed_by, NEW.closed_at, NEW.approved_by, NEW.approved_at, NEW.approved_hash, NEW.approval_notes)
          IS DISTINCT FROM (OLD.snapshot, OLD.snapshot_hash, OLD.closed_by, OLD.closed_at, OLD.approved_by, OLD.approved_at, OLD.approved_hash, OLD.approval_notes) THEN
      RAISE EXCEPTION 'السنة المقفولة لا تتغير — تتفتح تاني فقط بسبب' USING ERRCODE = '42501';
    END IF;
  ELSIF NEW.status = 'reopened' THEN
    RAISE EXCEPTION 'تتفتح تاني السنة المقفولة فقط' USING ERRCODE = '42501';
  END IF;
  IF NEW.status = 'closed' AND OLD.status <> 'approved' THEN
    RAISE EXCEPTION 'التقفيل محتاج اعتماد الأول' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER fy_closings_guard BEFORE UPDATE ON fy_closings FOR EACH ROW EXECUTE FUNCTION fy_closings_guard();

-- the review work (checklist, issues, reconciliations) changes only while its closing is under review / approval
CREATE FUNCTION fy_work_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE st text;
BEGIN
  SELECT status INTO st FROM fy_closings WHERE id = NEW.closing_id;
  IF st IS NULL OR st NOT IN ('in_review','approved') THEN
    RAISE EXCEPTION 'السنة دي مقفولة أو اتفتحت تاني — مراجعتها مقفولة' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.closing_id <> OLD.closing_id THEN
    RAISE EXCEPTION 'لا يتغير التقفيل التابع له' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER fy_review_items_guard BEFORE INSERT OR UPDATE ON fy_review_items FOR EACH ROW EXECUTE FUNCTION fy_work_guard();
CREATE TRIGGER fy_issues_guard BEFORE INSERT OR UPDATE ON fy_issues FOR EACH ROW EXECUTE FUNCTION fy_work_guard();
CREATE TRIGGER fy_reconciliations_guard BEFORE INSERT OR UPDATE ON fy_reconciliations FOR EACH ROW EXECUTE FUNCTION fy_work_guard();

-- carried balances: written only at the moment of closing; afterwards only «superseded» when that closing is reopened
CREATE FUNCTION fy_opening_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE st text;
BEGIN
  SELECT status INTO st FROM fy_closings WHERE id = NEW.closing_id;
  IF TG_OP = 'INSERT' THEN
    IF st IS DISTINCT FROM 'closed' OR NEW.status <> 'active' THEN
      RAISE EXCEPTION 'الأرصدة الافتتاحية بتتولد من تقفيل معتمد بس' USING ERRCODE = '42501';
    END IF;
  ELSIF NOT (OLD.status = 'active' AND NEW.status = 'superseded' AND st = 'reopened'
             AND (NEW.closing_id, NEW.entity_type, NEW.entity_id, NEW.source_balance, NEW.carry_balance, NEW.from_year, NEW.to_year, NEW.classification, NEW.label)
                 IS NOT DISTINCT FROM (OLD.closing_id, OLD.entity_type, OLD.entity_id, OLD.source_balance, OLD.carry_balance, OLD.from_year, OLD.to_year, OLD.classification, OLD.label)) THEN
    RAISE EXCEPTION 'الأرصدة الافتتاحية لا تتعدل يدوي' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER fy_opening_balances_guard BEFORE INSERT OR UPDATE ON fy_opening_balances FOR EACH ROW EXECUTE FUNCTION fy_opening_guard();

-- a closed year takes no new money dated inside it (receipts / expenses can be recorded up to 400 days back)
CREATE FUNCTION fy_closed_year_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE y int := extract(year FROM (NEW.occurred_at AT TIME ZONE 'Africa/Cairo'))::int;
BEGIN
  IF EXISTS (SELECT 1 FROM fy_closings WHERE fiscal_year = y AND status = 'closed') THEN
    RAISE EXCEPTION 'السنة المالية % مقفولة — سجّل الحركة بتاريخ بعد التقفيل', y USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cash_receipts_closed_year BEFORE INSERT ON cash_receipts FOR EACH ROW EXECUTE FUNCTION fy_closed_year_guard();
CREATE TRIGGER cash_expenses_closed_year BEFORE INSERT ON cash_expenses FOR EACH ROW EXECUTE FUNCTION fy_closed_year_guard();
