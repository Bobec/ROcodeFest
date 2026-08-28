-- =====================================================================
-- QA — the analytics star schema and the ETL that fills it
-- =====================================================================
-- Until now this half of the database had almost no coverage. Four of
-- eleven suites LOADED 02_/03_, but 03_etl.sql only installs functions --
-- nothing called analytics.run_etl(), so no suite had ever looked at a
-- populated warehouse. vw_leaderboard and vw_team_season_progress had
-- zero assertions of any kind.
--
-- That matters more here than it would elsewhere: the worst defect this
-- project has found so far (the chasm trap, 35x on a small fixture and
-- 678x at scale) lived in exactly this layer. It is the half where a
-- wrong answer looks like a plausible answer, because nobody can tell
-- by eye that a number is 3x too large.
--
-- The fixture is therefore built to make grain errors VISIBLE:
--   * one match scored by THREE judges  -> any per-score count that
--     claims to be a per-match count reads 3 instead of 1
--   * one team that submits NOTHING     -> any INNER JOIN silently
--     drops the row that matters most
--   * challenges in TWO categories      -> any denominator that ignores
--     eligibility dilutes the percentage
--   * two versions of one submission    -> any count that forgets
--     DISTINCT inflates participation
--
--   psql -d qa_an -f db/01_oltp_schema.sql
--   psql -d qa_an -f db/02_analytics_schema.sql
--   psql -d qa_an -f db/03_etl.sql
--   psql -d qa_an -f db/qa_analytics.sql
-- =====================================================================

\set ON_ERROR_STOP on
\ir _qa_harness.sql
SELECT qa.suite('analytics');

-- ---------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('anc@t','x','club'), ('anm@t','x','member'),
  ('anj1@t','x','judge'), ('anj2@t','x','judge'), ('anj3@t','x','judge'),
  -- a judge who does nothing at all, and a club with no activity. Both
  -- exist to prove the reporting views still list them: a dimension row
  -- with no facts is the row an INNER JOIN drops, and P1 showed that is
  -- not a hypothetical concern in this warehouse.
  ('anj4@t','x','judge'), ('anc2@t','x','club');
INSERT INTO oltp.clubs(account_id,club_name)   SELECT account_id,'AnClub'  FROM oltp.accounts WHERE email='anc@t';
INSERT INTO oltp.clubs(account_id,club_name)   SELECT account_id,'IdleClub' FROM oltp.accounts WHERE email='anc2@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,'AnMember' FROM oltp.accounts WHERE email='anm@t';
INSERT INTO oltp.judges(account_id,full_name)  SELECT account_id,'AnJudge '||email FROM oltp.accounts WHERE role='judge';

-- SCORED plays and is judged; SILENT exists and does nothing. The second
-- one is the whole point: a team at 0% is the row a progress report is
-- FOR, and it is the row an INNER JOIN removes.
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'ScoredTeam','AN-1'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS' AND c.club_name='AnClub';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'SilentTeam','AN-2'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS' AND c.club_name='AnClub';

INSERT INTO oltp.seasons(name,start_date) VALUES ('AnSeason','2026-01-01');

-- two challenges the ROBOTICS teams may enter, one they may not
INSERT INTO oltp.challenges(season_id,name,stage)
  SELECT s.season_id, n, 'final' FROM oltp.seasons s, (VALUES ('AN-CH1'),('AN-CH2')) AS c(n);
INSERT INTO oltp.challenges(season_id,name,stage,category_id)
  SELECT s.season_id,'AN-CH-OTHER','final', tc.category_id
  FROM oltp.seasons s, oltp.team_categories tc WHERE tc.code <> 'ROBOTICS' ORDER BY tc.category_id LIMIT 1;

INSERT INTO oltp.matches(challenge_id,round_name,status,scheduled_at)
  SELECT challenge_id,'AN R1','completed','2026-06-01 10:00+00' FROM oltp.challenges WHERE name='AN-CH1';
INSERT INTO oltp.match_teams(match_id,team_id)
  SELECT m.match_id,t.team_id FROM oltp.matches m, oltp.teams t WHERE t.participation_code='AN-1';
