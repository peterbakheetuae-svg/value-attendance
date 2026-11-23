-- Proves the grouped daily cash series returns exactly the same rows as the current per-day correlated query.
-- Runs ONLY on the isolated synthetic database va_perf, inside a transaction that is rolled back.
BEGIN;
-- edge data: every kind, reversed receipts, decimals, Cairo midnight boundaries, Egypt DST start/end days
INSERT INTO cash_receipts (kind, amount_egp, cashbox, actual_recipient_id, payer_name, purpose, occurred_at, recorded_by, status, reversed_by, reversed_at, reverse_reason)
SELECT k, round((random()*90000)::numeric + 0.37, 2), CASE WHEN g % 2 = 0 THEN 'hr' ELSE 'office' END,
       (SELECT id FROM employees WHERE code='HR1'), 'edge '||g, 'edge', ts,
       (SELECT id FROM employees WHERE code='HR1'),
       CASE WHEN g % 7 = 0 THEN 'reversed' ELSE 'posted' END,
       CASE WHEN g % 7 = 0 THEN (SELECT id FROM employees WHERE code='OWNER') END,
       CASE WHEN g % 7 = 0 THEN ts + interval '1 hour' END,
       CASE WHEN g % 7 = 0 THEN 'اختبار عكس' END
FROM (SELECT row_number() OVER () g, k, ts FROM
       unnest(ARRAY['reservation','down_payment','installment','settlement','other','commission','injection']) k
       CROSS JOIN unnest(ARRAY[
         (timestamp '2026-03-10 23:59:59' AT TIME ZONE 'Africa/Cairo'), (timestamp '2026-03-11 00:00:00' AT TIME ZONE 'Africa/Cairo'),
         (timestamp '2026-04-23 23:59:59.999' AT TIME ZONE 'Africa/Cairo'), (timestamp '2026-04-24 00:30:00' AT TIME ZONE 'Africa/Cairo'),
         (timestamp '2026-04-24 01:30:00' AT TIME ZONE 'Africa/Cairo'), (timestamp '2026-10-29 23:30:00' AT TIME ZONE 'Africa/Cairo'),
         (timestamp '2026-10-30 00:00:00' AT TIME ZONE 'Africa/Cairo'), (timestamp '2026-11-22 00:00:00' AT TIME ZONE 'Africa/Cairo'),
         (timestamp '2026-11-21 23:59:59' AT TIME ZONE 'Africa/Cairo'), now() - interval '3 days']) ts) x;

CREATE TEMP TABLE ranges AS
SELECT f::date AS f, (f + (len || ' days')::interval)::date AS t FROM (
  SELECT d AS f, len FROM generate_series('2025-11-01'::date, '2026-11-22'::date, interval '9 days') d CROSS JOIN unnest(ARRAY[0, 1, 6, 13, 30, 89]) len) z
UNION SELECT '2025-11-01', '2026-11-23' UNION SELECT '2026-04-23', '2026-04-25' UNION SELECT '2026-10-29', '2026-10-31';

CREATE TEMP TABLE diffs (f date, t date, side text, n int);
DO $$ DECLARE r record; n1 int; n2 int; BEGIN
  FOR r IN SELECT * FROM ranges LOOP
    CREATE TEMP TABLE old_q ON COMMIT DROP AS
      SELECT d::date AS day,
             COALESCE((SELECT sum(amount_egp) FILTER (WHERE kind = 'reservation') FROM cash_receipts WHERE status = 'posted' AND (occurred_at AT TIME ZONE 'Africa/Cairo')::date = d::date), 0) AS k_res,
             COALESCE((SELECT sum(amount_egp) FILTER (WHERE kind = 'down_payment') FROM cash_receipts WHERE status = 'posted' AND (occurred_at AT TIME ZONE 'Africa/Cairo')::date = d::date), 0) AS k_down,
             COALESCE((SELECT sum(amount_egp) FILTER (WHERE kind = 'installment') FROM cash_receipts WHERE status = 'posted' AND (occurred_at AT TIME ZONE 'Africa/Cairo')::date = d::date), 0) AS k_inst,
             COALESCE((SELECT sum(amount_egp) FROM cash_receipts WHERE status = 'posted' AND (occurred_at AT TIME ZONE 'Africa/Cairo')::date = d::date), 0) AS k_all
        FROM generate_series(r.f, r.t, interval '1 day') d ORDER BY 1;
    CREATE TEMP TABLE new_q ON COMMIT DROP AS
      WITH days AS (SELECT d::date AS day FROM generate_series(r.f, r.t, interval '1 day') d),
           x AS (SELECT (occurred_at AT TIME ZONE 'Africa/Cairo')::date AS day,
                        sum(amount_egp) FILTER (WHERE kind = 'reservation') AS k_res,
                        sum(amount_egp) FILTER (WHERE kind = 'down_payment') AS k_down,
                        sum(amount_egp) FILTER (WHERE kind = 'installment') AS k_inst,
                        sum(amount_egp) AS k_all
                   FROM cash_receipts
                  WHERE status = 'posted'
                    AND occurred_at >= (r.f::timestamp AT TIME ZONE 'Africa/Cairo')
                    AND occurred_at <  ((r.t + 1)::timestamp AT TIME ZONE 'Africa/Cairo')
                  GROUP BY 1)
      SELECT days.day, COALESCE(x.k_res, 0) AS k_res, COALESCE(x.k_down, 0) AS k_down, COALESCE(x.k_inst, 0) AS k_inst, COALESCE(x.k_all, 0) AS k_all
        FROM days LEFT JOIN x USING (day) ORDER BY 1;
    SELECT count(*) INTO n1 FROM (SELECT * FROM old_q EXCEPT ALL SELECT * FROM new_q) a;
    SELECT count(*) INTO n2 FROM (SELECT * FROM new_q EXCEPT ALL SELECT * FROM old_q) b;
    IF n1 + n2 > 0 OR (SELECT count(*) FROM old_q) <> (SELECT count(*) FROM new_q) THEN INSERT INTO diffs VALUES (r.f, r.t, 'mismatch', n1 + n2); END IF;
    DROP TABLE old_q; DROP TABLE new_q;
  END LOOP;
END $$;
SELECT (SELECT count(*) FROM ranges) AS ranges_compared, (SELECT count(*) FROM diffs) AS ranges_with_differences,
       (SELECT count(*) FROM cash_receipts WHERE purpose = 'edge') AS edge_receipts,
       (SELECT count(*) FROM cash_receipts WHERE purpose = 'edge' AND status = 'reversed') AS edge_reversed;
ROLLBACK;
