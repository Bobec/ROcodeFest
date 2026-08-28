-- =====================================================================
-- QA — R4 silent-misresolution probe (oltp vs public)
-- =====================================================================
-- Question: when the resubmission gate reads submission_reviews
-- UNQUALIFIED, can search_path make it consult public.submission_reviews
-- instead of oltp.submission_reviews -- answering from the wrong table
-- WITHOUT raising an error?
--
-- Three distinct outcomes, never collapsed into pass/fail:
--   CRASH          object missing (Step A NULL, or Step B errors)
--   MISRESOLUTION  seen_by_gate <> truth_oltp -- read the decoy. RED.
--   CORRECT        seen_by_gate = truth_oltp, and the source is proven
--                  to be oltp.
--
-- Running without an error is NOT a pass. PASS requires the values to
-- agree AND the source to be demonstrated.
--
--   psql -d qa_r4 -f db/01_oltp_schema.sql
--   psql -d qa_r4 -f db/qa_r4_search_path_probe.sql
-- =====================================================================

\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;
DROP SCHEMA IF EXISTS qa CASCADE;
CREATE SCHEMA qa;

CREATE TABLE qa.results(
  seq SERIAL PRIMARY KEY, step TEXT, path TEXT,
  seen BOOLEAN, truth BOOLEAN, verdict TEXT, detail TEXT);

-- ---------------------------------------------------------------------
-- Fixture. The prompt's seed uses literal ids (9001 / 7001) and ids
-- 1,1,1 for team/challenge/judge. Those columns are GENERATED ALWAYS AS
-- IDENTITY here, so the inserts need OVERRIDING SYSTEM VALUE, and the
-- referenced rows must be built first or the FKs reject them.
-- ---------------------------------------------------------------------
SET search_path = oltp, public;

-- account 1 must be the judge (judge_id = 1); account 2 the club
INSERT INTO oltp.accounts(email,password_hash,role) VALUES ('j1@t','x','judge');
INSERT INTO oltp.judges(account_id, full_name)
  SELECT account_id,'J1' FROM oltp.accounts WHERE email='j1@t';
INSERT INTO oltp.accounts(email,password_hash,role) VALUES ('c@t','x','club');
INSERT INTO oltp.clubs(account_id, club_name)
  SELECT account_id,'C' FROM oltp.accounts WHERE email='c@t';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id, tc.category_id, 'T', 'T-1'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.seasons(name,start_date) VALUES ('S','2026-01-01');
INSERT INTO oltp.challenges(season_id,name,stage)
  SELECT season_id,'CH','final' FROM oltp.seasons;

-- REAL (oltp): v1 does NOT request a resubmission -> the gate must refuse v2
INSERT INTO oltp.submissions
  (submission_id, team_id, challenge_id, version, title, submitted_by_account_id)
  OVERRIDING SYSTEM VALUE
SELECT 9001, t.team_id, c.challenge_id, 1, 'v1', 1
FROM oltp.teams t, oltp.challenges c;

INSERT INTO oltp.submission_reviews
  (review_id, submission_id, judge_id, feedback, requires_resubmission)
  OVERRIDING SYSTEM VALUE
VALUES (7001, 9001, 1, 'ok, minor notes', false);

-- DECOY (public): same submission_id, opposite answer
CREATE TABLE IF NOT EXISTS public.submission_reviews (
  review_id int PRIMARY KEY, submission_id int, judge_id int,
  feedback text, requires_resubmission boolean);
INSERT INTO public.submission_reviews
  (review_id, submission_id, judge_id, feedback, requires_resubmission)
VALUES (7001, 9001, 1, 'RESUBMIT', true);


-- =====================================================================
-- STEP A — separate CRASH from silent misresolution
-- =====================================================================
\echo ''
\echo '--- STEP A: do both objects exist? ---'
SELECT to_regclass('oltp.submission_reviews')   AS oltp_exists,
       to_regclass('public.submission_reviews') AS public_exists;