-- anj4 is deliberately left OFF the panel. It exists only to prove that a
-- judge with no activity at all still appears in vw_judge_workload at
-- zero rather than being dropped -- which is the failure P1 records on
-- the other view.
INSERT INTO oltp.match_judges(match_id,judge_id)
  SELECT m.match_id,a.account_id FROM oltp.matches m, oltp.accounts a
  WHERE a.email IN ('anj1@t','anj2@t','anj3@t');

-- ONE match, THREE judges. This is the grain trap, set deliberately.
INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score,scored_at)
  SELECT m.match_id,t.team_id,a.account_id,8,8,8,8,'2026-06-01 12:00+00'
  FROM oltp.matches m, oltp.teams t, oltp.accounts a
  WHERE t.participation_code='AN-1' AND a.email IN ('anj1@t','anj2@t','anj3@t');

-- ScoredTeam submits to ONE of its two eligible challenges, and revises
-- it. Two versions of one submission must not count as two challenges.
INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
  SELECT t.team_id,c.challenge_id,'AN sub v1',a.account_id,'2026-05-01 09:00+00'
  FROM oltp.teams t, oltp.challenges c, oltp.accounts a
  WHERE t.participation_code='AN-1' AND c.name='AN-CH1' AND a.email='anm@t';
-- TWO reviewers on the same submission, with explicit assigned_at so the
-- order is deterministic. The ETL keeps one judge per submission --
-- DISTINCT ON (submission_id) ORDER BY assigned_at, judge_id -- which is
-- the right fix for fan-out but means the SECOND reviewer is not carried
-- into the warehouse at all. Group J is about what that costs.
INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission,feedback,assigned_at,reviewed_at)
  SELECT s.submission_id, a.account_id, TRUE, 'needs rework', '2026-05-02 09:00+00', now()
  FROM oltp.submissions s, oltp.accounts a WHERE a.email='anj1@t';
INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission,feedback,assigned_at,reviewed_at)
  SELECT s.submission_id, a.account_id, FALSE, 'looks fine to me', '2026-05-03 09:00+00', now()
  FROM oltp.submissions s, oltp.accounts a WHERE a.email='anj2@t';
INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
  SELECT t.team_id,c.challenge_id,'AN sub v2',a.account_id,'2026-05-08 09:00+00'
  FROM oltp.teams t, oltp.challenges c, oltp.accounts a
  WHERE t.participation_code='AN-1' AND c.name='AN-CH1' AND a.email='anm@t';

-- TWO appeals about the same round, filed the two ways the schema allows:
-- one against a specific SCORE, one against the MATCH. They are otherwise
-- identical. Group F is about the fact that only one of them reaches the
-- funnel.
INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason,score_id)
  SELECT t.team_id, a.account_id, 'disputed score',
         (SELECT sc.score_id FROM oltp.scores sc
            JOIN oltp.accounts j ON j.account_id = sc.judge_id
           WHERE j.email='anj1@t' LIMIT 1)
  FROM oltp.teams t, oltp.accounts a
  WHERE t.participation_code='AN-1' AND a.email='anm@t';
INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason,match_id)
  SELECT t.team_id, a.account_id, 'disputed match',
         (SELECT match_id FROM oltp.matches LIMIT 1)
  FROM oltp.teams t, oltp.accounts a
  WHERE t.participation_code='AN-1' AND a.email='anm@t';

SELECT analytics.run_etl();


-- =====================================================================
-- L — vw_leaderboard
-- =====================================================================
DO $$
DECLARE
  v_matches INT; v_scorerows INT; v_reported INT;
  v_total BIGINT; v_avg NUMERIC; v_count INT;
