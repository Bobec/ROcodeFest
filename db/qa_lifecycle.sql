-- =====================================================================
-- QA — decisions and lifecycles: does a row agree with itself?
-- =====================================================================
-- Every other suite asks whether a row may EXIST. This one asks whether
-- a row that exists is INTERNALLY COHERENT: an appeal marked accepted
-- with nobody recorded as having accepted it, a membership that ended
-- before it began, a decision dated before the thing it decided was
-- filed.
--
-- The enums guard the VALUES. Nothing guards the PATH between them:
-- there are no transition triggers on appeals.status,
-- join_requests.status or matches.status.
--
-- A NOTE ON METHOD, because it nearly went wrong here. The first pass at
-- this suite was built on a scan of pg_constraint, which reported that
-- memberships and join_requests carried no constraints at all. They
-- carry two, as PARTIAL UNIQUE INDEXES -- which live in pg_index, not
-- pg_constraint. Both are asserted below as strengths precisely because
-- they were almost written up as gaps. A catalogue query is evidence
-- about the catalogue, not about behaviour; only executing the statement
-- settles it.
--
--   psql -d qa_lc -f db/01_oltp_schema.sql
--   psql -d qa_lc -f db/qa_lifecycle.sql
-- =====================================================================

\set ON_ERROR_STOP on
\ir _qa_harness.sql
SELECT qa.suite('lifecycle');

-- ---------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('lc@t','x','club'), ('lj@t','x','judge'),
  ('lm1@t','x','member'), ('lm2@t','x','member'), ('lm3@t','x','member'),
  ('lm4@t','x','member'), ('lm5@t','x','member'), ('lm6@t','x','member');
INSERT INTO oltp.clubs(account_id,club_name)   SELECT account_id,'LClub' FROM oltp.accounts WHERE email='lc@t';
INSERT INTO oltp.judges(account_id,full_name)  SELECT account_id,'LJudge' FROM oltp.accounts WHERE email='lj@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,'M '||email FROM oltp.accounts WHERE role='member';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'LTeam','LC-1'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'LTeam2','LC-2'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.seasons(name,start_date,end_date,is_active)
  VALUES ('LSeason','2026-01-01','2026-12-31',TRUE);
INSERT INTO oltp.challenges(season_id,name,stage)
  SELECT season_id,'LCH','final' FROM oltp.seasons WHERE name='LSeason';


-- =====================================================================
-- A — an appeal decided by nobody
-- =====================================================================
DO $$
DECLARE
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='LC-1');
  v_m BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='lm1@t');
  v_a BIGINT; v_b BIGINT; v_c BIGINT; v_r BIGINT; v_j BIGINT; v_n INT;
