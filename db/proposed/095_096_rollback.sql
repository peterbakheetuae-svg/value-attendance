-- Rollback of 095_login_throttle and 096_attendance_events (NOT applied automatically; owner-run only, after an approved
-- revert of the code that uses them). Both migrations only ADD tables, so the code before them never reads these tables
-- and a code revert alone is safe: this script is needed only to remove the tables afterwards.
-- Limitation: dropping attendance_events deletes the punch evidence recorded since 096 (attendance itself is untouched);
-- take a backup first. login_throttle holds only short-lived throttling state.
BEGIN;
DROP TABLE IF EXISTS attendance_events;
DROP TABLE IF EXISTS login_throttle;
DELETE FROM schema_migrations WHERE name IN ('095_login_throttle.sql', '096_attendance_events.sql');
COMMIT;
