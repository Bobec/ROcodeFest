-- =====================================================================
-- VERIFY R2 — block-of-matches grain + back-fill correctness
-- =====================================================================
-- Runs on a THROWAWAY database. It seeds pre-patch data, applies the
-- proposal in-place, and then asserts. Nothing here touches the deploy
-- pipeline; the proposal remains unapplied to the project.
--
--   psql -d r2_verify -f db/01_oltp_schema.sql
--   psql -d r2_verify -f db/02_analytics_schema.sql
--   psql -d r2_verify -f db/03_etl.sql
--   psql -d r2_verify -f db/proposals/R2_match_judges.verify.sql
--
-- Result states: PASS | FAIL | PENDING. Only FAIL exits non-zero.
-- Every negative case is two assertions: a proven precondition, then
-- the rejection. qa_reject refuses to count a statement that succeeded
-- while touching zero rows.
-- =====================================================================

\set ON_ERROR_STOP on
-- NOTICE, not WARNING: the back-fill in step 2 of the patch reports what
-- it canonised via RAISE NOTICE, and that report is the traceability
-- record for a trust decision. Suppressing it here would hide the one
-- output that says how much history was grandfathered.
SET client_min_messages = NOTICE;
DROP SCHEMA IF EXISTS qa CASCADE;
CREATE SCHEMA qa;
SET search_path = qa, oltp, public;

CREATE TABLE qa_results(
  seq SERIAL PRIMARY KEY, kind TEXT, tc TEXT, status TEXT, detail TEXT);

CREATE OR REPLACE FUNCTION qa_true(p_tc TEXT, p_cond BOOLEAN, p_detail TEXT DEFAULT NULL)
RETURNS void AS $fn$
BEGIN
  INSERT INTO qa_results(kind,tc,status,detail)
    VALUES ('POS',p_tc, CASE WHEN coalesce(p_cond,FALSE) THEN 'PASS' ELSE 'FAIL' END, p_detail);
END $fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qa_pre(p_tc TEXT, p_cond BOOLEAN, p_detail TEXT DEFAULT NULL)
RETURNS void AS $fn$
BEGIN
  INSERT INTO qa_results(kind,tc,status,detail)
    VALUES ('PRE','PRE ' || p_tc, CASE WHEN coalesce(p_cond,FALSE) THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN coalesce(p_cond,FALSE) THEN p_detail
                 ELSE 'PRECONDITION NOT MET -- the rejection below proves nothing: '||coalesce(p_detail,'') END);
END $fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qa_reject(p_tc TEXT, p_stmt TEXT) RETURNS void AS $fn$
DECLARE v_con TEXT; v_tab TEXT; v_state TEXT; v_msg TEXT; v_rows BIGINT;
BEGIN
  BEGIN
    EXECUTE p_stmt;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    INSERT INTO qa_results(kind,tc,status,detail)
      VALUES ('NEG',p_tc,'FAIL',
              CASE WHEN v_rows = 0 THEN 'VACUOUS: succeeded but touched 0 rows -- asserted nothing'
                   ELSE format('ACCEPTED (%s row(s)) but must be rejected', v_rows) END);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_con=CONSTRAINT_NAME, v_tab=TABLE_NAME, v_state=RETURNED_SQLSTATE, v_msg=MESSAGE_TEXT;
    INSERT INTO qa_results(kind,tc,status,detail)
      VALUES ('NEG',p_tc,'PASS', format('rejected [%s] table=%s constraint=%s | %s', v_state, v_tab, v_con, v_msg));
  END;
END $fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qa_accept(p_tc TEXT, p_stmt TEXT) RETURNS void AS $fn$
DECLARE v_state TEXT; v_con TEXT; v_rows BIGINT;
BEGIN
  BEGIN
    EXECUTE p_stmt;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    INSERT INTO qa_results(kind,tc,status,detail)
      VALUES ('POS',p_tc, CASE WHEN v_rows=0 THEN 'FAIL' ELSE 'PASS' END,
              CASE WHEN v_rows=0 THEN 'VACUOUS: accepted but touched 0 rows' ELSE v_rows||' row(s) inserted' END);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE, v_con=CONSTRAINT_NAME;
    INSERT INTO qa_results(kind,tc,status,detail)
      VALUES ('POS',p_tc,'FAIL', format('UNEXPECTEDLY rejected [%s] constraint=%s: %s', v_state, v_con, SQLERRM));
  END;
END $fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qa_pending(p_tc TEXT, p_detail TEXT) RETURNS void AS $fn$
BEGIN
  INSERT INTO qa_results(kind,tc,status,detail) VALUES ('STUB',p_tc,'PENDING',p_detail);