BEGIN
  -- The rule, given by the owner: "an appeal is closed when the judge
  -- gives a final answer, supported by a rule." R7 turned that sentence
  -- into three columns that must arrive together, a judge FK, and
  -- finality. What follows used to be four GAPs.
  INSERT INTO oltp.rule_sections(code,title) VALUES ('LC','Lifecycle section');
  INSERT INTO oltp.rules(section_id,code,title,body)
    SELECT section_id,'LC1','A current rule','text' FROM oltp.rule_sections WHERE code='LC';
  v_r := (SELECT rule_id FROM oltp.rules WHERE code='LC1');
  v_j := (SELECT account_id FROM oltp.accounts WHERE email='lj@t');

  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t,v_m,'to be closed')
    RETURNING appeal_id INTO v_a;
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t,v_m,'closed badly')
    RETURNING appeal_id INTO v_b;

  PERFORM qa_pre('A','A1 the schema has somewhere to record who decided, when, and under what',
    (SELECT count(*) FROM information_schema.columns
      WHERE table_schema='oltp' AND table_name='appeals'
        AND column_name IN ('decided_at','decided_by_account_id','decided_under_rule_id')) = 3,
    'all three columns exist, so closing an appeal has a complete form to fill in');

  PERFORM qa_pair('A','A1 closing an appeal requires a judge, a time AND a rule',
    'ck_appeals_closure_is_accountable -- the complete closure is the control, so this is not "every update fails"',
    format('UPDATE oltp.appeals SET status=''accepted'', decided_at=now(), decided_by_account_id=%s, '
           ||'decided_under_rule_id=%s WHERE appeal_id=%s', v_j, v_r, v_a),
    format('UPDATE oltp.appeals SET status=''rejected'' WHERE appeal_id=%s', v_b));

  PERFORM qa_true('A','A1 the verdict pinned the wording it was given under',
    'pin_decided_revision mirrors the citation side, so a decision cannot drift with the rulebook',
    (SELECT decided_revision_id FROM oltp.appeals WHERE appeal_id=v_a) IS NOT NULL,
    format('appeal %s rests on revision %s of rule LC1', v_a,
      (SELECT decided_revision_id FROM oltp.appeals WHERE appeal_id=v_a)));

  PERFORM qa_true('A','A1 the filer''s own citation was left untouched',
    'rule_id is what the filer invoked; the verdict may rest on different grounds',
    (SELECT rule_id FROM oltp.appeals WHERE appeal_id=v_a) IS NULL,
    'this appeal cited no rule when filed, and closing it under LC1 did not rewrite that');

  -- A2 final means final
  PERFORM qa_pre('A','A2 the appeal is closed',
    (SELECT status FROM oltp.appeals WHERE appeal_id=v_a) <> 'pending',
    'appeal '||v_a||' is '||(SELECT status FROM oltp.appeals WHERE appeal_id=v_a)::text);
  PERFORM qa_pair('A','A2 a closed appeal cannot be reopened',
    'enforce_appeal_finality -- editing a non-status column of a closed appeal is still allowed',
    format('UPDATE oltp.appeals SET reason = reason || '' (typo fixed)'' WHERE appeal_id=%s', v_a),
    format('UPDATE oltp.appeals SET status=''pending'' WHERE appeal_id=%s', v_a));

  -- A3 a decision cannot predate the appeal
  PERFORM qa_pair('A','A3 a decision cannot be dated before the appeal was filed',
    'ck_appeals_decided_after_created -- the same guard forum_posts received in R6',
    format('UPDATE oltp.appeals SET decided_at = created_at + interval ''1 hour'' WHERE appeal_id=%s', v_a),
    format('UPDATE oltp.appeals SET decided_at = created_at - interval ''5 days'' WHERE appeal_id=%s', v_a));

  -- A3b only a judge may sign a verdict
  PERFORM qa_pre('A','A3b the filer is not a judge',
    NOT EXISTS (SELECT 1 FROM oltp.judges WHERE account_id=v_m),
    'account '||v_m||' is a member, so only the judges FK can refuse the closure below');
  -- a third appeal, so the negative has a PENDING target of its own.
  -- Aiming it at "the first pending appeal" would match nothing once the
  -- controls above have closed the other two, and an UPDATE that touches
  -- no rows succeeds -- the harness records that as VACUOUS rather than
  -- crediting a pass.
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (v_t,v_m,'signed by a member')
    RETURNING appeal_id INTO v_c;
  PERFORM qa_pair('A','A3b only a judge may close an appeal',
    'fk_appeals_decided_by_judge -- identical closures differing only in who signs them',
    format('UPDATE oltp.appeals SET status=''accepted'', decided_at=now(), decided_by_account_id=%s, '
           ||'decided_under_rule_id=%s WHERE appeal_id=%s', v_j, v_r, v_b),
    format('UPDATE oltp.appeals SET status=''accepted'', decided_at=now(), decided_by_account_id=%s, '
           ||'decided_under_rule_id=%s WHERE appeal_id=%s', v_m, v_r, v_c));

  -- A4 the control: appeals are NOT unguarded in general, so the findings
  -- elsewhere are specific omissions rather than an untouched table.
  -- Closing this one as rejected takes the full form now, which is itself
  -- the point of A1.
  UPDATE oltp.appeals SET status='rejected', decided_at=now(),
         decided_by_account_id=v_j, decided_under_rule_id=v_r
   WHERE appeal_id=v_c;
  SELECT count(*) INTO v_n FROM oltp.appeals WHERE team_id=v_t AND status='rejected';
  PERFORM qa_pre('A','A4 the team already has rejected appeals on record', v_n >= 1,
    format('%s rejected appeal(s) for team %s, which is what the limit counts', v_n, v_t));
  PERFORM qa_true('A','A4 enforce_appeal_limit IS enforced on this table',
    'the control for the whole group: a rule that WAS specified here does hold',
    EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
            WHERE NOT t.tgisinternal AND p.proname='enforce_appeal_limit'),
    'appeals carries a working business-rule trigger, so the findings above are gaps in what was '
    ||'specified, not evidence of a neglected table');
