-- =====================================================================
-- PROPOSAL R5 — citing the rulebook, made durable
-- =====================================================================
-- STATUS: ADOPTED on 2026-08-27. This file is now a RECORD, not a
-- migration: its contents were folded into 01_oltp_schema.sql and the
-- pipeline builds them from there. Do NOT run it against a current
-- database -- it would fail on objects that already exist. It is kept
-- because the reasoning here is the reasoning behind the schema, and
-- 01_ carries only the short form of it.
--
-- Evidence: db/qa_rule_references.sql, 4 gaps on a throwaway database.
-- Verified by: db/proposals/R5_rule_citations.verify.sql
--
-- The four gaps are not independent. X4 (a citation follows the rule,
-- not the wording it was made under) is the root: once rule text has a
-- history, "which wording was cited" becomes expressible, and the other
-- three become small. So Part 1 comes first and the rest build on it.
--
--   Part 1  rule_revisions            -> closes X4
--   Part 2  citations capture the revision -> closes X4 for both paths
--   Part 3  retire, do not delete     -> closes X3
--   Part 4  appeal_rule_references    -> closes A4
--   Part 5  code/section agreement    -> closes R4
--
-- Parts 3, 4 and 5 are independently reviewable: rejecting one does not
-- break the others. Part 2 depends on Part 1.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Part 1 — rule_revisions (closes X4)
-- ---------------------------------------------------------------------
-- Today oltp.rules is a single mutable row per rule. Editing G4 rewrites
-- history: every appeal and every forum post that ever cited it silently
-- starts pointing at the new wording. Measured: an appeal filed against
-- "Members must be registered before the season." ended up citing
-- "REWRITTEN: members may register at any time."
--
-- For a competition rulebook that is the sharpest failure available -- a
-- dispute decided against wording the filer never saw.
--
-- The fix keeps `rules` as the IDENTITY of a rule (its code, its
-- section, its current state) and adds an append-only log of every
-- wording it has ever had. Nothing about how rules are queried today
-- changes; the history is additive.
CREATE TABLE oltp.rule_revisions (
  revision_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_id        BIGINT NOT NULL REFERENCES oltp.rules(rule_id) ON DELETE CASCADE,
  title          VARCHAR(200) NOT NULL,
  body           TEXT NOT NULL,
  version_label  VARCHAR(30),
  recorded_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_rule_revisions_rule_id ON oltp.rule_revisions(rule_id, revision_id DESC);

-- Append-only by construction: no UPDATE or DELETE path is provided, and
-- the trigger below only ever inserts. A revision is a historical fact;
-- editing one would recreate the problem this table exists to solve.
CREATE OR REPLACE FUNCTION oltp.record_rule_revision() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public          -- R4-class hardening, see R4 patch
AS $fn$
BEGIN
  -- Only record when the CITABLE CONTENT changes. A touch of
  -- sort_order or an unrelated column must not manufacture a revision
  -- that no reader would recognise as different.
  IF TG_OP = 'INSERT'
     OR NEW.title IS DISTINCT FROM OLD.title
     OR NEW.body  IS DISTINCT FROM OLD.body
     OR NEW.version_label IS DISTINCT FROM OLD.version_label THEN
    INSERT INTO oltp.rule_revisions(rule_id, title, body, version_label)
      VALUES (NEW.rule_id, NEW.title, NEW.body, NEW.version_label);
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_rules_revision
  AFTER INSERT OR UPDATE ON oltp.rules
  FOR EACH ROW EXECUTE FUNCTION oltp.record_rule_revision();

-- Back-fill: every existing rule gets its current wording as revision 1,
-- otherwise citations made before this migration have nothing to point
-- at. Same reasoning, and the same ordering hazard, as R2 step 2 -- this
-- MUST run before anything that references a revision.
INSERT INTO oltp.rule_revisions(rule_id, title, body, version_label, recorded_at)
SELECT rule_id, title, body, version_label, updated_at FROM oltp.rules;


-- ---------------------------------------------------------------------
-- Part 2 — citations capture the revision (closes X4 for both paths)
-- ---------------------------------------------------------------------
-- A citation now records WHICH wording was invoked. Nullable, because a
-- citation may legitimately predate the revision log, and because
-- appeals.rule_id itself is optional.
--
-- Populated BY TRIGGER, not by the caller. The application layer does
-- not exist yet, and N1 established what happens to work that is left
-- to it: nothing does it. A default the database fills in is the only
-- kind that can be relied on today.
ALTER TABLE oltp.appeals
  ADD COLUMN cited_revision_id BIGINT REFERENCES oltp.rule_revisions(revision_id);
CREATE INDEX ix_appeals_cited_revision ON oltp.appeals(cited_revision_id);

ALTER TABLE oltp.post_rule_references
  ADD COLUMN cited_revision_id BIGINT REFERENCES oltp.rule_revisions(revision_id);
CREATE INDEX ix_post_rule_references_cited_revision ON oltp.post_rule_references(cited_revision_id);

CREATE OR REPLACE FUNCTION oltp.pin_cited_revision() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
DECLARE v_rule BIGINT;
BEGIN
  v_rule := NEW.rule_id;
  IF v_rule IS NULL OR NEW.cited_revision_id IS NOT NULL THEN
    RETURN NEW;                          -- nothing cited, or caller pinned it
  END IF;
  SELECT revision_id INTO NEW.cited_revision_id
  FROM oltp.rule_revisions
  WHERE rule_id = v_rule
  ORDER BY revision_id DESC
  LIMIT 1;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_appeals_pin_revision
  BEFORE INSERT ON oltp.appeals
  FOR EACH ROW EXECUTE FUNCTION oltp.pin_cited_revision();

CREATE TRIGGER trg_post_rule_references_pin_revision
  BEFORE INSERT ON oltp.post_rule_references
  FOR EACH ROW EXECUTE FUNCTION oltp.pin_cited_revision();

-- Back-fill existing citations to the revision that was current when the
-- log was created. Not strictly correct for citations made before an
-- edit -- that information is gone and cannot be reconstructed. Recorded
-- honestly rather than papered over: see the TRUST note at the bottom.
UPDATE oltp.appeals a
   SET cited_revision_id = (SELECT rv.revision_id FROM oltp.rule_revisions rv
                            WHERE rv.rule_id = a.rule_id ORDER BY rv.revision_id LIMIT 1)
 WHERE a.rule_id IS NOT NULL AND a.cited_revision_id IS NULL;

UPDATE oltp.post_rule_references p
   SET cited_revision_id = (SELECT rv.revision_id FROM oltp.rule_revisions rv
                            WHERE rv.rule_id = p.rule_id ORDER BY rv.revision_id LIMIT 1)
 WHERE p.cited_revision_id IS NULL;


-- ---------------------------------------------------------------------
-- Part 3 — retire, do not delete (closes X3)
-- ---------------------------------------------------------------------
-- Measured: deleting a rule cited by an APPEAL is refused, while the
-- identical statement against a rule cited by a POST succeeds and
-- silently erases the citation -- the post keeps arguing from a rule the
-- reader can no longer look up.
--
-- One act, two behaviours, neither of them a decision: appeals.rule_id
-- simply has no ON DELETE clause while post_rule_references.rule_id was
-- given CASCADE. This makes both paths agree on the stricter reading: a
-- rule that has ever been cited is part of the record.
ALTER TABLE oltp.post_rule_references
  DROP CONSTRAINT post_rule_references_rule_id_fkey;
ALTER TABLE oltp.post_rule_references
  ADD CONSTRAINT post_rule_references_rule_id_fkey
  FOREIGN KEY (rule_id) REFERENCES oltp.rules(rule_id);   -- NO ACTION, as appeals already has

-- Withdrawal without destruction. A retired rule stops being citable but
-- every existing citation still resolves.
ALTER TABLE oltp.rules ADD COLUMN retired_at TIMESTAMPTZ;
COMMENT ON COLUMN oltp.rules.retired_at IS
  'When the rule left the active rulebook. Existing citations keep resolving; new ones are refused.';

CREATE OR REPLACE FUNCTION oltp.refuse_retired_rule_citation() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
DECLARE v_retired TIMESTAMPTZ;
BEGIN
  IF NEW.rule_id IS NULL THEN RETURN NEW; END IF;
  SELECT retired_at INTO v_retired FROM oltp.rules WHERE rule_id = NEW.rule_id;
  IF v_retired IS NOT NULL THEN
    RAISE EXCEPTION 'rule % was retired on % and can no longer be cited', NEW.rule_id, v_retired
      USING HINT = 'existing citations still resolve; cite a current rule instead';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_appeals_no_retired_rule
  BEFORE INSERT ON oltp.appeals
  FOR EACH ROW EXECUTE FUNCTION oltp.refuse_retired_rule_citation();
CREATE TRIGGER trg_post_rule_references_no_retired_rule
  BEFORE INSERT ON oltp.post_rule_references
  FOR EACH ROW EXECUTE FUNCTION oltp.refuse_retired_rule_citation();


-- ---------------------------------------------------------------------
-- Part 4 — an appeal may invoke several rules (closes A4)
-- ---------------------------------------------------------------------
-- A forum post cites any number of rules through a junction; an appeal
-- was capped at one by a single nullable FK. A real dispute breaches
-- several rules at once, and today the filer must pick one and put the
-- rest in free-text `reason`, where nothing can query them.
--
-- The junction mirrors post_rule_references exactly -- same shape, same
-- composite PK, same revision pinning -- so the two citation paths stop
-- being modelled differently.
CREATE TABLE oltp.appeal_rule_references (
  appeal_id          BIGINT NOT NULL REFERENCES oltp.appeals(appeal_id) ON DELETE CASCADE,
  rule_id            BIGINT NOT NULL REFERENCES oltp.rules(rule_id),
  cited_revision_id  BIGINT REFERENCES oltp.rule_revisions(revision_id),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (appeal_id, rule_id)
);
CREATE INDEX ix_appeal_rule_references_rule_id ON oltp.appeal_rule_references(rule_id);

CREATE TRIGGER trg_appeal_rule_references_pin_revision
  BEFORE INSERT ON oltp.appeal_rule_references
  FOR EACH ROW EXECUTE FUNCTION oltp.pin_cited_revision();
CREATE TRIGGER trg_appeal_rule_references_no_retired_rule
  BEFORE INSERT ON oltp.appeal_rule_references
  FOR EACH ROW EXECUTE FUNCTION oltp.refuse_retired_rule_citation();

-- Move existing single citations into the junction so there is one place
-- to read from.
INSERT INTO oltp.appeal_rule_references(appeal_id, rule_id, cited_revision_id, created_at)
SELECT appeal_id, rule_id, cited_revision_id, created_at
FROM oltp.appeals WHERE rule_id IS NOT NULL
ON CONFLICT (appeal_id, rule_id) DO NOTHING;

-- appeals.rule_id is left in place ON PURPOSE, not dropped:
--   * dropping it is a breaking change for anything already reading it;
--   * 99_tests.sql and qa_rule_references.sql both write it directly.
-- Mark it deprecated, migrate readers, drop it in a later change once
-- nothing depends on it. Two half-populated sources of the same fact is
-- a real cost -- it is accepted here only as a transitional state, and
-- it is the single largest reason to review this part carefully.
COMMENT ON COLUMN oltp.appeals.rule_id IS
  'DEPRECATED: superseded by oltp.appeal_rule_references, which allows several rules per appeal. '
  'Kept for compatibility; back-filled into the junction. Drop once no reader remains.';


-- ---------------------------------------------------------------------
-- Part 5 — a code must agree with its section (closes R4)
-- ---------------------------------------------------------------------
-- Measured: a rule with code 'A99' was accepted under section 'G'. A
-- citation would then resolve to a rule whose code implies a different
-- chapter of the rulebook.
--
-- A CHECK cannot express this: the section's code lives in another
-- table. Hence a trigger, in the same style as the schema's existing
-- cross-row rules (enforce_team_capacity, enforce_appeal_limit).
CREATE OR REPLACE FUNCTION oltp.enforce_rule_code_section() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
DECLARE v_section_code TEXT;
BEGIN
  SELECT code INTO v_section_code FROM oltp.rule_sections WHERE section_id = NEW.section_id;
  IF upper(NEW.code) NOT LIKE upper(v_section_code) || '%' THEN
    RAISE EXCEPTION 'rule code % does not belong to section % ', NEW.code, v_section_code
      USING HINT = 'the code is a denormalised copy of the section prefix; G-section rules start with G';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_rules_code_section
  BEFORE INSERT OR UPDATE ON oltp.rules
  FOR EACH ROW EXECUTE FUNCTION oltp.enforce_rule_code_section();


-- =====================================================================
-- WHAT THIS DOES NOT ESTABLISH -- read before approving
-- =====================================================================
-- The Part 2 back-fill pins every pre-existing citation to the EARLIEST
-- recorded revision of its rule. For a citation made before an edit that
-- is correct only by luck: the wording actually invoked was not
-- recorded, and cannot be reconstructed from anything in the database.
--
-- So the guarantee "a citation knows which wording it invoked" is
-- forward-looking. Citations made before this migration carry a
-- plausible revision, not a verified one. That is the same shape as the
-- R2 back-fill: a trust decision, and it should be taken deliberately
-- rather than inherited from a green migration.
--
-- KNOCK-ON -- MEASURED on a throwaway database, not estimated:
--
--   * db/99_tests.sql: 212/213. The single failure is
--       "MANIFEST: no undocumented column exists (schema-drift guard)"
--     listing appeal_rule_references.*, rule_revisions.*,
--     appeals.cited_revision_id, post_rule_references.cited_revision_id,
--     rules.retired_at. That is the drift guard doing its job: adopting
--     this patch REQUIRES adding those columns to the manifest in
--     99_tests.sql with an origin, which is the review step the manifest
--     exists to force. Nothing else in 213 assertions moves.
--
--   * db/qa_rule_references.sql: aborts at line 102 with
--       "rule code A99 does not belong to section G"
--     which is case R4-GAP deliberately creating the drift this patch
--     now refuses. Case X3-GAP (deleting a post-cited rule) would fail
--     for the same reason if the script reached it. Both are GAP
--     demonstrations that become obsolete once the gap is closed -- they
--     should be rewritten as paired negatives, exactly as
--     R5_rule_citations.verify.sql already does.
--
--   * Part 5 also rejects any PRE-EXISTING rule whose code disagrees
--     with its section: the ALTER succeeds, but the next UPDATE of that
--     row fails. Audit before adopting:
--       SELECT r.code, s.code FROM oltp.rules r
--       JOIN oltp.rule_sections s ON s.section_id = r.section_id
--       WHERE upper(r.code) NOT LIKE upper(s.code) || '%';
--
--   * analytics is untouched: no fact or dimension reads rules.
--
-- OPEN QUESTION, not decided here: should retiring a rule also retire
-- the citations that point at it -- i.e. should an appeal filed under a
-- since-retired rule be flagged for review? That is a competition-rules
-- question, not a schema one.
-- =====================================================================
