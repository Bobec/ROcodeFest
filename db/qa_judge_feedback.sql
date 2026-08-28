-- =====================================================================
-- QA — judge feedback surface (DB layer)
-- =====================================================================
-- This project has NO API layer (no package.json, no server, no routes).
-- HTTP-level behaviour (status codes, request/response bodies, authn +
-- authz) CANNOT be executed here. Those cases are recorded as
-- PENDING-API and are never coloured green.
--
-- Three result states, deliberately distinct:
--   PASS            verified against the live database
--   FAIL            verified and wrong
--   PENDING-API     needs an API layer that does not exist yet
--   PENDING-SCHEMA  needs a schema object that does not exist yet (see
--                   db/proposals/R2_match_judges.patch.sql)
-- Only FAIL makes this script exit non-zero. A PENDING is an open item,
-- not a success.
--
-- CREDIBILITY RULE (R1): every negative case is TWO assertions --
--   1. a positive precondition proving the base state it relies on
--      actually exists, and
--   2. the rejection itself.
-- qa_reject additionally refuses to count a statement that succeeded
-- while touching ZERO rows: an INSERT..SELECT matching nothing is not a
-- passed rejection, it is a test that asserted nothing.
--
-- Run:
--   psql -d qa_judge -f db/01_oltp_schema.sql
--   psql -d qa_judge -f db/02_analytics_schema.sql
--   psql -d qa_judge -f db/03_etl.sql
--   psql -d qa_judge -f db/qa_judge_feedback.sql
-- =====================================================================

\set ON_ERROR_STOP on
SET client_min_messages = WARNING;
-- Helpers come from the shared harness. They used to be defined
-- inline here, one private copy per suite, which is why a fix to
-- qa_reject's vacuity guard reached exactly one of them.
\ir _qa_harness.sql
SELECT qa.suite('judge_feedback');

-- ---------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('qa-club@t.dev','x','club'), ('qa-m1@t.dev','x','member'),
  ('qa-j1@t.dev','x','judge'), ('qa-j2@t.dev','x','judge'), ('qa-j3@t.dev','x','judge'),
  -- j4 is on the panel and scores nowhere else, so B4's positive control
  -- can insert without colliding with a score some earlier case left behind
  ('qa-j4@t.dev','x','judge');
INSERT INTO oltp.clubs(account_id,club_name,city)
  SELECT account_id,'QA Club','Cluj' FROM oltp.accounts WHERE email='qa-club@t.dev';
INSERT INTO oltp.members(account_id,full_name)
  SELECT account_id,'QA Member' FROM oltp.accounts WHERE email='qa-m1@t.dev';
INSERT INTO oltp.judges(account_id,full_name)
  SELECT account_id,'QA Judge '||account_id FROM oltp.accounts WHERE role='judge';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'QA Team','QA-1'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
-- Second team, deliberately NOT fielded in the match. Without it the
-- composite-FK case has nothing to insert and would pass vacuously.
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'QA Team Unfielded','QA-2'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.seasons(name,start_date,end_date) VALUES ('QA Season','2026-01-01','2026-12-31');
INSERT INTO oltp.challenges(season_id,name,stage) SELECT season_id,'QA Challenge','final' FROM oltp.seasons;
INSERT INTO oltp.matches(challenge_id,round_name,scheduled_at,status)
  SELECT challenge_id,'QA R1','2026-06-01 10:00+00','completed' FROM oltp.challenges;
INSERT INTO oltp.match_teams(match_id,team_id)
  SELECT m.match_id,t.team_id FROM oltp.matches m, oltp.teams t WHERE t.participation_code='QA-1';
-- j1 and j2 are on the officiating panel; j3 is deliberately LEFT OFF so
-- B4 has an unassigned judge to reject. Seeding all three would make B4
-- pass for the wrong reason -- there would be nothing left to violate.
INSERT INTO oltp.match_judges(match_id,judge_id)
  SELECT m.match_id, a.account_id
  FROM oltp.matches m, oltp.accounts a
  WHERE a.email IN ('qa-j1@t.dev','qa-j2@t.dev','qa-j4@t.dev');
INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
  SELECT t.team_id,c.challenge_id,'QA sub v1',a.account_id,'2026-05-01 09:00+00'
  FROM oltp.teams t, oltp.challenges c, oltp.accounts a
  WHERE a.email='qa-m1@t.dev' AND t.participation_code='QA-1';

-- =====================================================================
-- =====================================================================
-- CHANNEL A — submission review  ::  MOVED
-- =====================================================================
-- This channel used to duplicate db/qa_submission_reviews.sql: both
-- tested the FK on judge_id, the member/club rejection, and the repeat
-- review. The reviews suite covers all of it and covers it better --
-- every negative there is paired, so it reported 0 lint findings while
-- this copy reported 4 unpaired rejections.
--
-- Duplicated coverage is not extra safety. It is two places to update
-- when a rule changes, and one of them will be forgotten.
--
-- Canonical suite for submission_reviews:  db/qa_submission_reviews.sql
-- This file now owns the SCORES channel and the end-to-end flow.
-- =====================================================================

-- CHANNEL B — score
-- =====================================================================
DO $$
DECLARE
  v_match BIGINT := (SELECT match_id FROM oltp.matches LIMIT 1);
  v_team  BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='QA-1');
  v_unfielded BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='QA-2');
  v_j1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='qa-j1@t.dev');
  v_j2 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='qa-j2@t.dev');
  v_j3 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='qa-j3@t.dev');
  v_j4 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='qa-j4@t.dev');
  v_m1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='qa-m1@t.dev');
  v_total SMALLINT;
