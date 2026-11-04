-- Company information page: description, address and the official contact shown across the app.
ALTER TABLE company_settings
  ADD COLUMN description    text NOT NULL DEFAULT '' CHECK (length(description) <= 2000),
  ADD COLUMN address        text NOT NULL DEFAULT '' CHECK (length(address) <= 500),
  ADD COLUMN contact_phone  text NOT NULL DEFAULT '01080660100' CHECK (contact_phone ~ '^\+?[0-9]{8,15}$'),
  ADD COLUMN contact_email  text NOT NULL DEFAULT 'info@valueaqar.com' CHECK (contact_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  ADD COLUMN updated_by     uuid REFERENCES employees(id);
