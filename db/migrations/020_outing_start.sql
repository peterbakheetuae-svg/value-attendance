-- Hourly permission has its own start time (it may start later today, or have started at shift start);
-- a visit starts when it is requested. NULL = starts when requested (all older rows).
ALTER TABLE outing_requests ADD COLUMN starts_at timestamptz;
ALTER TABLE outing_requests ADD CONSTRAINT outing_start_before_return CHECK (starts_at IS NULL OR starts_at < expected_return_at);
