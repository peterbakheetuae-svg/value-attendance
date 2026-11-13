-- نظام الليدز (العملاء المحتملين) — inspired by EngazCRM, tied to our own projects (commission_projects),
-- units (ex_inventory) and reservations (ex_units). No separate inventory.
--  * the lead distributor (موزّع الليدز) enters / imports leads and picks the salesmen: one → it is his,
--    several → they take turns (the one who got a lead longest ago is next)
--  * the salesman works his leads with «إضافة أكشن» (stage + answered + next follow-up + comment)
--  * a lead nobody acted on within company_settings.lead_pending_minutes (25) rings the salesman's manager
--  * «حجز» from a lead opens the normal reservation (ex_units.lead_id); it is confirmed when the accountant /
--    the general manager confirms receiving the deposit (the existing flow), the contract makes it «تم البيع»

INSERT INTO permissions (key, description) VALUES
  ('leads.own',        'Leads: work the leads assigned to me'),
  ('leads.team',       'Leads: see and re-assign my team''s leads'),
  ('leads.distribute', 'Leads: add / import leads and assign them to any salesman'),
  ('leads.read_all',   'Leads: see every lead and the reports'),
  ('leads.config',     'Leads: channels, campaigns and cancel reasons')
  ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_key, perm_key) SELECT 'owner', key FROM permissions ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) VALUES
  ('manager','leads.read_all'), ('manager','leads.distribute'), ('manager','leads.config'),
  ('accountant','leads.read_all'), ('accountant','leads.distribute'), ('accountant','leads.config'),
  ('sales_manager','leads.own'), ('sales_manager','leads.team'),
  ('sales_employee','leads.own')
  ON CONFLICT DO NOTHING;
-- the job positions follow their base role (they were copied from it when created)
INSERT INTO role_permissions (role_key, perm_key)
  SELECT r.key, rp.perm_key FROM roles r JOIN role_permissions rp ON rp.role_key = r.base_key
   WHERE r.base_key IS NOT NULL AND rp.perm_key LIKE 'leads.%'
  ON CONFLICT DO NOTHING;

ALTER TABLE company_settings ADD COLUMN lead_pending_minutes int NOT NULL DEFAULT 25 CHECK (lead_pending_minutes BETWEEN 5 AND 1440);

-- ------------------------------------------------------------------ channels / campaigns / cancel reasons
CREATE TABLE lead_channels (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 80),
  sort          int  NOT NULL DEFAULT 100,
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX lead_channels_name ON lead_channels (lower(trim(name)));
INSERT INTO lead_channels (name, sort) VALUES
  ('فيسبوك', 10), ('إنستجرام', 20), ('تيك توك', 30), ('واتساب', 40), ('سناب شات', 50), ('جوجل', 60),
  ('بروبرتي فايندر', 70), ('بيانات الشركة', 80), ('بيانات شخصية', 90), ('ترشيح من عميل', 100), ('زيارة للمكتب', 110);

CREATE TABLE lead_campaigns (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 120),
  channel_id  uuid REFERENCES lead_channels(id),
  project_id  uuid REFERENCES commission_projects(id),
  starts_on   date,
  ends_on     date,
  cost        numeric(14,2) NOT NULL DEFAULT 0 CHECK (cost >= 0),
  active      boolean NOT NULL DEFAULT true,
  created_by  uuid REFERENCES employees(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on)
);

CREATE TABLE lead_cancel_reasons (
  id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name    text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 80),
  sort    int  NOT NULL DEFAULT 100,
  active  boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX lead_cancel_reasons_name ON lead_cancel_reasons (lower(trim(name)));
INSERT INTO lead_cancel_reasons (name, sort) VALUES
  ('مش مهتم', 10), ('الميزانية قليلة', 20), ('اشترى خلاص', 30), ('الرقم غلط', 40), ('مش بيرد خالص', 50);

-- ------------------------------------------------------------------ leads
CREATE SEQUENCE lead_ref_seq START 1001;

