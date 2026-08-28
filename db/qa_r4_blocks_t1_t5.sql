-- =====================================================================
-- QA — resubmit gate, blocks T1..T5 (three-way verdict grid)
-- =====================================================================
-- Verdicts, never collapsed into pass/fail:
--   CORRECT         the gate saw the truth in oltp, for a declared reason
--   MISRESOLUTION   it answered from the wrong place / wrong rows /
--                   not at all -- and did NOT error. RED.
--   CRASH           an object or precondition is missing.
--
-- Exit 0 only if MISRESOLUTION = 0 AND CRASH = 0.
--
-- Migrations: none applied to the project. T1 installs the fix on this
-- throwaway database only; every other block leaves the schema alone.
--
--   psql -d qa_blocks -f db/01_oltp_schema.sql
--   psql -d qa_blocks -f db/qa_r4_blocks_t1_t5.sql
-- =====================================================================

\set ON_ERROR_STOP on
SET client_min_messages = WARNING;
DROP SCHEMA IF EXISTS qa CASCADE;
CREATE SCHEMA qa;
SET search_path = oltp, public;

CREATE TABLE qa.results(
  seq SERIAL PRIMARY KEY, block TEXT, state TEXT,
  seen TEXT, truth TEXT, verdict TEXT, kind TEXT, detail TEXT);

-- kind = 'live' : a defect present in the shipped schema
-- kind = 'demo' : a misresolution deliberately provoked to prove the
--                 probe can detect one. Counted separately, because a
--                 demo folded into the failure total makes the exit code
--                 meaningless -- it could never reach 0 by design.
CREATE OR REPLACE FUNCTION qa.rec(b TEXT, st TEXT, seen TEXT, truth TEXT, v TEXT, d TEXT,
                                  k TEXT DEFAULT 'live')
RETURNS void AS $$ INSERT INTO qa.results(block,state,seen,truth,verdict,kind,detail)
                   VALUES (b,st,seen,truth,v,k,d); $$ LANGUAGE sql;

-- ---------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('j1@t','x','judge'),('c@t','x','club'),
  ('owner@t','x','member'),('stranger@t','x','member');
INSERT INTO oltp.judges(account_id,full_name) SELECT account_id,'J1' FROM oltp.accounts WHERE email='j1@t';
INSERT INTO oltp.clubs(account_id,club_name)  SELECT account_id,'C'  FROM oltp.accounts WHERE email='c@t';
INSERT INTO oltp.members(account_id,full_name)
  SELECT account_id, email FROM oltp.accounts WHERE role='member';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id, tc.category_id,'Owners','T-OWN'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id, tc.category_id,'Others','T-OTH'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
-- owner belongs to T-OWN; stranger belongs to T-OTH (so "unauthorised"
-- means a real, existing account that simply is not on this roster)
INSERT INTO oltp.memberships(team_id,member_id)
  SELECT t.team_id, a.account_id FROM oltp.teams t, oltp.accounts a
  WHERE t.participation_code='T-OWN' AND a.email='owner@t';
INSERT INTO oltp.memberships(team_id,member_id)
  SELECT t.team_id, a.account_id FROM oltp.teams t, oltp.accounts a
  WHERE t.participation_code='T-OTH' AND a.email='stranger@t';
INSERT INTO oltp.seasons(name,start_date) VALUES ('S','2026-01-01');
INSERT INTO oltp.challenges(season_id,name,stage)
  SELECT s.season_id, n, 'final' FROM oltp.seasons s,
    (VALUES ('CH-T1'),('CH-T2'),('CH-T3'),('CH-T4'),('CH-T5')) AS c(n);

-- decoy schema: same table name, opposite answer
CREATE TABLE IF NOT EXISTS public.submission_reviews (
  review_id int PRIMARY KEY, submission_id int, judge_id int,
  feedback text, requires_resubmission boolean);

