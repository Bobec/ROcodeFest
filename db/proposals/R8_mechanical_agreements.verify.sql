-- =====================================================================
-- VERIFY R8 — does each part close what it claims, and nothing else?
-- =====================================================================
--   psql -d r8 -f db/01_oltp_schema.sql
--   psql -d r8 -f db/02_analytics_schema.sql
--   psql -d r8 -f db/03_etl.sql
--   psql -d r8 -f db/proposals/R8_mechanical_agreements.patch.sql
--   psql -d r8 -f db/proposals/R8_mechanical_agreements.verify.sql
--
-- Every constraint case is PAIRED. The two view cases are before/after
-- comparisons against OLTP truth, because a view has no negative to
-- reject -- what it can do is omit, and omission is only visible next to
-- the row that should have been there.
-- =====================================================================

\set ON_ERROR_STOP on
\ir ../_qa_harness.sql
SELECT qa.suite('R8-verify');

INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('r8c@t','x','club'), ('r8j@t','x','judge'),
  ('r8m1@t','x','member'), ('r8m2@t','x','member'), ('r8m3@t','x','member'),
  ('r8p@t','x','partner'), ('r8free@t','x','member');
INSERT INTO oltp.clubs(account_id,club_name)   SELECT account_id,'R8Club' FROM oltp.accounts WHERE email='r8c@t';
INSERT INTO oltp.judges(account_id,full_name)  SELECT account_id,'R8Judge' FROM oltp.accounts WHERE email='r8j@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,'R8M '||email
  FROM oltp.accounts WHERE email IN ('r8m1@t','r8m2@t','r8m3@t');
INSERT INTO oltp.partners(account_id,contact_name,partner_type)
  SELECT account_id,'R8 Contact','sponsor' FROM oltp.accounts WHERE email='r8p@t';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'R8TeamA','R8-A'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'R8TeamB','R8-B'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';


-- ---- Part 1: a verdict has words ------------------------------------
DO $$
DECLARE
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='R8-A');
  v_j BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r8j@t');
  v_m BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r8m1@t');
  v_s BIGINT;
BEGIN
  INSERT INTO oltp.seasons(name,start_date) VALUES ('R8S','2026-01-01');
  INSERT INTO oltp.challenges(season_id,name,stage)
    SELECT season_id,'R8CH','final' FROM oltp.seasons WHERE name='R8S';
  INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id)
    SELECT v_t, challenge_id, 'R8 sub', v_m FROM oltp.challenges WHERE name='R8CH'
    RETURNING submission_id INTO v_s;

  PERFORM qa_accept('1','U1 an ASSIGNED review may still be empty',
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id) VALUES (%s,%s)', v_s, v_j));
  PERFORM qa_pre('1','U1 that review is unreviewed',
    (SELECT reviewed_at FROM oltp.submission_reviews WHERE submission_id=v_s AND judge_id=v_j) IS NULL,
    'assigned-but-not-yet-reviewed is the ordinary starting state, and must stay legal');

  PERFORM qa_pair('1','U1 a review that was WRITTEN must say something',
    'ck_submission_reviews_verdict_has_text -- the same update with feedback is the control',
    format('UPDATE oltp.submission_reviews SET reviewed_at=now(), feedback=''looks good'' '
           ||'WHERE submission_id=%s AND judge_id=%s', v_s, v_j),
    format('UPDATE oltp.submission_reviews SET reviewed_at=now(), feedback=NULL '
           ||'WHERE submission_id=%s AND judge_id=%s', v_s, v_j));
END $$;


-- ---- Part 2: a membership came from its own request -----------------
DO $$
DECLARE
  v_ta BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='R8-A');
  v_tb BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='R8-B');
  v_m1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r8m1@t');
  v_m2 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r8m2@t');
  v_m3 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r8m3@t');
  v_r1 BIGINT; v_r2 BIGINT;
