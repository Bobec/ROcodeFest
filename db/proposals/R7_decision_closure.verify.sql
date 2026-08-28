-- =====================================================================
-- VERIFY R7 — does the patch close what it claims, and nothing else?
-- =====================================================================
-- Run on a throwaway database:
--   psql -d r7 -f db/01_oltp_schema.sql
--   psql -d r7 -f db/_qa_harness.sql
--   psql -d r7 -f db/proposals/R7_decision_closure.patch.sql
--   psql -d r7 -f db/proposals/R7_decision_closure.verify.sql
--
-- Every case is PAIRED: the permitted form must still work. A patch that
-- closes a gap by refusing everything is not a fix, and six of the seven
-- checks here would pass just as well against such a patch if the
-- control were missing.
-- =====================================================================

\set ON_ERROR_STOP on
\ir ../_qa_harness.sql
SELECT qa.suite('R7-verify');

INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('r7c@t','x','club'), ('r7m@t','x','member'), ('r7m2@t','x','member'),
  ('r7j@t','x','judge'), ('r7j2@t','x','judge');
INSERT INTO oltp.clubs(account_id,club_name)   SELECT account_id,'R7Club' FROM oltp.accounts WHERE email='r7c@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,'R7M '||email FROM oltp.accounts WHERE role='member';
INSERT INTO oltp.judges(account_id,full_name)  SELECT account_id,'R7Judge '||email FROM oltp.accounts WHERE role='judge';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'R7Team','R7-1'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.rule_sections(code,title) VALUES ('R7','R7 section')
  ON CONFLICT DO NOTHING;
INSERT INTO oltp.rules(section_id,code,title,body)
  SELECT section_id,'R7A','Live rule','text' FROM oltp.rule_sections WHERE code='R7';
INSERT INTO oltp.rules(section_id,code,title,body)
  SELECT section_id,'R7B','Retired rule','text' FROM oltp.rule_sections WHERE code='R7';
UPDATE oltp.rules SET retired_at = now() WHERE code='R7B';
INSERT INTO oltp.seasons(name,start_date,is_active) VALUES ('R7S','2026-01-01',TRUE);
INSERT INTO oltp.challenges(season_id,name,stage)
  SELECT season_id,'R7CH','final' FROM oltp.seasons WHERE name='R7S';


-- ---- Part 1: intervals ------------------------------------------------
DO $$
DECLARE
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='R7-1');
  v_m BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r7m@t');
  v_j BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r7j@t');
  v_r BIGINT := (SELECT rule_id FROM oltp.rules WHERE code='R7A');
  v_a BIGINT;
BEGIN
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t,v_m,'open')
    RETURNING appeal_id INTO v_a;

  PERFORM qa_pair('1','U1 a decision cannot predate the appeal',
    'ck_appeals_decided_after_created, with a forward-dated decision as the control',
    format('UPDATE oltp.appeals SET status=''accepted'', decided_at=now(), decided_by_account_id=%s, '
           ||'decided_under_rule_id=%s WHERE appeal_id=%s', v_j, v_r, v_a),
    format('UPDATE oltp.appeals SET decided_at = created_at - interval ''1 day'' WHERE appeal_id=%s', v_a));

  INSERT INTO oltp.memberships(team_id,member_id) VALUES (v_t,v_m);
  PERFORM qa_pair('1','U2 a membership cannot end before it begins',
    'ck_memberships_left_after_joined -- leaving later is still permitted',
    format('UPDATE oltp.memberships SET left_at = joined_at + interval ''1 day'' WHERE team_id=%s', v_t),
    format('UPDATE oltp.memberships SET left_at = joined_at - interval ''1 day'' WHERE team_id=%s', v_t));

  PERFORM qa_pair('1','U3 a season cannot end before it starts',
    'ck_seasons_end_after_start',
    'UPDATE oltp.seasons SET end_date = start_date + 300 WHERE name=''R7S''',
    'UPDATE oltp.seasons SET end_date = start_date - 300 WHERE name=''R7S''');
END $$;


-- ---- Part 2: one active season ---------------------------------------
DO $$
BEGIN
  PERFORM qa_pre('2','U4 exactly one season is active',
    (SELECT count(*) FROM oltp.seasons WHERE is_active) = 1,
    'so the second active season below is the only thing that can collide');
  PERFORM qa_pair('2','U4 a second ACTIVE season is refused',
    'uq_seasons_single_active -- an inactive season is still perfectly legal',
    'INSERT INTO oltp.seasons(name,start_date,is_active) VALUES (''R7S-next'',''2027-01-01'',FALSE)',
    'INSERT INTO oltp.seasons(name,start_date,is_active) VALUES (''R7S-rival'',''2027-06-01'',TRUE)');

  -- handover must remain possible, or the index would freeze the festival
  -- on its first season forever
  UPDATE oltp.seasons SET is_active = FALSE WHERE name='R7S';
  PERFORM qa_accept('2','U4 the active season can be handed over',
    'UPDATE oltp.seasons SET is_active = TRUE WHERE name=''R7S-next''');
  PERFORM qa_true('2','U4 still exactly one active season afterwards',
    'a handover that left two active would satisfy the accept above',
    (SELECT count(*) FROM oltp.seasons WHERE is_active) = 1,
    (SELECT 'active: '||name FROM oltp.seasons WHERE is_active));