END $$;


-- =====================================================================
-- J — join requests: accepted, and then nothing happens
-- =====================================================================
DO $$
DECLARE
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='LC-2');
  v_m2 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='lm2@t');
  v_m3 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='lm3@t');
  v_r BIGINT; v_before INT; v_after INT;
BEGIN
  -- J1 a strength, asserted because it was nearly written up as a gap:
  -- pg_constraint reports nothing on this table, and the guard is a
  -- PARTIAL UNIQUE INDEX instead
  INSERT INTO oltp.join_requests(member_id,team_id) VALUES (v_m2,v_t) RETURNING request_id INTO v_r;
  PERFORM qa_pre('J','J1 a pending request already exists to collide with',
    EXISTS (SELECT 1 FROM oltp.join_requests WHERE request_id=v_r AND status='pending'),
    'request '||v_r||' is pending for member '||v_m2||' on team '||v_t);
  PERFORM qa_pair('J','J1 the same member cannot have two pending requests to one team',
    'uq_join_requests_pending -- a partial unique index, invisible to a pg_constraint scan',
    format('INSERT INTO oltp.join_requests(member_id,team_id) VALUES (%s,%s)', v_m3, v_t),
    format('INSERT INTO oltp.join_requests(member_id,team_id) VALUES (%s,%s)', v_m2, v_t));

  -- J2 accepting a request changes a word and nothing else
  SELECT count(*) INTO v_before FROM oltp.memberships WHERE team_id=v_t AND member_id=v_m2;
  UPDATE oltp.join_requests SET status='accepted' WHERE request_id=v_r;
  SELECT count(*) INTO v_after FROM oltp.memberships WHERE team_id=v_t AND member_id=v_m2;

  PERFORM qa_gap('J','J2-GAP an accepted request creates no membership',
    'what does "accepted" actually accomplish?',
    format('request %s moved to accepted; memberships for that (team, member) went %s -> %s',
           v_r, v_before, v_after),
    'memberships.source_request_id exists specifically to link a membership back to the request '
    ||'that produced it, so the relationship was modelled -- but nothing creates the membership, '
    ||'and nothing detects its absence. The member is told yes and is not on the team. Whether '
    ||'the write belongs in a trigger or in an application is a design decision; today neither '
    ||'exists, which is the same shape as the notification emitter gap (qa_notifications N1).');

  PERFORM qa_gap('J','J2-GAP a decided request need not record who decided it',
    'the same accountability question as A1, on the other decision table',
    format('request %s is accepted with decided_at=%s and decided_by=%s', v_r,
      coalesce((SELECT decided_at::text FROM oltp.join_requests WHERE request_id=v_r),'NULL'),
      coalesce((SELECT decided_by::text   FROM oltp.join_requests WHERE request_id=v_r),'NULL')),
    'join_requests carries decided_at and decided_by for the same reason appeals does, and leaves '
    ||'them optional for the same reason: the status column is not tied to them. One CHECK per '
    ||'table closes both.');

  -- J3 nothing stops the reverse either
  UPDATE oltp.join_requests SET status='rejected' WHERE request_id=v_r;
  PERFORM qa_gap('J','J3-GAP an accepted request can later be rejected',
    'is a decision final?',
    format('request %s went pending -> accepted -> rejected with no rule consulted', v_r),
    'If J2 were closed and acceptance did create a membership, this transition would leave the '
    ||'membership in place under a rejected request -- so the two gaps compound. That is the '
    ||'argument for closing them together rather than in sequence.');
END $$;


-- =====================================================================
-- M — memberships: the interval
-- =====================================================================
DO $$
DECLARE
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='LC-1');
  v_t2 BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='LC-2');
  v_max INT; v_active INT; v_first BIGINT; v_rejoiner BIGINT;
