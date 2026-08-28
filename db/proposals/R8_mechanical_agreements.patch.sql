-- =====================================================================
-- PROPOSAL R8 — the agreements nobody had to decide
-- =====================================================================
-- STATUS: ADOPTED on 2026-08-28. This file is now a RECORD, not a
-- migration: its contents were folded into 01_oltp_schema.sql (and
-- 02_analytics_schema.sql, for the view) and the pipeline builds them
-- from there. Do NOT run it against a current database -- it would
-- fail on objects that already exist. It is kept because the
-- reasoning here is the reasoning behind the schema, and the
-- pipeline carries only the short form of it.
--
-- Evidence: db/qa_submission_reviews.sql (A3), db/qa_lifecycle.sql
-- (group R), db/qa_partners.sql (P3, P3b), db/qa_analytics.sql (P1, P2).
--
-- Verified by: db/proposals/R8_mechanical_agreements.verify.sql
--
-- WHAT MAKES THESE SIX DIFFERENT
-- ------------------------------
-- Of the findings still open, most are waiting on a business answer --
-- may an accepted join request be reversed? is an exercised right
-- permanent? -- and closing those without the answer would be inventing
-- policy rather than enforcing it.
--
-- These six are not like that. Each states an agreement the schema
-- ALREADY makes somewhere else, and each has exactly one defensible
-- reading:
--
--   1. two columns on one row that must not contradict each other
--   2. a link that must point at the thing it claims to have come from
--   3. an invariant already enforced from one side, enforced from both
--   4. a report that must not silently omit the rows it exists for
--
-- Every fix below reuses a pattern already present in this schema. None
-- of them required a decision from anyone.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Part 1 — a review that was written has something written in it
-- ---------------------------------------------------------------------
-- reviews A3: reviewed_at and feedback are two independent answers to
-- "was this reviewed?", and they can disagree. A row with a timestamp
-- and no text says a judge reviewed the submission and said nothing,
-- which reads as an empty verdict rather than as a missing one.
--
-- Same one-row shape as ck_forum_posts_edited_after_created (R6) and the
-- four interval checks (R7): both columns live on the row being checked.
--
-- Deliberately NOT requiring feedback on an unreviewed row -- an
-- assigned-but-not-yet-reviewed review is the ordinary starting state.
ALTER TABLE oltp.submission_reviews
  ADD CONSTRAINT ck_submission_reviews_verdict_has_text
  CHECK (reviewed_at IS NULL OR feedback IS NOT NULL);


-- ---------------------------------------------------------------------
-- Part 2 — a membership came from ITS OWN request
-- ---------------------------------------------------------------------
-- lifecycle R3: source_request_id is a bare FK, so the provenance link
-- can point at a request filed by someone else, or for another team. The
-- audit trail then reads "this person joined because of that request"
-- when the request was for somewhere else entirely.
--
-- The schema already owns this exact pattern three times over: scores
-- reaches match_teams through a COMPOSITE FK, and R6 gave forum_comments
-- and forum_post_tags the same treatment. A composite FK needs a unique
-- key on the parent side to point at, which is what the index below is
-- for -- request_id is already unique as the PK, so this adds no new
-- restriction, it only makes the triple addressable.
CREATE UNIQUE INDEX uq_join_requests_identity
  ON oltp.join_requests (request_id, member_id, team_id);

ALTER TABLE oltp.memberships
  ADD CONSTRAINT fk_memberships_source_request_matches
  FOREIGN KEY (source_request_id, member_id, team_id)
  REFERENCES oltp.join_requests (request_id, member_id, team_id)
  -- The column list is load-bearing. Without it Postgres nulls EVERY
  -- referencing column on delete, and member_id/team_id are NOT NULL --
  -- so deleting a join request would fail outright instead of merely
  -- clearing the provenance. The single-column FK this replaces had no
  -- such trap, and the QA suite caught it on the first run.
  ON DELETE SET NULL (source_request_id);

-- The original single-column FK is now redundant: the composite one
-- covers it and says strictly more. Dropped so there is one rule, not
-- two that could later disagree.
ALTER TABLE oltp.memberships
  DROP CONSTRAINT memberships_source_request_id_fkey;

-- NOTE, deliberately not closed here: nothing requires the cited request
-- to have been ACCEPTED (lifecycle R4). That one is entangled with J2
-- and J3 -- acceptance creates no membership and rejection removes none
-- -- so it belongs to whichever decision finally links a request's
-- status to the roster. Adding it now would settle half a question.


