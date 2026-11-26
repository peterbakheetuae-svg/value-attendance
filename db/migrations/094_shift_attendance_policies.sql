-- Release: shift attendance policies (PR #22, merged 2026-11-26). Applied by the production deploy of main (owner-authorised
-- 2026-11-26). Body = db/proposed/094_shift_attendance_policies.sql, byte for byte. Rollback: db/proposed/094_rollback.sql.
-- 094 — shift-based attendance policies (requirements 2026-11-26). PROPOSED: not in db/migrations, never applied by a deploy.
--
--  1. company_settings — four new settings, all OFF / empty by default (no invented values; nothing changes until the
--     company sets them in the app):
--       absence_threshold_mode   NULL (off: today's behaviour) | 'fixed_hours' | 'half_shift'
--       absence_threshold_hours  NULL | hours (0.25–24) — used by 'fixed_hours' only
--       unauthorized_exit_tiers  '[]' — «شرائح خروج بدون إذن»: [{fromMinutes, toMinutes|null, amount, enabled}]
--       unauthorized_exit_deduction false — the deduction applies only when switched on (with at least one enabled tier)
--  2. unauthorized_exit_incidents — one row per verified unauthorized exit: open → closed (minutes, tier and amount
--     frozen once) → optionally reversed (auditable, by a payroll approver, never one's own). One open incident per
--     employee and one per exit instant (unique indexes): replayed pings, a second phone, concurrent requests never add
--     a second one. Never deleted; identity and the frozen figures never change (trigger).
--  3. notification_preferences — per person and category; no row = on.
--
-- Additive only: new nullable / defaulted columns, two new tables, one trigger. No existing row, attendance or payroll
-- record is changed. Safe to re-run. PostgreSQL 16 and 18. Rollback: 094_rollback.sql.

ALTER TABLE company_settings ADD COLUMN IF NOT EXISTS absence_threshold_mode text;
ALTER TABLE company_settings ADD COLUMN IF NOT EXISTS absence_threshold_hours numeric(4,2);
ALTER TABLE company_settings ADD COLUMN IF NOT EXISTS unauthorized_exit_tiers jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE company_settings ADD COLUMN IF NOT EXISTS unauthorized_exit_deduction boolean NOT NULL DEFAULT false;
DO $$ BEGIN
  ALTER TABLE company_settings ADD CONSTRAINT company_settings_absence_threshold CHECK (
    (absence_threshold_mode IS NULL OR absence_threshold_mode IN ('fixed_hours', 'half_shift'))
    AND (absence_threshold_hours IS NULL OR (absence_threshold_hours >= 0.25 AND absence_threshold_hours <= 24))
    AND (absence_threshold_mode IS DISTINCT FROM 'fixed_hours' OR absence_threshold_hours IS NOT NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE company_settings ADD CONSTRAINT company_settings_exit_tiers CHECK (jsonb_typeof(unauthorized_exit_tiers) = 'array');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS unauthorized_exit_incidents (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id       uuid NOT NULL REFERENCES employees(id),
  work_date         date NOT NULL,
  attendance_id     uuid NOT NULL REFERENCES attendance(id),
  period            date NOT NULL CHECK (extract(day FROM period) = 1),
  exit_at           timestamptz NOT NULL,                    -- the verified exit (first outside ping, no approved permission)
  device_key        text NOT NULL DEFAULT '',
  outing_id         uuid REFERENCES outing_requests(id),     -- the request pending (or expired) at the exit, if any
  permission_state  text NOT NULL CHECK (permission_state IN ('none', 'pending', 'expired')),
  shift_end_at      timestamptz NOT NULL,                    -- the scheduled shift end that day
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'reversed')),
  ended_at          timestamptz,
  end_reason        text CHECK (end_reason IN ('returned', 'checked_out', 'shift_end')),
  minutes           int CHECK (minutes >= 0),
  tier              jsonb,                                   -- the tier that applied, as configured at closing
  amount_egp        numeric(12,2) CHECK (amount_egp > 0),    -- NULL = recorded, not deducted
  deduction_enabled boolean,
  reversed_by       uuid REFERENCES employees(id),
  reversed_at       timestamptz,
  reverse_reason    text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, exit_at),
  CHECK (reversed_by IS NULL OR reversed_by <> employee_id),
  CHECK ((status = 'open') = (ended_at IS NULL)),
  CHECK ((status = 'reversed') = (reversed_at IS NOT NULL)),
  CHECK (status <> 'reversed' OR length(trim(reverse_reason)) >= 3)
);
CREATE UNIQUE INDEX IF NOT EXISTS unauthorized_exit_one_open ON unauthorized_exit_incidents (employee_id) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS unauthorized_exit_period ON unauthorized_exit_incidents (period, employee_id);

CREATE OR REPLACE FUNCTION unauthorized_exit_incidents_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'an unauthorized-exit incident is never deleted (it is reversed)' USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'open' OR NEW.ended_at IS NOT NULL OR NEW.amount_egp IS NOT NULL OR NEW.reversed_at IS NOT NULL THEN
      RAISE EXCEPTION 'an incident starts open, with no amount' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.id, NEW.employee_id, NEW.work_date, NEW.attendance_id, NEW.period, NEW.exit_at, NEW.device_key, NEW.outing_id,
      NEW.permission_state, NEW.shift_end_at, NEW.created_at)
     IS DISTINCT FROM (OLD.id, OLD.employee_id, OLD.work_date, OLD.attendance_id, OLD.period, OLD.exit_at, OLD.device_key,
      OLD.outing_id, OLD.permission_state, OLD.shift_end_at, OLD.created_at) THEN
    RAISE EXCEPTION 'an incident''s exit record never changes' USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.status = 'open' AND NEW.status = 'closed' THEN
    IF NEW.reversed_at IS NOT NULL OR NEW.reversed_by IS NOT NULL THEN
      RAISE EXCEPTION 'closing an incident does not reverse it' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'closed' AND NEW.status = 'reversed' THEN
    IF (NEW.ended_at, NEW.end_reason, NEW.minutes, NEW.tier, NEW.amount_egp, NEW.deduction_enabled)
       IS DISTINCT FROM (OLD.ended_at, OLD.end_reason, OLD.minutes, OLD.tier, OLD.amount_egp, OLD.deduction_enabled)
       OR NEW.reversed_by IS NULL THEN
      RAISE EXCEPTION 'a reversal keeps the frozen figures and records who reversed it' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'an incident cannot go from % to %', OLD.status, NEW.status USING ERRCODE = 'check_violation';
END $$;
DROP TRIGGER IF EXISTS unauthorized_exit_incidents_guard ON unauthorized_exit_incidents;
CREATE TRIGGER unauthorized_exit_incidents_guard BEFORE INSERT OR UPDATE OR DELETE ON unauthorized_exit_incidents
  FOR EACH ROW EXECUTE FUNCTION unauthorized_exit_incidents_guard();

CREATE TABLE IF NOT EXISTS notification_preferences (
  employee_id uuid NOT NULL REFERENCES employees(id),
  category    text NOT NULL CHECK (category IN ('unauthorized_exit', 'outings', 'requests', 'lateness_absence', 'attendance', 'finance', 'announcements')),
  enabled     boolean NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employee_id, category)
);