BEGIN
  -- B1 happy path --------------------------------------------------------
  PERFORM qa_pre('B','B1',
    EXISTS (SELECT 1 FROM oltp.match_teams WHERE match_id=v_match AND team_id=v_team)
    AND EXISTS (SELECT 1 FROM oltp.judges WHERE account_id=v_j1),
    'team '||v_team||' IS fielded in match '||v_match||' and judge '||v_j1||' exists');
  INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score,scored_at)
    VALUES (v_match,v_team,v_j1,9,8,7,6,'2026-06-01 12:00+00');
  SELECT total_score INTO v_total FROM oltp.scores WHERE match_id=v_match AND team_id=v_team AND judge_id=v_j1;
  PERFORM qa_true('B','B1 total_score computed by the DB (9+8+7+6=30)', v_total=30, 'got '||v_total);

  -- B2 boundaries ---------------------------------------------------------
  PERFORM qa_pre('B','B2 generated',
    (SELECT is_generated FROM information_schema.columns
      WHERE table_schema='oltp' AND table_name='scores' AND column_name='total_score') = 'ALWAYS',
    'scores.total_score is declared GENERATED ALWAYS');
  PERFORM qa_reject('B','B2 total_score cannot be supplied by the caller',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score,total_score) VALUES (%s,%s,%s,1,1,1,1,4)', v_match,v_team,v_j2), '428C9');

  PERFORM qa_pre('B','B2 range',
    EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='oltp.scores'::regclass
              AND contype='c' AND conname='scores_innovation_score_check')
    AND EXISTS (SELECT 1 FROM oltp.match_teams WHERE match_id=v_match AND team_id=v_team),
    'the 1..10 CHECK exists AND the (match,team) pair is valid, so only the range can cause a rejection');
  PERFORM qa_reject('B','B2 criterion = 0 rejected',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,0,5,5,5)', v_match,v_team,v_j2), '23514');
  PERFORM qa_reject('B','B2 negative criterion rejected',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,-1,5,5,5)', v_match,v_team,v_j2), '23514');
  PERFORM qa_reject('B','B2 criterion = 11 rejected',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,11,5,5,5)', v_match,v_team,v_j2), '23514');
  PERFORM qa_accept('B','B2 boundary 1 and 10 accepted',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,1,10,1,10)', v_match,v_team,v_j2));
  PERFORM qa_pending('B','B2 smallint min/max boundary','PENDING-API',
    'Not applicable at DB level: criteria are CHECK 1..10 and total_score is generated, so smallint limits are unreachable. Range validation messages are an API concern.');

  -- B3 referential integrity ----------------------------------------------
  PERFORM qa_pre('B','B3 no such match', NOT EXISTS (SELECT 1 FROM oltp.matches WHERE match_id=999999),
    'match_id 999999 genuinely does not exist');
  PERFORM qa_reject('B','B3 nonexistent match_id rejected',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (999999,%s,%s,5,5,5,5)', v_team,v_j1), '23503');

  PERFORM qa_pre('B','B3 no such team', NOT EXISTS (SELECT 1 FROM oltp.teams WHERE team_id=999999),
    'team_id 999999 genuinely does not exist');
  PERFORM qa_reject('B','B3 nonexistent team_id rejected',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,999999,%s,5,5,5,5)', v_match,v_j1), '23503');

  PERFORM qa_pre('B','B3 unfielded team',
    v_unfielded IS NOT NULL
    AND EXISTS (SELECT 1 FROM oltp.teams WHERE team_id=v_unfielded)
    AND NOT EXISTS (SELECT 1 FROM oltp.match_teams WHERE match_id=v_match AND team_id=v_unfielded),
    'team '||coalesce(v_unfielded::text,'NONE')||' EXISTS and is NOT fielded in match '||v_match);
  PERFORM qa_reject('B','B3 team not fielded in that match rejected (composite FK)',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,5,5,5,5)', v_match,v_unfielded,v_j1), '23503');

  PERFORM qa_pre('B','B3 non-judge',
    EXISTS (SELECT 1 FROM oltp.accounts WHERE account_id=v_m1)
    AND NOT EXISTS (SELECT 1 FROM oltp.judges WHERE account_id=v_m1),
    'account '||v_m1||' exists but is not a judge');
  PERFORM qa_reject('B','B3 non-judge account cannot score',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,5,5,5,5)', v_match,v_team,v_m1), '23503');

  -- B4 judge not assigned to the match --------------------------------------
  -- Was PENDING-SCHEMA until R2 was adopted: there was no match<->judge
  -- relation to violate, so any judge could score any fielded (match,team).
  -- fk_scores_match_judge now gives the rule a parent, and the case
  -- becomes an ordinary paired negative.
  PERFORM qa_pre('B','B4 assignment table present',
    EXISTS (SELECT 1 FROM information_schema.tables
            WHERE table_schema='oltp' AND table_name='match_judges'),
    'oltp.match_judges exists (R2 adopted), so the rule has something to enforce');

  -- The pairing is what makes the rejection mean anything: j4 IS on the
  -- panel and j3 is NOT, and the two inserts are identical otherwise.
  -- If the FK were dropped, the control would still pass and the negative
  -- would go red -- which is the only way to tell a real guard from a
  -- fixture that happens to fail.
  PERFORM qa_pre('B','B4 unassigned judge',
    EXISTS (SELECT 1 FROM oltp.judges WHERE account_id=v_j3)
    AND NOT EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_match AND judge_id=v_j3),
    'judge '||v_j3||' exists and is NOT on the panel for match '||v_match);
  PERFORM qa_pair('B','B4 only an assigned judge can score',
    'identical scores differing only in whether the judge sits on the panel: j4 does, j3 does not',
    -- control: j4 is on the panel
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,3,3,3,3)', v_match,v_team,v_j4),
    -- negative: j3 is not
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,3,3,3,3)', v_match,v_team,v_j3));

  -- Removing a judge from the panel takes their scores with them: a score
  -- by someone who was never on the panel is not a record worth keeping.
  PERFORM qa_pre('B','B4 cascade',
    EXISTS (SELECT 1 FROM oltp.scores WHERE match_id=v_match AND judge_id=v_j4),
    'judge '||v_j4||' has a score on match '||v_match||' for the delete to cascade to');
  DELETE FROM oltp.match_judges WHERE match_id=v_match AND judge_id=v_j4;
  PERFORM qa_true('B','B4 de-assigning a judge cascades to their scores',
    NOT EXISTS (SELECT 1 FROM oltp.scores WHERE match_id=v_match AND judge_id=v_j4),
    'scores by judge '||v_j4||' on match '||v_match||' are gone');
  -- put the panel back: Channel C runs after this
  INSERT INTO oltp.match_judges(match_id,judge_id) VALUES (v_match,v_j4);

  -- B5 duplicate score --------------------------------------------------------
  PERFORM qa_pre('B','B5',
    EXISTS (SELECT 1 FROM oltp.scores WHERE match_id=v_match AND team_id=v_team AND judge_id=v_j1),
    'a score by judge '||v_j1||' on ('||v_match||','||v_team||') already exists to collide with');
  PERFORM qa_reject('B','B5 duplicate score by the same judge BLOCKED',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,%s,%s,4,4,4,4)', v_match,v_team,v_j1), '23505');
  PERFORM qa_accept('B','B5 revising a score is an UPDATE, and it is allowed',
    format('UPDATE oltp.scores SET innovation_score=10 WHERE match_id=%s AND team_id=%s AND judge_id=%s', v_match,v_team,v_j1));
  SELECT total_score INTO v_total FROM oltp.scores WHERE match_id=v_match AND team_id=v_team AND judge_id=v_j1;
  PERFORM qa_true('B','B5 total_score recomputed after the revision (10+8+7+6=31)', v_total=31, 'got '||v_total);
