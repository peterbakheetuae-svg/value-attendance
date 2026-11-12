-- المطورين: every project (حصري / تسويق) belongs to a developer. An exclusive project's developer is its owner (the
-- money held is his); a marketing project's developer pays the office its commission. Additive only.
CREATE TABLE developers (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 120),
  phone       text NOT NULL DEFAULT '',
  notes       text NOT NULL DEFAULT '',
  created_by  uuid REFERENCES employees(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX developers_name ON developers (lower(trim(name)));
ALTER TABLE commission_projects ADD COLUMN developer_id uuid REFERENCES developers(id);
CREATE INDEX commission_projects_developer ON commission_projects (developer_id);

-- today's exclusive owners become developers (one per name), and their projects are linked
INSERT INTO developers (name, phone)
SELECT DISTINCT ON (lower(trim(owner_name))) trim(owner_name), COALESCE(owner_phone, '')
  FROM commission_projects WHERE kind = 'exclusive' AND owner_name IS NOT NULL AND length(trim(owner_name)) >= 2
 ORDER BY lower(trim(owner_name)), created_at
ON CONFLICT DO NOTHING;
UPDATE commission_projects p SET developer_id = d.id FROM developers d
 WHERE p.kind = 'exclusive' AND p.developer_id IS NULL AND lower(trim(p.owner_name)) = lower(trim(d.name));