-- helper: current v1 of a named challenge
CREATE OR REPLACE FUNCTION qa.sub_of(p_ch TEXT, p_ver SMALLINT DEFAULT 1) RETURNS BIGINT AS $$
  SELECT s.submission_id FROM oltp.submissions s
  JOIN oltp.challenges c ON c.challenge_id = s.challenge_id
  JOIN oltp.teams t ON t.team_id = s.team_id
  WHERE c.name = p_ch AND s.version = p_ver AND t.participation_code='T-OWN';
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION qa.new_version(p_ch TEXT, p_by TEXT DEFAULT 'owner@t') RETURNS TEXT AS $fn$
DECLARE v SMALLINT;
BEGIN
  INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id)
  SELECT s.team_id, s.challenge_id, 'next', (SELECT account_id FROM oltp.accounts WHERE email=p_by)
  FROM oltp.submissions s JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
  JOIN oltp.teams t ON t.team_id=s.team_id
  WHERE c.name=p_ch AND t.participation_code='T-OWN'
  ORDER BY s.version DESC LIMIT 1
  RETURNING version INTO v;
  RETURN 'ALLOWED v' || v;
EXCEPTION WHEN others THEN
  RETURN 'REFUSED (' || SQLSTATE || ')';
END $fn$ LANGUAGE plpgsql;

-- v1 for each block, owned by T-OWN
INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id)
SELECT t.team_id, c.challenge_id, c.name||' v1', a.account_id
FROM oltp.teams t, oltp.challenges c, oltp.accounts a
WHERE t.participation_code='T-OWN' AND a.email='owner@t';


-- =====================================================================
-- T1 — the permanent fix, as a regression
-- =====================================================================
-- Gate A: UNQUALIFIED read (the R4 hazard).
CREATE OR REPLACE FUNCTION oltp.gate() RETURNS trigger AS $f$
DECLARE v BOOLEAN; p BIGINT;
BEGIN
  IF NEW.version <= 1 THEN RETURN NEW; END IF;
  SELECT submission_id INTO p FROM oltp.submissions
   WHERE team_id=NEW.team_id AND challenge_id=NEW.challenge_id ORDER BY version DESC LIMIT 1;
  SELECT coalesce(bool_or(requires_resubmission),FALSE) INTO v
    FROM submission_reviews WHERE submission_id = p;          -- UNQUALIFIED
  IF NOT v THEN RAISE EXCEPTION 'gate refused v%', NEW.version; END IF;
  RETURN NEW;
END $f$ LANGUAGE plpgsql;
CREATE TRIGGER trg_zz_gate BEFORE INSERT ON oltp.submissions
  FOR EACH ROW EXECUTE FUNCTION oltp.gate();

DO $$
DECLARE v_s BIGINT; v_out TEXT; v_truth BOOLEAN;
BEGIN
  v_s := qa.sub_of('CH-T1');
  -- oltp says FALSE, decoy says TRUE
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,feedback,requires_resubmission)
    VALUES (v_s,(SELECT account_id FROM oltp.accounts WHERE email='j1@t'),'ok, minor notes',FALSE);
  INSERT INTO public.submission_reviews VALUES (7001, v_s, 1, 'RESUBMIT', TRUE);
  SELECT bool_or(requires_resubmission) INTO v_truth FROM oltp.submission_reviews WHERE submission_id=v_s;

  -- B2 replay, BEFORE the fix
  SET LOCAL search_path = public, oltp;
  v_out := qa.new_version('CH-T1');
  PERFORM qa.rec('T1','before fix / search_path=public,oltp', v_out, 'must be REFUSED (oltp='||v_truth||')',
    CASE WHEN v_out LIKE 'ALLOWED%' THEN 'MISRESOLUTION' ELSE 'CORRECT' END,
    'unqualified gate reads the decoy; permissive failure, no error raised', 'demo');
END $$;

