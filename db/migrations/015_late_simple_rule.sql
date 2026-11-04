-- Simple lateness rule asked by the owner: late more than N minutes → a fixed amount;
-- late an hour or more → an amount per hour (proportional). Off until chosen as the deduction mode.
ALTER TABLE company_settings DROP CONSTRAINT company_settings_deduction_mode_check;
ALTER TABLE company_settings ADD CONSTRAINT company_settings_deduction_mode_check
  CHECK (deduction_mode IN ('per_minute', 'tiers', 'hourly'));
ALTER TABLE company_settings
  ADD COLUMN late_fixed_after_minutes int NOT NULL DEFAULT 30 CHECK (late_fixed_after_minutes BETWEEN 0 AND 59),
  ADD COLUMN late_fixed_amount  numeric(10,2) NOT NULL DEFAULT 0 CHECK (late_fixed_amount >= 0 AND late_fixed_amount <= 100000),
  ADD COLUMN late_hour_amount   numeric(10,2) NOT NULL DEFAULT 0 CHECK (late_hour_amount >= 0 AND late_hour_amount <= 100000);