BEGIN
  SELECT count(DISTINCT match_id), count(*) INTO v_matches, v_scorerows FROM oltp.scores;
  -- Recorded as PREMISES, not as assertions. If the trap is not set, or
  -- the view is empty, the GAP below proves nothing -- and the report has
  -- to say so rather than showing a passed test next to a finding that
  -- rests on it.
  PERFORM qa_pre('L','L0 the grain trap is actually set',
    v_matches = 1 AND v_scorerows = 3,
    format('%s distinct match scored by %s judges -- a per-score count and a per-match '
           ||'count must differ, or L1 cannot detect anything', v_matches, v_scorerows));

  PERFORM qa_pre('L','L1 the leaderboard returns the team at all',
    (SELECT count(*) FROM analytics.vw_leaderboard WHERE team_name='ScoredTeam') = 1,
    (SELECT format('ScoredTeam: %s scored_matches, %s total, %s avg',
       scored_matches, total_score, avg_score)
     FROM analytics.vw_leaderboard WHERE team_name='ScoredTeam'));

  SELECT scored_matches, total_score, avg_score INTO v_reported, v_total, v_avg
    FROM analytics.vw_leaderboard WHERE team_name='ScoredTeam';

  PERFORM qa_gap('L','L1-GAP scored_matches counts SCORES, not matches',
    'does the column mean what its name says?',
    format('the team was scored in %s match by %s judges; the view reports scored_matches = %s',
           v_matches, v_scorerows, v_reported),
    'fact_scores has one row per (match, team, judge), so count(*) is a count of VERDICTS. '
    ||'A team judged by a three-judge panel appears to have played three times as many matches '
    ||'as one judged by a single judge, and the leaderboard is the most-read object in the '
    ||'warehouse. Worse, the correct value is NOT RECOVERABLE here: fact_scores carries no '
    ||'match_key and there is no dim_match, so match identity is dropped during the ETL. This '
    ||'is not a view fix -- it needs the grain carried into the fact table.');

  -- the view IS internally coherent, which is why nobody caught it: the
  -- three numbers agree with each other at the score grain
  PERFORM qa_true('L','L2 the three columns agree with each other at the SCORE grain',
    'the mislabel is invisible from inside the view -- total/count really does equal avg',
    round(v_total::numeric / v_reported, 1) = v_avg,
    format('%s / %s = %s, which matches avg_score exactly', v_total, v_reported, v_avg));

  PERFORM qa_note('L','L2-NOTE why this survived review',
    'a wrong number that is self-consistent',
    'Every internal check passes: the sum divided by the count equals the average, the ordering '
    ||'is sensible, and the row count is right. Only comparing against the SOURCE reveals it. '
    ||'That is the argument for testing warehouse views against OLTP truth rather than against '
    ||'themselves.');

  -- and confirm the fix is genuinely blocked, rather than merely not done
  SELECT count(*) INTO v_count FROM information_schema.columns
   WHERE table_schema='analytics' AND table_name='fact_scores' AND column_name LIKE '%match%';
  PERFORM qa_true('L','L3 the warehouse cannot answer "how many matches" at all',
    'sizing the fix: is this a view change or a schema change?',
    v_count = 0
    AND NOT EXISTS (SELECT 1 FROM information_schema.tables
                    WHERE table_schema='analytics' AND table_name='dim_match'),
    'fact_scores has no match column and there is no dim_match, so no rewrite of the view can '
    ||'produce the right number');
END $$;


-- =====================================================================
-- P — vw_team_season_progress
-- =====================================================================
DO $$
DECLARE
  v_eligible INT; v_denominator INT; v_pct NUMERIC; v_versions INT;