END $$;


-- ---- Part 3: appeal closure ------------------------------------------
DO $$
DECLARE
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='R7-1');
  v_m2 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r7m2@t');
  v_j BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r7j@t');
  v_r BIGINT := (SELECT rule_id FROM oltp.rules WHERE code='R7A');
  v_dead BIGINT := (SELECT rule_id FROM oltp.rules WHERE code='R7B');
  v_a BIGINT; v_b BIGINT;
BEGIN
  -- Two appeals, so the negative has a target of its OWN. Pointing it at
  -- "the first pending appeal" made the UPDATE match zero rows once the
  -- control had closed the only one -- and an UPDATE that touches nothing
  -- succeeds. The harness caught it as VACUOUS rather than crediting a
  -- pass; without that guard this file would have shipped green while
  -- testing nothing.
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t,v_m2,'to be closed')
    RETURNING appeal_id INTO v_a;
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t,v_m2,'closed badly')
    RETURNING appeal_id INTO v_b;

  PERFORM qa_pair('3','U5 closing requires a judge, a time AND a rule',
    'ck_appeals_closure_is_accountable -- the complete form is the control, so this is not "all updates fail"',
    format('UPDATE oltp.appeals SET status=''accepted'', decided_at=now(), decided_by_account_id=%s, '
           ||'decided_under_rule_id=%s WHERE appeal_id=%s', v_j, v_r, v_a),
    format('UPDATE oltp.appeals SET status=''rejected'' WHERE appeal_id=%s', v_b));

  PERFORM qa_true('3','U5 the deciding revision was pinned automatically',
    'pin_decided_revision mirrors pin_cited_revision, so a verdict does not drift with the rulebook',
    (SELECT decided_revision_id FROM oltp.appeals WHERE appeal_id=v_a) IS NOT NULL,
    format('appeal %s pinned revision %s', v_a,
      (SELECT decided_revision_id FROM oltp.appeals WHERE appeal_id=v_a)));

  PERFORM qa_true('3','U5 the filer''s citation was NOT overwritten',
    'the whole reason for a separate column: rule_id must stay whatever the filer invoked',
    (SELECT rule_id FROM oltp.appeals WHERE appeal_id=v_a) IS NULL,
    'this appeal cited no rule at filing, and closing it under R7A left that untouched');

  -- U6 finality
  PERFORM qa_pre('3','U6 the appeal is closed',
    (SELECT status FROM oltp.appeals WHERE appeal_id=v_a) <> 'pending',
    'appeal '||v_a||' is '||(SELECT status FROM oltp.appeals WHERE appeal_id=v_a)::text);
  PERFORM qa_pair('3','U6 a closed appeal cannot be reopened',
    'enforce_appeal_finality -- editing a non-status column of a closed appeal is still allowed',
    format('UPDATE oltp.appeals SET reason = reason || '' (typo fixed)'' WHERE appeal_id=%s', v_a),
    format('UPDATE oltp.appeals SET status=''pending'' WHERE appeal_id=%s', v_a));
  -- the second limb needs its own control too: closing a still-pending
  -- appeal AS rejected must work, or "cannot be flipped to rejected"
  -- would pass against a patch that simply refused the value outright
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t,v_m2,'closed as rejected')
    RETURNING appeal_id INTO v_b;
  PERFORM qa_pair('3','U6 nor flipped to the opposite verdict',
    'rejecting a PENDING appeal is legitimate; rejecting a CLOSED one is not',
    format('UPDATE oltp.appeals SET status=''rejected'', decided_at=now(), decided_by_account_id=%s, '
           ||'decided_under_rule_id=%s WHERE appeal_id=%s', v_j, v_r, v_b),
    format('UPDATE oltp.appeals SET status=''rejected'' WHERE appeal_id=%s', v_a));

  -- U7 the decider must be a judge, and the rule must be current
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t,v_m2,'second')
    RETURNING appeal_id INTO v_a;
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t,v_m2,'second, badly')
    RETURNING appeal_id INTO v_b;
  PERFORM qa_pre('3','U7 a non-judge account exists',
    NOT EXISTS (SELECT 1 FROM oltp.judges WHERE account_id=v_m2),
    'account '||v_m2||' is a member, not a judge');
  PERFORM qa_pair('3','U7 only a judge may close an appeal',
    'fk_appeals_decided_by_judge -- identical closures differing only in who signs them',
    format('UPDATE oltp.appeals SET status=''accepted'', decided_at=now(), decided_by_account_id=%s, '
           ||'decided_under_rule_id=%s WHERE appeal_id=%s', v_j, v_r, v_a),
    format('UPDATE oltp.appeals SET status=''accepted'', decided_at=now(), decided_by_account_id=%s, '
           ||'decided_under_rule_id=%s WHERE appeal_id=%s', v_m2, v_r, v_b));

  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t,v_m2,'third')
    RETURNING appeal_id INTO v_a;
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t,v_m2,'third, retired basis')
    RETURNING appeal_id INTO v_b;
  PERFORM qa_pre('3','U7 R7B is retired and R7A is not',
    (SELECT retired_at FROM oltp.rules WHERE rule_id=v_dead) IS NOT NULL
    AND (SELECT retired_at FROM oltp.rules WHERE rule_id=v_r) IS NULL,
    'the two closures below differ in exactly one thing: which rule they rest on');
  PERFORM qa_pair('3','U7 a retired rule cannot be the basis of a decision',
    'refuse_retired_deciding_rule -- the identical closure under a CURRENT rule is the control',
    format('UPDATE oltp.appeals SET status=''accepted'', decided_at=now(), decided_by_account_id=%s, '
           ||'decided_under_rule_id=%s WHERE appeal_id=%s', v_j, v_r, v_a),
    format('UPDATE oltp.appeals SET status=''accepted'', decided_at=now(), decided_by_account_id=%s, '
           ||'decided_under_rule_id=%s WHERE appeal_id=%s', v_j, v_dead, v_b));
