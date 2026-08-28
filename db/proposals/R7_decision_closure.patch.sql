-- =====================================================================
-- PROPOSAL R7 — closing a decision, and the intervals around it
-- =====================================================================
-- STATUS: ADOPTED on 2026-08-28. This file is now a RECORD, not a
-- migration: its contents were folded into 01_oltp_schema.sql (and
-- 02_analytics_schema.sql, for the view) and the pipeline builds them
-- from there. Do NOT run it against a current database -- it would
-- fail on objects that already exist. It is kept because the
-- reasoning here is the reasoning behind the schema, and the
-- pipeline carries only the short form of it.
--
-- Evidence: db/qa_lifecycle.sql, 11 GAPs recorded on a throwaway
-- database. This patch closes 6 of them. The remaining 5 are listed at
-- the bottom as deliberately NOT closed, with the reason.
--
-- Verified by: db/proposals/R7_decision_closure.verify.sql
--
-- BUSINESS RULES (given by the owner, not derived):
--   1. "an appeal is closed when the judge gives a final answer,
--       supported by a rule"
--        -> closing requires a JUDGE, a time, and a rule
--        -> FINAL means final: a closed appeal does not reopen
--   2. "a cancelled match receives no results, it is marked void"
--        -> and, by extension agreed separately, only a match that has
--           actually been played may be scored
--   3. "one active season per year"
--        -> at most one season carries is_active at a time
--
-- The interval checks (Part 1) were not decided by anyone: they are the
-- mechanical half, where no reading of the business makes the reversed
-- order correct.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Part 1 — intervals that run forwards (closes A3, M4, S1)
-- ---------------------------------------------------------------------
-- Three one-row CHECKs. The pattern is already in this schema:
-- ck_forum_posts_edited_after_created arrived with R6 and does exactly
-- this for forum_posts. These are the same shape at the same cost, and
-- were simply never applied to the other tables that carry a pair of
-- timestamps.
--
-- All three are written to tolerate NULL, because in every case the
-- second timestamp is genuinely optional: an undecided appeal, a current
-- membership, an open-ended season.

ALTER TABLE oltp.appeals
  ADD CONSTRAINT ck_appeals_decided_after_created
  CHECK (decided_at IS NULL OR decided_at >= created_at);

ALTER TABLE oltp.join_requests
  ADD CONSTRAINT ck_join_requests_decided_after_requested
  CHECK (decided_at IS NULL OR decided_at >= requested_at);

ALTER TABLE oltp.memberships
  ADD CONSTRAINT ck_memberships_left_after_joined
  CHECK (left_at IS NULL OR left_at >= joined_at);

ALTER TABLE oltp.seasons
  ADD CONSTRAINT ck_seasons_end_after_start
  CHECK (end_date IS NULL OR end_date >= start_date);


-- ---------------------------------------------------------------------
-- Part 2 — one active season (closes S2)
-- ---------------------------------------------------------------------
-- "One active season per year." Implemented as one active season FULL
-- STOP, which is the stricter reading and satisfies the stated rule for
-- any cadence of one season a year. Scoping it to the calendar year
-- instead would permit two simultaneously active seasons whose start
-- dates fall either side of a new year, which is the situation the flag
-- exists to prevent.
--
-- A partial unique index on a constant expression is the exact way to
-- say "at most one row satisfies this predicate". The schema already
-- uses the shape twice -- uq_memberships_active_team_member and
-- uq_join_requests_pending -- so this is an established idiom here, not
-- a trick.
CREATE UNIQUE INDEX uq_seasons_single_active
  ON oltp.seasons ((TRUE)) WHERE is_active;


-- ---------------------------------------------------------------------
-- Part 3 — an appeal is closed by a judge, on a rule (closes A1, A2)
-- ---------------------------------------------------------------------
-- WHY A NEW COLUMN RATHER THAN REUSING rule_id
-- --------------------------------------------
-- appeals.rule_id is the rule the FILER invokes, pinned at INSERT by
-- pin_cited_revision(). The rule the DECISION rests on is a different
-- claim, and the difference is the interesting one: "you cited G4, but
-- the decision is made under A21" is a real outcome in a competition and
-- is not expressible if the two share a column. Reusing rule_id would
-- also silently rewrite the filer's citation whenever a judge decided on
-- other grounds, destroying the record R5 exists to protect.
ALTER TABLE oltp.appeals
  ADD COLUMN decided_under_rule_id BIGINT REFERENCES oltp.rules(rule_id),
  ADD COLUMN decided_revision_id   BIGINT REFERENCES oltp.rule_revisions(revision_id);

