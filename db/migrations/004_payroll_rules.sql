-- Automatic payroll rules (Value HR feature set). Off until the owner/HR turns them on.
ALTER TABLE company_settings
  ADD COLUMN payroll_auto_deductions boolean NOT NULL DEFAULT false,
  ADD COLUMN day_divisor   int  NOT NULL DEFAULT 30 CHECK (day_divisor IN (26, 30)),
  -- 'per_minute': every minute after the grace is deducted at the minute wage
  -- 'tiers'     : fixed amount of the highest tier reached, once per day (late and early use the same method)
  ADD COLUMN deduction_mode text NOT NULL DEFAULT 'per_minute' CHECK (deduction_mode IN ('per_minute', 'tiers')),
  ADD COLUMN late_tiers  jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(late_tiers) = 'array' AND jsonb_array_length(late_tiers) <= 6),
  ADD COLUMN early_tiers jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(early_tiers) = 'array' AND jsonb_array_length(early_tiers) <= 6),
  -- days of wage deducted per unapproved absence day
  ADD COLUMN absence_penalty_days numeric(4,2) NOT NULL DEFAULT 1 CHECK (absence_penalty_days BETWEEN 0 AND 5);
