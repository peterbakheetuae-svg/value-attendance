-- Rollback of 094_shift_attendance_policies.sql. Refuses (changes nothing) once an incident carries a deduction amount:
-- those are financial records. Preferences and amount-free incidents go with the tables; the API then behaves as before 094.
BEGIN;
DO $$ BEGIN
  IF to_regclass('public.unauthorized_exit_incidents') IS NOT NULL
     AND EXISTS (SELECT 1 FROM unauthorized_exit_incidents WHERE amount_egp IS NOT NULL) THEN
    RAISE EXCEPTION '094 rollback refused: unauthorized-exit incidents carry deductions';
  END IF;
END $$;
DROP TABLE IF EXISTS notification_preferences;
DROP TRIGGER IF EXISTS unauthorized_exit_incidents_guard ON unauthorized_exit_incidents;
DROP FUNCTION IF EXISTS unauthorized_exit_incidents_guard();
DROP INDEX IF EXISTS unauthorized_exit_period;
DROP INDEX IF EXISTS unauthorized_exit_one_open;
DROP TABLE IF EXISTS unauthorized_exit_incidents;
ALTER TABLE company_settings DROP CONSTRAINT IF EXISTS company_settings_exit_tiers;
ALTER TABLE company_settings DROP CONSTRAINT IF EXISTS company_settings_absence_threshold;
ALTER TABLE company_settings DROP COLUMN IF EXISTS unauthorized_exit_deduction;
ALTER TABLE company_settings DROP COLUMN IF EXISTS unauthorized_exit_tiers;
ALTER TABLE company_settings DROP COLUMN IF EXISTS absence_threshold_hours;
ALTER TABLE company_settings DROP COLUMN IF EXISTS absence_threshold_mode;
COMMIT;
