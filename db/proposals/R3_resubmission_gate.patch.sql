-- =====================================================================
-- PROPOSAL R3 — the resubmission gate
-- =====================================================================
-- STATUS: ADOPTED on 2026-08-27. This file is now a RECORD, not a
-- migration: its contents were folded into 01_oltp_schema.sql and the
-- pipeline builds them from there. Do NOT run it against a current
-- database -- it would fail on objects that already exist. It is kept
-- because the reasoning here is the reasoning behind the schema, and
-- 01_ carries only the short form of it.
--
-- Evidence: db/qa_resubmission.sql, 5 GAPs recorded on a throwaway
-- database. Four of them (G2, G3, I2, J1) are ONE missing rule seen
-- from four angles; the fifth (H3) is separate.
--
-- BUSINESS RULE (given, not derived):
--   version N+1 of a (team, challenge) chain may exist only if
--   version N has at least one review with requires_resubmission = TRUE.
--   Aggregation is ANY / bool_or -- not ALL, not latest-wins.
--
-- WHY A TRIGGER AND NOT A CHECK OR A UNIQUE INDEX
-- -----------------------------------------------
-- The rule spans rows in two tables: it asks about the reviews of a
-- DIFFERENT submission row than the one being inserted. A CHECK cannot
-- reference another table, and a partial unique index cannot express an
-- aggregate over a related table. This is the same category of rule as
-- enforce_team_capacity and enforce_appeal_limit, which the schema
-- already implements as BEFORE INSERT triggers -- so the shape below is
-- consistent with existing practice, not a new mechanism.
--
-- A composite FK cannot help here either: there is no parent_submission_id
-- to point at (see H2-NOTE), and the predicate is an aggregate, not a
-- key lookup.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Part 1 — the gate (closes G2, G3, I2 and J1 together)
-- ---------------------------------------------------------------------
-- The rule is INDUCTIVE, which is why one trigger closes four gaps:
--   G2  a unanimous FALSE round is a dead end            -- bool_or FALSE
--   G3  an unreviewed parent blocks the child            -- bool_or over
--                                                           zero rows
--   I2  v3 requires v2 to have asked, not v1             -- the check
--                                                           looks at the
--                                                           IMMEDIATE
--                                                           predecessor
--   J1  a burst is impossible: the second new version    -- because the
--       would need the FIRST new version reviewed           first is not
--
-- Note on J1 specifically: this does not "consume" a right in the sense
-- of marking it used. It does not need to. Requiring the immediate
-- predecessor to have asked means two versions can never be created
-- from one request, because the first of them has no reviews yet.
-- SET search_path pinned on the function itself: this proposal was
-- written BEFORE the R4 class was discovered, and without it these two
-- functions would ship the very defect R4 exists to fix -- unqualified
-- names resolved against the caller's path.
CREATE OR REPLACE FUNCTION oltp.enforce_resubmission_gate() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
DECLARE
  v_prev_id      BIGINT;
  v_prev_version SMALLINT;
  v_allowed      BOOLEAN;
  v_reviews      INT;
BEGIN
  -- version 1 opens a chain and needs no predecessor
  IF NEW.version IS NULL OR NEW.version <= 1 THEN
    RETURN NEW;
  END IF;

  SELECT submission_id, version INTO v_prev_id, v_prev_version
  FROM oltp.submissions
  WHERE team_id = NEW.team_id AND challenge_id = NEW.challenge_id
  ORDER BY version DESC LIMIT 1;

  IF v_prev_id IS NULL THEN
    RAISE EXCEPTION
      'submission version % has no predecessor in the (team %, challenge %) chain',
      NEW.version, NEW.team_id, NEW.challenge_id;
  END IF;

  SELECT coalesce(bool_or(requires_resubmission), FALSE), count(*)
    INTO v_allowed, v_reviews
  FROM oltp.submission_reviews WHERE submission_id = v_prev_id;

  IF NOT v_allowed THEN
    RAISE EXCEPTION
      'version % refused: version % (submission %) has % review(s) and none requested a resubmission',
      NEW.version, v_prev_version, v_prev_id, v_reviews
      USING HINT = 'a new version requires at least one review with requires_resubmission = true '
                   'on the immediately preceding version (ANY / bool_or)';
  END IF;

  RETURN NEW;