BEGIN
  -- P1 the row that matters most is the one that is missing
  PERFORM qa_pre('P','P1 SilentTeam exists and has submitted nothing',
    EXISTS (SELECT 1 FROM oltp.teams WHERE participation_code='AN-2')
    AND NOT EXISTS (SELECT 1 FROM oltp.submissions s JOIN oltp.teams t USING (team_id)
                    WHERE t.participation_code='AN-2'),
    'SilentTeam is registered and has 0 submissions -- a 0% row can only be missed if '
    ||'there is a team that should produce one');

  -- Was P1-GAP: the view was DRIVEN from fact_submissions, so a team that
  -- had submitted nothing produced no row and was reported as absent
  -- rather than as 0%. The teams furthest behind were exactly the ones it
  -- omitted, and an empty entry reads as "no data" rather than "no work".
  -- R8 drives it from dim_team instead.
  PERFORM qa_true('P','P1 a team with zero submissions appears at 0%',
    'the row a progress report exists for is the one an INNER JOIN removed',
    (SELECT progress_pct FROM analytics.vw_team_season_progress
      WHERE team_name='SilentTeam') = 0,
    (SELECT format('SilentTeam: %s of %s challenge(s), %s%%',
       submitted_challenges, total_challenges, progress_pct)
       FROM analytics.vw_team_season_progress WHERE team_name='SilentTeam'));

  PERFORM qa_true('P','P1 every team in the dimension now has a row',
    'a report that quietly drops teams is worse than one that shows zeros',
    (SELECT count(DISTINCT team_key) FROM analytics.vw_team_season_progress)
      = (SELECT count(*) FROM analytics.dim_team),
    format('%s of %s team(s) listed',
      (SELECT count(DISTINCT team_key) FROM analytics.vw_team_season_progress),
      (SELECT count(*) FROM analytics.dim_team)));

  -- P2 the denominator counts challenges the team may not enter
  SELECT count(*) INTO v_eligible FROM oltp.challenges c
   WHERE c.category_id IS NULL
      OR c.category_id = (SELECT category_id FROM oltp.teams WHERE participation_code='AN-1');
  SELECT total_challenges, progress_pct INTO v_denominator, v_pct
    FROM analytics.vw_team_season_progress WHERE team_name='ScoredTeam';

  PERFORM qa_pre('P','P2 the season holds a challenge this team cannot enter',
    (SELECT count(*) FROM oltp.challenges WHERE name='AN-CH-OTHER'
      AND category_id IS DISTINCT FROM (SELECT category_id FROM oltp.teams WHERE participation_code='AN-1')) = 1,
    'AN-CH-OTHER is scoped to another category than ScoredTeam -- without an out-of-category '
    ||'challenge the denominator cannot be shown to be wrong');

  -- Was P2-GAP: the denominator counted EVERY challenge in the season
  -- regardless of category, while challenges.category_id exists precisely
  -- to scope them -- so a team was measured against work it is not
  -- allowed to do, and its progress fell whenever an unrelated category
  -- added a challenge. A number that gets worse on its own.
  PERFORM qa_true('P','P2 the denominator counts only eligible challenges',
    'a team must not be measured against work it cannot enter',
    v_denominator = v_eligible,
    format('ScoredTeam may enter %s challenge(s) and the view divides by %s, reporting %s%%',
           v_eligible, v_denominator, v_pct));

  PERFORM qa_true('P','P2 the out-of-category challenge is excluded specifically',
    'the control for the count above: the season really does hold one the team cannot enter',
    (SELECT count(*) FROM oltp.challenges WHERE name='AN-CH-OTHER') = 1
    AND v_denominator < (SELECT count(*) FROM oltp.challenges),
    format('the season holds %s challenge(s) in total and %s count for this team',
      (SELECT count(*) FROM oltp.challenges), v_denominator));

  -- P3 what the view gets RIGHT, asserted so it cannot regress
  SELECT count(*) INTO v_versions FROM oltp.submissions s
    JOIN oltp.teams t USING (team_id) WHERE t.participation_code='AN-1';
  PERFORM qa_true('P','P3 two versions of one submission count as ONE challenge',
    'count(DISTINCT challenge_key) is load-bearing -- without it a revision inflates participation',
    v_versions = 2
    AND (SELECT submitted_challenges FROM analytics.vw_team_season_progress
          WHERE team_name='ScoredTeam') = 1,
    format('%s submission rows across 1 challenge, reported as 1', v_versions));
END $$;


-- =====================================================================
-- E — the ETL contract
-- =====================================================================
-- 03_etl.sql states three rules as load-bearing. All three were
-- unverified: no suite had ever called run_etl(), let alone called it
-- twice. A documented invariant nobody exercises is a comment.
-- =====================================================================
DO $$
DECLARE
  v_h1 TEXT; v_h2 TEXT; v_n1 TEXT; v_n2 TEXT;
  v_sent_j BIGINT; v_sent_c BIGINT; v_key BIGINT; v_key2 BIGINT;
