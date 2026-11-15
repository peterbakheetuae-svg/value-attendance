-- توزيع الليدز اللي بتيجي لوحدها (فاليو عقار، إعلانات Meta، فورم الحملة):
--  * Value Aqar is a direct channel («فاليو عقار»), not a campaign: each project / property it sends can have its own
--    rule (+ a default rule for everything else).
--  * a rule (and a campaign) says who gets the lead:
--      one    → one fixed salesman
--      online → in turn among the chosen salesmen who are online now; nobody online → the lead waits, the general
--               manager / administrative officer are alerted, and if nobody distributed it, the first chosen salesman
--               to come online gets it
--      turn   → in turn among the chosen salesmen, online or not
CREATE TABLE lead_routes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source      text NOT NULL DEFAULT 'valueaqar' CHECK (source IN ('valueaqar')),
  target      text NOT NULL CHECK (target IN ('default', 'project', 'property')),
  external_id text NOT NULL DEFAULT '' CHECK (length(external_id) <= 80),
  label       text NOT NULL DEFAULT '' CHECK (length(label) <= 200),
  mode        text NOT NULL DEFAULT 'online' CHECK (mode IN ('one', 'online', 'turn')),
  assignees   uuid[] NOT NULL DEFAULT '{}',
  project_id  uuid,                                   -- (no FK: the data reset wipes projects) the leads' project, when known
  updated_by  uuid REFERENCES employees(id),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source, target, external_id),
  CHECK ((target = 'default') = (external_id = ''))
);

ALTER TABLE lead_campaigns ADD COLUMN assign_mode text NOT NULL DEFAULT 'turn' CHECK (assign_mode IN ('one', 'online', 'turn'));

-- a lead that found nobody online waits for the first of these to come online (unless a manager distributes it first)
ALTER TABLE leads ADD COLUMN assign_mode text NOT NULL DEFAULT 'turn' CHECK (assign_mode IN ('one', 'online', 'turn'));
ALTER TABLE leads ADD COLUMN wait_pool uuid[] NOT NULL DEFAULT '{}';
ALTER TABLE leads ADD COLUMN wait_since timestamptz;
CREATE INDEX leads_waiting ON leads (wait_since) WHERE assigned_to IS NULL AND wait_since IS NOT NULL;

-- what Value Aqar used before (a campaign) becomes its default rule: the same salesmen in turn, the same project
INSERT INTO lead_routes (source, target, external_id, label, mode, assignees, project_id)
  SELECT 'valueaqar', 'default', '', 'كل الاستفسارات', 'turn', COALESCE(c.form_assignees, '{}'), c.project_id
    FROM integrations i JOIN lead_campaigns c ON c.id = i.campaign_id
   WHERE i.source = 'valueaqar'
  ON CONFLICT DO NOTHING;
UPDATE integrations SET campaign_id = NULL WHERE source = 'valueaqar';

-- who is alerted when a new lead finds no salesman online: the owner, the general manager, the administrative officer
INSERT INTO permissions (key, description) VALUES ('leads.waiting_alert', 'Leads: alerted when a new lead finds no salesman online')
  ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
  SELECT key, 'leads.waiting_alert' FROM roles WHERE key IN ('owner', 'manager', 'admin_officer') OR name_ar = 'مسؤول إداري'
  ON CONFLICT DO NOTHING;