-- ---- THE FIX: qualify the reference -----------------------------------
-- Applied here only, on a throwaway database. CREATE OR REPLACE, so it
-- is a body swap rather than a structural migration.
CREATE OR REPLACE FUNCTION oltp.gate() RETURNS trigger AS $f$
DECLARE v BOOLEAN; p BIGINT;
BEGIN
  IF NEW.version <= 1 THEN RETURN NEW; END IF;
  SELECT submission_id INTO p FROM oltp.submissions
   WHERE team_id=NEW.team_id AND challenge_id=NEW.challenge_id ORDER BY version DESC LIMIT 1;
  SELECT coalesce(bool_or(requires_resubmission),FALSE) INTO v
    FROM oltp.submission_reviews WHERE submission_id = p;     -- QUALIFIED
  IF NOT v THEN RAISE EXCEPTION 'gate refused v%', NEW.version; END IF;
  RETURN NEW;
END $f$ LANGUAGE plpgsql;

DO $$
DECLARE v_out TEXT; v_b1 BOOLEAN; v_b2 BOOLEAN; v_s BIGINT;
BEGIN
  v_s := qa.sub_of('CH-T1');
  SET LOCAL search_path = public, oltp;
  v_out := qa.new_version('CH-T1');
  PERFORM qa.rec('T1','AFTER fix / search_path=public,oltp', v_out, 'must be REFUSED',
    CASE WHEN v_out LIKE 'REFUSED%' THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
    'qualified gate ignores the decoy under the same hostile search_path');

  -- Decoy potency. NOTE: a correct fix makes the GATE immune, so the
  -- gate must NOT flip. What must still flip is the unqualified PROBE --
  -- proving the decoy is still live and T1's "CORRECT" is not simply a
  -- verdict frozen into one branch.
  EXECUTE 'SET LOCAL search_path = oltp, public';
  SELECT bool_or(requires_resubmission) INTO v_b1 FROM submission_reviews WHERE submission_id=v_s;
  EXECUTE 'SET LOCAL search_path = public, oltp';
  SELECT bool_or(requires_resubmission) INTO v_b2 FROM submission_reviews WHERE submission_id=v_s;
  PERFORM qa.rec('T1','decoy potency after fix', v_b2::text, v_b1::text,
    CASE WHEN v_b1 IS DISTINCT FROM v_b2 THEN 'CORRECT' ELSE 'CRASH' END,
    'unqualified probe still flips (B1='||v_b1||' vs B2='||v_b2||'); the gate no longer follows it');
END $$;


-- =====================================================================
-- T2 — multi-version chain: which version's reviews does the gate read?
-- =====================================================================
-- The seed as briefed ("v1 without resubmit -> v2 permitted") cannot
-- exist under a working gate: refusing exactly that is the rule. The
-- discriminating shape is the one the brief's own decoy describes --
-- v1 and v2 carrying OPPOSITE values, with the verdict on v3 following
-- v2 alone.
DO $$
DECLARE v1 BIGINT; v2 BIGINT; v_out TEXT; v_j BIGINT;
BEGIN
  v_j := (SELECT account_id FROM oltp.accounts WHERE email='j1@t');
  v1 := qa.sub_of('CH-T2');
  -- v1 asks for a resubmission, so v2 is legitimately created
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission)
    VALUES (v1, v_j, TRUE);
  SET LOCAL search_path = oltp, public;
  v_out := qa.new_version('CH-T2');
  PERFORM qa.rec('T2','v1=TRUE -> create v2', v_out, 'must be ALLOWED',
    CASE WHEN v_out LIKE 'ALLOWED%' THEN 'CORRECT' ELSE 'CRASH' END,
    'precondition: without a real v2 the rest of T2 is untestable');

  v2 := qa.sub_of('CH-T2', 2::SMALLINT);

  -- CASE 1: v1 TRUE, v2 FALSE -> reading only v2 must REFUSE v3.
  -- Aggregating v1+v2 would give bool_or = TRUE and wrongly allow it.
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission)
    VALUES (v2, v_j, FALSE);
  v_out := qa.new_version('CH-T2');
  PERFORM qa.rec('T2','v1=TRUE, v2=FALSE -> v3', v_out, 'must be REFUSED (follow v2 only)',
    CASE WHEN v_out LIKE 'REFUSED%' THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
    'if this were ALLOWED the gate aggregated the whole chain and answered from v1');

  -- CASE 2: flip both -> reading only v2 must ALLOW v3.
  UPDATE oltp.submission_reviews SET requires_resubmission=FALSE WHERE submission_id=v1;
  UPDATE oltp.submission_reviews SET requires_resubmission=TRUE  WHERE submission_id=v2;
  v_out := qa.new_version('CH-T2');
  PERFORM qa.rec('T2','v1=FALSE, v2=TRUE -> v3', v_out, 'must be ALLOWED (follow v2 only)',
    CASE WHEN v_out LIKE 'ALLOWED%' THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
    'the mirror case: a gate anchored on v1 would refuse here. Both directions are needed, '
    ||'because either one alone is satisfied by a gate that always answers the same way.');
