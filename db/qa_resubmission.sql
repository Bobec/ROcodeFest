-- =====================================================================
-- QA — the CONSEQUENCE of a resubmission (Phase 2)
-- =====================================================================
-- Business rule under test:
--   when at least one review of a submission has
--   requires_resubmission = TRUE, the team gains the right to upload a
--   new version. Aggregation is ANY / bool_or over ALL reviews of that
--   submission -- not ALL, not latest-wins.
--
-- Scope: oltp.submissions x oltp.submission_reviews. Analytics untouched.
-- No migration applied; any proposed constraint goes to db/proposals/.
--
-- CREDIBILITY RULE: every expected rejection runs as qa_pair() -- a
-- positive control that actually inserts, plus the rejection. PASS only
-- if the control took effect.
--
-- Result states: PASS | FAIL | GAP | NOTE. Only FAIL exits non-zero.
-- GAP = the database permits what the business rule forbids. Recorded
-- as a discovered gap, never as a passed test.
--
--   psql -d qa_resub -f db/01_oltp_schema.sql
--   psql -d qa_resub -f db/qa_resubmission.sql
-- =====================================================================

\set ON_ERROR_STOP on
SET client_min_messages = NOTICE;
-- Helpers come from the shared harness. They used to be defined
-- inline here, one private copy per suite, which is why a fix to
-- qa_reject's vacuity guard reached exactly one of them.
\ir _qa_harness.sql
SELECT qa.suite('resubmission');

-- the business rule, expressed once, exactly as specified
CREATE OR REPLACE FUNCTION qa_resubmit_allowed(p_submission BIGINT) RETURNS BOOLEAN AS $fn$
  SELECT coalesce(bool_or(requires_resubmission), FALSE)
  FROM oltp.submission_reviews WHERE submission_id = p_submission;
$fn$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Fixture: four independent chains, one per scenario, so a test cannot
-- disturb another's preconditions.
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('c@t','x','club'), ('m@t','x','member'),
  ('j1@t','x','judge'), ('j2@t','x','judge'), ('j3@t','x','judge'),
  ('j4@t','x','judge'), ('j5@t','x','judge');
INSERT INTO oltp.clubs(account_id,club_name) SELECT account_id,'C' FROM oltp.accounts WHERE email='c@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,'M' FROM oltp.accounts WHERE email='m@t';
INSERT INTO oltp.judges(account_id,full_name) SELECT account_id,'J '||email FROM oltp.accounts WHERE role='judge';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'T1','T-1' FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'T2','T-2' FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.seasons(name,start_date) VALUES ('S','2026-01-01');
-- Since the R3 gate was adopted a chain is STATEFUL: creating a version
-- consumes the parent's open request, so two groups can no longer share
-- one chain the way they did when nothing consulted the reviews. Each
-- group that needs a usable positive control now gets its own chain.
INSERT INTO oltp.challenges(season_id,name,stage)
  SELECT s.season_id, n, 'city_challenge' FROM oltp.seasons s,
    (VALUES ('CH-MIXED'),('CH-ALLFALSE'),('CH-NOREVIEWS'),('CH-ROUNDS'),
            ('CH-CTRL1'),('CH-CTRL2'),('CH-LINEAGE'),('CH-BURST')) AS c(n);

-- v1 of each chain, all for team T1
INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
SELECT t.team_id, c.challenge_id, c.name||' v1', a.account_id, '2026-05-01 09:00+00'
FROM oltp.teams t, oltp.challenges c, oltp.accounts a
WHERE t.participation_code='T-1' AND a.email='m@t';

-- CH-MIXED: 2 TRUE + 3 FALSE  -> bool_or = TRUE   (the Phase 1 case D)
INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission,feedback,reviewed_at)
SELECT s.submission_id, a.account_id,
       (a.email IN ('j1@t','j2@t')), 'review', now()
FROM oltp.submissions s JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
   , oltp.accounts a