CREATE INDEX ix_appeals_decided_under_rule ON oltp.appeals(decided_under_rule_id);

COMMENT ON COLUMN oltp.appeals.decided_under_rule_id IS
  'The rule the VERDICT rests on. Distinct from rule_id, which is the rule '
  'the filer invoked -- a judge may decide on different grounds, and both '
  'claims are part of the record.';
COMMENT ON COLUMN oltp.appeals.decided_revision_id IS
  'The revision of decided_under_rule_id as it read when the decision was '
  'taken, pinned the same way cited_revision_id is pinned at filing.';

-- The decider must be a JUDGE, not merely an account. The owner''s rule
-- names the judge specifically, and decided_by_account_id was a bare FK
-- to accounts -- so a club or a member could be recorded as having
-- ruled on a protest against their own team.
--
-- Done as a second FK rather than by replacing the first: judges.account_id
-- is itself an FK to accounts, so both constraints hold simultaneously and
-- the existing one keeps documenting that the column is an account.
ALTER TABLE oltp.appeals
  ADD CONSTRAINT fk_appeals_decided_by_judge
  FOREIGN KEY (decided_by_account_id) REFERENCES oltp.judges(account_id);

-- Closing requires all three: who, when, and under which rule.
-- Expressible as a CHECK because every column involved is on this row.
ALTER TABLE oltp.appeals
  ADD CONSTRAINT ck_appeals_closure_is_accountable
  CHECK (
    status = 'pending'
    OR (decided_at IS NOT NULL
        AND decided_by_account_id IS NOT NULL
        AND decided_under_rule_id IS NOT NULL)
  );

-- Pin the deciding rule''s wording, mirroring pin_cited_revision(). Without
-- this the verdict would drift with the rulebook exactly as X4 showed a
-- citation does -- a decision could later appear to rest on text written
-- after it was taken.
CREATE OR REPLACE FUNCTION oltp.pin_decided_revision() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
BEGIN
  IF NEW.decided_under_rule_id IS NULL OR NEW.decided_revision_id IS NOT NULL THEN
    RETURN NEW;
  END IF;
  SELECT revision_id INTO NEW.decided_revision_id
  FROM rule_revisions WHERE rule_id = NEW.decided_under_rule_id
  ORDER BY revision_id DESC LIMIT 1;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_appeals_pin_decided_revision
  BEFORE INSERT OR UPDATE ON oltp.appeals
  FOR EACH ROW EXECUTE FUNCTION oltp.pin_decided_revision();

-- A retired rule cannot be the basis of a NEW decision, for the same
-- reason it cannot be freshly cited (R5). refuse_retired_rule_citation()
-- reads NEW.rule_id, so it cannot be reused as-is for this column.
CREATE OR REPLACE FUNCTION oltp.refuse_retired_deciding_rule() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
DECLARE v_retired TIMESTAMPTZ;
BEGIN
  IF NEW.decided_under_rule_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE'
     AND NEW.decided_under_rule_id IS NOT DISTINCT FROM OLD.decided_under_rule_id THEN
    RETURN NEW;   -- unchanged: an old decision keeps standing
  END IF;
  SELECT retired_at INTO v_retired FROM rules WHERE rule_id = NEW.decided_under_rule_id;
  IF v_retired IS NOT NULL THEN
    RAISE EXCEPTION 'rule % was retired on % and cannot be the basis of a decision',
      NEW.decided_under_rule_id, v_retired
      USING HINT = 'decisions already taken under it stand; decide under a current rule';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_appeals_no_retired_deciding_rule
  BEFORE INSERT OR UPDATE ON oltp.appeals
  FOR EACH ROW EXECUTE FUNCTION oltp.refuse_retired_deciding_rule();