END $$;


-- =====================================================================
-- T3 — empty set: bool_or over zero rows is NULL
-- =====================================================================
DO $$
DECLARE v_out TEXT; v_agg TEXT; v_j BIGINT;
BEGIN
  v_j := (SELECT account_id FROM oltp.accounts WHERE email='j1@t');
  SELECT coalesce(bool_or(requires_resubmission)::text,'NULL') INTO v_agg
    FROM oltp.submission_reviews WHERE submission_id = qa.sub_of('CH-T3');
  PERFORM qa.rec('T3','v1 has zero reviews', v_agg, 'NULL',
    CASE WHEN v_agg='NULL' THEN 'CORRECT' ELSE 'CRASH' END,
    'precondition: the aggregate really is NULL, not FALSE');

  SET LOCAL search_path = oltp, public;
  v_out := qa.new_version('CH-T3');
  PERFORM qa.rec('T3','NULL handled by declared policy', v_out, 'must be REFUSED',
    CASE WHEN v_out LIKE 'REFUSED%' THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
    'policy is DECLARED in the gate as coalesce(...,FALSE): no review => no resubmission requested '
    ||'=> refuse. Chosen, not inherited from three-valued logic.');

  -- decoy: adding a TRUE review must flip the verdict
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission)
    VALUES (qa.sub_of('CH-T3'), v_j, TRUE);
  v_out := qa.new_version('CH-T3');
  PERFORM qa.rec('T3','decoy: one TRUE review added', v_out, 'must be ALLOWED',
    CASE WHEN v_out LIKE 'ALLOWED%' THEN 'CORRECT' ELSE 'CRASH' END,
    'proves the refusal above came from the empty set, not from a gate that refuses everything');
END $$;

-- what an UNCOALESCED gate would do with the same empty set
CREATE OR REPLACE FUNCTION oltp.gate() RETURNS trigger AS $f$
DECLARE v BOOLEAN; p BIGINT;
BEGIN
  IF NEW.version <= 1 THEN RETURN NEW; END IF;
  SELECT submission_id INTO p FROM oltp.submissions
   WHERE team_id=NEW.team_id AND challenge_id=NEW.challenge_id ORDER BY version DESC LIMIT 1;
  SELECT bool_or(requires_resubmission) INTO v                 -- NO coalesce
    FROM oltp.submission_reviews WHERE submission_id = p;
  IF NOT v THEN RAISE EXCEPTION 'gate refused v%', NEW.version; END IF;
  RETURN NEW;
END $f$ LANGUAGE plpgsql;

DO $$
DECLARE v_out TEXT;
BEGIN
  SET LOCAL search_path = oltp, public;
  v_out := qa.new_version('CH-T4');   -- CH-T4's v1 still has zero reviews here
  PERFORM qa.rec('T3','uncoalesced gate, empty set', v_out, 'MISRESOLUTION expected',
    CASE WHEN v_out LIKE 'ALLOWED%' THEN 'MISRESOLUTION' ELSE 'CORRECT' END,
    'NULL is not TRUE, so `IF NOT v` never fires and the row passes -- a branch nobody chose. '
    ||'Shown to prove T3 discriminates; the coalesced gate is restored immediately after.', 'demo');