WHERE c.name='CH-MIXED' AND a.role='judge';

-- CH-ALLFALSE: every review FALSE -> bool_or = FALSE
INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission,feedback,reviewed_at)
SELECT s.submission_id, a.account_id, FALSE, 'no rework needed', now()
FROM oltp.submissions s JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
   , oltp.accounts a
WHERE c.name='CH-ALLFALSE' AND a.role='judge';

-- CH-NOREVIEWS: deliberately left with zero reviews
--
-- The rest each get exactly ONE TRUE review on v1, which is the minimum
-- that opens the gate. They exist to be the positive control half of a
-- pair: a refusal only means something if the same statement, run
-- against a chain whose parent DID ask for rework, goes through.
--   CH-ROUNDS   round-1 legitimacy (H2's "other challenge" case)
--   CH-CTRL1    control for G2, and later for I2
--   CH-CTRL2    control for G3
--   CH-LINEAGE  H3's own chain, so its inserts cannot disturb CH-MIXED
--   CH-BURST    J1's chain
INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission,feedback,reviewed_at)
SELECT s.submission_id, a.account_id, TRUE, 'needs rework', now()
FROM oltp.submissions s JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
   , oltp.accounts a
WHERE c.name IN ('CH-ROUNDS','CH-CTRL1','CH-CTRL2','CH-LINEAGE','CH-BURST')
  AND a.email='j1@t';


-- =====================================================================
-- G — the ANY / bool_or aggregation (the central invariant)
-- =====================================================================
DO $$
DECLARE
  v_mixed BIGINT; v_allf BIGINT; v_none BIGINT; v_ctrl1 BIGINT; v_ctrl2 BIGINT;
  v_t INT; v_f INT; v_ver SMALLINT; v_rows BIGINT;
