-- =====================================================================
-- PROPOSAL R2 — match <-> judge assignment
-- =====================================================================
-- STATUS: ADOPTED on 2026-08-27. This file is now a RECORD, not a
-- migration: its contents were folded into 01_oltp_schema.sql and the
-- pipeline builds them from there. Do NOT run it against a current
-- database -- it would fail on objects that already exist. It is kept
-- because the reasoning here is the reasoning behind the schema, and
-- 01_ carries only the short form of it.
--
-- Verified by: db/proposals/R2_match_judges.verify.sql (throwaway DB).
--
-- PROBLEM
-- -------
-- oltp.scores carries judge_id with an FK to oltp.judges, and a
-- composite FK guaranteeing the (match_id, team_id) pair is actually
-- fielded. Nothing states WHICH judge is assigned to WHICH match.
-- Consequence, demonstrated by "B4 GAP EVIDENCE" in
-- db/qa_judge_feedback.sql: a judge with no relationship to a match can
-- insert a score for it and the database accepts it.
--
-- ---------------------------------------------------------------------
-- Q1 — RESOLVED by reviewer: a judge is assigned to a BLOCK of matches.
-- ---------------------------------------------------------------------
-- Cardinality: one judge -> N matches, one match -> N judges.
--
-- The per-match grain below expresses that natively and needs nothing
-- added: a "block" is simply the set of match_judges rows sharing a
-- judge_id. Assigning a judge to three matches is three rows; the
-- N:N shape is the composite PK itself.
--
-- NO challenge_id or season_id column is added to match_judges. Scores
-- are recorded per match, so the guard must sit at the match grain to
-- be a total, declarative FK. A coarser column here would either be
-- redundant with challenges (reachable via matches.challenge_id) or
-- able to contradict it -- the same denormalisation trap already
-- rejected for matches.season_id.
--
-- Whether the BLOCK ITSELF should become a first-class entity is a
-- separate, still-open question -- see Q1-FOLLOWUP at the bottom. It is
-- NOT decided here and nothing below depends on it.
--
-- ---------------------------------------------------------------------
-- Q2 — RESOLVED by reviewer: back-fill is mandatory, and every
--      (match_id, judge_id) pair already present in oltp.scores is
--      DECLARED a legitimate assignment.
-- ---------------------------------------------------------------------
-- This is a trust decision the reviewer takes on in writing, not a fact
-- the migration establishes. See the notice printed by step 2 and the
-- TRUST BOUNDARY section at the bottom.
--
-- The rejected branch was "history may legitimately predate the rule".
-- Because that branch was NOT taken, this patch deliberately contains
-- NO temporal mechanism: no NOT VALID, no exemption column, no
-- INSERT-only trigger. The constraint is total and validated, and it
-- applies to every row equally. Anything less would smuggle the
-- rejected branch back in under a different name.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Step 1 — the assignment table
-- ---------------------------------------------------------------------
-- Composite PK (match_id, judge_id): the pair IS the whole fact being
-- recorded, so no surrogate key is needed -- the same reasoning, and
-- the same shape, as match_teams. One row per (match, judge); a judge's
-- block of matches is their set of rows.
CREATE TABLE oltp.match_judges (
  match_id     BIGINT NOT NULL REFERENCES oltp.matches(match_id) ON DELETE CASCADE,
  judge_id     BIGINT NOT NULL REFERENCES oltp.judges(account_id) ON DELETE CASCADE,
  assigned_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (match_id, judge_id)
);
-- match_id already leads the PK; judge_id does not, so it needs its own
-- index. This is the index that answers "which matches is this judge
-- on?" -- i.e. it is what makes reading a judge's BLOCK cheap.
CREATE INDEX ix_match_judges_judge_id ON oltp.match_judges(judge_id);


