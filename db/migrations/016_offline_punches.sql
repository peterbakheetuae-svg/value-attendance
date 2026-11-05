-- Punches recorded on the phone while it had no internet and sent later (device time, bounded to 48 h).
-- Flagged so HR can see which records came in offline.
ALTER TABLE attendance
  ADD COLUMN check_in_offline  boolean NOT NULL DEFAULT false,
  ADD COLUMN check_out_offline boolean NOT NULL DEFAULT false;
ALTER TABLE tracking_pings ADD COLUMN offline boolean NOT NULL DEFAULT false;