BEGIN
  SELECT s.submission_id INTO v_mixed FROM oltp.submissions s
    JOIN oltp.challenges c ON c.challenge_id=s.challenge_id WHERE c.name='CH-MIXED';
  SELECT s.submission_id INTO v_allf FROM oltp.submissions s
    JOIN oltp.challenges c ON c.challenge_id=s.challenge_id WHERE c.name='CH-ALLFALSE';
  SELECT s.submission_id INTO v_none FROM oltp.submissions s
    JOIN oltp.challenges c ON c.challenge_id=s.challenge_id WHERE c.name='CH-NOREVIEWS';
  SELECT s.submission_id INTO v_ctrl1 FROM oltp.submissions s
    JOIN oltp.challenges c ON c.challenge_id=s.challenge_id WHERE c.name='CH-CTRL1';
  SELECT s.submission_id INTO v_ctrl2 FROM oltp.submissions s
    JOIN oltp.challenges c ON c.challenge_id=s.challenge_id WHERE c.name='CH-CTRL2';

  -- ---- G1 mixed reviews -> ANY = TRUE ------------------------------
  SELECT count(*) FILTER (WHERE requires_resubmission),
         count(*) FILTER (WHERE NOT requires_resubmission) INTO v_t, v_f
    FROM oltp.submission_reviews WHERE submission_id=v_mixed;
  PERFORM qa_true('G','G1-FIXTURE the mixed case really is mixed',
    'ANY must be tested on genuinely divergent rows, or it degenerates to a single-value check',
    v_t >= 2 AND v_f >= 3, format('%s TRUE and %s FALSE review(s)', v_t, v_f));

  PERFORM qa_true('G','G1 ANY/bool_or over mixed reviews = TRUE',
    'one dissenting judge is enough to open the right to a new version',
    qa_resubmit_allowed(v_mixed) = TRUE,
    format('bool_or=%s (ALL would say %s, latest-wins %s -- neither is the rule)',
      qa_resubmit_allowed(v_mixed),
      (SELECT bool_and(requires_resubmission) FROM oltp.submission_reviews WHERE submission_id=v_mixed),
      (SELECT requires_resubmission FROM oltp.submission_reviews WHERE submission_id=v_mixed
        ORDER BY coalesce(reviewed_at,assigned_at) DESC, review_id DESC LIMIT 1)));

  INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
    SELECT team_id, challenge_id, 'CH-MIXED v2', submitted_by_account_id, '2026-05-10 09:00+00'
    FROM oltp.submissions WHERE submission_id=v_mixed
    RETURNING version INTO v_ver;
  PERFORM qa_true('G','G1 a new version is accepted when the right is open',
    'the permitted case must actually work, else G2/G3 prove nothing',
    v_ver = 2, format('version %s created while bool_or=TRUE', v_ver));

  -- ---- G2 all reviews FALSE -> ANY = FALSE -------------------------
  PERFORM qa_true('G','G2 ANY/bool_or over all-FALSE reviews = FALSE',
    'unanimous "no rework" must not open the right',
    qa_resubmit_allowed(v_allf) = FALSE,
    format('bool_or=%s over %s review(s)', qa_resubmit_allowed(v_allf),
      (SELECT count(*) FROM oltp.submission_reviews WHERE submission_id=v_allf)));

  -- Was G2-GAP until R3 was adopted: nothing on oltp.submissions consulted
  -- submission_reviews, so the right to resubmit was not represented in the
  -- schema at all. enforce_resubmission_gate now consults it, and the case
  -- becomes a paired negative.
  --
  -- The two statements are the same INSERT..SELECT against two chains that
  -- differ in one respect: CH-CTRL1's v1 carries a TRUE review, CH-ALLFALSE's
  -- carries five FALSE ones. If the gate were dropped, the control would
  -- still succeed and only the negative would flip -- which is what makes
  -- the pass attributable to the rule rather than to the fixture.
  PERFORM qa_pair('G','G2 a new version is refused when bool_or = FALSE',
    'unanimous "no rework" is a dead end: the chain cannot advance',
    'INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at) '
      ||'SELECT team_id, challenge_id, ''CH-CTRL1 v2 (control)'', submitted_by_account_id, ''2026-05-10 09:00+00'' '
      ||'FROM oltp.submissions WHERE submission_id=' || v_ctrl1,
    'INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at) '
      ||'SELECT team_id, challenge_id, ''CH-ALLFALSE v2 (must be refused)'', submitted_by_account_id, ''2026-05-10 09:00+00'' '
      ||'FROM oltp.submissions WHERE submission_id=' || v_allf);

  -- ---- G3 zero reviews -> ANY undefined -> FALSE -------------------
  PERFORM qa_true('G','G3 ANY/bool_or over zero reviews resolves to FALSE',
    'an unreviewed submission must not confer the right (no skipping the review round)',
    qa_resubmit_allowed(v_none) = FALSE,
    format('bool_or over 0 review(s) is NULL; coalesce(...,FALSE) = %s', qa_resubmit_allowed(v_none)));

  -- Was G3-GAP: the review round could be skipped entirely. The gate reads
  -- coalesce(bool_or(...), FALSE), so zero rows aggregate to FALSE and an
  -- unreviewed parent blocks its child -- the same code path as G2, which
  -- is why one constraint closed both.
  PERFORM qa_pair('G','G3 a new version is refused with ZERO reviews on the parent',
    'the review round cannot be skipped: bool_or over no rows is FALSE, not permissive',
    'INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at) '
      ||'SELECT team_id, challenge_id, ''CH-CTRL2 v2 (control)'', submitted_by_account_id, ''2026-05-10 09:00+00'' '
      ||'FROM oltp.submissions WHERE submission_id=' || v_ctrl2,
    'INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at) '
      ||'SELECT team_id, challenge_id, ''CH-NOREVIEWS v2 (must be refused)'', submitted_by_account_id, ''2026-05-10 09:00+00'' '
      ||'FROM oltp.submissions WHERE submission_id=' || v_none);
