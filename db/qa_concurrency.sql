-- =====================================================================
-- QA — concurrency and time
-- =====================================================================
-- The class no earlier suite touched: everything before this ran in ONE
-- session. Single-session testing cannot see a race, and a race is
-- exactly where a comment can be confidently wrong for months.
--
-- It found one immediately: 01_oltp_schema.sql claimed
-- assign_submission_version() prevented two racing resubmissions from
-- computing the same version. It does not. Both compute the same value;
-- the UNIQUE constraint is what refuses the second. The comment has been
-- corrected, and C1 below is the measurement that forced it.
--
-- MECHANISM: a second real backend via dblink, so the two sessions are
-- genuinely concurrent rather than two statements in one transaction.
-- Requires the connection string in `qa.conninfo`; the runner sets it.
-- Without it the concurrency cases are recorded SKIPPED -- never PASS.
-- A suite that cannot reach its precondition must say so.
--
--   psql -d qa_conc -f db/01_oltp_schema.sql
--   psql -d qa_conc -c "ALTER DATABASE qa_conc SET qa.conninfo = 'host=... dbname=qa_conc user=... password=...'"
--   psql -d qa_conc -f db/qa_concurrency.sql
-- =====================================================================

\set ON_ERROR_STOP on
\ir _qa_harness.sql
SELECT qa.suite('concurrency');

CREATE EXTENSION IF NOT EXISTS dblink;

-- Opens a second backend, or reports why it could not.
CREATE OR REPLACE FUNCTION qa.second_session(p_name TEXT) RETURNS BOOLEAN AS $fn$
DECLARE v_conn TEXT;
BEGIN
  BEGIN
    v_conn := current_setting('qa.conninfo');
  EXCEPTION WHEN others THEN
    RETURN FALSE;
  END;
  IF coalesce(v_conn,'') = '' THEN RETURN FALSE; END IF;
  BEGIN
    PERFORM dblink_connect(p_name, v_conn);
    PERFORM dblink_exec(p_name, 'SET search_path = oltp, public');
    RETURN TRUE;
  EXCEPTION WHEN others THEN
    RETURN FALSE;
  END;
END $fn$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Fixture: two independent chains so C1 and C3 cannot disturb each other
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('cc@t','x','club'), ('cm@t','x','member'),
  ('cj1@t','x','judge'), ('cj2@t','x','judge');
INSERT INTO oltp.clubs(account_id,club_name)   SELECT account_id,'CC' FROM oltp.accounts WHERE email='cc@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,'CM' FROM oltp.accounts WHERE email='cm@t';
INSERT INTO oltp.judges(account_id,full_name)  SELECT account_id,'CJ '||email FROM oltp.accounts WHERE role='judge';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'CT','CT-1'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.seasons(name,start_date) VALUES ('CS','2026-01-01');
INSERT INTO oltp.challenges(season_id,name,stage)
  SELECT s.season_id, n, 'final' FROM oltp.seasons s,
    (VALUES ('CC-RACE'),('CC-GATE'),('CC-WITHDRAW'),('CC-REVIEWS')) AS c(n);
INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id)
  SELECT t.team_id, c.challenge_id, c.name||' v1', a.account_id
  FROM oltp.teams t, oltp.challenges c, oltp.accounts a
  WHERE t.participation_code='CT-1' AND a.email='cm@t';

-- CC-RACE's v1 needs an open resubmission request, or the R3 gate refuses
-- BOTH racing sessions and C1 measures the gate instead of the race. The
-- other chains are seeded by the cases that own them: C2 is ABOUT an
-- uncommitted review, so seeding one here would destroy its premise.
INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission,feedback,reviewed_at)
SELECT s.submission_id, a.account_id, TRUE, 'needs rework', now()
FROM oltp.submissions s JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
   , oltp.accounts a
WHERE c.name='CC-RACE' AND a.email='cj1@t';