END $$;


-- ---- Part 4: only a played match is scored ---------------------------
DO $$
DECLARE
  v_ch BIGINT := (SELECT challenge_id FROM oltp.challenges WHERE name='R7CH');
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='R7-1');
  v_j BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r7j@t');
  v_j2 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='r7j2@t');
  v_played BIGINT; v_future BIGINT; v_void BIGINT;
BEGIN
  INSERT INTO oltp.matches(challenge_id,round_name,status) VALUES (v_ch,'played','completed')
    RETURNING match_id INTO v_played;
  INSERT INTO oltp.matches(challenge_id,round_name,status) VALUES (v_ch,'future','scheduled')
    RETURNING match_id INTO v_future;
  INSERT INTO oltp.matches(challenge_id,round_name,status) VALUES (v_ch,'void','cancelled')
    RETURNING match_id INTO v_void;
  INSERT INTO oltp.match_teams(match_id,team_id) VALUES (v_played,v_t),(v_future,v_t),(v_void,v_t);
  INSERT INTO oltp.match_judges(match_id,judge_id) VALUES (v_played,v_j),(v_future,v_j),(v_void,v_j),
                                                       (v_played,v_j2),(v_future,v_j2),(v_void,v_j2);

  PERFORM qa_pair('4','U8 a scheduled match cannot be scored',
    'enforce_match_is_playable -- the identical insert on a completed match is the control',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,'
           ||'presentation_score,teamwork_score) VALUES (%s,%s,%s,7,7,7,7)', v_played, v_t, v_j),
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,'
           ||'presentation_score,teamwork_score) VALUES (%s,%s,%s,7,7,7,7)', v_future, v_t, v_j));

  -- a second judge, so the control is a fresh (match, team, judge) triple
  -- rather than a duplicate of the one above
  PERFORM qa_pair('4','U8 nor can a cancelled one',
    'the same insert on the completed match, by a judge who has not scored it yet',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,'
           ||'presentation_score,teamwork_score) VALUES (%s,%s,%s,7,7,7,7)', v_played, v_t, v_j2),
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,'
           ||'presentation_score,teamwork_score) VALUES (%s,%s,%s,7,7,7,7)', v_void, v_t, v_j2));

  PERFORM qa_accept('4','U8 a match in progress CAN be scored',
    format('UPDATE oltp.matches SET status=''in_progress'' WHERE match_id=%s', v_future));
  PERFORM qa_accept('4','U8 and the score then goes through',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,'
           ||'presentation_score,teamwork_score) VALUES (%s,%s,%s,6,6,6,6)', v_future, v_t, v_j));

  -- U9 the other direction
  PERFORM qa_pre('4','U9 the played match carries results',
    (SELECT count(*) FROM oltp.scores WHERE match_id=v_played) > 0,
    format('match %s holds %s score(s)', v_played,
      (SELECT count(*) FROM oltp.scores WHERE match_id=v_played)));
  PERFORM qa_pair('4','U9 a match holding results cannot be cancelled',
    'enforce_cancel_has_no_scores -- cancelling an unscored match is still fine',
    format('UPDATE oltp.matches SET status=''cancelled'' WHERE match_id=%s',
      (SELECT match_id FROM oltp.matches WHERE round_name='void')),
    format('UPDATE oltp.matches SET status=''cancelled'' WHERE match_id=%s', v_played));

  PERFORM qa_accept('4','U9 removing the results first makes cancelling possible',
    format('DELETE FROM oltp.scores WHERE match_id=%s; '
           ||'UPDATE oltp.matches SET status=''cancelled'' WHERE match_id=%s', v_played, v_played));
END $$;


\echo ''
\echo '===================== R7 VERIFY ====================='
SELECT seq, grp, status, kind, tc, result FROM qa.results ORDER BY seq;
\echo ''
SELECT * FROM qa_summary();
\echo ''
SELECT * FROM qa_lint();
SELECT qa_finish();
