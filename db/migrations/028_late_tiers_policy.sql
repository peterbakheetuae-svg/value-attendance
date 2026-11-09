-- Approved late arrival / early leave policy: fixed-amount tiers, once per day, the highest tier passed.
-- Up to 15 minutes nothing; more than 15 → 25 EGP; more than 30 → 50; more than 60 → 100. Early leave the same.
-- Editable afterwards from Settings → خصم التأخير والانصراف بدري.
UPDATE company_settings SET
  deduction_mode = 'tiers',
  payroll_auto_deductions = true,
  late_tiers  = '[{"afterMinutes":15,"amount":25},{"afterMinutes":30,"amount":50},{"afterMinutes":60,"amount":100}]'::jsonb,
  early_tiers = '[{"afterMinutes":15,"amount":25},{"afterMinutes":30,"amount":50},{"afterMinutes":60,"amount":100}]'::jsonb;