END $$;

-- =====================================================================
-- CHANNEL C — end-to-end
-- =====================================================================
DO $$
DECLARE
  v_match BIGINT := (SELECT match_id FROM oltp.matches LIMIT 1);
  v_team  BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='QA-1');
  v_j1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='qa-j1@t.dev');
  v_m1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='qa-m1@t.dev');
  v_score BIGINT; v_appeal BIGINT; v_notif BIGINT;
  v_subs BIGINT; v_facts BIGINT; v_reviews BIGINT;
BEGIN
  SELECT score_id INTO v_score FROM oltp.scores WHERE judge_id=v_j1 LIMIT 1;
  PERFORM qa_pre('C','C1', v_score IS NOT NULL, 'a score by judge '||v_j1||' exists to be appealed');

  INSERT INTO oltp.appeals(team_id,match_id,score_id,filed_by_account_id,reason,created_at)
    VALUES (v_team,v_match,v_score,v_m1,'Scoring seems off','2026-06-02 09:00+00')
    RETURNING appeal_id INTO v_appeal;
  PERFORM qa_true('C','C1 appeal attaches to the exact score being disputed',
    (SELECT score_id FROM oltp.appeals WHERE appeal_id=v_appeal)=v_score, 'appeal_id='||v_appeal);
  -- Closing an appeal takes the full form since R7: a judge, a time, and
  -- the rule the verdict rests on. This case is about the end-to-end
  -- flow, so it uses whichever rule the fixture has -- the closure rule
  -- itself is owned by qa_lifecycle group A.
  INSERT INTO oltp.rule_sections(code,title) VALUES ('QA','QA section');
  INSERT INTO oltp.rules(section_id,code,title,body)
    SELECT section_id,'QA1','Scoring rule','text' FROM oltp.rule_sections WHERE code='QA';
  PERFORM qa_accept('C','C1 the appeal can be decided (judge, time and rule recorded)',
    format('UPDATE oltp.appeals SET status=''accepted'', decided_at=now(), decided_by_account_id=%s, '
           ||'decided_under_rule_id=(SELECT rule_id FROM oltp.rules WHERE code=''QA1'') '
           ||'WHERE appeal_id=%s', v_j1, v_appeal));
  PERFORM qa_accept('C','C1 judge revises the disputed score after the appeal',
    format('UPDATE oltp.scores SET execution_score=9 WHERE score_id=%s', v_score));
  PERFORM qa_true('C','C1 the revision did NOT create a second score row',
    (SELECT count(*) FROM oltp.scores WHERE score_id=v_score)=1, 'UPDATE in place');

  INSERT INTO oltp.notifications(recipient_account_id,title) VALUES (v_m1,'Appeal accepted')
    RETURNING notification_id INTO v_notif;
  PERFORM qa_accept('C','C1 appeal outcome can be linked to a notification',
    format('INSERT INTO oltp.notification_appeal_links(notification_id,event_type,appeal_id) VALUES (%s,''appeal_accepted'',%s)', v_notif, v_appeal));

  -- C2 fan-out ------------------------------------------------------------
  -- C2 builds its OWN multi-reviewer submission. It used to rely on the
  -- reviews left behind by channel A; when channel A moved out to
  -- qa_submission_reviews.sql this precondition went red -- correctly,
  -- and that is how the coupling was found. A test whose premise is a
  -- side effect of another test is a test that will break for reasons
  -- unrelated to what it checks.
  INSERT INTO oltp.submission_reviews(submission_id, judge_id, feedback, reviewed_at)
  SELECT s.submission_id, j.account_id, 'fan-out fixture', now()
  FROM oltp.submissions s, oltp.judges j
  WHERE s.title = 'QA sub v1'
  ON CONFLICT (submission_id, judge_id) DO NOTHING;

  PERFORM analytics.run_etl();
  SELECT count(*) INTO v_subs    FROM oltp.submissions;
  SELECT count(*) INTO v_facts   FROM analytics.fact_submissions;
  SELECT count(*) INTO v_reviews FROM oltp.submission_reviews;
  PERFORM qa_pre('C','C2', v_reviews > v_subs,
    v_reviews||' reviews over '||v_subs||' submissions -- a naive join WOULD inflate, so the check is meaningful');
  PERFORM qa_true('C','C2 fact_submissions has exactly one row per submission',
    v_facts = v_subs, format('%s facts vs %s submissions', v_facts, v_subs));
  PERFORM qa_true('C','C2 natural key holds: COUNT(*) = COUNT(DISTINCT source_submission_id)',
    (SELECT count(*) FROM analytics.fact_submissions)
      = (SELECT count(DISTINCT source_submission_id) FROM analytics.fact_submissions), NULL);
