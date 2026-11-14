-- نظام الليدز — المرحلة التانية:
--  تقييم العميل (ساخن / دافي / بارد)، مرفقات الليد، طلب العميل (للمطابقة مع الوحدات المتاحة)، التشيك إن في الميتنج،
--  رسايل واتساب جاهزة، التارجت الشهري، فورم عام لكل حملة، السحب الأوتوماتيك، سجل التصدير.

ALTER TABLE leads ADD COLUMN rating text CHECK (rating IN ('hot','warm','cold'));
-- the salesmen the lead was given to (when several: their turn) — the automatic pull moves it to the next of them
ALTER TABLE leads ADD COLUMN assign_pool uuid[] NOT NULL DEFAULT '{}';
CREATE INDEX leads_rating ON leads (rating) WHERE rating IS NOT NULL;

-- the lead's files (the ID, the contract, a screenshot…); small enough to travel in one request
CREATE TABLE lead_attachments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id     uuid NOT NULL REFERENCES leads(id),
  file_name   text NOT NULL CHECK (length(trim(file_name)) BETWEEN 1 AND 160),
  mime        text NOT NULL DEFAULT 'application/octet-stream',
  size_bytes  int  NOT NULL CHECK (size_bytes BETWEEN 1 AND 3200000),
  data        bytea NOT NULL,
  by_id       uuid REFERENCES employees(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX lead_attachments_lead ON lead_attachments (lead_id, created_at DESC);

-- what the client wants — matched against the available units (ex_inventory)
CREATE TABLE lead_requests (
  lead_id     uuid PRIMARY KEY REFERENCES leads(id),
  project_id  uuid REFERENCES commission_projects(id),
  unit_type   text NOT NULL DEFAULT '',
  floor       text NOT NULL DEFAULT '',
  min_area    numeric(12,2) CHECK (min_area IS NULL OR min_area > 0),
  max_area    numeric(12,2) CHECK (max_area IS NULL OR max_area > 0),
  max_price   numeric(16,2) CHECK (max_price IS NULL OR max_price > 0),
  payment     text NOT NULL DEFAULT 'any' CHECK (payment IN ('any','cash','installments')),
  notes       text NOT NULL DEFAULT '' CHECK (length(notes) <= 1000),
  updated_by  uuid REFERENCES employees(id),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- «وصلت الميتنج»: where and when the salesman was
CREATE TABLE lead_checkins (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id      uuid NOT NULL REFERENCES leads(id),
  employee_id  uuid NOT NULL REFERENCES employees(id),
  lat          double precision NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lng          double precision NOT NULL CHECK (lng BETWEEN -180 AND 180),
  accuracy_m   double precision,
  note         text NOT NULL DEFAULT '' CHECK (length(note) <= 500),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX lead_checkins_lead ON lead_checkins (lead_id, created_at DESC);
CREATE INDEX lead_checkins_emp ON lead_checkins (employee_id, created_at);

-- رسايل واتساب جاهزة: {الاسم} {المشروع} {السيلز} {الشركة} are filled in
CREATE TABLE lead_templates (
  id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name    text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 80),
  body    text NOT NULL CHECK (length(trim(body)) BETWEEN 2 AND 1500),
  sort    int  NOT NULL DEFAULT 100,
  active  boolean NOT NULL DEFAULT true
);
INSERT INTO lead_templates (name, body, sort) VALUES
  ('أول تواصل', 'أهلاً أستاذ {الاسم} 👋
معاك {السيلز} من {الشركة} بخصوص مشروع {المشروع}. أقدر أكلّم حضرتك إمتى؟', 10),
  ('مردّش', 'أهلاً أستاذ {الاسم}، حاولت أكلّم حضرتك بخصوص مشروع {المشروع}. ابعتلي الوقت المناسب وأنا أتصل بحضرتك 🙏', 20),
  ('تأكيد ميتنج', 'أهلاً أستاذ {الاسم}، بأكّد مع حضرتك معاد الميتنج بخصوص مشروع {المشروع}. في انتظار حضرتك 🌹 — {السيلز}', 30);

-- التارجت الشهري لكل سيلز
CREATE TABLE lead_targets (
  employee_id   uuid NOT NULL REFERENCES employees(id),
  month         date NOT NULL CHECK (extract(day FROM month) = 1),
  calls         int NOT NULL DEFAULT 0 CHECK (calls >= 0),
  meetings      int NOT NULL DEFAULT 0 CHECK (meetings >= 0),
  reservations  int NOT NULL DEFAULT 0 CHECK (reservations >= 0),
  deals         int NOT NULL DEFAULT 0 CHECK (deals >= 0),
  deals_value   numeric(16,2) NOT NULL DEFAULT 0 CHECK (deals_value >= 0),
  updated_by    uuid REFERENCES employees(id),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employee_id, month)
);

-- فورم عام للحملة: a link for an ad / a landing page; the leads it brings go to the chosen salesmen in turn
ALTER TABLE lead_campaigns
  ADD COLUMN form_token     text UNIQUE,
  ADD COLUMN form_assignees uuid[] NOT NULL DEFAULT '{}',
  ADD COLUMN form_title     text NOT NULL DEFAULT '';

-- السحب الأوتوماتيك (off by default): a lead nobody acted on for this long goes to the next salesman of its pool
ALTER TABLE company_settings ADD COLUMN lead_auto_reassign_minutes int CHECK (lead_auto_reassign_minutes IS NULL OR lead_auto_reassign_minutes BETWEEN 10 AND 10080);

-- who exported which leads / report, when
CREATE TABLE lead_exports (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind        text NOT NULL,
  rows_count  int NOT NULL DEFAULT 0,
  filters     jsonb NOT NULL DEFAULT '{}',
  by_id       uuid REFERENCES employees(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE lead_logs DROP CONSTRAINT lead_logs_kind_check;
ALTER TABLE lead_logs ADD CONSTRAINT lead_logs_kind_check
  CHECK (kind IN ('create','assign','edit','view','duplicate','referral','import','form','attachment','checkin','request','rating','bulk'));
