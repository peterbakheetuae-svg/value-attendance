-- Applied by the release of 2026-11-23 (owner-approved): copied unchanged from db/proposed/085_financial_integrity.sql below
-- this header, which only states the baseline month 085 asks for.
-- The owner (2026-11-23): today's ownership shares have been in force «from the beginning» and never changed — that is the
-- first month any money was recorded (the first receipt, expense or payout); with no money yet, this month.
SELECT set_config('valunivo.owner_share_baseline', to_char(COALESCE(LEAST(
    (SELECT min(date_trunc('month', occurred_at AT TIME ZONE 'Africa/Cairo'))::date FROM cash_receipts),
    (SELECT min(date_trunc('month', occurred_at AT TIME ZONE 'Africa/Cairo'))::date FROM cash_expenses),
    (SELECT min(period) FROM payouts)),
  date_trunc('month', now() AT TIME ZONE 'Africa/Cairo')::date), 'YYYY-MM-DD'), true);

-- 085 (PROPOSED — not in db/migrations, so no build runs it; it needs the owner's approval first).
-- Financial integrity (audit findings F1 / F6 / F9). Additive only: no table, column or row is dropped or changed, except
-- the one-time copy of today's ownership shares into the new history table. Rollback: 085_rollback.sql.
-- Applied by the migration runner (one transaction); by hand: BEGIN; … COMMIT;
--
--  • payouts_one_per_advance: one live payout per approved advance / work-expense request (the app already checks it under a
--    row lock; this makes a retry or a second path impossible at the database too).
--  • payouts_guard: a payout's money and identity never change (who, kind, amount, month, note, what it settles, who paid,
--    created_at); its status only moves forward and stamps received_at / cancelled_at / the dispute exactly once; a received
--    or cancelled payout is final in every column; a received payout is never deleted.
--  • company_owner_shares: نسبة الملكية with the month it applies from. The month from which TODAY's shares are in force is
--    a business fact only the owner can state — no record in the database proves it (the first receipt or payout says when
--    money was first recorded, not when an ownership share began). 085 therefore never guesses it: the person applying
--    085 states it, in the same session, as the first day of a month (not in the future):
--        psql -1 -v ON_ERROR_STOP=1 -c "SET valunivo.owner_share_baseline = '2026-12-01'" -f 085_financial_integrity.sql
--    Without it 085 refuses to install (nothing is changed) whenever there are shares to copy. The stated month is kept
--    in the audit log. Months before it carry no share (nothing earlier is claimed); a later change applies from its own
--    month on. With no owners yet — or on a re-run, the history already there — nothing is copied and nothing is asked.

-- precondition: refuse (and name them) if two live payouts already settle the same request — nothing is changed then
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(advance_id::text, ', ') INTO bad FROM (
    SELECT advance_id FROM payouts WHERE advance_id IS NOT NULL AND status <> 'cancelled' GROUP BY advance_id HAVING count(*) > 1) d;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION '085: these requests have more than one live payout — reconcile them first (nothing was changed): %', bad;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS payouts_one_per_advance ON payouts (advance_id)
  WHERE advance_id IS NOT NULL AND status <> 'cancelled';

-- a payout is a money record: who, what kind, how much, which month, what it settles, its note (method), who paid it and when
-- it was made never change. Its status only moves forward, each step stamping its own time exactly once:
--   pending  → received (received_at set) | cancelled (cancelled_at set) | disputed (dispute_reason + disputed_at set)
--   disputed → received | cancelled
--   received / cancelled → final: nothing of the row changes again, and a received payout is never deleted.
-- (The app's three updates — verify, cancel, dispute — are exactly these steps. The owner-only data reset uses TRUNCATE and
-- the backup restore runs with triggers off on a fresh database; neither is affected.)
CREATE OR REPLACE FUNCTION payouts_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'received' THEN RAISE EXCEPTION 'a received payment is never deleted'; END IF;
    RETURN OLD;
  END IF;
  IF (NEW.id, NEW.employee_id, NEW.kind, NEW.amount_egp, NEW.period, NEW.note, NEW.advance_id, NEW.commission_entitlement_id,
      NEW.batch_line_id, NEW.created_by, NEW.created_at)
     IS DISTINCT FROM
     (OLD.id, OLD.employee_id, OLD.kind, OLD.amount_egp, OLD.period, OLD.note, OLD.advance_id, OLD.commission_entitlement_id,
      OLD.batch_line_id, OLD.created_by, OLD.created_at) THEN
    RAISE EXCEPTION 'a payment cannot be changed (cancel it and make a new one)';
  END IF;
  IF OLD.status IN ('received', 'cancelled') THEN
    IF to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN RAISE EXCEPTION 'a received or cancelled payment is final'; END IF;
    RETURN NEW;
  END IF;
  -- OLD is pending or disputed
  IF NEW.status = OLD.status THEN
    IF (NEW.received_at, NEW.cancelled_at, NEW.dispute_reason, NEW.disputed_at) IS DISTINCT FROM
       (OLD.received_at, OLD.cancelled_at, OLD.dispute_reason, OLD.disputed_at) THEN
      RAISE EXCEPTION 'a payment''s confirmation history only changes with its status';
    END IF;
  ELSIF NEW.status = 'received' THEN
    IF NEW.received_at IS NULL OR OLD.received_at IS NOT NULL OR NEW.cancelled_at IS DISTINCT FROM OLD.cancelled_at
       OR (NEW.dispute_reason, NEW.disputed_at) IS DISTINCT FROM (OLD.dispute_reason, OLD.disputed_at) THEN
      RAISE EXCEPTION 'receiving a payment stamps received_at once and nothing else';
    END IF;
  ELSIF NEW.status = 'cancelled' THEN
    IF NEW.cancelled_at IS NULL OR OLD.cancelled_at IS NOT NULL OR NEW.received_at IS DISTINCT FROM OLD.received_at
       OR (NEW.dispute_reason, NEW.disputed_at) IS DISTINCT FROM (OLD.dispute_reason, OLD.disputed_at) THEN
      RAISE EXCEPTION 'cancelling a payment stamps cancelled_at once and nothing else';
    END IF;
  ELSIF NEW.status = 'disputed' AND OLD.status = 'pending' THEN
    IF NEW.disputed_at IS NULL OR NEW.dispute_reason IS NULL
       OR (NEW.received_at, NEW.cancelled_at) IS DISTINCT FROM (OLD.received_at, OLD.cancelled_at) THEN
      RAISE EXCEPTION 'disputing a payment stamps its reason and time and nothing else';
    END IF;
  ELSE
    RAISE EXCEPTION 'a payment cannot go from % to %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS payouts_guard ON payouts;
