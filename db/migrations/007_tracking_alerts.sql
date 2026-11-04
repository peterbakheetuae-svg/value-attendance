-- Value HR: reminders/alerts and in-shift location follow-up (Android app keeps sending positions while checked in).
ALTER TABLE company_settings
  ADD COLUMN checkin_reminder_minutes  int NOT NULL DEFAULT 30 CHECK (checkin_reminder_minutes BETWEEN 0 AND 240),  -- 0 = off
  ADD COLUMN tracking_enabled          boolean NOT NULL DEFAULT false,
  ADD COLUMN tracking_interval_minutes int NOT NULL DEFAULT 5  CHECK (tracking_interval_minutes BETWEEN 1 AND 30),
  ADD COLUMN tracking_stale_minutes    int NOT NULL DEFAULT 20 CHECK (tracking_stale_minutes BETWEEN 0 AND 240),    -- 0 = off
  ADD COLUMN away_margin_m             int NOT NULL DEFAULT 100 CHECK (away_margin_m BETWEEN 0 AND 5000),
  ADD COLUMN last_sweep_at             timestamptz;

-- latest known state per employee for today's shift
CREATE TABLE tracking_state (
  employee_id    uuid PRIMARY KEY REFERENCES employees(id),
  work_date      date NOT NULL,
  last_ping_at   timestamptz NOT NULL,
  lat            double precision NOT NULL,
  lng            double precision NOT NULL,
  accuracy_m     double precision,
  inside         boolean,               -- null when no office is configured
  distance_m     int,                   -- metres outside the nearest office circle (0 = inside)
  away_since     timestamptz,
  away_minutes   int NOT NULL DEFAULT 0 -- total minutes outside today
);

-- short history (kept 14 days) for the "where was he" view
CREATE TABLE tracking_pings (
  id           bigserial PRIMARY KEY,
  employee_id  uuid NOT NULL REFERENCES employees(id),
  at           timestamptz NOT NULL,
  lat          double precision NOT NULL,
  lng          double precision NOT NULL,
  accuracy_m   double precision,
  inside       boolean
);
CREATE INDEX tracking_pings_emp_at ON tracking_pings (employee_id, at);