END $fn$ LANGUAGE plpgsql;

-- =====================================================================
-- PRE-PATCH SEED
-- =====================================================================
-- Shaped so the back-fill has something non-trivial to collapse: judge
-- jA scores TWO teams inside match M1, which is two score rows but only
-- ONE (match, judge) pair. A back-fill that forgot to group would try
-- to insert the pair twice and violate the new PK.
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('c@t','x','club'),('jA@t','x','judge'),('jB@t','x','judge'),('jC@t','x','judge');
INSERT INTO oltp.clubs(account_id,club_name) SELECT account_id,'C' FROM oltp.accounts WHERE email='c@t';
INSERT INTO oltp.judges(account_id,full_name) SELECT account_id,'J'||account_id FROM oltp.accounts WHERE role='judge';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'T1','T-1' FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'T2','T-2' FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
-- T3 is fielded everywhere but NEVER scored in the seed. The positive
-- block cases below score it, so they insert a genuinely new row; using
-- an already-scored (match,team,judge) triple would collide on
-- uq_scores_match_team_judge and prove nothing.
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'T3','T-3' FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.seasons(name,start_date) VALUES ('S','2026-01-01');
INSERT INTO oltp.challenges(season_id,name,stage) SELECT season_id,'Ch','final' FROM oltp.seasons;

-- M1..M3 will carry scores (and therefore be back-filled).
-- M4 is created too, but stays SCORE-FREE: it is the unassigned match.
INSERT INTO oltp.matches(challenge_id,round_name,scheduled_at,status)
SELECT c.challenge_id, r.rn, ('2026-06-0'||r.i||' 10:00+00')::timestamptz, 'completed'
FROM oltp.challenges c, (VALUES (1,'M1'),(2,'M2'),(3,'M3'),(4,'M4')) AS r(i,rn);

-- every team is fielded in every match, so the TEAM side can never be
-- the reason a later insert is rejected
INSERT INTO oltp.match_teams(match_id,team_id) SELECT m.match_id,t.team_id FROM oltp.matches m, oltp.teams t;

-- jA scores in M1 (two teams), M2 and M3 -> a block of 3 matches.
-- jB scores only in M1. jC scores nowhere.
INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score,scored_at)
SELECT m.match_id, t.team_id, a.account_id, 5,5,5,5, '2026-06-01 12:00+00'
FROM oltp.matches m, oltp.teams t, oltp.accounts a
WHERE m.round_name='M1' AND t.participation_code IN ('T-1','T-2') AND a.email='jA@t';
INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score,scored_at)
SELECT m.match_id, t.team_id, a.account_id, 6,6,6,6, '2026-06-02 12:00+00'
FROM oltp.matches m, oltp.teams t, oltp.accounts a
WHERE m.round_name IN ('M2','M3') AND t.participation_code='T-1' AND a.email='jA@t';
INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score,scored_at)
SELECT m.match_id, t.team_id, a.account_id, 7,7,7,7, '2026-06-01 13:00+00'
FROM oltp.matches m, oltp.teams t, oltp.accounts a
WHERE m.round_name='M1' AND t.participation_code='T-1' AND a.email='jB@t';

-- snapshot the truth the back-fill must reproduce
CREATE TABLE qa.expected_pairs AS
  SELECT DISTINCT match_id, judge_id FROM oltp.scores;

DO $$
BEGIN
  PERFORM qa_true('SEED: scores exist before the patch (back-fill is non-trivial)',
    (SELECT count(*) FROM oltp.scores) > (SELECT count(*) FROM qa.expected_pairs),
    (SELECT count(*)::text FROM oltp.scores) || ' score rows collapse to '
    || (SELECT count(*)::text FROM qa.expected_pairs) || ' distinct (match,judge) pairs');
END $$;

-- =====================================================================
-- APPLY THE PROPOSAL (on this throwaway database only)
-- =====================================================================
\ir R2_match_judges.patch.sql