BEGIN
  -- E1 IDEMPOTENT
  SELECT md5(string_agg(x,'|' ORDER BY x)) INTO v_h1 FROM (
    SELECT fact_score_id||':'||team_key||':'||total_score AS x FROM analytics.fact_scores
    UNION ALL SELECT team_key||':'||team_name FROM analytics.dim_team
    UNION ALL SELECT challenge_key||':'||challenge_name FROM analytics.dim_challenge
    UNION ALL SELECT fact_submission_id||':'||team_key FROM analytics.fact_submissions) z;
  SELECT count(*)::text FROM analytics.fact_scores INTO v_n1;

  PERFORM analytics.run_etl();
  PERFORM analytics.run_etl();

  SELECT md5(string_agg(x,'|' ORDER BY x)) INTO v_h2 FROM (
    SELECT fact_score_id||':'||team_key||':'||total_score AS x FROM analytics.fact_scores
    UNION ALL SELECT team_key||':'||team_name FROM analytics.dim_team
    UNION ALL SELECT challenge_key||':'||challenge_name FROM analytics.dim_challenge
    UNION ALL SELECT fact_submission_id||':'||team_key FROM analytics.fact_submissions) z;
  SELECT count(*)::text FROM analytics.fact_scores INTO v_n2;

  PERFORM qa_true('E','E1 running the ETL three times leaves the warehouse identical',
    'the UPSERT-on-natural-key design claims this; re-running a loader is routine, not exotic',
    v_h1 = v_h2 AND v_n1 = v_n2,
    format('%s fact_scores before, %s after; content hash %s',
      v_n1, v_n2, CASE WHEN v_h1 = v_h2 THEN 'unchanged' ELSE 'CHANGED' END));

  -- E2 NEVER TRUNCATE -- the sentinels must survive a reload
  SELECT count(*) INTO v_sent_j FROM analytics.dim_judge WHERE judge_key = -1;
  SELECT count(*) INTO v_sent_c FROM analytics.dim_challenge WHERE challenge_key = -1;
  PERFORM qa_true('E','E2 the sentinel rows survive repeated loads',
    'a TRUNCATE would drop them and the IDENTITY sequence would hand -1 to a real row, '
    ||'silently repointing every fact that referenced the sentinel',
    v_sent_j = 1 AND v_sent_c = 1,
    format('judge_key=-1 present: %s, challenge_key=-1 present: %s', v_sent_j, v_sent_c));

  PERFORM qa_true('E','E2 the sentinels carry a NULL natural key',
    'that is WHY no upsert can match them -- the mechanism, not just the outcome',
    (SELECT judge_id FROM analytics.dim_judge WHERE judge_key=-1) IS NULL
    AND (SELECT challenge_id FROM analytics.dim_challenge WHERE challenge_key=-1) IS NULL,
    'both sentinels have a NULL source id, so ON CONFLICT cannot reach them');

  -- E3 SURROGATE KEYS ARE STABLE across a Type 1 overwrite
  SELECT team_key INTO v_key FROM analytics.dim_team WHERE team_name='ScoredTeam';
  UPDATE oltp.teams SET team_name = 'ScoredTeam Renamed' WHERE participation_code='AN-1';
  PERFORM analytics.run_etl();
  SELECT team_key INTO v_key2 FROM analytics.dim_team WHERE participation_code='AN-1';

  PERFORM qa_true('E','E3 a renamed team keeps its surrogate key',
    'facts loaded in an earlier run must stay attached when a dimension attribute changes',
    v_key = v_key2,
    format('team_key %s before the rename, %s after', v_key, v_key2));

  PERFORM qa_true('E','E3 the new name did land (the rename was not simply ignored)',
    'without this control, E3 would pass just as well if the ETL never updated anything',
    (SELECT team_name FROM analytics.dim_team WHERE participation_code='AN-1') = 'ScoredTeam Renamed',
    'dim_team now reads the new name under the same key');

  PERFORM qa_true('E','E3 the facts still point at that key',
    'a stable key is only worth anything if the facts kept using it',
    (SELECT count(*) FROM analytics.fact_scores WHERE team_key = v_key) = 3,
    format('%s fact_scores row(s) still attached to team_key %s',
      (SELECT count(*) FROM analytics.fact_scores WHERE team_key = v_key), v_key));

  UPDATE oltp.teams SET team_name = 'ScoredTeam' WHERE participation_code='AN-1';
  PERFORM analytics.run_etl();
