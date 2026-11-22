-- VALUNIVO — READ-ONLY role & privilege audit (no changes). Run in the Neon SQL editor as the owner.
-- Every statement is a SELECT; nothing is created, granted, revoked or modified. Output contains no passwords.

-- 1. Login roles and their powers (valunivo_app must be: no superuser / createdb / createrole / bypassrls / replication)
SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolbypassrls, rolreplication, rolcanlogin, rolconnlimit
FROM pg_roles WHERE rolcanlogin ORDER BY rolname;

-- 2. Role memberships (valunivo_app must NOT be a member of neondb_owner or any admin role)
SELECT r.rolname AS role, m.rolname AS member_of
FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.member JOIN pg_roles m ON m.oid = am.roleid
WHERE r.rolname = 'valunivo_app';

-- 3. Schema privileges (CREATE on public = the documented TEMPORARY exception)
SELECT has_schema_privilege('valunivo_app', 'public', 'USAGE')  AS usage,
       has_schema_privilege('valunivo_app', 'public', 'CREATE') AS create_temporary_exception;

-- 4. Objects owned by valunivo_app (expected: none, or only schema_migrations if a build ever ran as it)
SELECT c.relname, c.relkind FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner
WHERE r.rolname = 'valunivo_app' AND c.relnamespace = 'public'::regnamespace;

-- 5. Table privileges per table (expect SELECT/INSERT/UPDATE; DELETE only on the approved list; no UPDATE on audit_log;
--    no TRUNCATE / REFERENCES / TRIGGER anywhere)
SELECT table_name, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
FROM information_schema.role_table_grants
WHERE grantee = 'valunivo_app' AND table_schema = 'public'
GROUP BY table_name ORDER BY table_name;

SELECT table_name, privilege_type FROM information_schema.role_table_grants
WHERE grantee = 'valunivo_app' AND privilege_type IN ('TRUNCATE', 'REFERENCES', 'TRIGGER')
   OR (grantee = 'valunivo_app' AND table_name = 'audit_log' AND privilege_type IN ('UPDATE', 'DELETE'));

-- 6. Who is connected right now, by role (after cutover to valunivo_app, neondb_owner should only appear for admin work)
SELECT usename, application_name, count(*) AS connections, max(backend_start) AS newest
FROM pg_stat_activity WHERE datname = current_database() GROUP BY 1, 2 ORDER BY 1;