CREATE OR REPLACE FUNCTION qa.sub(p_ch TEXT, p_ver SMALLINT DEFAULT 1) RETURNS BIGINT AS $$
  SELECT s.submission_id FROM oltp.submissions s
  JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
  WHERE c.name=p_ch AND s.version=p_ver;
$$ LANGUAGE sql STABLE;


-- =====================================================================
-- C1 — two concurrent resubmissions compute the SAME version
-- =====================================================================
-- The point is not "does the database stay consistent" (it does). The
-- point is WHICH mechanism keeps it consistent, because the schema
-- comment named the wrong one.
DO $$
DECLARE
  v_a TEXT; v_state TEXT; v_ok BOOLEAN; v_rows INT;
BEGIN
  v_ok := qa.second_session('c1');
  IF NOT v_ok THEN
    PERFORM qa_pending('C1','concurrent version assignment','SKIPPED',
      'no second backend: qa.conninfo unset or unusable. Recorded SKIPPED, not PASS -- '
      ||'a concurrency case that never opened a second session has tested nothing.');
    RETURN;
  END IF;

  -- session A takes version 2 and holds the transaction open
  PERFORM dblink_exec('c1','BEGIN');
  SELECT x INTO v_a FROM dblink('c1',
    format('INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id)
            SELECT team_id,challenge_id,''A'',submitted_by_account_id
            FROM oltp.submissions WHERE submission_id=%s RETURNING version::text', qa.sub('CC-RACE'))
  ) AS t(x text);

  -- a premise, not a result: if session A did not take version 2 there is
  -- no contended key for session B to hit, and the collision below would
  -- prove nothing.
  PERFORM qa_pre('C1','C1 session A holds version 2', v_a = '2',
    'session A got version '||v_a||' and is holding its transaction open');

  -- session B, concurrently, computes the same number and collides.
  -- lock_timeout turns an indefinite wait into a deterministic error;
  -- the wait ITSELF is the evidence that both picked the same key.
  SET LOCAL lock_timeout = '3s';
  BEGIN
    INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id)
      SELECT team_id,challenge_id,'B',submitted_by_account_id
      FROM oltp.submissions WHERE submission_id = qa.sub('CC-RACE');
    v_state := 'NO CONFLICT';
  EXCEPTION WHEN others THEN
    v_state := SQLSTATE;
  END;

  PERFORM qa_true('C1','C1 the concurrent session collides on the SAME key',
    'if the trigger serialised resubmissions, B would compute 3 and insert cleanly',
    v_state IN ('55P03','23505'),
    format('session B: [%s] -- blocked on / duplicated the key session A already took. '
           ||'55P03 = still waiting on A''s open transaction; 23505 = A had committed.', v_state));

  -- Recorded as a NOTE, not a GAP: the behaviour is correct and the only
  -- defect was the comment describing it, which has been corrected. Kept
  -- because the reason matters more than the outcome -- someone reading
  -- "the trigger serialises resubmissions" could drop the unique
  -- constraint as redundant and silently allow duplicate versions.
  PERFORM qa_note('C1','C1-NOTE which mechanism actually prevents duplicate versions',
    'session A took version '||v_a||', session B computed the same and was refused',
    'assign_submission_version() does NOT serialise: under READ COMMITTED neither transaction '
    ||'sees the other''s uncommitted row, so MAX(version)+1 returns the same value in both. '
    ||'uq_submissions_team_challenge_version is the sole guard. The schema comment claiming '
    ||'otherwise has been corrected -- dropping that constraint would silently allow duplicates. '
    ||'The R3 gate does not change this: it reads committed state too, so both sessions pass it.');

  PERFORM dblink_exec('c1','COMMIT');
  PERFORM dblink_disconnect('c1');

  -- and the chain is still clean afterwards
  SELECT count(*) INTO v_rows FROM oltp.submissions s
   WHERE s.challenge_id = (SELECT challenge_id FROM oltp.challenges WHERE name='CC-RACE');
  PERFORM qa_true('C1','C1 the chain holds no duplicate version',
    'consistency is preserved -- by the constraint',
    v_rows = 2 AND (SELECT count(DISTINCT version) FROM oltp.submissions s
                    WHERE s.challenge_id=(SELECT challenge_id FROM oltp.challenges WHERE name='CC-RACE')) = 2,
    v_rows||' row(s), all versions distinct');
