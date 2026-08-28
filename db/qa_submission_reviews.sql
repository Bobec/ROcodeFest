-- =====================================================================
-- QA — judge feedback via oltp.submission_reviews
-- =====================================================================
-- Scope: submission_reviews (review_id, submission_id, judge_id,
-- feedback, requires_resubmission) against submissions. Out of scope by
-- instruction: the CONSEQUENCE of a resubmission (a new submissions
-- version), and the analytics star.
--
-- CREDIBILITY RULE, enforced mechanically rather than by convention:
-- qa_pair() runs a POSITIVE CONTROL and the REJECTION as one unit. The
-- case can only be PASS if the control actually inserted rows AND the
-- negative was refused. If the control does not take effect, the case
-- is FAIL with "the negative proves nothing" -- a rejection next to a
-- control that never ran is not evidence.
--
-- Result states: PASS | FAIL | GAP | NOTE.
--   GAP  = the database permits something the domain arguably should
--          not. Recorded as a discovered gap, never as a passed test.
--   NOTE = observation / aggregation, no rule asserted.
-- Only FAIL exits non-zero.
--
--   psql -d qa_rev -f db/01_oltp_schema.sql
--   psql -d qa_rev -f db/qa_submission_reviews.sql
-- =====================================================================

\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;
-- Helpers come from the shared harness. They used to be defined
-- inline here, one private copy per suite, which is why a fix to
-- qa_reject's vacuity guard reached exactly one of them.
\ir _qa_harness.sql
SELECT qa.suite('reviews');

-- ---------------------------------------------------------------------
-- Fixture: two challenges, so "a judge with no tie to this challenge"
-- is a distinguishable notion rather than a hypothetical.
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('c@t','x','club'), ('m@t','x','member'),
  ('jA@t','x','judge'), ('jB@t','x','judge'), ('jC@t','x','judge'), ('jX@t','x','judge'),
  -- jD is reserved for C2's positive control: every other judge is
  -- consumed by group B, and a control that inserts 0 rows makes the
  -- paired rejection prove nothing.
  ('jD@t','x','judge');
INSERT INTO oltp.clubs(account_id,club_name) SELECT account_id,'C' FROM oltp.accounts WHERE email='c@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,'M' FROM oltp.accounts WHERE email='m@t';
INSERT INTO oltp.judges(account_id,full_name)
  SELECT account_id,'J '||email FROM oltp.accounts WHERE role='judge';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'T1','T-1' FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.seasons(name,start_date) VALUES ('S','2026-01-01');
INSERT INTO oltp.challenges(season_id,name,stage)
  SELECT season_id,'Challenge ONE','city_challenge' FROM oltp.seasons;
INSERT INTO oltp.challenges(season_id,name,stage)
  SELECT season_id,'Challenge TWO','final' FROM oltp.seasons;

-- one submission per challenge (version 1 each; no resubmission here)
INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
  SELECT t.team_id,c.challenge_id,'Sub for ONE',a.account_id,'2026-05-01 09:00+00'
  FROM oltp.teams t, oltp.challenges c, oltp.accounts a
  WHERE c.name='Challenge ONE' AND a.email='m@t';
INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
  SELECT t.team_id,c.challenge_id,'Sub for TWO',a.account_id,'2026-05-01 09:00+00'
  FROM oltp.teams t, oltp.challenges c, oltp.accounts a
  WHERE c.name='Challenge TWO' AND a.email='m@t';

-- jX is tied ONLY to Challenge TWO, by having reviewed its submission.
-- That is the only kind of "tie" the schema can express today.
INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback,reviewed_at)
  SELECT s.submission_id,a.account_id,'jX works on Challenge TWO',now()
  FROM oltp.submissions s, oltp.accounts a
  WHERE s.title='Sub for TWO' AND a.email='jX@t';