END $$;


-- =====================================================================
-- H — is the new version well-formed?
-- =====================================================================
DO $$
DECLARE
  v_p BIGINT; v_c BIGINT; v_team BIGINT; v_chal BIGINT;
  v_t2 BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='T-2');
  v_other BIGINT; v_lin BIGINT;
  v_ver SMALLINT; v_new BIGINT;
BEGIN
  SELECT s.submission_id, s.team_id, s.challenge_id INTO v_p, v_team, v_chal
    FROM oltp.submissions s JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
    WHERE c.name='CH-MIXED' AND s.version=1;
  SELECT submission_id INTO v_c FROM oltp.submissions
    WHERE team_id=v_team AND challenge_id=v_chal AND version=2;

  -- H1 lineage + strict increment
  PERFORM qa_true('H','H1 the new version keeps team_id and challenge_id',
    'a resubmission belongs to the same team and the same challenge as its parent',
    (SELECT team_id FROM oltp.submissions WHERE submission_id=v_c) = v_team
    AND (SELECT challenge_id FROM oltp.submissions WHERE submission_id=v_c) = v_chal,
    format('parent(team=%s, challenge=%s) == child(team=%s, challenge=%s)', v_team, v_chal,
      (SELECT team_id FROM oltp.submissions WHERE submission_id=v_c),
      (SELECT challenge_id FROM oltp.submissions WHERE submission_id=v_c)));

  PERFORM qa_true('H','H1 version is strictly incremented (v -> v+1)',
    'trg_submissions_version assigns max(version)+1 per (team, challenge)',
    (SELECT version FROM oltp.submissions WHERE submission_id=v_c)
      = (SELECT version FROM oltp.submissions WHERE submission_id=v_p) + 1,
    format('parent v%s -> child v%s',
      (SELECT version FROM oltp.submissions WHERE submission_id=v_p),
      (SELECT version FROM oltp.submissions WHERE submission_id=v_c)));

  -- H2 a different team/challenge cannot masquerade as a resubmission
  INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
    VALUES (v_t2, v_chal, 'foreign team, same challenge', (SELECT account_id FROM oltp.accounts WHERE email='m@t'), '2026-05-11 09:00+00')
    RETURNING submission_id, version INTO v_new, v_ver;
  PERFORM qa_true('H','H2 changing team_id starts a NEW chain at v1, not v+1',
    'a foreign submission must not be able to present itself as the next version',
    v_ver = 1,
    format('team %s on the same challenge got version %s -- the chain is keyed by (team, challenge), '
           ||'so it cannot continue another team''s chain', v_t2, v_ver));

  SELECT challenge_id INTO v_other FROM oltp.challenges WHERE name='CH-ROUNDS';
  INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
    VALUES (v_team, v_other, 'same team, different challenge', (SELECT account_id FROM oltp.accounts WHERE email='m@t'), '2026-05-11 09:00+00')
    RETURNING version INTO v_ver;
  PERFORM qa_true('H','H2 changing challenge_id continues that challenge''s own chain',
    'the same team on another challenge advances the OTHER chain, never this one',
    v_ver = 2 AND (SELECT max(version) FROM oltp.submissions WHERE team_id=v_team AND challenge_id=v_chal) = 2,
    format('got v%s on CH-ROUNDS while CH-MIXED stayed at max v%s', v_ver,
      (SELECT max(version) FROM oltp.submissions WHERE team_id=v_team AND challenge_id=v_chal)));

  PERFORM qa_note('H','H2-NOTE there is no parent_submission_id',
    'how "resubmit of X" is actually expressed',
    'Lineage is implicit: the chain is (team_id, challenge_id) and order is `version`. No column points at '
    ||'the parent row. That is why H2 holds structurally -- a foreign submission simply lands in a '
    ||'different chain -- but it also means a review round cannot be tied to a specific parent by FK.');

  -- H3 runs on CH-LINEAGE, not CH-MIXED. Under the R3 gate an insert
  -- CONSUMES the parent's open request, so borrowing another group's chain
  -- would silently change what that group is testing.
  SELECT s.challenge_id INTO v_lin
    FROM oltp.submissions s JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
    WHERE c.name='CH-LINEAGE' AND s.version=1;

  -- H3 client-supplied version is overridden on INSERT (a strength)
  INSERT INTO oltp.submissions(team_id,challenge_id,version,title,submitted_by_account_id,created_at)
    VALUES (v_team, v_lin, 99, 'client claims v99', (SELECT account_id FROM oltp.accounts WHERE email='m@t'), '2026-05-12 09:00+00')
    RETURNING submission_id, version INTO v_new, v_ver;
  PERFORM qa_true('H','H3 a client-supplied version is ignored on INSERT',
    'the trigger assigns the version server-side, so a caller cannot skip or forge one',
    v_ver = 2, format('caller sent 99, stored %s', v_ver));

  -- H3 pair: version collisions are refused; a harmless UPDATE is not
  PERFORM qa_pair('H','H3 version cannot be UPDATEd onto an occupied value',
    'a duplicate version is refused, and the UPDATE path itself still works',
    format('UPDATE oltp.submissions SET title=''control: harmless update'' WHERE submission_id=%s', v_new),
    format('UPDATE oltp.submissions SET version=1 WHERE submission_id=%s', v_new));

  -- Was H3-GAP: version was mutable to any FREE value, so the QA run moved
  -- a row to version 7 and left the chain 1, 2, 7. The unique constraint
  -- caught collisions but never a SKIP, because trg_submissions_version is
  -- BEFORE INSERT only. R3 part 2 added an UPDATE-time guard, so the free
  -- value is now refused as well -- which is the case the unique constraint
  -- could never have covered.
  PERFORM qa_pair('H','H3 version cannot be UPDATEd to a FREE value either',
    'the sequence is protected after insert, not just against duplicates',
    format('UPDATE oltp.submissions SET title=''control: still a working UPDATE'' WHERE submission_id=%s', v_new),
    format('UPDATE oltp.submissions SET version=7 WHERE submission_id=%s', v_new));

  -- the mutation form of H2: moving a row between chains after the fact
  PERFORM qa_pair('H','H3 a submission cannot be moved to another chain after insert',
    'changing team or challenge post-hoc would land a row mid-sequence in a chain it never belonged to',
    format('UPDATE oltp.submissions SET description=''control: a non-lineage column'' WHERE submission_id=%s', v_new),
    format('UPDATE oltp.submissions SET team_id=%s WHERE submission_id=%s', v_t2, v_new));

  PERFORM qa_true('H','H3 the chain is left contiguous',
    'after all the refused mutations, CH-LINEAGE must still read 1, 2',
    (SELECT array_agg(version ORDER BY version) FROM oltp.submissions
      WHERE team_id=v_team AND challenge_id=v_lin) = ARRAY[1,2]::SMALLINT[],
    format('versions %s', (SELECT array_agg(version ORDER BY version) FROM oltp.submissions
      WHERE team_id=v_team AND challenge_id=v_lin)));