END $$;


-- =====================================================================
-- J — vw_judge_workload
-- =====================================================================
-- Three of the six reporting views had almost no assertions. This group
-- and the two below close that, and they are written the same way L and
-- P were: compare the view against OLTP truth, never against itself.
-- =====================================================================
DO $$
DECLARE
  v_j1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='anj1@t');
  v_j2 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='anj2@t');
  v_real INT; v_reported BIGINT; v_scores BIGINT;
BEGIN
  PERFORM qa_pre('J','J0 one submission carries TWO reviewers',
    (SELECT count(*) FROM oltp.submission_reviews sr
      JOIN oltp.submissions s USING (submission_id) WHERE s.version=1) = 2,
    'anj1 was assigned first and anj2 second, so a "one judge per submission" rule has to drop one');

  -- J1 the finding: the column name promises more than the grain holds
  SELECT count(DISTINCT sr.submission_id) INTO v_real
    FROM oltp.submission_reviews sr WHERE sr.judge_id = v_j2;
  SELECT submissions_reviewed INTO v_reported
    FROM analytics.vw_judge_workload w JOIN analytics.dim_judge d USING (judge_key)
   WHERE d.judge_id = v_j2;

  PERFORM qa_gap('J','J1-GAP submissions_reviewed counts only the FIRST-assigned reviewer',
    'does the column mean what its name says?',
    format('judge %s reviewed %s submission(s) in OLTP; the view reports submissions_reviewed = %s',
           v_j2, v_real, v_reported),
    'fact_submissions keeps one row per submission and picks its judge with '
    ||'DISTINCT ON (submission_id) ORDER BY assigned_at, judge_id. That is the CORRECT fix for '
    ||'fan-out -- without it every extra reviewer would inflate submission counts -- but it means '
    ||'the fact carries the first-assigned reviewer only, and a second reviewer''s work is absent '
    ||'from the warehouse entirely. The column therefore reports "submissions where this judge was '
    ||'assigned first", not "submissions reviewed". Same shape as L1: the number is defensible, the '
    ||'NAME is not, and no rewrite of the view can recover the missing reviewers -- it needs a '
    ||'bridge table at the (submission, judge) grain.');

  PERFORM qa_true('J','J1 the first-assigned reviewer IS reported',
    'the control: the mechanism works exactly as designed for the judge it does keep',
    (SELECT submissions_reviewed FROM analytics.vw_judge_workload w
       JOIN analytics.dim_judge d USING (judge_key) WHERE d.judge_id = v_j1) = 1,
    'anj1, assigned first, shows 1 submission');

  -- J2 what the view gets right, asserted so it cannot regress
  SELECT count(*) INTO v_scores FROM oltp.scores WHERE judge_id = v_j1;
  PERFORM qa_true('J','J2 scores_given matches OLTP exactly',
    'this column IS named for what it counts, and the pre-aggregated CTE keeps it from inflating',
    (SELECT scores_given FROM analytics.vw_judge_workload w
       JOIN analytics.dim_judge d USING (judge_key) WHERE d.judge_id = v_j1) = v_scores,
    format('OLTP holds %s score(s) by anj1, and the view agrees', v_scores));

  PERFORM qa_true('J','J2 a judge present in THREE facts is not inflated',
    'the chasm trap: anj1 has scores, a submission and an appeal against them',
    (SELECT scores_given FROM analytics.vw_judge_workload w
       JOIN analytics.dim_judge d USING (judge_key) WHERE d.judge_id = v_j1) = v_scores
    AND (SELECT appeals_against_their_scores FROM analytics.vw_judge_workload w
           JOIN analytics.dim_judge d USING (judge_key) WHERE d.judge_id = v_j1) = 1,
    format('scores_given stayed %s and appeals stayed 1 -- a naive three-fact join would have '
           ||'multiplied both', v_scores));

  PERFORM qa_true('J','J3 an idle judge still appears, at zero',
    'the LEFT JOIN from dim_judge -- the failure P1 records on the other view',
    (SELECT scores_given = 0 AND submissions_reviewed = 0 AND appeals_against_their_scores = 0
       FROM analytics.vw_judge_workload w JOIN analytics.dim_judge d USING (judge_key)
      WHERE d.judge_id = (SELECT account_id FROM oltp.accounts WHERE email='anj4@t')),
    'anj4 judged nothing and is listed with zeros rather than omitted');

  PERFORM qa_true('J','J4 the sentinel judge is excluded',
    'judge_key = -1 stands for "unknown", and an unknown judge has no workload to report',
    NOT EXISTS (SELECT 1 FROM analytics.vw_judge_workload WHERE judge_key = -1)
    AND EXISTS (SELECT 1 FROM analytics.dim_judge WHERE judge_key = -1),
    'the sentinel exists in the dimension and is filtered out of the view');
