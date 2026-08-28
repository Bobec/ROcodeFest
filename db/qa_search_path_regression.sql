-- =====================================================================
-- QA — search_path regression (the R4 class)
-- =====================================================================
-- THIS FILE DELIBERATELY DOES NOT LOAD _qa_harness.sql.
--
-- The harness sets `search_path = qa, oltp, public`, and so did every
-- suite before it. That is convenient and it is also the reason the R4
-- defect survived 213 green assertions: with oltp on the path, an
-- unqualified table reference inside a trigger body resolves correctly,
-- and the failure a default client connection hits is unobservable.
--
-- So this suite runs under RESET search_path -- i.e. `public` only,
-- which is how an ordinary application connects. Every statement below
-- is fully schema-qualified from the outside; anything that fails does
-- so because a FUNCTION BODY was not.
--
-- plpgsql resolves names at EXECUTION time against the CALLER's
-- search_path, not the one in force when the function was created. A
-- function is safe only if it qualifies its references or pins
-- `SET search_path` on itself (pg_proc.proconfig).
--
--   psql -d qa_sp -f db/01_oltp_schema.sql
--   psql -d qa_sp -f db/02_analytics_schema.sql
--   psql -d qa_sp -f db/03_etl.sql
--   psql -d qa_sp -f db/qa_search_path_regression.sql
--
-- Exit non-zero if any trigger path fails under a default connection.
-- =====================================================================

\set ON_ERROR_STOP on
SET client_min_messages = WARNING;

DROP SCHEMA IF EXISTS spqa CASCADE;
CREATE SCHEMA spqa;
CREATE TABLE spqa.results(
  seq SERIAL PRIMARY KEY, area TEXT, tc TEXT, status TEXT, detail TEXT);

CREATE OR REPLACE FUNCTION spqa.rec(a TEXT, t TEXT, s TEXT, d TEXT) RETURNS void
AS $$ INSERT INTO spqa.results(area,tc,status,detail) VALUES (a,t,s,d); $$ LANGUAGE sql;

-- Runs a statement under a DEFAULT connection path and reports whether
-- it survived. A failure here is a live defect, not a test artefact.
CREATE OR REPLACE FUNCTION spqa.under_default_path(a TEXT, t TEXT, stmt TEXT) RETURNS void
AS $fn$
DECLARE v_rows BIGINT;
BEGIN
  PERFORM set_config('search_path', 'public', true);   -- default client path
  BEGIN
    EXECUTE stmt;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM spqa.rec(a, t, CASE WHEN v_rows > 0 THEN 'PASS' ELSE 'FAIL' END,
      CASE WHEN v_rows > 0 THEN format('%s row(s) written with search_path=public', v_rows)
           ELSE 'VACUOUS: succeeded but wrote nothing' END);
  EXCEPTION WHEN others THEN
    PERFORM spqa.rec(a, t, 'FAIL',
      format('[%s] %s -- a trigger body resolved an unqualified name against public', SQLSTATE, SQLERRM));
  END;
  PERFORM set_config('search_path', 'oltp, public', true);
END $fn$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Fixture, built with the path SET (building it is not what we test)
-- ---------------------------------------------------------------------
SET search_path = oltp, public;
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('sp-c@t','x','club'), ('sp-m@t','x','member'), ('sp-j@t','x','judge');
INSERT INTO oltp.clubs(account_id,club_name)  SELECT account_id,'SP Club' FROM oltp.accounts WHERE email='sp-c@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,'SP M'   FROM oltp.accounts WHERE email='sp-m@t';
INSERT INTO oltp.judges(account_id,full_name)  SELECT account_id,'SP J'   FROM oltp.accounts WHERE email='sp-j@t';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'SP Team','SP-1'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.seasons(name,start_date) VALUES ('SP Season','2026-01-01');
INSERT INTO oltp.challenges(season_id,name,stage)
  SELECT season_id,'SP Challenge','final' FROM oltp.seasons;
INSERT INTO oltp.matches(challenge_id,round_name,status)
  SELECT challenge_id,'SP R1','completed' FROM oltp.challenges;
INSERT INTO oltp.match_teams(match_id,team_id) SELECT m.match_id,t.team_id FROM oltp.matches m, oltp.teams t;
INSERT INTO oltp.forum_categories(code,label) VALUES ('SP','SP cat');

-- ---------------------------------------------------------------------
-- One case per trigger function that touches tables
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='SP-1');
  v_c BIGINT := (SELECT challenge_id FROM oltp.challenges WHERE name='SP Challenge');
  v_m BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='sp-m@t');
  v_j BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='sp-j@t');
  v_mt BIGINT := (SELECT match_id FROM oltp.matches LIMIT 1);