END $$;


-- =====================================================================
-- I — reviews belong to their own version ("one round per version")
-- =====================================================================
DO $$
DECLARE
  v_team BIGINT; v_chal BIGINT; v_v1 BIGINT; v_v2 BIGINT; v_v3 BIGINT;
  v_ver SMALLINT;
BEGIN
  SELECT s.team_id, s.challenge_id INTO v_team, v_chal
    FROM oltp.submissions s JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
    WHERE c.name='CH-MIXED' LIMIT 1;
  SELECT submission_id INTO v_v1 FROM oltp.submissions WHERE team_id=v_team AND challenge_id=v_chal AND version=1;
  SELECT submission_id INTO v_v2 FROM oltp.submissions WHERE team_id=v_team AND challenge_id=v_chal AND version=2;

  -- I1 a review on v2 must not change v1's verdict, or vice versa
  PERFORM qa_true('I','I1-FIXTURE v2 starts with no reviews',
    'the isolation claim needs a clean starting point',
    (SELECT count(*) FROM oltp.submission_reviews WHERE submission_id=v_v2) = 0,
    'v2 has 0 review(s) before this test writes any');

  INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission,feedback,reviewed_at)
    VALUES (v_v2, (SELECT account_id FROM oltp.accounts WHERE email='j3@t'), FALSE, 'v2 looks fine', now());

  PERFORM qa_true('I','I1 a review on v2 does not contaminate v1''s bool_or',
    'each version carries its own review round',
    qa_resubmit_allowed(v_v1) = TRUE AND qa_resubmit_allowed(v_v2) = FALSE,
    format('v1 bool_or=%s (unchanged), v2 bool_or=%s -- computed per submission_id',
      qa_resubmit_allowed(v_v1), qa_resubmit_allowed(v_v2)));

  PERFORM qa_true('I','I1 reviews stay attached to the version they were written for',
    'submission_reviews.submission_id is the only link, and it is exact',
    (SELECT count(*) FROM oltp.submission_reviews WHERE submission_id=v_v1) = 5
    AND (SELECT count(*) FROM oltp.submission_reviews WHERE submission_id=v_v2) = 1,
    format('v1 holds %s review(s), v2 holds %s',
      (SELECT count(*) FROM oltp.submission_reviews WHERE submission_id=v_v1),
      (SELECT count(*) FROM oltp.submission_reviews WHERE submission_id=v_v2)));

  -- I2 v3 while v2's round says FALSE
  PERFORM qa_true('I','I2-FIXTURE v2''s round has NOT asked for a resubmission',
    'the precondition that should block v3',
    qa_resubmit_allowed(v_v2) = FALSE, 'v2 bool_or = FALSE');

  -- Was I2-GAP: nothing consulted the previous round, so v3 could be created
  -- while v2's verdict was FALSE. The gate looks at the IMMEDIATE
  -- predecessor, which is the part that distinguishes this case from G2 --
  -- v1's round DID ask for rework, and that must no longer help v3.
  --
  -- The control opens CH-CTRL1's head so both statements are inserts of a
  -- third version; they differ only in whether the version below them asked.
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission,feedback,reviewed_at)
    VALUES ((SELECT submission_id FROM oltp.submissions s
               JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
              WHERE c.name='CH-CTRL1' AND s.version=2),
            (SELECT account_id FROM oltp.accounts WHERE email='j2@t'), TRUE, 'v2 needs rework', now());
  PERFORM qa_true('I','I2-FIXTURE the control chain''s head HAS asked',
    'the pair is only meaningful if the two chains differ in exactly this',
    qa_resubmit_allowed((SELECT submission_id FROM oltp.submissions s
        JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
       WHERE c.name='CH-CTRL1' AND s.version=2)) = TRUE,
    'CH-CTRL1 v2 bool_or = TRUE, CH-MIXED v2 bool_or = FALSE');

  PERFORM qa_pair('I','I2 v3 is refused when v2''s round never requested a resubmission',
    'the gate reads the immediately preceding version, so v1''s old TRUE verdict does not carry forward',
    format('INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at) '
           ||'SELECT team_id, challenge_id, ''CH-CTRL1 v3 (control)'', submitted_by_account_id, ''2026-05-15 09:00+00'' '
           ||'FROM oltp.submissions s JOIN oltp.challenges c USING (challenge_id) '
           ||'WHERE c.name=''CH-CTRL1'' AND s.version=2'),
    format('INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at) '
           ||'VALUES (%s, %s, ''v3 without v2 asking'', %s, ''2026-05-15 09:00+00'')',
           v_team, v_chal, (SELECT account_id FROM oltp.accounts WHERE email='m@t')));

  PERFORM qa_true('I','I2 an older TRUE verdict does not resurrect the chain',
    'v1 asked for rework and got v2; that request is spent',
    qa_resubmit_allowed(v_v1) = TRUE
    AND (SELECT max(version) FROM oltp.submissions WHERE team_id=v_team AND challenge_id=v_chal) = 2,
    format('v1 still reads bool_or=TRUE, yet CH-MIXED stops at v%s',
      (SELECT max(version) FROM oltp.submissions WHERE team_id=v_team AND challenge_id=v_chal)));