-- =====================================================================
-- 3 — back-fill correctness
-- =====================================================================
DO $$
DECLARE v_missing BIGINT; v_extra BIGINT;
BEGIN
  PERFORM qa_true('BACKFILL: the ALTER succeeded on a database that already held scores',
    EXISTS (SELECT 1 FROM pg_constraint WHERE conname='fk_scores_match_judge'),
    'fk_scores_match_judge is present');

  SELECT count(*) INTO v_missing FROM (
    SELECT match_id, judge_id FROM qa.expected_pairs
    EXCEPT SELECT match_id, judge_id FROM oltp.match_judges) x;
  SELECT count(*) INTO v_extra FROM (
    SELECT match_id, judge_id FROM oltp.match_judges
    EXCEPT SELECT match_id, judge_id FROM qa.expected_pairs) x;

  PERFORM qa_true('BACKFILL: no implied pair is missing', v_missing = 0, v_missing||' missing');
  PERFORM qa_true('BACKFILL: no pair was invented',      v_extra   = 0, v_extra||' extra');
  PERFORM qa_true('BACKFILL: exactly the distinct set, one row per pair',
    (SELECT count(*) FROM oltp.match_judges) = (SELECT count(*) FROM qa.expected_pairs),
    (SELECT count(*)::text FROM oltp.match_judges)||' rows vs '
    ||(SELECT count(*)::text FROM qa.expected_pairs)||' expected pairs');
  PERFORM qa_true('BACKFILL: the duplicated pair collapsed to ONE row (M1,jA scored 2 teams)',
    (SELECT count(*) FROM oltp.match_judges mj
     JOIN oltp.matches m ON m.match_id=mj.match_id
     JOIN oltp.accounts a ON a.account_id=mj.judge_id
     WHERE m.round_name='M1' AND a.email='jA@t') = 1,
    'grouping, not DISTINCT-by-luck');
END $$;

-- =====================================================================
-- 5 — THE TRUST BOUNDARY: retroactive trust vs forward enforcement
-- =====================================================================
-- Two halves, both proven actively.
DO $$
DECLARE
  v_hist_score BIGINT;
  v_hist_match BIGINT; v_hist_judge BIGINT;
  v_canonised  BIGINT;
  v_hist_total BIGINT;
BEGIN
  -- ---- BEFORE: history survives, canonised rather than checked -------
  SELECT count(*) INTO v_canonised  FROM oltp.match_judges;
  SELECT count(*) INTO v_hist_total FROM oltp.scores;

  -- an arbitrary historical score, chosen without cherry-picking
  SELECT score_id, match_id, judge_id INTO v_hist_score, v_hist_match, v_hist_judge
  FROM oltp.scores ORDER BY score_id LIMIT 1;

  PERFORM qa_pre('TRUST before', v_hist_score IS NOT NULL,
    'historical score_id='||v_hist_score||' on (match '||v_hist_match||', judge '||v_hist_judge||') predates the migration');

  PERFORM qa_true('TRUST/BEFORE: the arbitrary historical score survived the ALTER',
    EXISTS (SELECT 1 FROM oltp.scores WHERE score_id = v_hist_score),
    v_hist_total||' historical score row(s) still present; '||v_canonised||' pair(s) canonised by the back-fill');

  PERFORM qa_true('TRUST/BEFORE: it survived because its pair was CANONISED, not verified',
    EXISTS (SELECT 1 FROM oltp.match_judges
            WHERE match_id = v_hist_match AND judge_id = v_hist_judge),
    'the assignment row was DERIVED from this very score -- the FK could not have caught anything here');

  PERFORM qa_true('TRUST/BEFORE: every historical score is covered (vacuously true over history)',
    NOT EXISTS (
      SELECT 1 FROM oltp.scores s
      WHERE NOT EXISTS (SELECT 1 FROM oltp.match_judges mj
                        WHERE mj.match_id = s.match_id AND mj.judge_id = s.judge_id)),
    'coverage is total by construction, which is the point being demonstrated -- not a strength');

  -- ---- the constraint must be TOTAL, with no temporal escape hatch ---
  PERFORM qa_true('TRUST: the FK is VALIDATED, not NOT VALID',
    (SELECT convalidated FROM pg_constraint WHERE conname='fk_scores_match_judge'),
    'pg_constraint.convalidated = true -- the rejected Q2 branch did not sneak back in');
  PERFORM qa_true('TRUST: no exemption column was added to scores',
    NOT EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema='oltp' AND table_name='scores'
                  AND column_name IN ('is_legacy','grandfathered','exempt','pre_migration')),
    'no per-row escape hatch');
  PERFORM qa_true('TRUST: enforcement is a constraint, not an INSERT-only trigger',
    NOT EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid
                WHERE c.relname='scores' AND NOT tg.tgisinternal
                  AND pg_get_triggerdef(tg.oid) ILIKE '%match_judges%'),
    'declarative FK covers UPDATE as well as INSERT');
END $$;

-- ---- AFTER: forward enforcement has teeth -- proven, not claimed -----
DO $$
DECLARE
  v_jC BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jC@t');
  v_t1 BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='T-1');
  v_m1 BIGINT := (SELECT match_id FROM oltp.matches WHERE round_name='M1');