-- FINAL means final. "An appeal is closed when the judge gives a final
-- answer" -- so a closed appeal does not return to pending, and does not
-- flip from accepted to rejected either.
--
-- This is the only transition rule in the schema, and it is deliberately
-- narrow: it constrains appeals because appeals were specified. The same
-- omission on join_requests.status and matches.status is left open (see
-- the bottom of this file), because "final" was stated about appeals and
-- assuming it elsewhere would be inventing policy.
CREATE OR REPLACE FUNCTION oltp.enforce_appeal_finality() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
BEGIN
  IF OLD.status <> 'pending' AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'appeal % was closed as % and cannot be reopened or changed to %',
      OLD.appeal_id, OLD.status, NEW.status
      USING HINT = 'the judge''s answer is final; file a new appeal if there are new grounds';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_appeals_finality
  BEFORE UPDATE ON oltp.appeals
  FOR EACH ROW EXECUTE FUNCTION oltp.enforce_appeal_finality();


-- ---------------------------------------------------------------------
-- Part 4 — only a played match is scored (closes X1)
-- ---------------------------------------------------------------------
-- "A cancelled match receives no results, it is marked void", extended
-- by agreement to scheduled matches: a result presumes the event
-- happened. R2 established that scoring requires an assigned judge and a
-- fielded team -- the panel and the roster were checked, the EVENT was
-- not.
--
-- This is a trigger and not a CHECK because matches.status lives on
-- another table.
CREATE OR REPLACE FUNCTION oltp.enforce_match_is_playable() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
DECLARE v_status match_status;
BEGIN
  SELECT status INTO v_status FROM matches WHERE match_id = NEW.match_id;
  IF v_status NOT IN ('in_progress','completed') THEN
    RAISE EXCEPTION 'match % is % and cannot be scored', NEW.match_id, v_status
      USING HINT = 'only a match that has been played may carry results';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_scores_match_playable
  BEFORE INSERT OR UPDATE ON oltp.scores
  FOR EACH ROW EXECUTE FUNCTION oltp.enforce_match_is_playable();

-- The other direction: a match that already carries results cannot be
-- quietly cancelled, which would leave exactly the state Part 4 exists to
-- prevent -- a void match holding scores that flow into fact_scores and
-- the leaderboard.
--
-- ASSUMPTION, flagged because it was not stated: this REFUSES the
-- cancellation rather than deleting the scores. Refusing preserves the
-- record and forces the removal to be a deliberate, visible act; deleting
-- would silently destroy officials'' work on a partially played match
-- (weather, dispute) with no way back. If the intent is instead that
-- cancelling voids the results automatically, replace the RAISE with a
-- DELETE -- the shape is the same and the choice is one line.
CREATE OR REPLACE FUNCTION oltp.enforce_cancel_has_no_scores() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
DECLARE v_n INT;
BEGIN
  IF NEW.status <> 'cancelled' OR OLD.status = 'cancelled' THEN RETURN NEW; END IF;
  SELECT count(*) INTO v_n FROM scores WHERE match_id = NEW.match_id;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'match % carries % score(s) and cannot be cancelled', NEW.match_id, v_n
      USING HINT = 'remove the results first, so voiding the match is an explicit act';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_matches_cancel_has_no_scores
  BEFORE UPDATE ON oltp.matches
  FOR EACH ROW EXECUTE FUNCTION oltp.enforce_cancel_has_no_scores();


-- =====================================================================
-- DELIBERATELY NOT CLOSED
-- =====================================================================
-- Five of the eleven lifecycle GAPs stay open, each for a stated reason
-- rather than by omission:
--
--   J2  an accepted join request creates no membership
--       The owner has not chosen between a trigger and application code,
--       and the question was left open pending an explanation of what
--       the two mean in practice. Closing it either way now would be
--       inventing the policy.
--
--   J2b a decided join request need not record who decided it
--       The same accountability rule as A1, on the other decision table.
--       NOT applied here, because the owner''s rule named appeals and
--       judges specifically, and join requests are decided by a club --
--       a different actor, so the FK would point somewhere else. One
--       line to add once that is confirmed.
--
--   J3  an accepted request can later be rejected
--       Finality was stated about appeals. Whether a club may reverse an
--       acceptance is a different question, and it compounds with J2:
--       if acceptance created a membership, reversal would need to decide
--       what happens to it.
--
--   X2  match status moves in any direction
--       Part 4 stops the harmful CONSEQUENCE (a void or unplayed match
--       carrying results) without imposing a lifecycle nobody specified.
--       A completed match can still return to scheduled -- but only after
--       its scores are gone, which makes the act visible.
--
--   L1  (analytics) scored_matches counts verdicts, not matches
--       Not a lifecycle issue and not fixable here: it needs match
--       identity carried into fact_scores. See db/qa_analytics.sql.
-- =====================================================================