BEGIN
  INSERT INTO oltp.join_requests(member_id,team_id,status) VALUES (v_m1,v_ta,'accepted')
    RETURNING request_id INTO v_r1;
  INSERT INTO oltp.join_requests(member_id,team_id,status) VALUES (v_m2,v_ta,'accepted')
    RETURNING request_id INTO v_r2;

  PERFORM qa_pre('2','U2 request '||v_r1||' belongs to member '||v_m1||' for team '||v_ta,
    (SELECT member_id FROM oltp.join_requests WHERE request_id=v_r1) = v_m1
    AND (SELECT team_id FROM oltp.join_requests WHERE request_id=v_r1) = v_ta,
    'so the mismatches below differ from the control in exactly one column');

  PERFORM qa_pair('2','U2 a membership must cite a request from the SAME member',
    'fk_memberships_source_request_matches -- the matching pair is the control',
    format('INSERT INTO oltp.memberships(team_id,member_id,source_request_id) VALUES (%s,%s,%s)',
           v_ta, v_m1, v_r1),
    format('INSERT INTO oltp.memberships(team_id,member_id,source_request_id) VALUES (%s,%s,%s)',
           v_ta, v_m3, v_r2));

  PERFORM qa_pair('2','U2 and for the SAME team',
    'the other column of the same composite key',
    format('INSERT INTO oltp.memberships(team_id,member_id,source_request_id) VALUES (%s,%s,%s)',
           v_ta, v_m2, v_r2),
    format('INSERT INTO oltp.memberships(team_id,member_id,source_request_id) VALUES (%s,%s,%s)',
           v_tb, v_m3, v_r2));

  PERFORM qa_accept('2','U2 a membership with NO request is still permitted',
    format('INSERT INTO oltp.memberships(team_id,member_id) VALUES (%s,%s)', v_tb, v_m1));

  PERFORM qa_true('2','U2 one request still yields at most one membership',
    'the pre-existing partial unique index must survive the new composite FK',
    EXISTS (SELECT 1 FROM pg_indexes
             WHERE schemaname='oltp' AND indexname='uq_memberships_source_request'),
    'uq_memberships_source_request is intact');

  PERFORM qa_true('2','U2 exactly one FK now governs the link',
    'the redundant single-column FK was dropped, so two rules cannot later disagree',
    (SELECT count(*) FROM pg_constraint
      WHERE conrelid='oltp.memberships'::regclass AND contype='f'
        AND confrelid='oltp.join_requests'::regclass) = 1,
    'one FK from memberships to join_requests, and it is the composite one');
END $$;


-- ---- Part 3: the subtype invariant, from both sides ------------------
DO $$
DECLARE
  v_p BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r8p@t');
  v_free BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r8free@t');
  v_broken INT;
BEGIN
  PERFORM qa_pre('3','U3 one account has a subtype record, one does not',
    EXISTS (SELECT 1 FROM oltp.partners WHERE account_id=v_p)
    AND NOT EXISTS (SELECT 1 FROM oltp.members WHERE account_id=v_free),
    format('account %s is a partner with a partner record; account %s is a member with none',
           v_p, v_free));

  PERFORM qa_pair('3','U3 an account cannot change role while a subtype record exists',
    'enforce_role_change_has_no_subtype -- an account with nothing attached still changes freely',
    format('UPDATE oltp.accounts SET role=''judge'' WHERE account_id=%s', v_free),
    format('UPDATE oltp.accounts SET role=''member'' WHERE account_id=%s', v_p));

  PERFORM qa_accept('3','U3 removing the record first makes the change possible',
    format('DELETE FROM oltp.partners WHERE account_id=%s; '
           ||'UPDATE oltp.accounts SET role=''member'' WHERE account_id=%s', v_p, v_p));

  PERFORM qa_true('3','U3 no mismatched pair exists anywhere afterwards',
    'the whole point: the shape enforce_subtype_role refuses on one side is now unreachable on both',
    (SELECT count(*) FROM (
       SELECT 1 FROM oltp.members   s JOIN oltp.accounts a USING (account_id) WHERE a.role <> 'member'
       UNION ALL
       SELECT 1 FROM oltp.clubs     s JOIN oltp.accounts a USING (account_id) WHERE a.role <> 'club'
       UNION ALL
       SELECT 1 FROM oltp.judges    s JOIN oltp.accounts a USING (account_id) WHERE a.role <> 'judge'
       UNION ALL
       SELECT 1 FROM oltp.partners  s JOIN oltp.accounts a USING (account_id) WHERE a.role <> 'partner'
     ) x) = 0,
    'members, clubs, judges and partners all agree with their accounts');

  PERFORM qa_accept('3','U3 an unrelated UPDATE on accounts is untouched',
    format('UPDATE oltp.accounts SET is_active=FALSE WHERE account_id=%s', v_free));
