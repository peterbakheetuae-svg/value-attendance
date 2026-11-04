-- Signed, expiring media links (photos / check-in selfies) so <img> tags work without auth headers,
-- and a place for the original JPH employee-form fields that have no column of their own.
ALTER TABLE company_settings
  ADD COLUMN media_secret text NOT NULL DEFAULT md5(random()::text || clock_timestamp()::text) || md5(random()::text || clock_timestamp()::text);

ALTER TABLE employees
  ADD COLUMN legacy_fields jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_fields) = 'object');