END $$;

-- restore the correct gate
CREATE OR REPLACE FUNCTION oltp.gate() RETURNS trigger AS $f$
DECLARE v BOOLEAN; p BIGINT;
BEGIN
  IF NEW.version <= 1 THEN RETURN NEW; END IF;
  SELECT submission_id INTO p FROM oltp.submissions
   WHERE team_id=NEW.team_id AND challenge_id=NEW.challenge_id ORDER BY version DESC LIMIT 1;
  SELECT coalesce(bool_or(requires_resubmission),FALSE) INTO v
    FROM oltp.submission_reviews WHERE submission_id = p;
  IF NOT v THEN RAISE EXCEPTION 'gate refused v%', NEW.version; END IF;
  RETURN NEW;
END $f$ LANGUAGE plpgsql;


-- =====================================================================
-- T4 — the resubmit notification
-- =====================================================================
DO $$
DECLARE v_s BIGINT; v_true BIGINT; v_false BIGINT; v_j2 BIGINT; v_j BIGINT;
        v_n_true INT; v_n_false INT;
BEGIN
  v_j := (SELECT account_id FROM oltp.accounts WHERE email='j1@t');
  INSERT INTO oltp.accounts(email,password_hash,role) VALUES ('j2@t','x','judge');
  INSERT INTO oltp.judges(account_id,full_name) SELECT account_id,'J2' FROM oltp.accounts WHERE email='j2@t';
  v_j2 := (SELECT account_id FROM oltp.accounts WHERE email='j2@t');
  v_s := qa.sub_of('CH-T5');

  -- decoy pair: one review that asks, one that does not
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission,feedback)
    VALUES (v_s, v_j, TRUE, 'please rework') RETURNING review_id INTO v_true;
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission,feedback)
    VALUES (v_s, v_j2, FALSE, 'fine by me') RETURNING review_id INTO v_false;

  SELECT count(*) INTO v_n_true  FROM oltp.notification_submission_review_links WHERE submission_review_id=v_true;
  SELECT count(*) INTO v_n_false FROM oltp.notification_submission_review_links WHERE submission_review_id=v_false;

  PERFORM qa.rec('T4','review requires_resubmission=TRUE', v_n_true||' notification(s)', 'exactly 1',
    CASE WHEN v_n_true = 1 THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
    'no trigger on submission_reviews emits a notification ('
    || (SELECT count(*) FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid
        WHERE c.relname='submission_reviews' AND NOT tg.tgisinternal)::text
    || ' non-internal trigger(s) on the table). The review is stored, nothing errors, '
    ||'and the team is never told -- a silent permissive failure.');

  PERFORM qa.rec('T4','decoy: review requires_resubmission=FALSE', v_n_false||' notification(s)', 'exactly 0',
    CASE WHEN v_n_false = 0 THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
    'the FALSE review correctly produces nothing -- but only because nothing is produced at all, '
    ||'so this leg cannot distinguish "correctly silent" from "uniformly silent"');
END $$;


