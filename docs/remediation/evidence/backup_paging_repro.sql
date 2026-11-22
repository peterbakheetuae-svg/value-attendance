-- Reproduces the backup export's ORDER BY ctid OFFSET paging under concurrent app writes (synthetic DB, rolled back).
BEGIN;
CREATE TEMP TABLE before_ids AS SELECT id FROM leads;                       -- what should be exported
CREATE TEMP TABLE got (id uuid, page int);
INSERT INTO got SELECT (to_jsonb(x)->>'id')::uuid, 1 FROM (SELECT * FROM leads x ORDER BY ctid OFFSET 0 LIMIT 2000) x;
-- the app keeps working while the backup pages through the table:
UPDATE leads SET last_action_at = now() WHERE id IN (SELECT id FROM got ORDER BY id LIMIT 25);                 -- 25 already-exported rows edited
DELETE FROM lead_logs WHERE lead_id IN (SELECT id FROM got ORDER BY id DESC LIMIT 10);
DELETE FROM leads WHERE id IN (SELECT id FROM got ORDER BY id DESC LIMIT 10);                                     -- 10 already-exported rows deleted
DO $$ DECLARE off int := 2000; n int; BEGIN
  LOOP
    INSERT INTO got SELECT (to_jsonb(x)->>'id')::uuid, off / 2000 + 1 FROM (SELECT * FROM leads x ORDER BY ctid OFFSET off LIMIT 2000) x;
    GET DIAGNOSTICS n = ROW_COUNT; EXIT WHEN n = 0; off := off + n;
  END LOOP; END $$;
SELECT (SELECT count(*) FROM before_ids) AS rows_at_start,
       (SELECT count(*) FROM got) AS rows_exported,
       (SELECT count(*) FROM (SELECT id FROM got GROUP BY id HAVING count(*) > 1) d) AS exported_twice,
       (SELECT count(*) FROM leads l WHERE NOT EXISTS (SELECT 1 FROM got g WHERE g.id = l.id)) AS live_rows_missing;
ROLLBACK;