-- ---------------------------------------------------------------------
-- Step 2 — back-fill  ***ORDER IS LOAD-BEARING: 1 -> 2 -> 3***
-- ---------------------------------------------------------------------
-- THIS MUST RUN BEFORE STEP 3, AND THE ORDER IS NOT NEGOTIABLE.
-- ADD CONSTRAINT validates EVERY existing row at the moment it
-- executes. On any database holding scores, an empty match_judges makes
-- that validation fail outright:
--     ERROR: insert or update on table "scores" violates foreign key
--            constraint "fk_scores_match_judge"
--     DETAIL: Key (match_id, judge_id)=(1, 2) is not present in
--             table "match_judges"
-- An earlier draft of this patch had steps 2 and 3 the other way round.
-- It appeared to work only because it was first tried on a database
-- with no scores yet -- the back-fill was never exercised, so the
-- ordering bug was invisible. R2_match_judges.verify.sql now seeds
-- historical scores BEFORE applying this file, specifically so that
-- mistake cannot come back unnoticed.
--
-- ---------------------------------------------------------------------
-- WHAT THIS STEP ACTUALLY DOES -- read before approving a deployment
-- ---------------------------------------------------------------------
-- This migration CANONISES A TRUST ASSUMPTION: that every
-- (match_id, judge_id) pair already present in oltp.scores was a
-- legitimate assignment. It does NOT produce independent evidence for
-- that -- there is no other source to corroborate against; scores are
-- the only record that the pairing ever happened.
--
-- Consequence, stated plainly: after this runs, fk_scores_match_judge
-- is VACUOUSLY TRUE over all historical rows. It holds there BY
-- DECISION, not by verification. Its enforcement value begins at the
-- moment of migration and applies only to rows written afterwards.
-- See TRUST BOUNDARY at the bottom of this file.
--
-- Mechanically: one pair can back several score rows -- a judge scoring
-- three teams in one match is three scores but ONE assignment -- so the
-- GROUP BY is what makes this correct, not a convenience.
--
-- The guard below treats a back-fill that touches ZERO rows on a
-- database that holds scores as an ERROR, not a success. That is the
-- same rule the negative-oracle audit applies to assertions: an
-- operation that reaches nothing has proven nothing, and must not pass
-- quietly.
DO $backfill$
DECLARE
  v_scores   BIGINT;
  v_pairs    BIGINT;
  v_pre      BIGINT;
  v_inserted BIGINT;
  v_missing  BIGINT;