EXCEPTION WHEN others THEN
  BEGIN PERFORM dblink_disconnect('c1'); EXCEPTION WHEN others THEN NULL; END;
  PERFORM qa_true('C1','C1 concurrent version assignment','probe completed', FALSE,
    format('probe itself failed: [%s] %s', SQLSTATE, SQLERRM));
END $$;


-- =====================================================================
-- C2 — the gate versus an UNCOMMITTED review (TOCTOU)
-- =====================================================================
-- A judge is mid-transaction marking requires_resubmission. Should the
-- team's new version be allowed on the strength of a review nobody has
-- committed? No. This checks the gate reads committed state only.
DO $$
DECLARE v_ok BOOLEAN; v_before BOOLEAN; v_after BOOLEAN; v_j BIGINT;
BEGIN
  v_ok := qa.second_session('c2');
  IF NOT v_ok THEN
    PERFORM qa_pending('C2','gate vs uncommitted review','SKIPPED','no second backend available');
    RETURN;
  END IF;
  v_j := (SELECT account_id FROM oltp.accounts WHERE email='cj1@t');

  -- judge writes a TRUE review but does not commit
  PERFORM dblink_exec('c2','BEGIN');
  PERFORM dblink_exec('c2', format(
    'INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission)
     VALUES (%s,%s,TRUE)', qa.sub('CC-GATE'), v_j));

  -- the rule, evaluated from this session, must not see it
  SELECT coalesce(bool_or(requires_resubmission),FALSE) INTO v_before
    FROM oltp.submission_reviews WHERE submission_id = qa.sub('CC-GATE');
  PERFORM qa_true('C2','C2 an uncommitted review does not open the right',
    'READ COMMITTED must hide another session''s in-flight decision',
    v_before = FALSE,
    'bool_or from this session while the judge''s transaction is open = '||v_before);

  PERFORM dblink_exec('c2','COMMIT');

  SELECT coalesce(bool_or(requires_resubmission),FALSE) INTO v_after
    FROM oltp.submission_reviews WHERE submission_id = qa.sub('CC-GATE');
  PERFORM qa_true('C2','C2 the same review opens it once committed',
    'the control: the review is real, so FALSE above was isolation and not absence',
    v_after = TRUE, 'bool_or after the judge commits = '||v_after);

  PERFORM dblink_disconnect('c2');
EXCEPTION WHEN others THEN
  BEGIN PERFORM dblink_disconnect('c2'); EXCEPTION WHEN others THEN NULL; END;
  PERFORM qa_true('C2','C2 gate vs uncommitted review','probe completed', FALSE,
    format('probe itself failed: [%s] %s', SQLSTATE, SQLERRM));
END $$;


-- =====================================================================
-- C3 — the justification is withdrawn after it was used
-- =====================================================================
-- v1 asks for a resubmission, v2 is created on that basis, then the
-- judge changes their mind. v2 already exists. Single-session, but it is
-- a TIME question, which is why it belongs here rather than in phase 2.
DO $$
DECLARE v_j BIGINT; v_v2 BIGINT; v_still INT; v_now BOOLEAN;
BEGIN
  v_j := (SELECT account_id FROM oltp.accounts WHERE email='cj1@t');
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission)
    VALUES (qa.sub('CC-WITHDRAW'), v_j, TRUE);

  INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id)
    SELECT team_id,challenge_id,'withdrawn-basis v2',submitted_by_account_id
    FROM oltp.submissions WHERE submission_id = qa.sub('CC-WITHDRAW')
    RETURNING submission_id INTO v_v2;
  PERFORM qa_pre('C3','C3 v2 exists before the basis is withdrawn', v_v2 IS NOT NULL,
    'v2 submission_id='||v_v2||' -- without a real child, retracting the review proves nothing');

  -- the judge retracts
  UPDATE oltp.submission_reviews SET requires_resubmission = FALSE
   WHERE submission_id = qa.sub('CC-WITHDRAW') AND judge_id = v_j;

  SELECT coalesce(bool_or(requires_resubmission),FALSE) INTO v_now
    FROM oltp.submission_reviews WHERE submission_id = qa.sub('CC-WITHDRAW');
  SELECT count(*) INTO v_still FROM oltp.submissions WHERE submission_id = v_v2;

  PERFORM qa_gap('C3','C3-GAP a version outlives the request that justified it',
    'is the right consumed, or merely checked once?',
    format('v2 exists (%s row) and the parent''s bool_or is now %s', v_still, v_now),
    'The version was authorised at insert time and nothing revisits that decision. Retracting '
    ||'the review leaves a version whose justification no longer exists, and no query flags it. '
    ||'The R3 gate, now adopted, does NOT close this -- it checks on INSERT only, and this suite '
    ||'is the evidence that adopting it did not quietly cover the case. '
    ||'Whether this matters is a business question: "the right was exercised" may reasonably be '
    ||'permanent. Recorded so the answer is chosen rather than inherited.');

  PERFORM qa_note('C3','C3-NOTE what closing it would take',
    'for the reviewer, not implemented here',
    'Either make the decision durable (record on the child which review authorised it, so the link '
    ||'survives a retraction), or forbid retraction once a child exists. Both are schema changes; '
    ||'neither is proposed until the business answer is known.');