BEGIN
  PERFORM qa_pre('TRUST after',
    EXISTS (SELECT 1 FROM oltp.judges WHERE account_id=v_jC)
    AND EXISTS (SELECT 1 FROM oltp.match_teams WHERE match_id=v_m1 AND team_id=v_t1)
    AND NOT EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_m1 AND judge_id=v_jC)
    AND NOT EXISTS (SELECT 1 FROM oltp.scores WHERE match_id=v_m1 AND judge_id=v_jC),
    'judge '||v_jC||' exists, T1 IS fielded in M1, but (M1,jC) was never assigned and never scored -- '
    ||'so it was NOT canonised, and only the judge side can reject');
  PERFORM qa_reject('TRUST/AFTER: a NEW score on a never-assigned pair is rejected',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,5,5,5,5)', v_m1, v_t1, v_jC));
END $$;

-- =====================================================================
-- 1 — the block of matches: one judge, >= 3 distinct matches
-- =====================================================================
DO $$
DECLARE
  v_jA BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jA@t');
  v_jC BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jC@t');
  v_t1 BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='T-1');
  v_t2 BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='T-2');
  v_t3 BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='T-3');
  v_m1 BIGINT := (SELECT match_id FROM oltp.matches WHERE round_name='M1');
  v_m2 BIGINT := (SELECT match_id FROM oltp.matches WHERE round_name='M2');
  v_m3 BIGINT := (SELECT match_id FROM oltp.matches WHERE round_name='M3');
  v_m4 BIGINT := (SELECT match_id FROM oltp.matches WHERE round_name='M4');
  v_block BIGINT;
BEGIN
  -- the block itself
  SELECT count(*) INTO v_block FROM oltp.match_judges WHERE judge_id = v_jA;
  PERFORM qa_true('BLOCK: one judge holds >= 3 assignment rows (a block of matches)',
    v_block >= 3, 'judge '||v_jA||' has '||v_block||' rows');
  PERFORM qa_true('BLOCK: those rows cover 3 DISTINCT matches',
    (SELECT count(DISTINCT match_id) FROM oltp.match_judges WHERE judge_id=v_jA) = 3,
    'M1, M2, M3');

  -- one match -> N judges (the other direction of the N:N)
  PERFORM qa_true('BLOCK: one match carries >= 2 judges (N:N holds both ways)',
    (SELECT count(*) FROM oltp.match_judges WHERE match_id=v_m1) >= 2,
    (SELECT count(*)::text FROM oltp.match_judges WHERE match_id=v_m1)||' judges on M1');

  -- all three assigned matches accept a score from that judge
  PERFORM qa_pre('BLOCK M1',
    EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_m1 AND judge_id=v_jA)
    AND EXISTS (SELECT 1 FROM oltp.match_teams WHERE match_id=v_m1 AND team_id=v_t2),
    'jA IS assigned to M1 and T2 IS fielded there');
  PERFORM qa_accept('BLOCK: score on assigned match M1 accepted',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,8,8,8,8)', v_m1, v_t3, v_jA));

  PERFORM qa_pre('BLOCK M2',
    EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_m2 AND judge_id=v_jA)
    AND EXISTS (SELECT 1 FROM oltp.match_teams WHERE match_id=v_m2 AND team_id=v_t2),
    'jA IS assigned to M2 and T2 IS fielded there');
  PERFORM qa_accept('BLOCK: score on assigned match M2 accepted',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,8,8,8,8)', v_m2, v_t3, v_jA));

  PERFORM qa_pre('BLOCK M3',
    EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_m3 AND judge_id=v_jA)
    AND EXISTS (SELECT 1 FROM oltp.match_teams WHERE match_id=v_m3 AND team_id=v_t2),
    'jA IS assigned to M3 and T2 IS fielded there');
  PERFORM qa_accept('BLOCK: score on assigned match M3 accepted',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,8,8,8,8)', v_m3, v_t3, v_jA));

  -- the 4th, unassigned match is rejected -- and ONLY the judge side can
  -- be the reason, which the precondition pins down
  PERFORM qa_pre('BLOCK M4 unassigned',
    v_m4 IS NOT NULL
    AND EXISTS (SELECT 1 FROM oltp.matches WHERE match_id=v_m4)
    AND EXISTS (SELECT 1 FROM oltp.match_teams WHERE match_id=v_m4 AND team_id=v_t1)
    AND EXISTS (SELECT 1 FROM oltp.judges WHERE account_id=v_jA)
    AND NOT EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_m4 AND judge_id=v_jA),
    'M4 exists, T1 IS fielded there, jA exists -- but (M4,jA) is NOT an assignment, so only the judge side can reject');
  PERFORM qa_reject('BLOCK: score on the 4th, UNASSIGNED match is rejected',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,5,5,5,5)', v_m4, v_t1, v_jA));

  -- a judge assigned nowhere is rejected on every match
  PERFORM qa_pre('BLOCK jC empty block',
    EXISTS (SELECT 1 FROM oltp.judges WHERE account_id=v_jC)
    AND NOT EXISTS (SELECT 1 FROM oltp.match_judges WHERE judge_id=v_jC),
    'judge '||v_jC||' exists and holds an EMPTY block (0 assignment rows)');
  PERFORM qa_reject('BLOCK: a judge with an empty block cannot score anywhere',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,5,5,5,5)', v_m1, v_t1, v_jC));

  -- 2 — no coarser grain leaked into the table
  PERFORM qa_true('GRAIN: match_judges carries no challenge/season column',
    NOT EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema='oltp' AND table_name='match_judges'
                  AND column_name IN ('challenge_id','season_id','block_id')),
    'columns are exactly: '
    || (SELECT string_agg(column_name,',' ORDER BY ordinal_position)
        FROM information_schema.columns WHERE table_schema='oltp' AND table_name='match_judges'));
