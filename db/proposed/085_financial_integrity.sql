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
--  • company_owner_shares: نسبة الملكية with the month it applies from. Today's shares are copied in as in force since
--    2000-01 (so every past month keeps exactly today's figure until a share changes); a change applies from its month on.

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

-- today's shares, in force for every month so far (the figures shown today do not move)
INSERT INTO company_owner_shares (employee_id, pct, effective_from, created_by, created_at)
SELECT employee_id, pct, DATE '2000-01-01', updated_by, updated_at FROM company_owners
ON CONFLICT (employee_id, effective_from) DO NOTHING;

-- validation (fails the transaction if the copy is incomplete)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM company_owners o WHERE NOT EXISTS (SELECT 1 FROM company_owner_shares s WHERE s.employee_id = o.employee_id)) THEN
    RAISE EXCEPTION '085: an owner share was not copied into the history';
  END IF;
END $$;
