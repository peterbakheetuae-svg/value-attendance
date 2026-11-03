-- JPH Real Estate HR — 002 KPI engine, evaluations, financial adjustments

-- ============================================================ KPI definitions
CREATE TABLE kpi_definitions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key               text NOT NULL UNIQUE CHECK (key ~ '^[a-z0-9_]{2,40}$'),
  name_ar           text NOT NULL,
  name_en           text NOT NULL DEFAULT '',
  measurement_type  text NOT NULL CHECK (measurement_type IN ('count','percent','amount_egp','score')),
  higher_is_better  boolean NOT NULL DEFAULT true,
  active            boolean NOT NULL DEFAULT true,
  created_by        uuid REFERENCES employees(id),
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- Suggested templates (NOT company targets): definitions only, inactive until HR uses them.
INSERT INTO kpi_definitions (key, name_ar, name_en, measurement_type, active) VALUES
  ('calls',            'عدد المكالمات',            'Calls',                 'count',      false),
  ('follow_ups',       'عدد المتابعات',            'Follow-ups',            'count',      false),
  ('qualified_leads',  'العملاء المؤهلون',          'Qualified leads',       'count',      false),
  ('meetings',         'عدد الاجتماعات',           'Meetings',              'count',      false),
  ('viewings',         'معاينات العقارات',          'Property viewings',     'count',      false),
  ('offers',           'العروض المقدمة',            'Offers',                'count',      false),
  ('closed_deals',     'الصفقات المغلقة',           'Closed deals',          'count',      false),
  ('sales_target',     'تحقيق المستهدف البيعي',      'Sales target achieved', 'amount_egp', false),
  ('attendance_commit','الالتزام بالحضور',          'Attendance commitment', 'percent',    false),
  ('punctuality',      'الانضباط في المواعيد',       'Punctuality',           'percent',    false),
  ('follow_up_quality','جودة المتابعة',             'Follow-up quality',     'score',      false),
  ('manager_rating',   'تقييم المدير',              'Manager evaluation',    'score',      false);

-- ============================================================ KPI sets (versioned)
-- A set applies to a job title or to one employee. Editing never mutates a used
-- version: a new version is created and the old one is retired.
CREATE TABLE kpi_sets (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL,
  scope_type     text NOT NULL CHECK (scope_type IN ('job_title','employee')),
  job_title      text,
  employee_id    uuid REFERENCES employees(id),
  version        int  NOT NULL DEFAULT 1,
  active         boolean NOT NULL DEFAULT true,
  created_by     uuid NOT NULL REFERENCES employees(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  retired_at     timestamptz,
  CHECK ((scope_type = 'job_title' AND job_title IS NOT NULL AND employee_id IS NULL)
      OR (scope_type = 'employee'  AND employee_id IS NOT NULL AND job_title IS NULL))
);
CREATE UNIQUE INDEX kpi_sets_one_active_title ON kpi_sets (job_title) WHERE active AND scope_type = 'job_title';
CREATE UNIQUE INDEX kpi_sets_one_active_emp   ON kpi_sets (employee_id) WHERE active AND scope_type = 'employee';

CREATE TABLE kpi_set_items (
  set_id      uuid NOT NULL REFERENCES kpi_sets(id),
  kpi_id      uuid NOT NULL REFERENCES kpi_definitions(id),
  weight      numeric(5,2) NOT NULL CHECK (weight > 0 AND weight <= 100),
  target      numeric(14,2) NOT NULL CHECK (target > 0),
  PRIMARY KEY (set_id, kpi_id)
);

-- Weight rule: every set must total exactly 100 at COMMIT time.
CREATE FUNCTION kpi_set_weight_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE sid uuid; total numeric;
BEGIN
  sid := COALESCE(NEW.set_id, OLD.set_id);
  IF NOT EXISTS (SELECT 1 FROM kpi_sets WHERE id = sid) THEN RETURN NULL; END IF;
  SELECT COALESCE(sum(weight),0) INTO total FROM kpi_set_items WHERE set_id = sid;
  IF total <> 100 THEN
    RAISE EXCEPTION 'KPI weights for set % total %, must be 100', sid, total USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER kpi_set_items_weight AFTER INSERT OR UPDATE OR DELETE ON kpi_set_items
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION kpi_set_weight_check();

CREATE FUNCTION kpi_set_nonempty_check() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM kpi_set_items WHERE set_id = NEW.id) THEN
    RAISE EXCEPTION 'KPI set % has no KPIs', NEW.id USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER kpi_sets_nonempty AFTER INSERT ON kpi_sets
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION kpi_set_nonempty_check();