BEGIN
  SELECT tc.max_members INTO v_max FROM oltp.teams t
    JOIN oltp.team_categories tc USING (category_id) WHERE t.team_id=v_t;

  -- fill the team to its category maximum
  INSERT INTO oltp.memberships(team_id,member_id)
    SELECT v_t, m.account_id FROM oltp.members m
    ORDER BY m.account_id LIMIT v_max;
  SELECT count(*) INTO v_active FROM oltp.memberships WHERE team_id=v_t AND left_at IS NULL;
  PERFORM qa_pre('M','M1 the team is exactly at capacity', v_active = v_max,
    format('%s active member(s), category maximum %s', v_active, v_max));

  -- The control joins the OTHER team, which is empty. Without it a
  -- refusal here would only show that some insert failed -- and this
  -- group has already been bitten once by a rejection that came from
  -- the wrong guard (see M3).
  PERFORM qa_pair('M','M1 a team at capacity refuses another member',
    'enforce_team_capacity, with an identical insert into a team that has room as the control',
    format('INSERT INTO oltp.memberships(team_id,member_id) SELECT %s, account_id FROM oltp.members '
           ||'WHERE account_id NOT IN (SELECT member_id FROM oltp.memberships WHERE team_id=%s) '
           ||'ORDER BY account_id LIMIT 1', v_t2, v_t2),
    format('INSERT INTO oltp.memberships(team_id,member_id) SELECT %s, account_id FROM oltp.members '
           ||'WHERE account_id NOT IN (SELECT member_id FROM oltp.memberships WHERE team_id=%s) '
           ||'ORDER BY account_id LIMIT 1', v_t, v_t));

  -- M2 a departure frees a slot -- the trigger counts left_at IS NULL,
  -- and this is the assertion that proves it rather than assuming it
  SELECT membership_id INTO v_first FROM oltp.memberships
   WHERE team_id=v_t AND left_at IS NULL ORDER BY membership_id LIMIT 1;
  UPDATE oltp.memberships SET left_at = now() WHERE membership_id = v_first;
  PERFORM qa_accept('M','M2 a member leaving frees a place',
    format('INSERT INTO oltp.memberships(team_id,member_id) SELECT %s, account_id FROM oltp.members '
           ||'WHERE account_id NOT IN (SELECT member_id FROM oltp.memberships WHERE team_id=%s AND left_at IS NULL) LIMIT 1',
           v_t, v_t));

  -- M3 a strength that a catalogue scan does not see.
  --
  -- Deliberately on the OTHER team. Run against the full one, this was
  -- refused by enforce_team_capacity (P0001) before the unique index was
  -- ever consulted -- a pass that would have been credited to the wrong
  -- mechanism entirely. The expected-SQLSTATE oracle caught it; the
  -- lesson is that a negative needs the OTHER guards out of its way, not
  -- merely a statement that fails.
  SELECT count(*) INTO v_active FROM oltp.memberships WHERE team_id=v_t2 AND left_at IS NULL;
  PERFORM qa_pre('M','M3 the second team has an active membership AND room to spare',
    v_active >= 1 AND v_active < v_max,
    format('team %s holds %s active member(s) of a possible %s -- it has someone to duplicate '
           ||'and space left, so capacity cannot be what refuses',
           v_t2, v_active, v_max));
  PERFORM qa_pair('M','M3 the same member cannot hold two ACTIVE memberships of one team',
    'uq_memberships_active_team_member -- a partial unique index, invisible to a pg_constraint scan',
    format('INSERT INTO oltp.memberships(team_id,member_id) SELECT %s, account_id FROM oltp.members '
           ||'WHERE account_id NOT IN (SELECT member_id FROM oltp.memberships WHERE team_id=%s) '
           ||'ORDER BY account_id LIMIT 1', v_t2, v_t2),
    format('INSERT INTO oltp.memberships(team_id,member_id) SELECT %s, member_id FROM oltp.memberships '
           ||'WHERE team_id=%s AND left_at IS NULL ORDER BY membership_id LIMIT 1', v_t2, v_t2));

  -- and the partial half of the index: once the member has LEFT, the
  -- same pair may be recorded again, which is what "active" means
  SELECT member_id INTO v_rejoiner FROM oltp.memberships
   WHERE team_id=v_t2 AND left_at IS NULL ORDER BY membership_id LIMIT 1;
  UPDATE oltp.memberships SET left_at = now()
   WHERE team_id=v_t2 AND left_at IS NULL AND member_id = v_rejoiner;
  PERFORM qa_accept('M','M3 a member who left may rejoin the same team',
    format('INSERT INTO oltp.memberships(team_id,member_id) VALUES (%s, %s)', v_t2, v_rejoiner));

  -- M4 the interval itself
  --
  -- Was M4-GAP. The error used to be invisible from the one place that
  -- reads the column: enforce_team_capacity keys on left_at IS NULL
  -- rather than on the dates, so a reversed interval still behaved
  -- correctly for capacity while returning a negative tenure everywhere
  -- else.
  PERFORM qa_pair('M','M4 a membership cannot end before it begins',
    'ck_memberships_left_after_joined -- leaving LATER is still perfectly ordinary',
    format('UPDATE oltp.memberships SET joined_at=''2026-01-01'', left_at=''2026-06-01'' '
           ||'WHERE membership_id=%s', v_first),
    format('UPDATE oltp.memberships SET joined_at=''2026-06-01'', left_at=''2026-01-01'' '
           ||'WHERE membership_id=%s', v_first));

  -- the NULL-tolerant half, asserted over the rows that already exist
  -- rather than by clearing left_at on a departed row -- doing that would
  -- reactivate it and collide with the replacement M2 brought in, which
  -- is uq_memberships_active_team_member doing its job, not this CHECK.
  PERFORM qa_true('M','M4 active memberships carry a NULL left_at and satisfy the constraint',
    'the guard must not turn "still a member" into an error',
    (SELECT count(*) FROM oltp.memberships WHERE left_at IS NULL) > 0,
    format('%s active membership(s) stand with left_at = NULL',
      (SELECT count(*) FROM oltp.memberships WHERE left_at IS NULL)));