END $$;


-- =====================================================================
-- J — idempotence / anti-abuse: one request, one new version
-- =====================================================================
DO $$
DECLARE
  v_team BIGINT; v_chal BIGINT; v_v1 BIGINT;
  v_before INT; v_after INT; v_a SMALLINT; v_b SMALLINT;
BEGIN
  -- CH-BURST is J's own chain: H2 advances CH-ROUNDS, which would leave the
  -- head unreviewed and make burst A fail for a reason J is not testing.
  SELECT s.team_id, s.challenge_id, s.submission_id INTO v_team, v_chal, v_v1
    FROM oltp.submissions s JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
    WHERE c.name='CH-BURST' AND s.version=1;

  PERFORM qa_true('J','J1-FIXTURE the parent round asked for exactly ONE resubmission',
    'one request is the unit being tested',
    qa_resubmit_allowed(v_v1) = TRUE
    AND (SELECT count(*) FROM oltp.submission_reviews WHERE submission_id=v_v1 AND requires_resubmission) = 1,
    'CH-BURST v1: bool_or=TRUE from a single TRUE review');

  SELECT count(*) INTO v_before FROM oltp.submissions WHERE team_id=v_team AND challenge_id=v_chal;

  -- Was J1-GAP: one TRUE review permitted UNLIMITED new versions, because
  -- the right was never consumed. The gate does not mark a request "used" --
  -- it does not have to. Requiring the IMMEDIATE predecessor to have asked
  -- means the second burst insert would need the first one reviewed, and
  -- the first one was created seconds ago with no reviews at all.
  --
  -- This pair is the two halves of the burst, in order: the first insert is
  -- the control and must succeed, the second must not.
  PERFORM qa_pair('J','J1 one request yields exactly one new version',
    'a burst is self-limiting: the second insert would need the first reviewed',
    format('INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at) '
           ||'VALUES (%s,%s,''burst A'',%s,''2026-05-16 09:00+00'')',
           v_team, v_chal, (SELECT account_id FROM oltp.accounts WHERE email='m@t')),
    format('INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at) '
           ||'VALUES (%s,%s,''burst B'',%s,''2026-05-16 09:01+00'')',
           v_team, v_chal, (SELECT account_id FROM oltp.accounts WHERE email='m@t')));

  SELECT count(*) INTO v_after FROM oltp.submissions WHERE team_id=v_team AND challenge_id=v_chal;
  PERFORM qa_true('J','J1 the chain grew by exactly one row',
    'counting the outcome, not just the exception: a refused insert must leave nothing behind',
    v_after = v_before + 1, format('chain went %s -> %s row(s)', v_before, v_after));

  PERFORM qa_note('J','J1-NOTE one constraint closed four cases',
    'why G2, G3, I2 and J1 were one defect seen from four angles',
    'The rule "version N+1 may exist only if version N has bool_or = TRUE" is inductive: v3 needs v2 reviewed, '
    ||'so a burst is impossible, an unreviewed parent blocks the child, and a unanimous FALSE round is a '
    ||'dead end. All four were symptoms of the same missing check, and all four went green together when '
    ||'enforce_resubmission_gate was adopted -- which is the evidence that the diagnosis was right.');
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