END;
$fn$;

-- MUST fire AFTER trg_submissions_version, which assigns NEW.version.
-- Postgres fires same-timing triggers in NAME order, and
-- 'trg_submissions_version' < 'trg_submissions_zz_resubmission_gate',
-- so the zz prefix is load-bearing, not decoration. Reading NEW.version
-- before it is assigned would compare against NULL and let everything
-- through -- a silently vacuous guard.
CREATE TRIGGER trg_submissions_zz_resubmission_gate
  BEFORE INSERT ON oltp.submissions
  FOR EACH ROW EXECUTE FUNCTION oltp.enforce_resubmission_gate();


-- ---------------------------------------------------------------------
-- Part 2 — version immutability (closes H3)
-- ---------------------------------------------------------------------
-- trg_submissions_version is BEFORE INSERT only, so `version` is freely
-- mutable afterwards. uq_submissions_team_challenge_version catches a
-- collision but not a SKIP: the QA run moved a row to version 7,
-- leaving the chain 1, 2, 7.
--
-- Also forbids moving a row between chains after the fact, which would
-- otherwise let a submission change its team or challenge and land
-- mid-sequence somewhere else -- the mutation form of H2.
CREATE OR REPLACE FUNCTION oltp.enforce_submission_lineage_immutable() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
BEGIN
  IF NEW.version IS DISTINCT FROM OLD.version THEN
    RAISE EXCEPTION 'submission % version is immutable (% -> %)',
      OLD.submission_id, OLD.version, NEW.version;
  END IF;
  IF NEW.team_id IS DISTINCT FROM OLD.team_id
     OR NEW.challenge_id IS DISTINCT FROM OLD.challenge_id THEN
    RAISE EXCEPTION 'submission % cannot move between chains after insert', OLD.submission_id;
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_submissions_lineage_immutable
  BEFORE UPDATE ON oltp.submissions
  FOR EACH ROW EXECUTE FUNCTION oltp.enforce_submission_lineage_immutable();


-- =====================================================================
-- KNOCK-ON, as MEASURED during adoption
-- =====================================================================
-- The estimate below was written before adoption and is left in place so
-- it can be compared against what actually happened.
--
-- ESTIMATED: every fixture inserting a second version needs the preceding
-- version to carry a TRUE review first. At minimum 99_tests.sql's
-- 'Alpha v2'/'Alpha v3' rows, qa_judge_feedback.sql's 'QA sub v2', and
-- qa_resubmission.sql's G2/G3/I2/J1 turning from GAPs into paired
-- negatives.
--
-- ACTUAL: three gate-opening reviews in 99_tests.sql (Alpha v2, Alpha v3,
-- and the tie-break fixture, which the estimate missed), plus one in
-- qa_concurrency.sql -- CC-RACE's v1, without which the gate refuses BOTH
-- racing sessions and C1 silently measures the gate instead of the race.
-- qa_judge_feedback.sql needed none: Channel A had already been moved out.
--
-- The estimate's real miss was structural rather than numerical. Under the
-- gate a chain becomes STATEFUL -- creating a version CONSUMES the
-- parent's open request -- so suites can no longer share one chain across
-- groups the way they did when nothing consulted the reviews. Groups H, I
-- and J in qa_resubmission.sql each needed a chain of their own, and four
-- new challenges were added to the fixture. Nothing in the pre-adoption
-- reading suggested that, and it is the part worth remembering: a
-- constraint that reads sibling rows changes what test isolation means,
-- not just how many rows a fixture needs.
--
-- All four GAPs closed together, as predicted, and the suite went from
-- 5 GAPs to 26 PASS / 0 GAP.
--
-- OPEN QUESTION for the reviewer, not decided here:
--   Should the gate also require the predecessor's reviews to be
--   COMPLETE (every assigned judge has reviewed) rather than merely
--   non-empty? Today a single early TRUE review opens the next version
--   while other judges are still assigned but silent. That is a
--   different rule from the one specified, so it is not implemented.
-- =====================================================================