-- =====================================================================
-- T5 — authorisation to submit the new version
-- =====================================================================
DO $$
DECLARE v_out_owner TEXT; v_out_stranger TEXT; v_ck INT; v_rls BOOLEAN; v_j BIGINT;
BEGIN
  v_j := (SELECT account_id FROM oltp.accounts WHERE email='j1@t');
  -- open the gate legitimately so authorisation is the only thing under test
  -- open the gate on the LATEST version of the chain. Opening v1 would
  -- leave the real predecessor unreviewed, and the gate would refuse --
  -- which is the gate being right and the test being wrong.
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission)
    SELECT s.submission_id, v_j, TRUE FROM oltp.submissions s
    JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
    JOIN oltp.teams t ON t.team_id=s.team_id
    WHERE c.name='CH-T1' AND t.participation_code='T-OWN'
    ORDER BY s.version DESC LIMIT 1
    ON CONFLICT (submission_id,judge_id) DO UPDATE SET requires_resubmission=TRUE;

  SET LOCAL search_path = oltp, public;
  v_out_owner := qa.new_version('CH-T1','owner@t');
  PERFORM qa.rec('T5','owner of T-OWN submits', v_out_owner, 'must be ALLOWED',
    CASE WHEN v_out_owner LIKE 'ALLOWED%' THEN 'CORRECT' ELSE 'CRASH' END,
    'positive control: the permitted case must work, or the refusal below proves nothing');

  -- reopen the gate for the next attempt
  INSERT INTO oltp.submission_reviews(submission_id,judge_id,requires_resubmission)
    SELECT s.submission_id, v_j, TRUE FROM oltp.submissions s
    JOIN oltp.challenges c ON c.challenge_id=s.challenge_id
    JOIN oltp.teams t ON t.team_id=s.team_id
    WHERE c.name='CH-T1' AND t.participation_code='T-OWN'
    ORDER BY s.version DESC LIMIT 1
    ON CONFLICT (submission_id,judge_id) DO UPDATE SET requires_resubmission=TRUE;

  v_out_stranger := qa.new_version('CH-T1','stranger@t');
  PERFORM qa.rec('T5','stranger (member of T-OTH) submits for T-OWN', v_out_stranger, 'must be REFUSED',
    CASE WHEN v_out_stranger LIKE 'REFUSED%' THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
    'submissions.submitted_by_account_id is a bare FK to accounts; nothing ties it to the owning '
    ||'team''s roster, so any existing account can author a version for any team');

  SELECT count(*) INTO v_ck FROM pg_constraint
   WHERE conrelid='oltp.submissions'::regclass AND contype IN ('c','f')
     AND pg_get_constraintdef(oid) ILIKE '%membership%';
  SELECT relrowsecurity INTO v_rls FROM pg_class WHERE oid='oltp.submissions'::regclass;
  PERFORM qa.rec('T5','catalogue: is authorisation expressible?', v_ck||' constraint(s), RLS='||v_rls,
    'some enforcement', CASE WHEN v_ck > 0 OR v_rls THEN 'CORRECT' ELSE 'MISRESOLUTION' END,
    'no constraint references memberships and row level security is off -- the RLS example in '
    ||'01_oltp_schema.sql is commented out, so authorisation is entirely unowned at the DB layer');
END $$;


-- =====================================================================
\echo ''
\echo '===================== VERDICT GRID ====================='
SELECT seq, block, state, seen AS "what the gate saw", truth AS "oltp truth", verdict, kind
FROM qa.results ORDER BY seq;
\echo ''
\echo '--- reasoning ---'
SELECT seq, block, verdict, detail FROM qa.results ORDER BY seq;
\echo ''
SELECT verdict, kind, count(*) FROM qa.results GROUP BY verdict, kind ORDER BY verdict, kind;

DO $$
DECLARE v_m INT; v_c INT;
BEGIN
  SELECT count(*) FILTER (WHERE verdict='MISRESOLUTION' AND kind='live'),
         count(*) FILTER (WHERE verdict='CRASH') INTO v_m, v_c FROM qa.results;
  RAISE NOTICE 'CORRECT=% MISRESOLUTION(live)=% MISRESOLUTION(demo)=% CRASH=%',
    (SELECT count(*) FROM qa.results WHERE verdict='CORRECT'), v_m,
    (SELECT count(*) FROM qa.results WHERE verdict='MISRESOLUTION' AND kind='demo'), v_c;
  IF v_m > 0 OR v_c > 0 THEN
    RAISE EXCEPTION 'NOT CLEAN: % misresolution(s), % crash(es)', v_m, v_c;
  END IF;
END $$;