END $$;


-- =====================================================================
-- K — vw_partner_club_summary
-- =====================================================================
DO $$
DECLARE v_total BIGINT; v_idle BIGINT;
BEGIN
  SELECT sum(total_score) INTO v_total FROM oltp.scores;
  PERFORM qa_true('K','K1 total_score matches the OLTP sum exactly',
    'three facts share club_key, so this is where a chasm inflation would show',
    (SELECT total_score FROM analytics.vw_partner_club_summary WHERE club_name='AnClub') = v_total,
    format('OLTP sums to %s and the view reports the same', v_total));

  PERFORM qa_true('K','K1 an idle club appears at zero rather than vanishing',
    'the LEFT JOIN from dim_club',
    (SELECT total_score = 0 AND submissions = 0 AND valid_appeals = 0
       FROM analytics.vw_partner_club_summary WHERE club_name='IdleClub'),
    'IdleClub registered, did nothing, and is still listed');

  PERFORM qa_true('K','K1 every club in the dimension is present',
    'a summary that quietly drops rows is worse than one that reports zeros',
    (SELECT count(*) FROM analytics.vw_partner_club_summary)
      = (SELECT count(*) FROM analytics.dim_club),
    format('%s of %s club(s) listed',
      (SELECT count(*) FROM analytics.vw_partner_club_summary),
      (SELECT count(*) FROM analytics.dim_club)));

  PERFORM qa_note('K','K2-NOTE the view is named for partners and contains none',
    'a naming question for the reviewer, not a defect',
    'vw_partner_club_summary selects from dim_club and the three facts; no partner table, column '
    ||'or filter appears anywhere in it. Every club is returned, not the clubs a given partner '
    ||'sponsors. Read as "the club summary a partner is shown" the name is defensible; read as '
    ||'"clubs per partner" it is wrong, and the two readings differ in what the page built on it '
    ||'would display. Recorded rather than changed, because renaming a shipped view is a decision.');
END $$;