END $$;


-- =====================================================================
-- R — where a membership came from
-- =====================================================================
-- memberships.source_request_id is the one partial unique index in the
-- schema that had no test at all. It says a join request produces at
-- most one membership, which is a real rule and holds. What it does not
-- say is anything about WHICH request: the column is a bare FK, so the
-- link can point at a request belonging to someone else, to another
-- team, or to a refusal.
--
-- The schema already owns the fix pattern -- scores reaches match_teams
-- through a COMPOSITE FK, and R6 gave forum_comments and forum_post_tags
-- the same treatment -- so this is a place the established idiom was not
-- applied rather than a problem without a precedent.
-- =====================================================================
DO $$
DECLARE
  v_club BIGINT := (SELECT account_id FROM oltp.clubs LIMIT 1);
  v_cat  BIGINT := (SELECT category_id FROM oltp.team_categories WHERE code='ROBOTICS');
  v_t3 BIGINT; v_t4 BIGINT;
  v_m1 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='lm1@t');
  v_m2 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='lm2@t');
  v_m3 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='lm3@t');
  v_m4 BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='lm4@t');
  v_r1 BIGINT; v_r2 BIGINT; v_ms BIGINT; v_n INT;
BEGIN
  INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
    VALUES (v_club,v_cat,'LTeam3','LC-3') RETURNING team_id INTO v_t3;
  INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
    VALUES (v_club,v_cat,'LTeam4','LC-4') RETURNING team_id INTO v_t4;

  INSERT INTO oltp.join_requests(member_id,team_id,status) VALUES (v_m1,v_t3,'accepted')
    RETURNING request_id INTO v_r1;
  INSERT INTO oltp.join_requests(member_id,team_id,status) VALUES (v_m2,v_t3,'accepted')
    RETURNING request_id INTO v_r2;
  INSERT INTO oltp.memberships(team_id,member_id,source_request_id) VALUES (v_t3,v_m1,v_r1);

  -- R1 the rule the index actually states
  PERFORM qa_pre('R','R1 request '||v_r1||' has already produced a membership',
    EXISTS (SELECT 1 FROM oltp.memberships WHERE source_request_id=v_r1),
    'so the second claim on it below has something to collide with');
  PERFORM qa_pair('R','R1 one join request yields at most one membership',
    'uq_memberships_source_request -- a second membership citing its OWN request is the control',
    format('INSERT INTO oltp.memberships(team_id,member_id,source_request_id) VALUES (%s,%s,%s)',
           v_t3, v_m2, v_r2),
    format('INSERT INTO oltp.memberships(team_id,member_id,source_request_id) VALUES (%s,%s,%s)',
           v_t3, v_m3, v_r1));

  -- R2 the PARTIAL half: the index must not stop direct additions
  PERFORM qa_accept('R','R2 several memberships may have no source request at all',
    format('INSERT INTO oltp.memberships(team_id,member_id) VALUES (%s,%s), (%s,%s)',
           v_t4, v_m1, v_t4, v_m2));
  PERFORM qa_true('R','R2 the NULLs coexist, which a plain UNIQUE would have forbidden',
    'a coach adding members directly is the ordinary path -- the WHERE clause is load-bearing',
    (SELECT count(*) FROM oltp.memberships WHERE team_id=v_t4 AND source_request_id IS NULL) = 2,
    'two memberships on the same team carry no request, and both stand');

  -- R3 what the link does NOT check ------------------------------------
  INSERT INTO oltp.join_requests(member_id,team_id,status) VALUES (v_m3,v_t3,'accepted')
    RETURNING request_id INTO v_r1;
  PERFORM qa_pre('R','R3 an unused request belonging to member '||v_m3,
    NOT EXISTS (SELECT 1 FROM oltp.memberships WHERE source_request_id=v_r1)
    AND (SELECT member_id FROM oltp.join_requests WHERE request_id=v_r1) = v_m3,
    'so the mismatches below are about WHOSE request it is, not about the index');

  -- Was R3-GAP, twice: source_request_id was a bare FK, so the link
  -- could point at a request filed by someone else, or for another team,
  -- and the audit trail read "this person joined because of that
  -- request" when the request was for somewhere else entirely. R8 made
  -- it a COMPOSITE FK -- the idiom scores already uses into match_teams
  -- and R6 gave both forum edges -- so one constraint closes both.
  PERFORM qa_pair('R','R3 a membership must cite a request for the SAME team',
    'fk_memberships_source_request_matches -- the matching pair is the control',
    format('INSERT INTO oltp.memberships(team_id,member_id,source_request_id) VALUES (%s,%s,%s)',
           v_t3, v_m3, v_r1),
    format('INSERT INTO oltp.memberships(team_id,member_id,source_request_id) VALUES (%s,%s,%s)',
           v_t4, v_m3, v_r1));
  DELETE FROM oltp.memberships WHERE team_id=v_t3 AND member_id=v_m3;

  PERFORM qa_pair('R','R3 and from the SAME member',
    'the other column of the same composite key -- one constraint governs both',
    format('INSERT INTO oltp.memberships(team_id,member_id,source_request_id) VALUES (%s,%s,%s)',
           v_t3, v_m3, v_r1),
    format('INSERT INTO oltp.memberships(team_id,member_id,source_request_id) VALUES (%s,%s,%s)',
           v_t3, v_m4, v_r1));

  PERFORM qa_true('R','R3 exactly one FK now governs the link',
    'the redundant single-column reference was dropped, so two rules cannot later disagree',
    (SELECT count(*) FROM pg_constraint
      WHERE conrelid='oltp.memberships'::regclass AND contype='f'
        AND confrelid='oltp.join_requests'::regclass) = 1,
    'one FK from memberships to join_requests, and it is the composite one');

  -- R4 the request still need not have been ACCEPTED
  UPDATE oltp.join_requests SET status='rejected' WHERE request_id=v_r1;
  SELECT membership_id INTO v_ms FROM oltp.memberships
   WHERE team_id=v_t3 AND member_id=v_m3 AND source_request_id=v_r1;
  PERFORM qa_gap('R','R4-GAP a membership may cite a REJECTED request as its origin',
    'can a refusal be the reason someone is on the team?',
    format('membership %s is active on team %s, citing request %s whose status is %s',
           v_ms, v_t3, v_r1, (SELECT status FROM oltp.join_requests WHERE request_id=v_r1)),
    'Nothing requires the cited request to have been accepted, so the row states that a refusal '
    ||'admitted someone. This compounds with J2 and J3 in the other direction: accepting a request '
    ||'creates no membership, and rejecting one removes none, so the status and the roster are '
    ||'fully independent in both directions. Whichever way that link is eventually made, it has to '
    ||'be made once for both.');

  -- R5 the surviving membership, and what it forgets
  SELECT count(*) INTO v_n FROM oltp.memberships WHERE source_request_id=v_r1;
  PERFORM qa_pre('R','R5 a membership currently cites request '||v_r1, v_n = 1,
    'so deleting the request below has a live link to act on');
  DELETE FROM oltp.join_requests WHERE request_id=v_r1;
  PERFORM qa_true('R','R5 deleting the request keeps the membership and clears the link',
    'ON DELETE SET NULL: someone stays on the team even if the paperwork is removed',
    EXISTS (SELECT 1 FROM oltp.memberships WHERE membership_id=v_ms)
    AND (SELECT source_request_id FROM oltp.memberships WHERE membership_id=v_ms) IS NULL,
    'the membership survives with source_request_id = NULL');

  PERFORM qa_note('R','R5-NOTE the provenance is erasable without trace',
    'a consequence of SET NULL, recorded rather than judged',
    'After the request is gone the membership is indistinguishable from one a coach added '
    ||'directly, and R2 shows that is a legitimate shape -- so nothing downstream can tell the '
    ||'difference between "joined without a request" and "joined through a request that was later '
    ||'deleted". CASCADE would be worse, removing a real person from a real team over an '
    ||'administrative delete. If the trail matters, the request should not be deletable while a '
    ||'membership cites it, which is the same ON DELETE decision R5 made for cited rules.');
