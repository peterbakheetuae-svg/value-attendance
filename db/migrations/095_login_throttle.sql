-- SEC-05 (2026-11-26): sign-in throttling state shared by every API instance (no in-memory counters).
-- One row per bucket: an account seen from one network / one known device of that account, an account as a whole
-- (distributed attempts), or an unknown sign-in name from one network (so an unknown name throttles exactly like a real
-- one and the reply never tells whether an account exists). Rows hold no secret: the key is account id + IP, or the
-- SHA-256 of an unknown name. Forward-only and additive: nothing existing changes; employees.failed_logins /
-- locked_until stay (no longer written by sign-in).
CREATE TABLE IF NOT EXISTS login_throttle (
  key            text PRIMARY KEY,
  fails          integer NOT NULL DEFAULT 0,
  last_fail_at   timestamptz NOT NULL DEFAULT now(),
  blocked_until  timestamptz
);
CREATE INDEX IF NOT EXISTS login_throttle_last_fail ON login_throttle (last_fail_at);
