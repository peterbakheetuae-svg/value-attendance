-- SEC-06 (2026-11-26): attendance evidence — what the phone claimed next to what the server knows, for every
-- check-in / check-out / «I'm back», accepted or refused. Additive and forward-only: attendance itself and every
-- earlier record are unchanged (old records simply have no event rows). No selfie, no extra tracking: the location is
-- the one already sent with the punch.
--   device_time         the phone's clock as sent (offlineAt for a queued punch, deviceTime for an online one) — a claim
--   server_received_at  the API's own clock when the request arrived — a fact, never taken from the request
--   used_time           the time the attendance record was given (the existing trusted-time rules), null when refused
--   client_id           the app's per-punch id (UUID): a retried / replayed punch returns the first reply, adds nothing
--   flags               review flags for HR (offline, late_arrival, clock_drift, ordering, claim_overridden,
--                       mock_reported, low_accuracy, no_location, device_changed)
CREATE TABLE IF NOT EXISTS attendance_events (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id         uuid NOT NULL REFERENCES employees(id),
  step                text NOT NULL CHECK (step IN ('check_in', 'check_out', 'return')),
  client_id           uuid,
  state               text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'accepted', 'refused')),
  refusal             text,
  device_time         timestamptz,
  server_received_at  timestamptz NOT NULL,
  used_time           timestamptz,
  offline             boolean NOT NULL DEFAULT false,
  lat                 double precision,
  lng                 double precision,
  accuracy_m          double precision,
  mocked              boolean,
  session_id          uuid,
  device_id           text,
  flags               text[] NOT NULL DEFAULT '{}',
  reply_status        integer,
  reply               jsonb,
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS attendance_events_client ON attendance_events (employee_id, client_id) WHERE client_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS attendance_events_employee_time ON attendance_events (employee_id, server_received_at DESC);
CREATE INDEX IF NOT EXISTS attendance_events_flagged ON attendance_events (server_received_at DESC) WHERE flags <> '{}';