END $$;


-- =====================================================================
-- S — seasons
-- =====================================================================
DO $$
DECLARE v_n INT;
BEGIN
  PERFORM qa_pair('S','S1 a season cannot end before it starts',
    'ck_seasons_end_after_start -- a forward range is still perfectly ordinary',
    'INSERT INTO oltp.seasons(name,start_date,end_date,is_active) '
      ||'VALUES (''LForwards'',''2027-01-01'',''2027-12-31'',FALSE)',
    'INSERT INTO oltp.seasons(name,start_date,end_date,is_active) '
      ||'VALUES (''LBackwards'',''2026-12-31'',''2026-01-01'',FALSE)');

  -- S2 one active season at a time. The control is an INACTIVE season,
  -- so the negative is refused for holding the flag and not for existing.
  SELECT count(*) INTO v_n FROM oltp.seasons WHERE is_active;
  PERFORM qa_pre('S','S2 exactly one season is active', v_n = 1,
    format('%s active season, so the second one below is the only thing that can collide', v_n));
  PERFORM qa_pair('S','S2 a second ACTIVE season is refused',
    'uq_seasons_single_active -- "the current season" has to resolve to one row',
    'INSERT INTO oltp.seasons(name,start_date,is_active) VALUES (''LDormant'',''2028-01-01'',FALSE)',
    'INSERT INTO oltp.seasons(name,start_date,is_active) VALUES (''LRival'',''2028-06-01'',TRUE)');

  -- and the handover must stay possible, or the index would freeze the
  -- festival on its first season forever
  UPDATE oltp.seasons SET is_active = FALSE WHERE name='LSeason';
  PERFORM qa_accept('S','S2 the active season can be handed over',
    'UPDATE oltp.seasons SET is_active = TRUE WHERE name=''LDormant''');
  PERFORM qa_true('S','S2 still exactly one active season afterwards',
    'a handover that left two active would satisfy the accept above',
    (SELECT count(*) FROM oltp.seasons WHERE is_active) = 1,
    (SELECT 'active: '||name FROM oltp.seasons WHERE is_active));
