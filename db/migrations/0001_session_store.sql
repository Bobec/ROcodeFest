-- =====================================================================
-- 0001 — sessions move out of process memory
-- =====================================================================
-- express-session was using its default store, which keeps sessions in
-- the memory of one process. Every restart signed everybody out, two
-- instances could not share a session, and nothing pruned the memory.
--
-- This is also the migration that exists to be run. The machinery
-- around it -- app.schema_migrations, db/migrate.ps1, the CI job that
-- proves the migrations and the schema files agree -- was built for a
-- database that has data in it and therefore cannot be rebuilt. Testing
-- that machinery with an invented change would have proved only that
-- the invention worked.
--
-- APPLIED BY:  pwsh db/migrate.ps1
-- ALSO IN:     db/00_app_schema.sql, so a from-scratch build has it too
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS app;

CREATE TABLE IF NOT EXISTS app.session (
  sid    VARCHAR NOT NULL COLLATE "default",
  sess   JSON NOT NULL,
  expire TIMESTAMP(6) NOT NULL,
  CONSTRAINT session_pkey PRIMARY KEY (sid)
);

-- The store's sweep of expired rows is a range scan on expire.
CREATE INDEX IF NOT EXISTS ix_session_expire ON app.session (expire);

COMMENT ON TABLE app.session IS
  'Signed-in sessions, kept here rather than in process memory so a restart does not sign everyone out.';
