-- (1) مراحل الليدز: the stages become a list the leads settings edit (like Elite): add stages, rename, order, and per
--     stage «وقت التنبيه» (remind N minutes before the follow-up time) and «مدة التأخير» (late only N minutes after it).
--     The built-in stages stay (the system relies on them) — they can be renamed / tuned, never deleted.
CREATE TABLE lead_stages (
  key            text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]{1,39}$'),
  name_ar        text NOT NULL CHECK (length(trim(name_ar)) BETWEEN 2 AND 60),
  kind           text NOT NULL CHECK (kind IN ('new','action','lost','reserve','won')),
  needs_date     boolean NOT NULL DEFAULT true,     -- «إضافة أكشن» asks for the next follow-up time
  color          text NOT NULL DEFAULT '#7FB4E8' CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
  alert_minutes  int NOT NULL DEFAULT 0 CHECK (alert_minutes BETWEEN 0 AND 10080),
  delay_minutes  int NOT NULL DEFAULT 0 CHECK (delay_minutes BETWEEN 0 AND 43200),
  sort           int NOT NULL DEFAULT 100,
  active         boolean NOT NULL DEFAULT true,
  builtin        boolean NOT NULL DEFAULT false,
  created_at     timestamptz NOT NULL DEFAULT now()
);
INSERT INTO lead_stages (key, name_ar, kind, needs_date, color, sort, builtin) VALUES
  ('new',           'جديد',               'new',     false, '#7FB4E8', 10, true),
  ('no_answer',     'أول مكالمة — مردّش', 'action',  true,  '#8F8B84', 20, true),
  ('following',     'متابعة',             'action',  true,  '#F7A928', 30, true),
  ('interested',    'مهتم',               'action',  true,  '#C99A76', 40, true),
  ('meeting',       'ميتنج',              'action',  true,  '#FF6A3D', 50, true),
  ('after_meeting', 'متابعة بعد الميتنج', 'action',  true,  '#B28DFF', 60, true),
  ('reschedule',    'تأجيل ميتنج',        'action',  true,  '#E38BC8', 70, true),
  ('cancelled',     'إلغاء',              'lost',    false, '#FF7D6E', 80, true),
  ('reservation',   'حجز',                'reserve', false, '#3FC1C9', 90, true),
  ('done_deal',     'تم البيع',           'won',     false, '#4FCF73', 95, true);

ALTER TABLE leads DROP CONSTRAINT IF EXISTS leads_stage_check;
ALTER TABLE leads ADD CONSTRAINT leads_stage_fk FOREIGN KEY (stage) REFERENCES lead_stages(key);
ALTER TABLE lead_actions DROP CONSTRAINT IF EXISTS lead_actions_stage_check;
ALTER TABLE lead_actions ADD CONSTRAINT lead_actions_stage_fk FOREIGN KEY (stage) REFERENCES lead_stages(key);

-- (2) the client's stars (1–5), and the WhatsApp tab: every message sent from the app to the client is kept
ALTER TABLE leads ADD COLUMN stars smallint CHECK (stars IS NULL OR stars BETWEEN 1 AND 5);
CREATE TABLE lead_whatsapp (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seq        bigint GENERATED ALWAYS AS IDENTITY,
  lead_id    uuid NOT NULL REFERENCES leads(id),
  direction  text NOT NULL DEFAULT 'out' CHECK (direction IN ('out','in')),   -- 'in': a reply the salesman pasted in
  body       text NOT NULL CHECK (length(body) BETWEEN 0 AND 4000),
  template_id uuid REFERENCES lead_templates(id),
  by_id      uuid REFERENCES employees(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX lead_whatsapp_lead ON lead_whatsapp (lead_id, created_at DESC);

-- (3) الصفقات (Deals): a lead turned into a deal; a board of Open / Won / Lost (drag a card to move it)
CREATE TABLE deals (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_no        int NOT NULL,
  lead_id       uuid REFERENCES leads(id),
  title         text NOT NULL CHECK (length(trim(title)) BETWEEN 2 AND 160),
  value         numeric(16,2) CHECK (value IS NULL OR value >= 0),
  project_id    uuid REFERENCES commission_projects(id),
  unit_text     text NOT NULL DEFAULT '' CHECK (length(unit_text) <= 120),
  stage         text NOT NULL DEFAULT 'open' CHECK (stage IN ('open','won','lost')),
  expected_at   date,
  lost_reason   text NOT NULL DEFAULT '' CHECK (length(lost_reason) <= 300),
  notes         text NOT NULL DEFAULT '' CHECK (length(notes) <= 2000),
  owner_id      uuid REFERENCES employees(id),        -- the salesman of the deal
  sort          double precision NOT NULL DEFAULT 0,   -- the card's place in its column
  created_by    uuid REFERENCES employees(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  closed_at     timestamptz
);
CREATE SEQUENCE deal_ref_seq START 1001;
ALTER TABLE deals ALTER COLUMN ref_no SET DEFAULT nextval('deal_ref_seq');
CREATE INDEX deals_stage ON deals (stage, sort);
CREATE INDEX deals_owner ON deals (owner_id);
CREATE INDEX deals_lead ON deals (lead_id);

INSERT INTO permissions (key, description) VALUES
  ('leads.stages', 'Manage the lead stages'),
  ('deals.view',   'Open the deals board'),
  ('deals.create', 'Add deals (convert a lead)'),
  ('deals.edit',   'Edit / move deals'),
  ('deals.delete', 'Delete deals')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key) SELECT 'owner', key FROM permissions ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
  SELECT DISTINCT rp.role_key, p.k FROM role_permissions rp CROSS JOIN (VALUES ('deals.view'), ('deals.create'), ('deals.edit')) p(k)
   WHERE rp.perm_key IN ('leads.own', 'leads.distribute', 'leads.read_all', 'leads.team') ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
  SELECT DISTINCT rp.role_key, p.k FROM role_permissions rp CROSS JOIN (VALUES ('deals.delete'), ('leads.stages')) p(k)
   WHERE rp.perm_key = 'leads.config' ON CONFLICT DO NOTHING;

ALTER TABLE lead_logs DROP CONSTRAINT lead_logs_kind_check;
ALTER TABLE lead_logs ADD CONSTRAINT lead_logs_kind_check
  CHECK (kind IN ('create','assign','edit','view','duplicate','referral','import','form','attachment','checkin','request','rating','bulk',
                  'call','whatsapp','stars','deal'));