END $$;

-- =====================================================================
-- Report -- identical shape in every suite, from the shared harness.
-- =====================================================================
-- E — the R2 assignment table at depth
-- =====================================================================
-- B4 tests match_judges through the one case that motivated it: an
-- unassigned judge cannot score. The table itself -- its key, its two
-- FKs, and what happens to a panel when a match goes away -- had no
-- coverage at all. Those are the parts a reader assumes are fine
-- precisely because the interesting rule above them passes.
-- =====================================================================
DO $$
DECLARE
  v_match BIGINT := (SELECT match_id FROM oltp.matches LIMIT 1);
  v_j3 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='qa-j3@t.dev');
  v_m1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='qa-m1@t.dev');
  v_chal BIGINT := (SELECT challenge_id FROM oltp.challenges LIMIT 1);
  v_m2 BIGINT; v_team BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='QA-1');
  v_panel INT; v_scores INT;
BEGIN
  PERFORM qa_pre('E','E1 j3 is not yet on this panel',
    NOT EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_match AND judge_id=v_j3),
    'so the first insert below is a real assignment and not a no-op');
  PERFORM qa_pair('E','E1 a judge cannot be assigned to the same match twice',
    'the composite PK makes the (match, judge) pair itself the recorded fact',
    format('INSERT INTO oltp.match_judges(match_id,judge_id) VALUES (%s,%s)', v_match, v_j3),
    format('INSERT INTO oltp.match_judges(match_id,judge_id) VALUES (%s,%s)', v_match, v_j3));

  PERFORM qa_pre('E','E2 an account exists that is not a judge',
    EXISTS (SELECT 1 FROM oltp.accounts WHERE account_id=v_m1)
    AND NOT EXISTS (SELECT 1 FROM oltp.judges WHERE account_id=v_m1),
    'account '||v_m1||' is a member, so only the judges FK can refuse it');
  PERFORM qa_reject('E','E2 a non-judge account cannot sit on a panel',
    format('INSERT INTO oltp.match_judges(match_id,judge_id) VALUES (%s,%s)', v_match, v_m1),
    '23503');
  PERFORM qa_reject('E','E2 nor can a panel exist for a match that does not',
    format('INSERT INTO oltp.match_judges(match_id,judge_id) VALUES (999999,%s)', v_j3),
    '23503');

  -- E3 deleting the MATCH, not the assignment. B4 covered the other
  -- direction (de-assigning a judge takes their scores). This is the
  -- two-hop cascade: match -> panel -> scores, and nothing tests that a
  -- cancelled match leaves no orphaned panel behind.
  -- 'completed', not 'scheduled': R7 refuses scores on a match that has
  -- not been played, and E3 is about the CASCADE, not about match state.
  -- A scheduled match here would fail for a reason this case is not testing.
  INSERT INTO oltp.matches(challenge_id,round_name,status)
    VALUES (v_chal,'QA R2 (to be cancelled)','completed') RETURNING match_id INTO v_m2;
  INSERT INTO oltp.match_teams(match_id,team_id) VALUES (v_m2, v_team);
  INSERT INTO oltp.match_judges(match_id,judge_id) VALUES (v_m2, v_j3);
  INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score)
    VALUES (v_m2, v_team, v_j3, 5,5,5,5);

  SELECT count(*) INTO v_panel  FROM oltp.match_judges WHERE match_id=v_m2;
  SELECT count(*) INTO v_scores FROM oltp.scores       WHERE match_id=v_m2;
  PERFORM qa_pre('E','E3 the doomed match has a panel and a score',
    v_panel = 1 AND v_scores = 1,
    format('match %s: %s panel row, %s score -- both must go', v_m2, v_panel, v_scores));

  DELETE FROM oltp.matches WHERE match_id = v_m2;
  PERFORM qa_true('E','E3 cancelling a match clears its panel and its scores',
    'an assignment to a match that no longer exists is not a record worth keeping',
    NOT EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_m2)
    AND NOT EXISTS (SELECT 1 FROM oltp.scores WHERE match_id=v_m2),
    'panel and scores both gone with the match');

  PERFORM qa_true('E','E3 the other match was untouched',
    'a cascade that reached further than the deleted row would pass the assertion above too',
    EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_match),
    (SELECT count(*)::text||' judge(s) still on the original panel'
       FROM oltp.match_judges WHERE match_id=v_match));
END $$;


-- =====================================================================
\echo ''
\echo '===================== RESULTS ====================='
SELECT seq, grp, status, kind, tc, intent FROM qa.results ORDER BY seq;
\echo ''
\echo '--- control + result, per case ---'
SELECT seq, grp, status, control, result FROM qa.results ORDER BY seq;
\echo ''
SELECT * FROM qa_summary();
\echo ''
\echo '--- harness lint (method hygiene, not schema findings) ---'
SELECT * FROM qa_lint();
\echo ''
\echo '========== SCHEMA GAPS DISCOVERED =========='
SELECT seq, grp, tc, result FROM qa.results WHERE status='GAP' ORDER BY seq;
SELECT qa_finish();
