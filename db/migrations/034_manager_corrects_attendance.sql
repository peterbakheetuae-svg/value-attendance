-- المدير (general manager) may correct check-in / check-out times from the daily attendance report, like HR and the
-- owner. Every correction keeps the original times and who made it (attendance_corrections, append-only).
INSERT INTO role_permissions (role_key, perm_key) VALUES ('manager', 'attendance.correct') ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_key, perm_key)
SELECT r.key, 'attendance.correct' FROM roles r WHERE r.base_key = 'manager'
ON CONFLICT DO NOTHING;
