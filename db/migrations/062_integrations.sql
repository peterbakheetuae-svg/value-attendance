-- الربط التلقائي:
--  * Value Aqar (valueaqar.com, on Supabase): its database webhooks post every new inquiry → a lead on the chosen
--    campaign; every project / unit → «المشاريع الواردة», and only the projects the office adopts (تسويق / حصري)
--    come into the app with their units (kept in sync).
--  * Meta lead ads: the page's lead forms → a lead on the campaign whose Meta form id matches (or the default one).
-- Keys / tokens are kept server side only (never returned by the API).
CREATE TABLE integrations (
  source       text PRIMARY KEY CHECK (source IN ('valueaqar','meta')),
  key_hash     text,                                   -- Value Aqar: sha256 of the key it sends (x-value-key)
  key_hint     text NOT NULL DEFAULT '',
  verify_token text,                                   -- Meta: the webhook verify token (not a secret by itself)
  access_token text,                                   -- Meta: the page / system-user token (never sent back)
  campaign_id  uuid,                                   -- (no FK so the data reset can wipe the campaigns) where the leads go (its project / channel / salesmen)
  active       boolean NOT NULL DEFAULT true,
  last_at      timestamptz,
  last_error   text NOT NULL DEFAULT '',
  updated_by   uuid REFERENCES employees(id),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE lead_campaigns ADD COLUMN meta_form_id text;
CREATE UNIQUE INDEX lead_campaigns_meta_form ON lead_campaigns (meta_form_id) WHERE meta_form_id IS NOT NULL;

CREATE TABLE partner_projects (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source       text NOT NULL,
  external_id  text NOT NULL,
  name         text NOT NULL DEFAULT '',
  developer    text NOT NULL DEFAULT '',
  location     text NOT NULL DEFAULT '',
  data         jsonb NOT NULL DEFAULT '{}',
  status       text NOT NULL DEFAULT 'new' CHECK (status IN ('new','adopted','ignored','deleted')),
  project_id   uuid REFERENCES commission_projects(id),
  adopted_by   uuid REFERENCES employees(id),
  received_at  timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source, external_id)
);
CREATE TABLE partner_units (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source              text NOT NULL,
  external_id         text NOT NULL,
  external_project_id text NOT NULL DEFAULT '',
  data                jsonb NOT NULL DEFAULT '{}',
  deleted             boolean NOT NULL DEFAULT false,
  received_at         timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source, external_id)
);
CREATE INDEX partner_units_project ON partner_units (source, external_project_id);
ALTER TABLE ex_inventory ADD COLUMN external_ref text;
CREATE UNIQUE INDEX ex_inventory_external ON ex_inventory (external_ref) WHERE external_ref IS NOT NULL;

INSERT INTO lead_channels (name, sort) SELECT 'فاليو عقار', 60 WHERE NOT EXISTS (SELECT 1 FROM lead_channels WHERE name = 'فاليو عقار');