CREATE TRIGGER payouts_guard BEFORE UPDATE OR DELETE ON payouts FOR EACH ROW EXECUTE FUNCTION payouts_guard();

CREATE TABLE IF NOT EXISTS company_owner_shares (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id     uuid NOT NULL REFERENCES employees(id),
  pct             numeric(7,4) NOT NULL CHECK (pct >= 0 AND pct <= 100),
  effective_from  date NOT NULL CHECK (extract(day FROM effective_from) = 1),
  created_by      uuid REFERENCES employees(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, effective_from)
);
CREATE INDEX IF NOT EXISTS company_owner_shares_emp ON company_owner_shares (employee_id, effective_from);

-- today's shares, in force from the month the owner states (see the header) — never a guessed or invented date
DO $$
DECLARE
  v text := nullif(trim(current_setting('valunivo.owner_share_baseline', true)), '');
  d date;
  first_rec date;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM company_owners o
                  WHERE NOT EXISTS (SELECT 1 FROM company_owner_shares s WHERE s.employee_id = o.employee_id)) THEN
    RETURN; -- no owner, or every owner already has a history (a re-run): nothing to copy, nothing to ask
  END IF;
  IF v IS NULL THEN
    RAISE EXCEPTION '085: state the month today''s ownership shares are in force from — SET valunivo.owner_share_baseline = ''YYYY-MM-01'' in the same session (nothing was changed)';
  END IF;
  BEGIN
    d := v::date;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION '085: valunivo.owner_share_baseline must be a date (YYYY-MM-01), got %', v;
  END;
  IF extract(day FROM d) <> 1 THEN
    RAISE EXCEPTION '085: valunivo.owner_share_baseline must be the first day of a month, got %', d;
  END IF;
  IF d > date_trunc('month', now() AT TIME ZONE 'Africa/Cairo')::date THEN
    RAISE EXCEPTION '085: valunivo.owner_share_baseline % is in the future', d;
  END IF;
  INSERT INTO company_owner_shares (employee_id, pct, effective_from, created_by, created_at)
  SELECT o.employee_id, o.pct, d, o.updated_by, o.updated_at FROM company_owners o
   WHERE NOT EXISTS (SELECT 1 FROM company_owner_shares s WHERE s.employee_id = o.employee_id)
  ON CONFLICT (employee_id, effective_from) DO NOTHING;
  INSERT INTO audit_log (actor_id, action, entity, entity_id, before, after)
  VALUES (NULL, 'owners.share_baseline', 'company_owner_shares', NULL, NULL,
          jsonb_build_object('effective_from', d, 'source', 'migration_085',
                             'shares', (SELECT jsonb_object_agg(employee_id, pct) FROM company_owners)));
  -- for the person applying it: money recorded before the stated month gets no owner share (stated, not changed)
  first_rec := LEAST(
    (SELECT min(date_trunc('month', occurred_at AT TIME ZONE 'Africa/Cairo'))::date FROM cash_receipts),
    (SELECT min(date_trunc('month', occurred_at AT TIME ZONE 'Africa/Cairo'))::date FROM cash_expenses),
    (SELECT min(period) FROM payouts));
  IF first_rec IS NOT NULL AND first_rec < d THEN
    RAISE WARNING '085: money is recorded from % — the months before % carry no owner share', first_rec, d;
  END IF;
END $$;

-- validation (fails the transaction if the copy is incomplete)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM company_owners o WHERE NOT EXISTS (SELECT 1 FROM company_owner_shares s WHERE s.employee_id = o.employee_id)) THEN
    RAISE EXCEPTION '085: an owner share was not copied into the history';
  END IF;
END $$;
