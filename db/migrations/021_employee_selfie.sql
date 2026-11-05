-- Per-employee "check in with a photo" (the company switch sets it for everyone; HR fine-tunes per employee).
ALTER TABLE employees ADD COLUMN selfie_required boolean NOT NULL DEFAULT false;
UPDATE employees SET selfie_required = (SELECT selfie_required FROM company_settings LIMIT 1);