-- Items of a set that already has results are frozen.
CREATE FUNCTION kpi_set_items_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM kpi_results WHERE set_id = COALESCE(OLD.set_id, NEW.set_id)) THEN
    RAISE EXCEPTION 'KPI set is in use; create a new version' USING ERRCODE = '42501';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

-- ============================================================ KPI results (per employee / month / KPI)
CREATE TABLE kpi_results (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id      uuid NOT NULL REFERENCES employees(id),
  period           date NOT NULL CHECK (extract(day FROM period) = 1),
  set_id           uuid NOT NULL REFERENCES kpi_sets(id),
  kpi_id           uuid NOT NULL REFERENCES kpi_definitions(id),
  weight_snapshot  numeric(5,2)  NOT NULL,
  target_snapshot  numeric(14,2) NOT NULL,
  actual           numeric(14,2) CHECK (actual IS NULL OR actual >= 0),
  state            text NOT NULL DEFAULT 'not_evaluated'
                     CHECK (state IN ('not_evaluated','in_progress','completed')),
  entered_by       uuid REFERENCES employees(id),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, period, kpi_id),
  -- missing data is never zero: not_evaluated ⇔ actual IS NULL
  CHECK ((state = 'not_evaluated') = (actual IS NULL))
);
CREATE TRIGGER kpi_set_items_frozen_trg BEFORE UPDATE OR DELETE ON kpi_set_items
  FOR EACH ROW EXECUTE FUNCTION kpi_set_items_frozen();

-- ============================================================ evaluations
CREATE TABLE evaluations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id     uuid NOT NULL REFERENCES employees(id),
  evaluator_id    uuid NOT NULL REFERENCES employees(id),
  evaluator_kind  text NOT NULL CHECK (evaluator_kind IN ('manager','hr','owner')),
  period          date NOT NULL CHECK (extract(day FROM period) = 1),
  discipline      int CHECK (discipline BETWEEN 1 AND 5),
  attendance      int CHECK (attendance BETWEEN 1 AND 5),
  communication   int CHECK (communication BETWEEN 1 AND 5),
  follow_up       int CHECK (follow_up BETWEEN 1 AND 5),
  teamwork        int CHECK (teamwork BETWEEN 1 AND 5),
  sales_performance int CHECK (sales_performance BETWEEN 1 AND 5),
  initiative      int CHECK (initiative BETWEEN 1 AND 5),
  professional_behavior int CHECK (professional_behavior BETWEEN 1 AND 5),
  feedback        text NOT NULL DEFAULT '',
  strengths       text NOT NULL DEFAULT '',
  improvements    text NOT NULL DEFAULT '',
  improvement_plan text NOT NULL DEFAULT '',
  status          text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  published_at    timestamptz,
  CHECK (evaluator_id <> employee_id),
  CHECK ((status = 'published') = (published_at IS NOT NULL)),
  UNIQUE (employee_id, period, evaluator_kind)
);

CREATE FUNCTION evaluations_published_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'published' THEN
      RAISE EXCEPTION 'published evaluations are permanent' USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status = 'published' THEN
    RAISE EXCEPTION 'published evaluations are permanent' USING ERRCODE = '42501';
  END IF;
  IF NEW.status = 'published' AND (
       NEW.discipline IS NULL OR NEW.attendance IS NULL OR NEW.communication IS NULL
    OR NEW.follow_up IS NULL OR NEW.teamwork IS NULL OR NEW.sales_performance IS NULL
    OR NEW.initiative IS NULL OR NEW.professional_behavior IS NULL) THEN
    RAISE EXCEPTION 'all eight dimensions must be scored before publishing' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER evaluations_published BEFORE UPDATE OR DELETE ON evaluations
  FOR EACH ROW EXECUTE FUNCTION evaluations_published_guard();

-- ============================================================ financial adjustments (EGP)
CREATE TABLE salary_adjustments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id   uuid NOT NULL REFERENCES employees(id),
  period        date NOT NULL CHECK (extract(day FROM period) = 1),
  kind          text NOT NULL CHECK (kind IN ('deduction','bonus')),
  amount_egp    numeric(12,2) NOT NULL CHECK (amount_egp > 0),
  reason        text NOT NULL CHECK (length(trim(reason)) >= 3),
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  created_by    uuid NOT NULL REFERENCES employees(id),
  decided_by    uuid REFERENCES employees(id),
  decided_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (decided_by IS NULL OR (decided_by <> created_by AND decided_by <> employee_id)),
  CHECK (created_by <> employee_id)
);