CREATE TABLE leads (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no             bigint NOT NULL UNIQUE DEFAULT nextval('lead_ref_seq'),
  full_name          text NOT NULL CHECK (length(trim(full_name)) BETWEEN 2 AND 120),
  phone              text NOT NULL CHECK (length(trim(phone)) BETWEEN 5 AND 30),
  phone_norm         text NOT NULL,                       -- digits only, Egyptian numbers as 01xxxxxxxxx
  extra_phones       text[] NOT NULL DEFAULT '{}',
  email              text NOT NULL DEFAULT '',
  budget             numeric(16,2) CHECK (budget IS NULL OR budget >= 0),
  kind               text NOT NULL DEFAULT 'fresh' CHECK (kind IN ('fresh','cold')),
  channel_id         uuid REFERENCES lead_channels(id),
  campaign_id        uuid REFERENCES lead_campaigns(id),
  project_id         uuid REFERENCES commission_projects(id),
  assigned_to        uuid REFERENCES employees(id),
  assigned_at        timestamptz,
  assigned_by        uuid REFERENCES employees(id),
  stage              text NOT NULL DEFAULT 'new' CHECK (stage IN ('new','no_answer','following','interested','meeting',
                       'after_meeting','reschedule','cancelled','reservation','done_deal')),
  stage_changed_at   timestamptz NOT NULL DEFAULT now(),
  next_at            timestamptz,                         -- the next follow-up (موعد المتابعة)
  reminded_at        timestamptz,                         -- the salesman was told that next_at came
  last_action_at     timestamptz,
  last_action_by     uuid REFERENCES employees(id),
  last_comment       text NOT NULL DEFAULT '',
  no_answer_count    int  NOT NULL DEFAULT 0,
  cancel_reason_id   uuid REFERENCES lead_cancel_reasons(id),
  duplicate_of       uuid REFERENCES leads(id),
  pending_alerted_at timestamptz,                         -- the manager was told nobody acted on it
  notes              text NOT NULL DEFAULT '' CHECK (length(notes) <= 2000),
  created_by         uuid REFERENCES employees(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX leads_assigned ON leads (assigned_to, stage);
CREATE INDEX leads_phone ON leads (phone_norm);
CREATE INDEX leads_next ON leads (next_at) WHERE next_at IS NOT NULL;
CREATE INDEX leads_created ON leads (created_at DESC);

-- every «أكشن» on a lead (and the replies of the manager on it)
CREATE TABLE lead_actions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id          uuid NOT NULL REFERENCES leads(id),
  parent_id        uuid REFERENCES lead_actions(id),     -- a reply to a comment
  stage            text CHECK (stage IN ('no_answer','following','interested','meeting','after_meeting','reschedule',
                     'cancelled','reservation','done_deal')),
  answered         boolean,
  call_seconds     int CHECK (call_seconds IS NULL OR call_seconds BETWEEN 0 AND 36000),
  comment          text NOT NULL CHECK (length(trim(comment)) BETWEEN 1 AND 2000),
  next_at          timestamptz,
  meeting_kind     text NOT NULL DEFAULT '',
  meeting_place    text NOT NULL DEFAULT '',
  cancel_reason_id uuid REFERENCES lead_cancel_reasons(id),
  ex_unit_id       uuid REFERENCES ex_units(id),
  auto             boolean NOT NULL DEFAULT false,       -- written by the system (reservation received, contract…)
  by_id            uuid REFERENCES employees(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (parent_id IS NOT NULL OR stage IS NOT NULL)
);
CREATE INDEX lead_actions_lead ON lead_actions (lead_id, created_at DESC);
CREATE INDEX lead_actions_by ON lead_actions (by_id, created_at);

-- what happened to the lead: added, assigned (by whom, to whom, turn or by hand), edited, opened, shared
CREATE TABLE lead_logs (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id    uuid NOT NULL REFERENCES leads(id),
  kind       text NOT NULL CHECK (kind IN ('create','assign','edit','view','duplicate','referral','import')),
  by_id      uuid REFERENCES employees(id),
  data       jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX lead_logs_lead ON lead_logs (lead_id, created_at DESC);
CREATE INDEX lead_logs_assign ON lead_logs (kind, created_at) WHERE kind = 'assign';

-- a lead shared with another salesman (it stays its owner's)
CREATE TABLE lead_referrals (
  lead_id     uuid NOT NULL REFERENCES leads(id),
  employee_id uuid NOT NULL REFERENCES employees(id),
  by_id       uuid REFERENCES employees(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (lead_id, employee_id)
);

-- the reservation made from a lead
ALTER TABLE ex_units ADD COLUMN lead_id uuid REFERENCES leads(id);
CREATE INDEX ex_units_lead ON ex_units (lead_id) WHERE lead_id IS NOT NULL;

-- ------------------------------------------------------------------ tasks (المهام)
CREATE TABLE tasks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no       bigint NOT NULL UNIQUE DEFAULT nextval('lead_ref_seq'),
  title        text NOT NULL CHECK (length(trim(title)) BETWEEN 2 AND 160),
  description  text NOT NULL DEFAULT '' CHECK (length(description) <= 3000),
  assigned_to  uuid NOT NULL REFERENCES employees(id),
  created_by   uuid NOT NULL REFERENCES employees(id),
  lead_id      uuid REFERENCES leads(id),
  due_at       timestamptz,
  status       text NOT NULL DEFAULT 'open' CHECK (status IN ('open','doing','done','cancelled')),
  done_at      timestamptz,
  reminded_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX tasks_assigned ON tasks (assigned_to, status);
CREATE INDEX tasks_creator ON tasks (created_by, status);
