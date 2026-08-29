-- =====================================================================
-- ROcodeFest — application schema (infrastructure, not domain)
-- =====================================================================
-- Two things live here and neither is part of the festival:
--
--   app.schema_migrations   which migrations a database has had applied
--   app.session             where signed-in sessions are kept
--
-- They are deliberately NOT in `oltp`. That schema describes the
-- competition -- accounts, teams, matches, appeals -- and 99_tests.sql
-- holds an exact manifest of every column in it, so a session table
-- landing there would be reported as schema drift, correctly. It is not
-- drift; it is a different kind of thing, and it gets a different
-- schema.
--
-- LOAD ORDER
-- ----------
-- This file is loaded FIRST, before 01_oltp_schema.sql. It has no
-- dependency on the domain and the domain has none on it, so the order
-- is a convention rather than a requirement -- but the migration runner
-- needs app.schema_migrations to exist before it can record anything.
--
-- WHY THIS FILE ALSO STAMPS
-- -------------------------
-- A database can arrive at the current schema two ways:
--
--   from scratch    load 00_ 01_ 02_ 03_ -- what CI and development do
--   by migration    apply db/migrations/* -- what a database with data
--                   in it does, because rebuilding would destroy it
--
-- Both must end up the same. So every migration whose effect is already
-- written into these files is stamped as applied at the bottom of this
-- file: a freshly built database knows it does not need them, and the
-- runner will not try to create a table that is already there.
--
-- The checksum is left NULL by those stamps, and that is meaningful --
-- it records "this arrived with the from-scratch build" rather than
-- "the runner applied this exact file". db/migrate.ps1 prints the
-- difference.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS app;

-- ---------------------------------------------------------------------
-- Which migrations this database has had
-- ---------------------------------------------------------------------
-- version is the FILENAME without .sql, so the ordering the runner uses
-- and the ordering a person reading `ls db/migrations` sees are the same
-- ordering. A numeric column would be a second thing to keep in step.
CREATE TABLE IF NOT EXISTS app.schema_migrations (
  version     TEXT PRIMARY KEY,
  applied_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- SHA-256 of the file as applied. NULL means the change arrived with
  -- the from-scratch schema files instead of through the runner, which
  -- is a normal state for a fresh database and not a fault.
  checksum    TEXT,
  -- How long it took. Useful the first time a migration on a real
  -- table turns out to lock something for a minute.
  duration_ms INTEGER
);

COMMENT ON TABLE app.schema_migrations IS
  'One row per applied migration. Written by db/migrate.ps1, or stamped by db/00_app_schema.sql for a database built from scratch.';

-- ---------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------
-- express-session's default store keeps sessions in the memory of one
-- process. That has three consequences, and all three are ordinary
-- rather than exotic:
--
--   * every restart signs everybody out, so every deploy does
--   * two instances cannot share a session, so a request landing on the
--     wrong one is a request from a stranger
--   * memory grows with the number of sessions and nothing prunes it
--
-- The columns are the shape connect-pg-simple expects; the quoting is
-- its convention too. Deviating would mean configuring it to match,
-- which is more moving parts than accepting the default names.
CREATE TABLE IF NOT EXISTS app.session (
  sid    VARCHAR NOT NULL COLLATE "default",
  sess   JSON NOT NULL,
  expire TIMESTAMP(6) NOT NULL,
  CONSTRAINT session_pkey PRIMARY KEY (sid)
);

-- The store deletes expired rows on a schedule, and that sweep is a
-- range scan on expire. Without this index it is a sequential scan over
-- every live session, which is fine at ten and not at ten thousand.
CREATE INDEX IF NOT EXISTS ix_session_expire ON app.session (expire);

COMMENT ON TABLE app.session IS
  'Signed-in sessions, kept here rather than in process memory so a restart does not sign everyone out.';

-- ---------------------------------------------------------------------
-- Stamps
-- ---------------------------------------------------------------------
-- Every migration whose effect is already present above. Adding a
-- migration means adding its DDL to the appropriate schema file AND a
-- line here -- and qa_migrations.sql fails the build if the two lists
-- disagree, so forgetting is loud rather than silent.
INSERT INTO app.schema_migrations (version, checksum) VALUES
  ('0001_session_store', NULL)
ON CONFLICT (version) DO NOTHING;