BEGIN
  -- assign_submission_version : queries `submissions`
  PERFORM spqa.under_default_path('assign_submission_version','insert a submission',
    format('INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id) VALUES (%s,%s,''sp v1'',%s)', v_t, v_c, v_m));

  -- enforce_team_capacity : queries `teams`, `team_categories`, `memberships`
  PERFORM spqa.under_default_path('enforce_team_capacity','insert a membership',
    format('INSERT INTO oltp.memberships(team_id,member_id) VALUES (%s,%s)', v_t, v_m));

  -- enforce_appeal_limit : queries `appeals`
  PERFORM spqa.under_default_path('enforce_appeal_limit','insert an appeal',
    format('INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (%s,%s,''sp appeal'')', v_t, v_m));

  -- enforce_subtype_role : queries `accounts`
  PERFORM spqa.under_default_path('enforce_subtype_role','insert a judge subtype row',
    'INSERT INTO oltp.accounts(email,password_hash,role) VALUES (''sp-j2@t'',''x'',''judge'');
     INSERT INTO oltp.judges(account_id,full_name) SELECT account_id,''SP J2'' FROM oltp.accounts WHERE email=''sp-j2@t''');

  -- set_updated_at : touches no table, but exercise the UPDATE path
  PERFORM spqa.under_default_path('set_updated_at','update an account',
    format('UPDATE oltp.accounts SET is_active=TRUE WHERE account_id=%s', v_m));

  -- enforce_single_notification_link : queries all four link tables
  PERFORM spqa.under_default_path('enforce_single_notification_link','insert a notification link',
    format('INSERT INTO oltp.notifications(recipient_account_id,title) VALUES (%s,''sp'');
            INSERT INTO oltp.submission_reviews(submission_id,judge_id) SELECT submission_id,%s FROM oltp.submissions LIMIT 1;
            INSERT INTO oltp.notification_submission_review_links(notification_id,event_type,submission_review_id)
              SELECT currval(pg_get_serial_sequence(''oltp.notifications'',''notification_id'')),''judge_feedback_given'',
                     (SELECT review_id FROM oltp.submission_reviews ORDER BY review_id DESC LIMIT 1)', v_m, v_j));
END $$;

-- ---------------------------------------------------------------------
-- The analytics side, previously flagged as "looks safe, not probed"
-- ---------------------------------------------------------------------
DO $$
DECLARE v_rows BIGINT;
BEGIN
  PERFORM set_config('search_path', 'public', true);
  BEGIN
    PERFORM analytics.run_etl();
    SELECT count(*) INTO v_rows FROM analytics.fact_submissions;
    PERFORM spqa.rec('analytics.run_etl','full ETL under search_path=public','PASS',
      format('completed; fact_submissions=%s', v_rows));
  EXCEPTION WHEN others THEN
    PERFORM spqa.rec('analytics.run_etl','full ETL under search_path=public','FAIL',
      format('[%s] %s', SQLSTATE, SQLERRM));
  END;

  BEGIN
    PERFORM count(*) FROM analytics.etl_quality_report();
    PERFORM spqa.rec('analytics.etl_quality_report','quality gate under search_path=public','PASS','completed');
  EXCEPTION WHEN others THEN
    PERFORM spqa.rec('analytics.etl_quality_report','quality gate under search_path=public','FAIL',
      format('[%s] %s', SQLSTATE, SQLERRM));
  END;

  BEGIN
    PERFORM count(*) FROM analytics.vw_partner_dashboard;
    PERFORM spqa.rec('analytics.vw_partner_dashboard','dashboard view under search_path=public','PASS','readable');
  EXCEPTION WHEN others THEN
    PERFORM spqa.rec('analytics.vw_partner_dashboard','dashboard view under search_path=public','FAIL',
      format('[%s] %s', SQLSTATE, SQLERRM));
  END;
  PERFORM set_config('search_path', 'oltp, public', true);
END $$;

-- ---------------------------------------------------------------------
-- Static inventory: which functions are structurally exposed
-- ---------------------------------------------------------------------
SET search_path = oltp, public;
DO $$
DECLARE r RECORD; v_exposed INT := 0;
BEGIN
  FOR r IN
    SELECT n.nspname AS sch, p.proname,
           (p.proconfig IS NULL) AS unpinned,
           (p.prosrc ~* '(FROM|JOIN|INTO|UPDATE)\s+(?!oltp\.|analytics\.|pg_|information_schema\.)[a-z_]+') AS looks_unqualified
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('oltp','analytics') AND p.prolang = (SELECT oid FROM pg_language WHERE lanname='plpgsql')
    ORDER BY 1,2
  LOOP
    IF r.unpinned AND r.looks_unqualified THEN
      v_exposed := v_exposed + 1;
      PERFORM spqa.rec('inventory', r.sch||'.'||r.proname, 'EXPOSED',
        'no SET search_path pinned AND body contains an unqualified table reference');
    END IF;
  END LOOP;

  PERFORM spqa.rec('inventory','summary',
    CASE WHEN v_exposed = 0 THEN 'PASS' ELSE 'INFO' END,
    format('%s plpgsql function(s) structurally exposed to search_path', v_exposed));
END $$;

-- =====================================================================
\echo ''
\echo '============ search_path regression (default connection) ============'
SELECT seq, area, tc, status, detail FROM spqa.results ORDER BY seq;
\echo ''
SELECT status, count(*) FROM spqa.results GROUP BY status ORDER BY status;

DO $$
DECLARE v INT := (SELECT count(*) FROM spqa.results WHERE status='FAIL');
BEGIN
  RAISE NOTICE '[search_path] FAIL=% EXPOSED=%', v,
    (SELECT count(*) FROM spqa.results WHERE status='EXPOSED');
  IF v > 0 THEN
    RAISE EXCEPTION '[search_path] % trigger/ETL path(s) fail on a DEFAULT client connection. '
                    'See db/proposals/R4_trigger_search_path.patch.sql', v;
  END IF;
END $$;
