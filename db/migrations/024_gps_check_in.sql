-- Check-in (and the return from a permission / visit) is tied to the office location.
-- Nothing is blocked while no office location is saved.
UPDATE company_settings SET gps_required = true;
