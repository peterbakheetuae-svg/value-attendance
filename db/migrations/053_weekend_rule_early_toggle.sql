-- خصم التأخير والانصراف بدري: two switches
--  early_deduction: the early leave is deducted (or only shown) — kept as it was: deducted except in the hourly mode
--  weekend_absence_rule: absent the day before AND the day after the weekly rest → the rest day(s) become absence
ALTER TABLE company_settings ADD COLUMN early_deduction boolean NOT NULL DEFAULT true;
ALTER TABLE company_settings ADD COLUMN weekend_absence_rule boolean NOT NULL DEFAULT false;
UPDATE company_settings SET early_deduction = (deduction_mode <> 'hourly');
