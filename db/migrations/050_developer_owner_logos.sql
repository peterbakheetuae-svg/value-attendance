-- المطورين: the development company (name) and its owner; a picture of the company and its logo for its documents
ALTER TABLE developers ADD COLUMN owner_name text NOT NULL DEFAULT '';
CREATE TABLE developer_images (
  developer_id uuid NOT NULL REFERENCES developers(id),
  kind         text NOT NULL CHECK (kind IN ('photo','logo')),
  mime         text NOT NULL CHECK (mime IN ('image/jpeg','image/png','image/webp')),
  data         text NOT NULL,                 -- base64
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid REFERENCES employees(id),
  PRIMARY KEY (developer_id, kind)
);

-- the company's own logo, on its documents (payment vouchers, payslips …)
CREATE TABLE company_assets (
  key        text PRIMARY KEY CHECK (key IN ('logo')),
  mime       text NOT NULL CHECK (mime IN ('image/jpeg','image/png','image/webp')),
  data       text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES employees(id)
);