-- =====================================================================
-- GROUP A — the feedback column: faithful persistence
-- =====================================================================
DO $$
DECLARE
  v_s1 BIGINT := (SELECT submission_id FROM oltp.submissions WHERE title='Sub for ONE');
  v_s2 BIGINT := (SELECT submission_id FROM oltp.submissions WHERE title='Sub for TWO');
  v_jA BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jA@t');
  v_jB BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jB@t');
  v_jC BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jC@t');
  v_long TEXT := repeat('Recenzie ăâîșț ĂÂÎȘȚ 0123456789 ', 8000);  -- ~256k chars
  v_uni  TEXT := 'Diacritice: ăâîșț ĂÂÎȘȚ | Ø å ç ñ ü | CJK: 机器人 | emoji: 🤖🏆 | RTL: مرحبا';
  v_back TEXT; v_len INT; v_rev BIGINT;
BEGIN
  -- A1 long text round-trip, byte-for-byte
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback,reviewed_at)
    VALUES (v_s1,v_jA,v_long,now()) RETURNING review_id INTO v_rev;
  SELECT feedback, length(feedback) INTO v_back, v_len
    FROM oltp.submission_reviews WHERE review_id=v_rev;
  PERFORM qa_true('A','A1 long feedback round-trips without truncation',
    'a long review body is stored and read back identical',
    v_back = v_long AND v_len = length(v_long),
    format('wrote %s chars, read %s chars, identical=%s', length(v_long), v_len, (v_back = v_long)));

  -- A2 Unicode round-trip
  UPDATE oltp.submission_reviews SET feedback=v_uni WHERE review_id=v_rev;
  SELECT feedback INTO v_back FROM oltp.submission_reviews WHERE review_id=v_rev;
  PERFORM qa_true('A','A2 Unicode / diacritics round-trip',
    'diacritics, CJK, emoji and RTL survive a write/read cycle',
    v_back = v_uni, 'read back: ' || left(v_back, 60) || '...');

  -- A3 NULL vs empty string: BOTH accepted, and distinguishable on read
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback)
    VALUES (v_s1,v_jB,NULL);
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback)
    VALUES (v_s1,v_jC,'');
  PERFORM qa_true('A','A3 NULL and empty string are both stored and remain distinct',
    'the schema comment says NULL = assigned but not yet reviewed; empty string is a different value',
    (SELECT feedback IS NULL FROM oltp.submission_reviews WHERE submission_id=v_s1 AND judge_id=v_jB)
    AND (SELECT feedback = '' FROM oltp.submission_reviews WHERE submission_id=v_s1 AND judge_id=v_jC),
    'IS NULL and = '''' are separately queryable');

  -- Was A3-GAP: nothing tied feedback to reviewed_at, so the two signals
  -- for "has this been reviewed?" could contradict each other -- a row
  -- claiming a review timestamp with no text says a judge reviewed the
  -- submission and said nothing, which reads as an empty verdict rather
  -- than a missing one. R8 made the two agree.
  PERFORM qa_pair('A','A3 a review that was WRITTEN must say something',
    'ck_submission_reviews_verdict_has_text -- the same update WITH text is the control',
    format('UPDATE oltp.submission_reviews SET reviewed_at=now(), feedback=''looks fine'' '
           ||'WHERE judge_id=%s AND submission_id=%s', v_jB, v_s1),
    format('UPDATE oltp.submission_reviews SET reviewed_at=now(), feedback=NULL '
           ||'WHERE judge_id=%s AND submission_id=%s', v_jC, v_s1));

  PERFORM qa_true('A','A3 an ASSIGNED review may still be empty',
    'assigned-but-not-yet-reviewed is the ordinary starting state and must stay legal',
    EXISTS (SELECT 1 FROM oltp.submission_reviews
             WHERE submission_id=v_s1 AND reviewed_at IS NULL),
    (SELECT count(*)::text||' review(s) stand with no timestamp and no text'
       FROM oltp.submission_reviews WHERE submission_id=v_s1 AND reviewed_at IS NULL));
  PERFORM qa_note('A','A3-NOTE which of NULL / empty string is the intended rule',
    'to confirm with the domain owner',
    'Schema comment designates NULL as "assigned, not yet reviewed". Empty string therefore ought to mean '
    ||'"reviewed, no remarks" -- but nothing enforces that reading, and no CHECK forbids '''' either. '
    ||'A CHECK (feedback <> '''') would make the distinction real; not proposed here, flagged for Phase 2.');
END $$;


-- =====================================================================
-- GROUP B — the right to leave feedback (FKs)
-- =====================================================================
DO $$
DECLARE
  v_s1 BIGINT := (SELECT submission_id FROM oltp.submissions WHERE title='Sub for ONE');
  v_s2 BIGINT := (SELECT submission_id FROM oltp.submissions WHERE title='Sub for TWO');
  v_jA BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jA@t');
  v_jX BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jX@t');
  v_mem BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='m@t');
  v_club BIGINT := (SELECT account_id FROM oltp.clubs LIMIT 1);
  v_ghost BIGINT := 999999;
BEGIN
  -- B1 submission_id must exist
  PERFORM qa_pair('B','B1 submission_id must reference a live submission',
    'a review cannot hang off a submission that does not exist',
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback) VALUES (%s,%s,''control: real submission'')', v_s2, v_jA),
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback) VALUES (%s,%s,''ghost submission'')', v_ghost, v_jA));

  -- B2 judge_id must exist
  PERFORM qa_pair('B','B2 judge_id must reference a live judge',
    'a review cannot be attributed to an account that does not exist',
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback) VALUES (%s,%s,''control: real judge'')',
           v_s2, (SELECT account_id FROM oltp.accounts WHERE email='jB@t')),
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback) VALUES (%s,%s,''ghost judge'')', v_s2, v_ghost));

  -- B3 the account must be a JUDGE, not merely an account
  PERFORM qa_pair('B','B3 a member account cannot leave a review',
    'judge_id is FK to judges, so a non-judge account is refused',
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback) VALUES (%s,%s,''control: judge jC'')',
           v_s2, (SELECT account_id FROM oltp.accounts WHERE email='jC@t')),
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback) VALUES (%s,%s,''member tries'')', v_s2, v_mem));

  PERFORM qa_pair('B','B4 a club account cannot leave a review',
    'same seam, different non-judge role',
    format('UPDATE oltp.submission_reviews SET feedback=''control: touched an existing review'' WHERE submission_id=%s AND judge_id=%s', v_s2, v_jX),
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback) VALUES (%s,%s,''club tries'')', v_s2, v_club));

  -- ------------------------------------------------------------------
  -- B5 THE CRITICAL SEAM: right judge, wrong challenge
  -- ------------------------------------------------------------------
  -- jX has only ever worked on Challenge TWO. Nothing in the schema
  -- relates a judge to a challenge, so this is expected to be ACCEPTED.
  -- Recorded as a GAP, not as a passing test.
  PERFORM qa_note('B','B5-SETUP jX is tied only to Challenge TWO',
    'establish that "unrelated to Challenge ONE" is a real property of jX, not an assumption',
    format('jX has %s review(s), all on Challenge TWO; %s on Challenge ONE',
      (SELECT count(*) FROM oltp.submission_reviews r JOIN oltp.submissions s ON s.submission_id=r.submission_id
        JOIN oltp.challenges c ON c.challenge_id=s.challenge_id WHERE r.judge_id=v_jX AND c.name='Challenge TWO'),
      (SELECT count(*) FROM oltp.submission_reviews r JOIN oltp.submissions s ON s.submission_id=r.submission_id
        JOIN oltp.challenges c ON c.challenge_id=s.challenge_id WHERE r.judge_id=v_jX AND c.name='Challenge ONE')));

  BEGIN
    INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback,reviewed_at)
      VALUES (v_s1, v_jX, 'jX reviews a challenge it was never assigned to', now());
    PERFORM qa_gap('B','B5-GAP a judge with no tie to the challenge CAN review it',
      'the twin of fk_scores_match_judge on scores -- does the schema stop the wrong judge?',
      'ACCEPTED. submission_reviews.judge_id proves the account is A judge, never THE judge for this '
      ||'submission''s challenge. There is no judge<->challenge (nor judge<->submission assignment) '
      ||'relation to constrain against. Note that the proposed fk_scores_match_judge would guard the '
      ||'SCORES side only; this side would remain open.');
  EXCEPTION WHEN others THEN
    PERFORM qa_true('B','B5 a judge with no tie to the challenge is refused',
      'the schema does constrain judge<->challenge after all',
      TRUE, format('rejected [%s] %s -- the gap does not exist', SQLSTATE, SQLERRM));
  END;

  -- control proving B5's insert path is otherwise ordinary
  PERFORM qa_note('B','B5-CONTROL an assigned judge reviewing the same submission',
    'shows the DB treats related and unrelated judges identically',
    format('jA (also unrelated by any stored fact) already holds %s review(s) on Challenge ONE -- '
           ||'indistinguishable from jX''s insert',
      (SELECT count(*) FROM oltp.submission_reviews WHERE submission_id=v_s1 AND judge_id=v_jA)));
END $$;


-- =====================================================================
-- GROUP C — multiplicity (1:N)
-- =====================================================================
DO $$
DECLARE
  v_s1 BIGINT := (SELECT submission_id FROM oltp.submissions WHERE title='Sub for ONE');
  v_s2 BIGINT := (SELECT submission_id FROM oltp.submissions WHERE title='Sub for TWO');
  v_jA BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jA@t');
  v_jD BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jD@t');
  v_n INT; v_judges INT;
BEGIN
  -- C1 positive: several judges review one submission
  SELECT count(*), count(DISTINCT judge_id) INTO v_n, v_judges
    FROM oltp.submission_reviews WHERE submission_id=v_s1;
  PERFORM qa_true('C','C1 one submission carries reviews from several judges (1:N)',
    '1:N must not be blocked -- multiple judges may review the same submission',
    v_n >= 2 AND v_judges >= 2,
    format('%s review(s) from %s distinct judge(s) on submission %s', v_n, v_judges, v_s1));

  -- C2 negative: the SAME judge twice on the SAME submission.
  -- The control is the FIRST of those two inserts: identical statement,
  -- identical pair. If the first succeeds and the second is refused, the
  -- rejection is attributable to duplication and nothing else.
  PERFORM qa_pair('C','C2 the same judge cannot review one submission twice',
    'uq_submission_reviews_submission_judge scopes uniqueness to (submission, judge)',
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback) VALUES (%s,%s,''control: jD first review'')', v_s1, v_jD),
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback) VALUES (%s,%s,''jD second review, same submission'')', v_s1, v_jD));

  -- and the same judge on a DIFFERENT submission is fine -- proving the
  -- constraint is scoped to the pair, not to the judge
  PERFORM qa_pair('C','C2b the pair, not the judge, is what is unique',
    'the same judge may review another submission; only the repeat pair is refused',
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback) VALUES (%s,%s,''control: jD on the OTHER submission'')', v_s2, v_jD),
    format('INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback) VALUES (%s,%s,''jD repeats on the other submission'')', v_s2, v_jD));

  PERFORM qa_note('C','C2-NOTE the intended rule, confirmed against the schema',
    'is a repeat review by the same judge meant to be blocked?',
    'BLOCKED by uq_submission_reviews_submission_judge. The schema comment states a judge revising their '
    ||'view should UPDATE the existing row, and that a re-review of a RESUBMISSION is a new submissions '
    ||'row getting its own review. Consistent with the constraint -- no contradiction found.');

  -- C3 a judge may review many different submissions
  PERFORM qa_true('C','C3 one judge may review many submissions (the other 1:N direction)',
    'uniqueness is on the pair, so a judge is not limited to one review overall',
    (SELECT count(*) FROM oltp.submission_reviews WHERE judge_id=v_jA) >= 2,
    format('judge %s holds %s review(s) across %s submission(s)', v_jA,
      (SELECT count(*) FROM oltp.submission_reviews WHERE judge_id=v_jA),
      (SELECT count(DISTINCT submission_id) FROM oltp.submission_reviews WHERE judge_id=v_jA)));
END $$;


-- =====================================================================
-- GROUP D — requires_resubmission as review state ONLY
-- =====================================================================
-- No expectation of, and no trigger for, a new submissions version.
DO $$
DECLARE
  v_s1 BIGINT := (SELECT submission_id FROM oltp.submissions WHERE title='Sub for ONE');
  v_jA BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jA@t');
  v_jB BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jB@t');
  v_jC BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jC@t');
  v_jX BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='jX@t');
  v_any BOOLEAN; v_all BOOLEAN; v_latest BOOLEAN; v_t INT; v_f INT;
  v_versions INT;
BEGIN
  -- D1 default
  PERFORM qa_true('D','D1 requires_resubmission defaults to FALSE',
    'an unmarked review does not implicitly demand a resubmission',
    (SELECT requires_resubmission = FALSE FROM oltp.submission_reviews
      WHERE submission_id=v_s1 AND judge_id=v_jC),
    'inserted without the column, read back FALSE');

  -- D2 true/false round-trip
  UPDATE oltp.submission_reviews SET requires_resubmission=TRUE  WHERE submission_id=v_s1 AND judge_id=v_jA;
  UPDATE oltp.submission_reviews SET requires_resubmission=FALSE WHERE submission_id=v_s1 AND judge_id=v_jB;
  UPDATE oltp.submission_reviews SET requires_resubmission=TRUE  WHERE submission_id=v_s1 AND judge_id=v_jX;
  PERFORM qa_true('D','D2 TRUE and FALSE both round-trip',
    'the flag is written and read faithfully in both directions',
    (SELECT requires_resubmission FROM oltp.submission_reviews WHERE submission_id=v_s1 AND judge_id=v_jA)
    AND NOT (SELECT requires_resubmission FROM oltp.submission_reviews WHERE submission_id=v_s1 AND judge_id=v_jB),
    'jA=TRUE, jB=FALSE read back as written');

  -- D3 NOT NULL, with a positive control
  PERFORM qa_pair('D','D3 requires_resubmission cannot be NULL',
    'the flag is a decision; "unknown" is not a permitted third state',
    format('UPDATE oltp.submission_reviews SET requires_resubmission=TRUE WHERE submission_id=%s AND judge_id=%s', v_s1, v_jC),
    format('UPDATE oltp.submission_reviews SET requires_resubmission=NULL WHERE submission_id=%s AND judge_id=%s', v_s1, v_jA));

  -- reset jC so the divergence below is genuinely mixed
  UPDATE oltp.submission_reviews SET requires_resubmission=FALSE WHERE submission_id=v_s1 AND judge_id=v_jC;

  -- D4 divergence across reviews of ONE submission: observation only
  SELECT bool_or(requires_resubmission), bool_and(requires_resubmission),
         count(*) FILTER (WHERE requires_resubmission), count(*) FILTER (WHERE NOT requires_resubmission)
    INTO v_any, v_all, v_t, v_f
    FROM oltp.submission_reviews WHERE submission_id=v_s1;
  SELECT requires_resubmission INTO v_latest
    FROM oltp.submission_reviews WHERE submission_id=v_s1
    ORDER BY coalesce(reviewed_at, assigned_at) DESC, review_id DESC LIMIT 1;

  PERFORM qa_note('D','D4 divergent flags on one submission are permitted',
    'how would a single answer to "is a resubmission required?" be derived?',
    format('submission %s has %s TRUE and %s FALSE. Three defensible aggregations DISAGREE on this same row set: '
           ||'ANY (bool_or) = %s | ALL (bool_and) = %s | LATEST-WINS = %s. '
           ||'The schema imposes none of them.', v_s1, v_t, v_f, v_any, v_all, v_latest));

  PERFORM qa_true('D','D4-EVIDENCE the aggregations really disagree (not a hypothetical)',
    'the divergence must be demonstrable on actual rows, or the note is empty',
    v_any IS DISTINCT FROM v_all,
    format('ANY=%s vs ALL=%s on the same %s review(s)', v_any, v_all, v_t + v_f));

  -- D5 scope guard: no submissions version was created by any of this
  SELECT count(*) INTO v_versions FROM oltp.submissions WHERE submission_id=v_s1;
  PERFORM qa_true('D','D5 nothing here created a new submissions version',
    'requires_resubmission is tested strictly as review state; the consequence is out of scope',
    v_versions = 1
    AND (SELECT count(*) FROM oltp.submissions
         WHERE team_id=(SELECT team_id FROM oltp.submissions WHERE submission_id=v_s1)
           AND challenge_id=(SELECT challenge_id FROM oltp.submissions WHERE submission_id=v_s1)) = 1,
    'still exactly one submissions row for this (team, challenge) -- version 1, untouched');
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