-- =====================================================================
-- F — vw_challenge_funnel
-- =====================================================================
DO $$
DECLARE v_sub BIGINT; v_sc BIGINT; v_ap BIGINT; v_shown BIGINT; v_lost BIGINT;
BEGIN
  SELECT count(DISTINCT s.submission_id) INTO v_sub FROM oltp.submissions s
    JOIN oltp.challenges c USING (challenge_id) WHERE c.name='AN-CH1';
  SELECT count(*) INTO v_sc FROM oltp.scores;
  SELECT count(*) INTO v_ap FROM oltp.appeals;

  PERFORM qa_pre('F','F0 the funnel challenge has all three stages',
    v_sub > 0 AND v_sc > 0 AND v_ap = 2,
    format('AN-CH1: %s submission(s), %s score(s), %s appeal(s) -- one filed against a score, '
           ||'one against the match', v_sub, v_sc, v_ap));

  PERFORM qa_true('F','F1 the first two stages match OLTP, neither inflated by the others',
    'three facts on one challenge_key is the classic chasm shape, and the CTEs pre-aggregate',
    (SELECT submissions = v_sub AND scores_recorded = v_sc
       FROM analytics.vw_challenge_funnel WHERE challenge_name='AN-CH1'),
    (SELECT format('view: %s submissions, %s scores | OLTP: %s / %s',
       submissions, scores_recorded, v_sub, v_sc)
       FROM analytics.vw_challenge_funnel WHERE challenge_name='AN-CH1'));

  -- Was F1-GAP: etl_phase2_facts derived challenge_key ONLY from
  -- a.match_id, so an appeal filed against a score -- with match_id NULL --
  -- fell to the sentinel and disappeared from the funnel, which excludes
  -- -1. Disputing one judge's score is the ordinary way to appeal, so the
  -- stage was undercounting its common case. The ETL now resolves the
  -- challenge down both paths.
  --
  -- The two appeals are the pair: same round, same team, identical except
  -- for which column names the target.
  SELECT count(*) INTO v_shown FROM analytics.fact_appeals WHERE challenge_key <> -1;
  SELECT count(*) INTO v_lost  FROM analytics.fact_appeals WHERE challenge_key = -1;
  PERFORM qa_pre('F','F1 both appeals loaded, one filed each way',
    (SELECT count(*) FROM analytics.fact_appeals) = 2
    AND (SELECT count(*) FROM oltp.appeals WHERE score_id IS NOT NULL) = 1
    AND (SELECT count(*) FROM oltp.appeals WHERE match_id IS NOT NULL) = 1,
    'one appeal names a score, the other names the match -- so the assertion below is about '
    ||'attribution and not about a missing row');

  PERFORM qa_true('F','F1 an appeal filed against a SCORE reaches the funnel',
    'the challenge is resolved through score -> match -> challenge, not only through match_id',
    v_lost = 0 AND v_shown = 2,
    format('%s appeal(s) carry a real challenge_key, %s fell to the sentinel', v_shown, v_lost));

  PERFORM qa_true('F','F1 the funnel counts both ways of filing',
    'the stage must not undercount its most ordinary case',
    (SELECT appeals_filed FROM analytics.vw_challenge_funnel WHERE challenge_name='AN-CH1') = v_ap,
    format('view reports %s appeal(s), OLTP holds %s',
      (SELECT appeals_filed FROM analytics.vw_challenge_funnel WHERE challenge_name='AN-CH1'), v_ap));

  PERFORM qa_true('F','F1 both appeals resolve to the SAME challenge',
    'they dispute the same round, so two paths that disagreed would be worse than one that failed',
    (SELECT count(DISTINCT challenge_key) FROM analytics.fact_appeals) = 1,
    'the match path and the score path agree on which challenge this was');

  PERFORM qa_true('F','F1 the score-filed appeal still knows its judge',
    'the fix must not have cost the dimension that already worked',
    (SELECT judge_key FROM analytics.fact_appeals fa
       JOIN oltp.appeals a ON a.appeal_id = fa.source_appeal_id
      WHERE a.score_id IS NOT NULL) <> -1,
    'judge_key is still resolved through oltp.scores');

  PERFORM qa_true('F','F1 an appeal naming neither still falls to the sentinel',
    'the sentinel must remain reachable, or the fact would lose its NOT NULL key',
    (SELECT count(*) FROM analytics.dim_challenge WHERE challenge_key = -1) = 1,
    'the sentinel row is intact and still available for an appeal with no target');

  PERFORM qa_true('F','F1 scores_recorded is honestly named',
    'unlike vw_leaderboard.scored_matches, this column says "scores" and counts scores',
    (SELECT scores_recorded FROM analytics.vw_challenge_funnel WHERE challenge_name='AN-CH1') = v_sc,
    format('%s score rows, reported as %s', v_sc, v_sc));

  PERFORM qa_true('F','F2 a challenge nobody entered still appears',
    'a funnel that hides its empty top is not a funnel',
    (SELECT submissions = 0 AND scores_recorded = 0 AND appeals_filed = 0
       FROM analytics.vw_challenge_funnel WHERE challenge_name='AN-CH2'),
    'AN-CH2 received nothing and is listed with zeros');

  PERFORM qa_true('F','F3 the sentinel challenge is excluded',
    'challenge_key = -1 is "unknown", which is not a stage of any funnel',
    NOT EXISTS (SELECT 1 FROM analytics.vw_challenge_funnel WHERE challenge_key = -1),
    'the sentinel is filtered out');
END $$;


-- =====================================================================
-- Report
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