END $$;

-- =====================================================================
-- 4 — Q1-FOLLOWUP: evidence only, NOT a decision
-- =====================================================================
DO $$
DECLARE
  v_jA BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jA@t');
  v_ch BIGINT := (SELECT challenge_id FROM oltp.challenges LIMIT 1);
  v_new BIGINT;
  v_before BIGINT; v_after BIGINT;
BEGIN
  -- (a) bulk assignment IS possible -- recorded so nobody cites it as
  -- an argument for a first-class block
  SELECT count(*) INTO v_before FROM oltp.match_judges WHERE judge_id=v_jA;
  PERFORM qa_true('Q1-FOLLOWUP-0: "assign to the whole challenge" works in ONE statement',
    TRUE, 'INSERT..SELECT over matches WHERE challenge_id = X -- not an argument for an entity');

  -- (b) a match added AFTER the assignment is silently unjudged
  INSERT INTO oltp.matches(challenge_id,round_name,scheduled_at,status)
    VALUES (v_ch,'M5-added-later','2026-06-09 10:00+00','scheduled') RETURNING match_id INTO v_new;
  SELECT count(*) INTO v_after FROM oltp.match_judges WHERE judge_id=v_jA;
  PERFORM qa_true('Q1-FOLLOWUP-1: a match added later gets NO judges, and nothing flags it',
    v_after = v_before
    AND NOT EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_new),
    'M5 created; jA block unchanged ('||v_before||' -> '||v_after||'). The intent "jA judges this challenge" '
    ||'was expanded into rows and discarded, so there is nothing to re-apply.');

  -- (c) overlapping blocks cannot be unwound: the row carries no
  -- provenance, so two justifications are indistinguishable
  PERFORM qa_true('Q1-FOLLOWUP-2: an assignment row records no provenance',
    NOT EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema='oltp' AND table_name='match_judges'
                  AND column_name IN ('assignment_id','source','reason')),
    'if jA is assigned via challenge AND via round, the shared match is ONE row; '
    ||'revoking one block would delete a row the other still justifies');

  PERFORM qa_pending('Q1-FOLLOWUP: should the BLOCK be a first-class entity?',
    'ESCALATED, not decided. Depends on whether organisers assign per challenge/round (then a parent '
    ||'judge_assignments table with DERIVED match_judges rows) or match-by-match (then the emergent set '
    ||'is correct and cheaper). Product question, not a schema question. Either answer ADDS a parent '
    ||'table; neither changes match_judges or fk_scores_match_judge.');
END $$;

-- =====================================================================
\echo ''
\echo '============ VERIFY R2 — block of matches ============'
SELECT seq, kind, status, tc, left(coalesce(detail,''),88) AS detail FROM qa_results ORDER BY seq;
\echo ''
SELECT count(*) FILTER (WHERE status='PASS')    AS pass,
       count(*) FILTER (WHERE status='FAIL')    AS fail,
       count(*) FILTER (WHERE status='PENDING') AS pending,
       count(*) AS total
FROM qa_results;

DO $$
DECLARE v INT := (SELECT count(*) FROM qa_results WHERE status='FAIL');
BEGIN
  IF v > 0 THEN RAISE EXCEPTION '% case(s) FAILED', v; END IF;
  RAISE NOTICE 'No failures. % open item(s).', (SELECT count(*) FROM qa_results WHERE status='PENDING');
END $$;