-- ---------------------------------------------------------------------
-- Part 3 — the subtype invariant, enforced from both sides
-- ---------------------------------------------------------------------
-- partners P3: enforce_subtype_role guards writes to members, clubs,
-- judges and partners, and guards them well -- on INSERT and on UPDATE.
-- Nothing guards accounts.role, so changing the role leaves the subtype
-- row attached and the database ends up holding precisely the shape its
-- own trigger exists to reject. P3b proved this on all four tables, not
-- just the one where it was noticed.
--
-- The account may still change role once the old subtype row is removed,
-- which is what makes this a guard rather than a freeze.
CREATE OR REPLACE FUNCTION oltp.enforce_role_change_has_no_subtype() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
DECLARE v_tbl TEXT; v_found BOOLEAN;
BEGIN
  IF NEW.role IS NOT DISTINCT FROM OLD.role THEN RETURN NEW; END IF;

  -- the table that matches the role being LEFT is the one that would be
  -- orphaned; the others were never valid for this account anyway
  v_tbl := CASE OLD.role
             WHEN 'member'  THEN 'members'
             WHEN 'club'    THEN 'clubs'
             WHEN 'judge'   THEN 'judges'
             WHEN 'partner' THEN 'partners'
           END;
  IF v_tbl IS NULL THEN RETURN NEW; END IF;

  EXECUTE format('SELECT EXISTS (SELECT 1 FROM oltp.%I WHERE account_id = $1)', v_tbl)
    INTO v_found USING OLD.account_id;

  IF v_found THEN
    RAISE EXCEPTION 'account % still has a % record and cannot change role from % to %',
      OLD.account_id, v_tbl, OLD.role, NEW.role
      USING HINT = 'remove the subtype record first -- enforce_subtype_role refuses to create '
                   'a mismatched pair, and this keeps one from appearing the other way round';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_accounts_role_change_has_no_subtype
  BEFORE UPDATE ON oltp.accounts
  FOR EACH ROW EXECUTE FUNCTION oltp.enforce_role_change_has_no_subtype();


-- ---------------------------------------------------------------------
-- Part 4 — two reports that stopped omitting rows
-- ---------------------------------------------------------------------
-- These replace views in analytics, so they belong in 02_ rather than
-- 01_ when this proposal is adopted. Both are view-only changes: every
-- column they need is already carried into the warehouse.
--
-- analytics P1: team_submission_counts INNER JOINs fact_submissions, so
-- a team that has submitted nothing produces no row and is reported as
-- ABSENT rather than as 0%. The teams furthest behind are exactly the
-- ones a progress report is for, and an empty entry reads as "no data"
-- rather than "no work".
--
-- analytics P2: the denominator counted every challenge in the season
-- regardless of category, while challenges.category_id exists precisely
-- to scope them -- so a team was measured against work it is not allowed
-- to do, and its progress fell whenever an unrelated category added a
-- challenge. A number that gets worse on its own.
--
-- dim_team.category_label and dim_challenge.category_label were both
-- already being loaded; nothing new is needed from the ETL.
CREATE OR REPLACE VIEW analytics.vw_team_season_progress AS
WITH eligible AS (
  -- a challenge counts towards a team's denominator when it is open to
  -- every category (category_label IS NULL) or to that team's own
  SELECT t.team_key, t.team_name, ch.season_name,
         count(*) AS total_challenges
  FROM analytics.dim_team t
  JOIN analytics.dim_challenge ch
    ON ch.challenge_key <> -1
   AND (ch.category_label IS NULL OR ch.category_label = t.category_label)
  GROUP BY t.team_key, t.team_name, ch.season_name
),
submitted AS (
  SELECT t.team_key, ch.season_name,
         count(DISTINCT fsub.challenge_key) AS submitted_challenges
  FROM analytics.dim_team t
  JOIN analytics.fact_submissions fsub ON fsub.team_key = t.team_key
  JOIN analytics.dim_challenge ch      ON ch.challenge_key = fsub.challenge_key
  GROUP BY t.team_key, ch.season_name
)
SELECT e.team_key,
       e.team_name,
       e.season_name,
       COALESCE(s.submitted_challenges, 0) AS submitted_challenges,
       e.total_challenges,
       round(100.0 * COALESCE(s.submitted_challenges, 0)::numeric
             / NULLIF(e.total_challenges, 0)::numeric, 1) AS progress_pct
FROM eligible e
LEFT JOIN submitted s
  ON s.team_key = e.team_key AND s.season_name::text = e.season_name::text;

COMMENT ON VIEW analytics.vw_team_season_progress IS
  'Progress per team and season. Driven from dim_team, so a team that has '
  'submitted nothing appears at 0% rather than vanishing; the denominator '
  'counts only challenges the team is eligible to enter.';


-- =====================================================================
-- KNOCK-ON, measured before adoption
-- =====================================================================
-- Measured by building a template with this patch applied and running
-- every suite against it. Recorded here rather than discovered later,
-- which is the lesson R3 left behind.
--
-- To re-measure:
--   psql -d t -f db/01_oltp_schema.sql -f db/02_analytics_schema.sql \
--             -f db/03_etl.sql -f db/proposals/R8_...patch.sql
--   then run each suite against a clone of it.
-- =====================================================================