END $$;


-- ---- Part 4: the progress report stops omitting rows ----------------
DO $$
DECLARE
  v_club BIGINT := (SELECT account_id FROM oltp.clubs LIMIT 1);
  v_other BIGINT; v_silent BIGINT; v_elig INT; v_denom INT;
BEGIN
  -- a challenge scoped to ANOTHER category, which the denominator must
  -- now exclude, and a team that has submitted nothing
  SELECT category_id INTO v_other FROM oltp.team_categories WHERE code <> 'ROBOTICS'
   ORDER BY category_id LIMIT 1;
  INSERT INTO oltp.challenges(season_id,name,stage,category_id)
    SELECT season_id,'R8CH-OTHER','final',v_other FROM oltp.seasons WHERE name='R8S';
  INSERT INTO oltp.challenges(season_id,name,stage)
    SELECT season_id,'R8CH2','final' FROM oltp.seasons WHERE name='R8S';
  INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
    SELECT v_club, category_id, 'R8Silent','R8-S' FROM oltp.team_categories WHERE code='ROBOTICS'
    RETURNING team_id INTO v_silent;

  PERFORM analytics.run_etl();

  PERFORM qa_pre('4','U4 a team exists that has submitted nothing',
    NOT EXISTS (SELECT 1 FROM oltp.submissions WHERE team_id=v_silent),
    'R8Silent is registered and has 0 submissions -- the row a progress report is FOR');

  PERFORM qa_true('4','U4 the silent team appears at 0% instead of vanishing',
    'driven from dim_team, so "no work" no longer reads as "no data"',
    (SELECT progress_pct FROM analytics.vw_team_season_progress WHERE team_name='R8Silent') = 0,
    (SELECT format('R8Silent: %s of %s challenge(s), %s%%',
       submitted_challenges, total_challenges, progress_pct)
       FROM analytics.vw_team_season_progress WHERE team_name='R8Silent'));

  -- the denominator counts only what the team may enter
  SELECT count(*) INTO v_elig FROM oltp.challenges c
   WHERE c.category_id IS NULL
      OR c.category_id = (SELECT category_id FROM oltp.teams WHERE team_id=v_silent);
  SELECT total_challenges INTO v_denom
    FROM analytics.vw_team_season_progress WHERE team_name='R8Silent';

  PERFORM qa_pre('4','U4 the season holds a challenge this team cannot enter',
    EXISTS (SELECT 1 FROM oltp.challenges WHERE name='R8CH-OTHER'
             AND category_id IS DISTINCT FROM
                 (SELECT category_id FROM oltp.teams WHERE team_id=v_silent)),
    'R8CH-OTHER is scoped to another category, so an unscoped denominator would over-count');

  PERFORM qa_true('4','U4 the denominator counts only eligible challenges',
    'a team must not be measured against work it is not allowed to do',
    v_denom = v_elig,
    format('R8Silent may enter %s challenge(s) and the view divides by %s', v_elig, v_denom));

  PERFORM qa_true('4','U4 a team that DID submit is still reported correctly',
    'the control: fixing the omission must not break the rows that already worked',
    (SELECT submitted_challenges FROM analytics.vw_team_season_progress
      WHERE team_name='R8TeamA') = 1,
    (SELECT format('R8TeamA: %s of %s, %s%%', submitted_challenges, total_challenges, progress_pct)
       FROM analytics.vw_team_season_progress WHERE team_name='R8TeamA'));

  PERFORM qa_true('4','U4 every team in the dimension now has a row',
    'a report that quietly drops teams is worse than one that shows zeros',
    (SELECT count(DISTINCT team_key) FROM analytics.vw_team_season_progress)
      = (SELECT count(*) FROM analytics.dim_team),
    format('%s of %s team(s) listed',
      (SELECT count(DISTINCT team_key) FROM analytics.vw_team_season_progress),
      (SELECT count(*) FROM analytics.dim_team)));
END $$;


\echo ''
\echo '===================== R8 VERIFY ====================='
SELECT seq, grp, status, kind, tc, result FROM qa.results ORDER BY seq;
\echo ''
SELECT * FROM qa_summary();
\echo ''
SELECT * FROM qa_lint();
SELECT qa_finish();