DO $$
DECLARE v_o TEXT; v_p TEXT;
BEGIN
  v_o := to_regclass('oltp.submission_reviews')::text;
  v_p := to_regclass('public.submission_reviews')::text;
  IF v_o IS NULL THEN
    INSERT INTO qa.results(step,path,verdict,detail)
      VALUES ('A','n/a','CRASH','oltp.submission_reviews is missing -- nothing below is meaningful');
  ELSE
    INSERT INTO qa.results(step,path,verdict,detail)
      VALUES ('A','n/a','CORRECT',
        format('oltp=%s, public=%s -- both present, so an error below would be CRASH and a '
               ||'wrong value would be MISRESOLUTION', v_o, coalesce(v_p,'<none>')));
  END IF;
END $$;


-- =====================================================================
-- STEP B — what an unqualified read sees, per search_path
-- =====================================================================
-- The same statement, run twice, differing only in search_path. If the
-- decoy does not flip the answer, this probe proves nothing -- so the
-- flip is itself asserted below.

-- B1: oltp first (how every test suite in this repo connects)
SET search_path = oltp, public;
\echo ''
\echo '--- STEP B1: search_path = oltp, public ---'
SELECT
  (SELECT bool_or(requires_resubmission) FROM submission_reviews      WHERE submission_id = 9001) AS seen_by_gate,
  (SELECT bool_or(requires_resubmission) FROM oltp.submission_reviews WHERE submission_id = 9001) AS truth_oltp;

DO $$
DECLARE v_seen BOOLEAN; v_truth BOOLEAN;
BEGIN
  SELECT (SELECT bool_or(requires_resubmission) FROM submission_reviews      WHERE submission_id = 9001),
         (SELECT bool_or(requires_resubmission) FROM oltp.submission_reviews WHERE submission_id = 9001)
    INTO v_seen, v_truth;
  INSERT INTO qa.results(step,path,seen,truth,verdict,detail)
    VALUES ('B1','oltp, public', v_seen, v_truth,
      CASE WHEN v_seen IS NOT DISTINCT FROM v_truth THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
      'unqualified read resolved to oltp');
END $$;

-- B2: public first (a client that never sets search_path, or sets it wrong)
SET search_path = public, oltp;
\echo ''
\echo '--- STEP B2: search_path = public, oltp ---'
SELECT
  (SELECT bool_or(requires_resubmission) FROM submission_reviews      WHERE submission_id = 9001) AS seen_by_gate,
  (SELECT bool_or(requires_resubmission) FROM oltp.submission_reviews WHERE submission_id = 9001) AS truth_oltp;

DO $$
DECLARE v_seen BOOLEAN; v_truth BOOLEAN;
BEGIN
  SELECT (SELECT bool_or(requires_resubmission) FROM submission_reviews      WHERE submission_id = 9001),
         (SELECT bool_or(requires_resubmission) FROM oltp.submission_reviews WHERE submission_id = 9001)
    INTO v_seen, v_truth;
  INSERT INTO qa.results(step,path,seen,truth,verdict,detail)
    VALUES ('B2','public, oltp', v_seen, v_truth,
      CASE WHEN v_seen IS NOT DISTINCT FROM v_truth THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
      'unqualified read resolved to the decoy -- no error raised');
END $$;

-- credibility: the decoy MUST flip the answer, or B1's "CORRECT" is luck
DO $$
DECLARE v_b1 BOOLEAN; v_b2 BOOLEAN;
BEGIN
  SELECT seen INTO v_b1 FROM qa.results WHERE step='B1';
  SELECT seen INTO v_b2 FROM qa.results WHERE step='B2';
  INSERT INTO qa.results(step,path,seen,truth,verdict,detail)
    VALUES ('B-DECOY','both', v_b2, v_b1,
      CASE WHEN v_b1 IS DISTINCT FROM v_b2 THEN 'CORRECT' ELSE 'CRASH' END,
      format('decoy flips the verdict: B1 saw %s, B2 saw %s. If these matched, the probe would be '
             ||'unable to detect misresolution at all.', v_b1, v_b2));
END $$;


-- =====================================================================
-- STEP C — the actual R3 gate function, and an unqualified twin
-- =====================================================================
-- R3's enforce_resubmission_gate() reads oltp.submission_reviews
-- QUALIFIED. The twin below is byte-identical except for dropping the
-- schema prefix, which is exactly the R4 hazard. Running both under the
-- hostile search_path shows whether qualification is what protects it.
SET search_path = oltp, public;