BEGIN
  SELECT count(*) INTO v_scores FROM oltp.scores;
  SELECT count(*) INTO v_pairs  FROM (SELECT DISTINCT match_id, judge_id FROM oltp.scores) x;
  SELECT count(*) INTO v_pre    FROM oltp.match_judges;

  INSERT INTO oltp.match_judges (match_id, judge_id, assigned_at)
  SELECT s.match_id, s.judge_id, min(s.scored_at)
  FROM oltp.scores s
  GROUP BY s.match_id, s.judge_id
  ON CONFLICT (match_id, judge_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RAISE NOTICE 'R2 back-fill: % score row(s) imply % distinct (match,judge) pair(s); % canonised (table held % before).',
    v_scores, v_pairs, v_inserted, v_pre;
  RAISE NOTICE 'R2 back-fill: those % pair(s) are now TRUSTED BY DECLARATION, not verified.', v_pairs;

  -- vacuity guard: reaching nothing is a signal, not a success
  IF v_scores > 0 AND v_pre = 0 AND v_inserted = 0 THEN
    RAISE EXCEPTION
      'R2 back-fill touched 0 rows on a database holding % score(s). '
      'The step did not run against real data -- refusing to continue to the ALTER.', v_scores;
  END IF;

  -- coverage guard: the ALTER in step 3 will fail anyway, but failing
  -- here names the actual cause instead of surfacing as an FK error
  SELECT count(*) INTO v_missing FROM (
    SELECT DISTINCT match_id, judge_id FROM oltp.scores
    EXCEPT SELECT match_id, judge_id FROM oltp.match_judges) x;
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'R2 back-fill left % implied pair(s) uncovered; step 3 would fail.', v_missing;
  END IF;
END
$backfill$;


-- ---------------------------------------------------------------------
-- Step 3 — make an unassigned judge's score fail   ***RUNS LAST***
-- ---------------------------------------------------------------------
-- A composite FOREIGN KEY, not a trigger: declarative, enforced on
-- UPDATE as well as INSERT, and it mirrors fk_scores_match_team which
-- already guards the team side. A trigger would be strictly weaker.
--
-- scores now depends on TWO composite parents, (match,team) and
-- (match,judge). That is intentional -- the two facts are independent
-- and both must hold for a score to be legitimate.
--
-- Deliberately TOTAL and VALIDATED. No NOT VALID, no exemption column,
-- no INSERT-only trigger: those belong to the rejected branch of Q2
-- ("history may legitimately predate the rule"). The chosen branch is
-- "history is clean by declaration", which is expressed by step 2, not
-- by weakening this constraint. Re-adding any of those mechanisms later
-- would silently reopen a question the reviewer already closed.
ALTER TABLE oltp.scores
  ADD CONSTRAINT fk_scores_match_judge
  FOREIGN KEY (match_id, judge_id)
  REFERENCES oltp.match_judges(match_id, judge_id)
  ON DELETE CASCADE;


-- =====================================================================
-- The test that turns green once the above is applied
-- =====================================================================
-- Paste into db/qa_judge_feedback.sql, replacing the two B4 stubs
-- ("B4 assignment table absent" / "B4 GAP EVIDENCE"). Two-assertion
-- form, like the rest of that suite: proven precondition, then the
-- rejection.
--
--   PERFORM qa_pre('B','B4 assignment exists',
--     EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_match AND judge_id=v_j1)
--     AND EXISTS (SELECT 1 FROM oltp.judges WHERE account_id=v_j3)
--     AND NOT EXISTS (SELECT 1 FROM oltp.match_judges WHERE match_id=v_match AND judge_id=v_j3),
--     'judge '||v_j1||' IS on the panel for match '||v_match||'; judge '||v_j3||' exists but is NOT');
--
--   PERFORM qa_reject('B','B4 a judge NOT assigned to the match cannot score',
--     format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score)
--             VALUES (%s,%s,%s,3,3,3,3)', v_match, v_team, v_j3));
--
--   PERFORM qa_accept('B','B4 an ASSIGNED judge still scores normally',
--     format('INSERT INTO oltp.scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score)
--             VALUES (%s,%s,%s,7,7,7,7)', v_match, v_team, v_j2));
--
-- Fixture line needed so the precondition can hold:
--   INSERT INTO oltp.match_judges(match_id, judge_id)
--     SELECT m.match_id, j.account_id FROM oltp.matches m, oltp.judges j
--     WHERE j.account_id IN (<j1>, <j2>);     -- j3 deliberately left off
--
-- KNOCK-ON, verified not assumed: with this patch applied,
-- db/99_tests.sql fails at line 524 with fk_scores_match_judge, exit 3.
-- Its seeds insert scores directly and would each need a matching
-- match_judges row first. Real work, not a one-liner.
-- analytics is unaffected: fact_scores reads scores.judge_id, whose
-- shape does not change.


-- =====================================================================
-- TRUST BOUNDARY — where this constraint has teeth, and where it does not
-- =====================================================================
-- The migration splits the table's history in two, at the instant it
-- runs. Both halves are proven actively in R2_match_judges.verify.sql
-- rather than asserted here.
--
--   BEFORE (historical rows)
--     Every pre-existing score survives, because step 2 created an
--     assignment row for each pair it implied. The FK is satisfied over
--     this half BY CONSTRUCTION. It caught nothing and could not have:
--     the back-fill was derived from the very rows being validated.
--     Verified as "an arbitrary historical score is still present and
--     its pair was canonised", with the canonised count reported.
--
--   AFTER (rows written from now on)
--     A score on a pair that was never assigned is rejected outright.
--     This is where the constraint earns its place. Verified as an
--     actual rejection carrying fk_scores_match_judge, not as a claim.
--
-- Stated once, plainly, so nobody later reads the green migration as
-- evidence about the past: THE TRUST IS RETROACTIVE, NOT PERPETUAL.
-- Everything written after the migration is genuinely constrained;
-- everything before it is grandfathered by the reviewer's decision.
--
-- ---------------------------------------------------------------------
-- OPEN ITEM (to confirm, NOT to build now)
-- ---------------------------------------------------------------------
-- If anyone ever wants to re-examine the assumption rather than inherit
-- it, the audit would ask: which canonised pairs are NOT corroborated
-- by an independent record of assignment?
--
-- That query cannot be written today, and the reason matters more than
-- the query: THERE IS NO INDEPENDENT SOURCE. oltp.scores is the only
-- place the pairing was ever recorded, so any check written now would
-- compare the back-fill against its own input and always come back
-- clean -- a textbook vacuous oracle, exactly the pathology the
-- negative-oracle audit exists to catch. Building it would manufacture
-- false assurance about the one thing this migration explicitly does
-- not establish.
--
-- It becomes answerable only if a second, independent record of
-- assignment appears later -- an organiser-facing assignment log, an
-- imported panel roster, a judge_assignments parent table (Q1-FOLLOWUP
-- below). At that point the audit is roughly:
--     SELECT mj.* FROM oltp.match_judges mj
--     WHERE NOT EXISTS (SELECT 1 FROM <independent source> src
--                       WHERE src.match_id = mj.match_id
--                         AND src.judge_id = mj.judge_id);
-- flagged for review, not auto-deleted -- a pair with no corroboration
-- is a question, not a defect.
--
-- Until such a source exists this stays an open item. It is NOT a
-- blocker for the migration; it is a note so the decision remains
-- traceable instead of dissolving into "the FK is green".
-- =====================================================================


-- =====================================================================
-- Q1-FOLLOWUP — is the BLOCK itself a first-class entity? NOT DECIDED.
-- =====================================================================
-- The reviewer decided a judge covers N matches. The table above stores
-- that as an EMERGENT SET: the block exists only as "the rows sharing
-- judge_id". Nothing records that the rows were created together, or
-- why. That is sufficient for scoring integrity -- which is all this
-- patch claims -- but it loses the ASSIGNMENT INTENT, and three
-- administrative operations degrade as a result. Evidence, not opinion:
--
-- (a) "Assign judge X to the whole challenge" is still possible in one
--     transaction:
--         INSERT INTO oltp.match_judges(match_id, judge_id)
--         SELECT m.match_id, <judge> FROM oltp.matches m
--         WHERE m.challenge_id = <challenge>;
--     So this is NOT the argument for a first-class block. Stated
--     explicitly so nobody re-derives it as one.
--
-- (b) A MATCH ADDED AFTER THE ASSIGNMENT gets no judges, and nothing
--     detects it. The intent "X judges this challenge" was expanded
--     into rows at assignment time and then discarded; there is no
--     record to re-apply to the new match. The new match is simply
--     unjudged until somebody remembers. Demonstrated empirically in
--     R2_match_judges.verify.sql, case Q1-FOLLOWUP-1.
--
-- (c) OVERLAPPING BLOCKS CANNOT BE UNWOUND. If judge X is assigned to
--     challenge C and separately to round R, and a match belongs to
--     both, that match yields ONE row. Revoking the challenge-level
--     assignment must not remove a row still justified by the round
--     assignment -- but the row carries no provenance, so a bulk DELETE
--     cannot tell the two apart. Demonstrated in case Q1-FOLLOWUP-2.
--
-- (d) Panel roles ("head judge for this challenge") have nowhere to
--     live. Adding a role column to match_judges would repeat it on
--     every match in the block and let the copies drift.
--
-- If (b) and (c) are real workflows, the block wants to be an entity
-- (e.g. judge_assignments(assignment_id, judge_id, challenge_id|round)
-- with match_judges rows DERIVED from it and re-derived when matches
-- are added). If organisers always assign match-by-match, the emergent
-- set is correct and cheaper. That is a product question about how
-- assignment actually happens, not a schema question -- ESCALATED,
-- deliberately not decided here. Nothing above depends on the answer:
-- a first-class block would ADD a parent table, not change
-- match_judges or fk_scores_match_judge.
-- =====================================================================