END $$;


-- =====================================================================
-- X — match state versus the scores attached to it
-- =====================================================================
DO $$
DECLARE
  v_ch BIGINT := (SELECT challenge_id FROM oltp.challenges WHERE name='LCH');
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='LC-1');
  v_j BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='lj@t');
  v_future BIGINT; v_cancelled BIGINT; v_played BIGINT; v_empty BIGINT;
BEGIN
  INSERT INTO oltp.matches(challenge_id,round_name,status)
    VALUES (v_ch,'not played yet','scheduled') RETURNING match_id INTO v_future;
  INSERT INTO oltp.matches(challenge_id,round_name,status)
    VALUES (v_ch,'called off','cancelled') RETURNING match_id INTO v_cancelled;
  INSERT INTO oltp.match_teams(match_id,team_id) VALUES (v_future,v_t),(v_cancelled,v_t);
  INSERT INTO oltp.match_judges(match_id,judge_id) VALUES (v_future,v_j),(v_cancelled,v_j);

  PERFORM qa_pre('X','X1 the two matches are in non-played states',
    (SELECT status FROM oltp.matches WHERE match_id=v_future) = 'scheduled'
    AND (SELECT status FROM oltp.matches WHERE match_id=v_cancelled) = 'cancelled',
    format('match %s is scheduled, match %s is cancelled', v_future, v_cancelled));

  -- A result presumes the event happened. R2 had established that scoring
  -- requires an assigned judge and a fielded team -- the panel and the
  -- roster were checked, the EVENT was not.
  INSERT INTO oltp.matches(challenge_id,round_name,status)
    VALUES (v_ch,'played','completed') RETURNING match_id INTO v_played;
  INSERT INTO oltp.match_teams(match_id,team_id) VALUES (v_played,v_t);
  INSERT INTO oltp.match_judges(match_id,judge_id) VALUES (v_played,v_j);

  PERFORM qa_pair('X','X1 a scheduled match cannot be scored',
    'enforce_match_is_playable -- the identical insert on a completed match is the control',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,'
           ||'presentation_score,teamwork_score) VALUES (%s,%s,%s,7,7,7,7)', v_played, v_t, v_j),
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,'
           ||'presentation_score,teamwork_score) VALUES (%s,%s,%s,7,7,7,7)', v_future, v_t, v_j));

  -- the in-progress match doubles as the control here: it is the same
  -- insert by the same judge on a match that HAS started, so a refusal on
  -- the cancelled one cannot be blamed on anything else
  UPDATE oltp.matches SET status='in_progress' WHERE match_id=v_future;
  PERFORM qa_pair('X','X1 nor can a cancelled one',
    'enforce_match_is_playable again, with a match in progress as the permitted side',
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,'
           ||'presentation_score,teamwork_score) VALUES (%s,%s,%s,7,7,7,7)', v_future, v_t, v_j),
    format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,'
           ||'presentation_score,teamwork_score) VALUES (%s,%s,%s,7,7,7,7)', v_cancelled, v_t, v_j));

  -- X2 the other direction: a match holding results cannot be voided
  -- behind them. R7 stops the harmful CONSEQUENCE without imposing a
  -- lifecycle nobody specified -- a completed match may still return to
  -- scheduled, but only once its scores are gone, which makes the act
  -- visible instead of silent.
  PERFORM qa_pre('X','X2 the played match carries results',
    (SELECT count(*) FROM oltp.scores WHERE match_id=v_played) > 0,
    format('match %s holds %s score(s)', v_played,
      (SELECT count(*) FROM oltp.scores WHERE match_id=v_played)));
  -- a fresh, unscored match as the control: every other match in this
  -- block now carries a score, and cancelling one of those is exactly
  -- what the negative asserts is refused
  INSERT INTO oltp.matches(challenge_id,round_name,status)
    VALUES (v_ch,'no results yet','scheduled') RETURNING match_id INTO v_empty;
  PERFORM qa_pair('X','X2 a match holding results cannot be cancelled',
    'enforce_cancel_has_no_scores -- cancelling an unscored match is still fine',
    format('UPDATE oltp.matches SET status=''cancelled'' WHERE match_id=%s', v_empty),
    format('UPDATE oltp.matches SET status=''cancelled'' WHERE match_id=%s', v_played));

  PERFORM qa_accept('X','X2 removing the results first makes voiding possible',
    format('DELETE FROM oltp.scores WHERE match_id=%s; '
           ||'UPDATE oltp.matches SET status=''cancelled'' WHERE match_id=%s', v_played, v_played));

  PERFORM qa_gap('X','X2-GAP match status still moves in any direction',
    'is there a lifecycle, or just a label?',
    'R7 blocks the consequence -- a void match cannot hold results -- but the status itself is '
    ||'unconstrained: a completed match with no scores may return to scheduled freely',
    'matches.status has no transition rule, and neither does join_requests.status. appeals.status '
    ||'now does, because appeals were the only one specified. The remaining two share one '
    ||'omission, which is an argument for one decision about transitions rather than two separate '
    ||'patches -- and R7 deliberately did not assume it.');
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