CREATE OR REPLACE FUNCTION qa.gate_qualified(p_submission BIGINT) RETURNS BOOLEAN AS $fn$
DECLARE v BOOLEAN;
BEGIN
  SELECT coalesce(bool_or(requires_resubmission), FALSE) INTO v
  FROM oltp.submission_reviews WHERE submission_id = p_submission;   -- qualified
  RETURN v;
END $fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qa.gate_unqualified(p_submission BIGINT) RETURNS BOOLEAN AS $fn$
DECLARE v BOOLEAN;
BEGIN
  SELECT coalesce(bool_or(requires_resubmission), FALSE) INTO v
  FROM submission_reviews WHERE submission_id = p_submission;        -- UNQUALIFIED
  RETURN v;
END $fn$ LANGUAGE plpgsql;

SET search_path = public, oltp;
DO $$
DECLARE v_q BOOLEAN; v_u BOOLEAN; v_truth BOOLEAN;
BEGIN
  SELECT bool_or(requires_resubmission) INTO v_truth
    FROM oltp.submission_reviews WHERE submission_id = 9001;
  v_q := qa.gate_qualified(9001);
  v_u := qa.gate_unqualified(9001);

  INSERT INTO qa.results(step,path,seen,truth,verdict,detail)
    VALUES ('C-QUAL','public, oltp', v_q, v_truth,
      CASE WHEN v_q IS NOT DISTINCT FROM v_truth THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
      'a QUALIFIED gate under the hostile search_path -- this is how R3 is written');

  INSERT INTO qa.results(step,path,seen,truth,verdict,detail)
    VALUES ('C-UNQUAL','public, oltp', v_u, v_truth,
      CASE WHEN v_u IS NOT DISTINCT FROM v_truth THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
      'the same gate with the schema prefix removed -- the R4 hazard, shown live');
END $$;


-- =====================================================================
-- STEP D — grain separation: reviews vs scores
-- =====================================================================
-- The clean line submission -> reviews is keyed on submission_id alone.
-- The scoring branch is keyed on (match_id, team_id). Asserted from the
-- catalogue rather than assumed, so "no grain contamination" is a fact
-- about the schema and not a reading of it.
SET search_path = oltp, public;
DO $$
DECLARE v_rev TEXT; v_sco TEXT;
BEGIN
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_rev
  FROM information_schema.columns
  WHERE table_schema='oltp' AND table_name='submission_reviews'
    AND column_name IN ('submission_id','match_id','team_id');

  SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_sco
  FROM information_schema.columns
  WHERE table_schema='oltp' AND table_name='scores'
    AND column_name IN ('submission_id','match_id','team_id');

  INSERT INTO qa.results(step,path,verdict,detail)
    VALUES ('D','n/a',
      CASE WHEN v_rev = 'submission_id' AND v_sco = 'match_id,team_id'
           THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
      format('submission_reviews keys on [%s]; scores keys on [%s] -- disjoint, no shared grain',
             v_rev, v_sco));
END $$;


-- =====================================================================
\echo ''
\echo '===================== VERDICTS ====================='
SELECT seq, step, path, seen AS seen_by_gate, truth AS truth_oltp, verdict, detail
FROM qa.results ORDER BY seq;

\echo ''
SELECT verdict, count(*) FROM qa.results GROUP BY verdict ORDER BY verdict;

DO $$
DECLARE v_mis INT; v_crash INT;
BEGIN
  SELECT count(*) FILTER (WHERE verdict='MISRESOLUTION'),
         count(*) FILTER (WHERE verdict='CRASH')
    INTO v_mis, v_crash FROM qa.results;
  -- the runner parses this line; without it the suite reports
  -- "(no summary line)" and its result has to be read by hand
  RAISE NOTICE '[misresolution] correct=% misresolution=% crash=%',
    (SELECT count(*) FROM qa.results WHERE verdict='CORRECT'), v_mis, v_crash;
  RAISE NOTICE 'CRASH=% MISRESOLUTION=% -- see the table above; a MISRESOLUTION on a '
               'shipped gate is RED even though nothing errored.', v_crash, v_mis;
END $$;