END $$;


-- =====================================================================
-- C4 — two judges reviewing the same submission at the same time
-- =====================================================================
-- Different rows, so this must NOT block. If it did, a busy panel would
-- serialise on one submission.
DO $$
DECLARE v_ok BOOLEAN; v_j1 BIGINT; v_j2 BIGINT; v_state TEXT; v_n INT;
BEGIN
  v_ok := qa.second_session('c4');
  IF NOT v_ok THEN
    PERFORM qa_pending('C4','concurrent reviews by two judges','SKIPPED','no second backend available');
    RETURN;
  END IF;
  v_j1 := (SELECT account_id FROM oltp.accounts WHERE email='cj1@t');
  v_j2 := (SELECT account_id FROM oltp.accounts WHERE email='cj2@t');

  PERFORM dblink_exec('c4','BEGIN');
  PERFORM dblink_exec('c4', format(
    'INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission)
     VALUES (%s,%s,TRUE)', qa.sub('CC-REVIEWS'), v_j1));

  SET LOCAL lock_timeout = '3s';
  BEGIN
    INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission)
      VALUES (qa.sub('CC-REVIEWS'), v_j2, FALSE);
    v_state := 'OK';
  EXCEPTION WHEN others THEN
    v_state := SQLSTATE;
  END;

  PERFORM qa_true('C4','C4 a second judge is not blocked by the first',
    'distinct (submission, judge) rows must not serialise',
    v_state = 'OK',
    CASE WHEN v_state='OK' THEN 'inserted while the other judge''s transaction was still open'
         ELSE 'blocked with ['||v_state||'] -- a busy panel would queue on one submission' END);

  PERFORM dblink_exec('c4','COMMIT');
  SELECT count(*) INTO v_n FROM oltp.submission_reviews WHERE submission_id = qa.sub('CC-REVIEWS');
  PERFORM qa_true('C4','C4 both reviews landed',
    'the control: neither write was silently lost',
    v_n = 2, v_n||' review(s) on the submission');

  PERFORM dblink_disconnect('c4');
EXCEPTION WHEN others THEN
  BEGIN PERFORM dblink_disconnect('c4'); EXCEPTION WHEN others THEN NULL; END;
  PERFORM qa_true('C4','C4 concurrent reviews','probe completed', FALSE,
    format('probe itself failed: [%s] %s', SQLSTATE, SQLERRM));
END $$;


-- =====================================================================
-- Report -- identical shape in every suite, from the shared harness.
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
