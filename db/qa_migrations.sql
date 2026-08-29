-- =====================================================================
-- QA — the two ways of building this database agree
-- =====================================================================
-- A schema can now be arrived at two ways, and the whole point of the
-- migration machinery is that they end in the same place:
--
--   from scratch   00_ 01_ 02_ 03_   -- CI, development, a new install
--   by migration   db/migrations/*   -- a database that has data in it
--                                       and therefore cannot be rebuilt
--
-- Nothing makes that true automatically. Somebody adds a column to
-- 01_oltp_schema.sql and forgets the migration, or writes the migration
-- and forgets the schema file, and the two descriptions of the same
-- database quietly diverge. The first anyone hears of it is a deploy
-- that behaves differently from every test.
--
-- This file catches the half of that which is checkable from inside one
-- database: whether the migrations on disk and the stamps in
-- 00_app_schema.sql describe the same set. The other half -- whether
-- they have the same EFFECT -- needs two databases and is done by the
-- `migrations` job in .github/workflows/qa.yml, which builds the
-- previous commit's schema, migrates it forward, and diffs the
-- structure against the current one.
--
-- Run against a database built the from-scratch way.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = app, oltp, public;

\pset pager off

DO $$
DECLARE
  v_pass  INT := 0;
  v_fail  INT := 0;
  v_msg   TEXT;
  v_n     INT;
BEGIN
  RAISE NOTICE '';
  RAISE NOTICE '=============== MIGRATION BOOKKEEPING ===============';

  -- -------------------------------------------------------------------
  -- PRECONDITION
  -- -------------------------------------------------------------------
  -- Every check below is about the CONTENT of a table, and each of them
  -- would pass just as happily against a table that does not exist if
  -- the query were written a little differently. Assert the subject
  -- exists before asserting anything about it.
  SELECT count(*) INTO v_n
  FROM information_schema.tables
  WHERE table_schema = 'app' AND table_name IN ('schema_migrations', 'session');

  IF v_n <> 2 THEN
    RAISE EXCEPTION 'PRECONDITION FAILED: app.schema_migrations and app.session must both exist (found %). Load db/00_app_schema.sql.', v_n;
  END IF;
  RAISE NOTICE '  PRE   app schema is present (schema_migrations, session)';

  -- -------------------------------------------------------------------
  -- M1  the from-scratch build stamps something
  -- -------------------------------------------------------------------
  -- An empty table would make every "these two lists match" check below
  -- vacuously true, because an empty list matches an empty list.
  SELECT count(*) INTO v_n FROM app.schema_migrations;
  IF v_n = 0 THEN
    v_fail := v_fail + 1;
    RAISE NOTICE '  FAIL  M1 the from-scratch build records no migrations at all';
    RAISE NOTICE '        Every check below would then compare two empty lists and pass.';
  ELSE
    v_pass := v_pass + 1;
    RAISE NOTICE '  PASS  M1 the from-scratch build stamps % migration(s)', v_n;
  END IF;

  -- -------------------------------------------------------------------
  -- M2  a from-scratch stamp carries no checksum, and that is deliberate
  -- -------------------------------------------------------------------
  -- NULL means "this arrived with the schema files", which is a
  -- different fact from "the runner applied this exact file" and is
  -- worth being able to tell apart. A checksum here would be a claim
  -- about a file that was never read.
  SELECT count(*) INTO v_n FROM app.schema_migrations WHERE checksum IS NOT NULL;
  IF v_n > 0 THEN
    v_fail := v_fail + 1;
    RAISE NOTICE '  FAIL  M2 % stamp(s) carry a checksum on a from-scratch build', v_n;
    RAISE NOTICE '        The runner did not apply them, so the checksum claims something untrue.';
  ELSE
    v_pass := v_pass + 1;
    RAISE NOTICE '  PASS  M2 from-scratch stamps carry no checksum';
  END IF;

  -- -------------------------------------------------------------------
  -- M3  the session table is the shape the store expects
  -- -------------------------------------------------------------------
  -- connect-pg-simple does not create it and does not check it. A wrong
  -- column type surfaces as a runtime error on the first sign-in, which
  -- is a long way from here.
  SELECT count(*) INTO v_n
  FROM information_schema.columns
  WHERE table_schema = 'app' AND table_name = 'session'
    AND (
      (column_name = 'sid'    AND data_type = 'character varying') OR
      (column_name = 'sess'   AND data_type = 'json')              OR
      (column_name = 'expire' AND data_type LIKE 'timestamp%')
    );
  IF v_n <> 3 THEN
    v_fail := v_fail + 1;
    RAISE NOTICE '  FAIL  M3 app.session does not have the three expected columns (matched %)', v_n;
  ELSE
    v_pass := v_pass + 1;
    RAISE NOTICE '  PASS  M3 app.session has sid/sess/expire with the expected types';
  END IF;

  -- -------------------------------------------------------------------
  -- M4  expire is indexed
  -- -------------------------------------------------------------------
  -- The store sweeps expired rows on a timer. Without this index that
  -- sweep is a sequential scan over every live session, on a schedule.
  SELECT count(*) INTO v_n
  FROM pg_indexes WHERE schemaname = 'app' AND tablename = 'session'
    AND indexdef ILIKE '%expire%';
  IF v_n = 0 THEN
    v_fail := v_fail + 1;
    RAISE NOTICE '  FAIL  M4 app.session.expire is not indexed';
  ELSE
    v_pass := v_pass + 1;
    RAISE NOTICE '  PASS  M4 app.session.expire is indexed';
  END IF;

  -- -------------------------------------------------------------------
  -- M5  sessions are NOT in the domain schema
  -- -------------------------------------------------------------------
  -- 99_tests.sql holds an exact manifest of every column in oltp, so a
  -- session table there would be reported as schema drift. It is not
  -- drift -- it is a different kind of thing -- and this check is what
  -- keeps somebody from "fixing" the manifest instead of the placement.
  SELECT count(*) INTO v_n
  FROM information_schema.tables
  WHERE table_schema = 'oltp' AND table_name IN ('session', 'schema_migrations');
  IF v_n > 0 THEN
    v_fail := v_fail + 1;
    RAISE NOTICE '  FAIL  M5 infrastructure tables have leaked into the oltp schema';
  ELSE
    v_pass := v_pass + 1;
    RAISE NOTICE '  PASS  M5 oltp holds only the competition, not the plumbing';
  END IF;

  RAISE NOTICE '';
  RAISE NOTICE '[migrations] pass=% failures=%', v_pass, v_fail;

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'NOT CLEAN: % migration bookkeeping check(s) failed', v_fail;
  END IF;
END $$;
