-- =====================================================================
-- QA harness — ONE implementation, shared by every qa_* suite
-- =====================================================================
-- Why this file exists: the suites each carried their own copy of these
-- helpers. When the vacuity guard was added to qa_reject in one of them,
-- it propagated to none of the others -- so four suites kept happily
-- counting a statement that touched zero rows as a passed rejection.
-- A shared harness is the only thing that makes a correction to the
-- testing method actually reach the tests.
--
-- Include it at the top of a suite:
--     \ir _qa_harness.sql
--
-- It creates schema `qa` fresh, so it must come before any fixture.
-- 99_tests.sql is deliberately NOT migrated onto this: it has its own
-- `testing` schema, a different result shape (levels, blocking flags)
-- and 213 green assertions. Rewriting it to gain shared helpers would
-- risk a working suite for a cosmetic win.
--
-- ---------------------------------------------------------------------
-- THE RULES THIS HARNESS ENFORCES MECHANICALLY
-- ---------------------------------------------------------------------
-- 1. A rejection only counts if a positive control actually took effect.
--    qa_pair() runs both as one unit; if the control inserts 0 rows the
--    case is FAIL, not PASS, with "the negative proves nothing".
-- 2. A statement that succeeds while touching 0 rows is VACUOUS, never
--    a pass -- in either direction.
-- 3. A deliberately provoked failure (kind='demo') is counted apart from
--    a real one (kind='live'). Folding demos into the failure total makes
--    the exit code unreachable by construction, hence meaningless.
-- 4. A standalone rejection with no paired control is recorded but
--    FLAGGED by qa_lint(), because it is the shape that historically
--    passed for the wrong reason.
-- =====================================================================

DROP SCHEMA IF EXISTS qa CASCADE;
CREATE SCHEMA qa;

-- Every suite needs the same resolution order, so it is set once here
-- rather than forgotten once per suite.
--
-- BUT NOTE WHAT THIS COSTS, because it is the exact mechanism that hid
-- the R4 defect for the whole life of the project: with oltp on the
-- path, an unqualified reference inside a trigger resolves correctly,
-- and no suite loading this harness can ever observe the failure a
-- default client connection would hit. 213 green assertions could not
-- see it.
--
-- The compensating control is db/qa_search_path_regression.sql, which
-- deliberately does NOT load this harness and runs under RESET
-- search_path. If that file is ever deleted, this line silently becomes
-- a blind spot again.
SET search_path = qa, oltp, public;

-- qa_finish() reports the suite's one-line summary via RAISE NOTICE, and
-- the runner parses that line. A suite that leaves this at WARNING is
-- invisible to the runner, which then reports "(no summary line)".
SET client_min_messages = NOTICE;

CREATE TABLE qa.results(
  seq     SERIAL PRIMARY KEY,
  suite   TEXT,
  grp     TEXT,
  tc      TEXT,
  role    TEXT,          -- PRE | POS | NEG | GAP | NOTE | STUB
  status  TEXT,          -- PASS | FAIL | GAP | NOTE | PENDING-API | PENDING-SCHEMA
  kind    TEXT,          -- live | demo
  paired  BOOLEAN,       -- was the negative run with a positive control?
  intent  TEXT,
  control TEXT,
  result  TEXT
);

CREATE TABLE qa.meta(suite TEXT);

CREATE OR REPLACE FUNCTION qa.suite(p_name TEXT) RETURNS void AS $$
  DELETE FROM qa.meta; INSERT INTO qa.meta VALUES (p_name);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION qa._suite() RETURNS TEXT AS $$
  SELECT coalesce((SELECT suite FROM qa.meta LIMIT 1), '<unnamed>');
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Recording primitives
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION qa.rec(p_grp TEXT, p_tc TEXT, p_role TEXT, p_status TEXT,
                                  p_intent TEXT DEFAULT NULL, p_control TEXT DEFAULT NULL,
                                  p_result TEXT DEFAULT NULL, p_kind TEXT DEFAULT 'live',
                                  p_paired BOOLEAN DEFAULT NULL)
RETURNS void AS $$
  INSERT INTO qa.results(suite,grp,tc,role,status,kind,paired,intent,control,result)
  VALUES (qa._suite(),p_grp,p_tc,p_role,p_status,p_kind,p_paired,p_intent,p_control,p_result);
$$ LANGUAGE sql;

-- ---------------------------------------------------------------------
-- Positive assertion
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION qa_true(p_grp TEXT, p_tc TEXT, p_intent TEXT,
                                   p_cond BOOLEAN, p_result TEXT DEFAULT NULL)
RETURNS void AS $$
  SELECT qa.rec(p_grp,p_tc,'POS',
                CASE WHEN coalesce(p_cond,FALSE) THEN 'PASS' ELSE 'FAIL' END,
                p_intent,'direct read-back',p_result);
$$ LANGUAGE sql;

-- 4-arg form used by the older suites: (grp, tc, cond, detail)
CREATE OR REPLACE FUNCTION qa_true(p_grp TEXT, p_tc TEXT, p_cond BOOLEAN, p_detail TEXT DEFAULT NULL)
RETURNS void AS $$
  SELECT qa.rec(p_grp,p_tc,'POS',
                CASE WHEN coalesce(p_cond,FALSE) THEN 'PASS' ELSE 'FAIL' END,
                NULL,'direct read-back',p_detail);
$$ LANGUAGE sql;

-- ---------------------------------------------------------------------
-- Precondition: proves the base state a negative case relies on
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION qa_pre(p_grp TEXT, p_tc TEXT, p_cond BOOLEAN, p_detail TEXT DEFAULT NULL)
RETURNS void AS $$
  SELECT qa.rec(p_grp,'PRE '||p_tc,'PRE',
                CASE WHEN coalesce(p_cond,FALSE) THEN 'PASS' ELSE 'FAIL' END,
                NULL,'premise check',
                CASE WHEN coalesce(p_cond,FALSE) THEN p_detail
                     ELSE 'PRECONDITION NOT MET -- the rejection below proves nothing: '
                          || coalesce(p_detail,'') END);
$$ LANGUAGE sql;

-- ---------------------------------------------------------------------
-- Paired negative: control + rejection, judged as one unit
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION qa_pair(p_grp TEXT, p_tc TEXT, p_intent TEXT,
                                   p_pos TEXT, p_neg TEXT, p_kind TEXT DEFAULT 'live')
RETURNS void AS $fn$
DECLARE
  v_rows BIGINT; v_ok BOOLEAN := FALSE; v_pos TEXT;
  v_con TEXT; v_tab TEXT; v_state TEXT;
BEGIN
  BEGIN
    EXECUTE p_pos;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows > 0 THEN v_ok := TRUE; v_pos := format('control affected %s row(s)', v_rows);
    ELSE v_pos := 'control touched 0 rows (VACUOUS)'; END IF;
  EXCEPTION WHEN others THEN
    v_pos := format('control REJECTED [%s]: %s', SQLSTATE, SQLERRM);
  END;

  BEGIN
    EXECUTE p_neg;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM qa.rec(p_grp,p_tc,'NEG','FAIL',p_intent,v_pos,
      CASE WHEN v_rows=0 THEN 'VACUOUS: negative succeeded touching 0 rows -- asserted nothing'
           ELSE format('ACCEPTED (%s row(s)) but must be rejected', v_rows) END, p_kind, TRUE);
    RETURN;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_con=CONSTRAINT_NAME, v_tab=TABLE_NAME, v_state=RETURNED_SQLSTATE;
    PERFORM qa.rec(p_grp,p_tc,'NEG',
      CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END, p_intent,
      CASE WHEN v_ok THEN v_pos ELSE v_pos||' -- THE NEGATIVE PROVES NOTHING' END,
      format('rejected [%s] table=%s constraint=%s', v_state, coalesce(v_tab,''), coalesce(v_con,'')),
      p_kind, TRUE);
  END;
END $fn$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Standalone forms. qa_reject is deliberately marked paired=FALSE so
-- qa_lint() can surface it: an unpaired rejection is exactly the shape
-- that used to pass for the wrong reason.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION qa_reject(p_grp TEXT, p_tc TEXT, p_stmt TEXT) RETURNS void AS $fn$
DECLARE v_rows BIGINT; v_con TEXT; v_tab TEXT; v_state TEXT;
BEGIN
  BEGIN
    EXECUTE p_stmt;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM qa.rec(p_grp,p_tc,'NEG','FAIL',NULL,'no positive control',
      CASE WHEN v_rows=0 THEN 'VACUOUS: succeeded touching 0 rows'
           ELSE format('ACCEPTED (%s row(s)) but must be rejected', v_rows) END,'live',FALSE);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_con=CONSTRAINT_NAME, v_tab=TABLE_NAME, v_state=RETURNED_SQLSTATE;
    PERFORM qa.rec(p_grp,p_tc,'NEG','PASS',NULL,'no positive control',
      format('rejected [%s] table=%s constraint=%s', v_state, coalesce(v_tab,''), coalesce(v_con,'')),
      'live',FALSE);
  END;
END $fn$ LANGUAGE plpgsql;

-- Reject WITH a declared reason. This is the cheaper half of the pairing
-- discipline: a positive control proves the write path works, while an
-- expected SQLSTATE proves the rejection came from the rule under test
-- and not from, say, a mistyped column name -- which also raises, and
-- would otherwise be recorded as a pass.
--
-- Use this when a qa_pre() already proves the state and the only open
-- question is WHY the statement failed.
CREATE OR REPLACE FUNCTION qa_reject(p_grp TEXT, p_tc TEXT, p_stmt TEXT, p_expect TEXT) RETURNS void AS $fn$
DECLARE v_rows BIGINT; v_con TEXT; v_tab TEXT; v_state TEXT;
BEGIN
  BEGIN
    EXECUTE p_stmt;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM qa.rec(p_grp,p_tc,'NEG','FAIL',NULL,'expected SQLSTATE '||p_expect,
      CASE WHEN v_rows=0 THEN 'VACUOUS: succeeded touching 0 rows'
           ELSE format('ACCEPTED (%s row(s)) but must be rejected', v_rows) END,'live',TRUE);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_con=CONSTRAINT_NAME, v_tab=TABLE_NAME, v_state=RETURNED_SQLSTATE;
    PERFORM qa.rec(p_grp,p_tc,'NEG',
      CASE WHEN v_state = p_expect THEN 'PASS' ELSE 'FAIL' END,
      NULL, 'expected SQLSTATE '||p_expect,
      CASE WHEN v_state = p_expect
           THEN format('rejected [%s] table=%s constraint=%s', v_state, coalesce(v_tab,''), coalesce(v_con,''))
           ELSE format('REJECTED FOR THE WRONG REASON: got [%s] expected [%s] -- %s',
                       v_state, p_expect, SQLERRM) END,
      'live', TRUE);
  END;
END $fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qa_accept(p_grp TEXT, p_tc TEXT, p_stmt TEXT) RETURNS void AS $fn$
DECLARE v_rows BIGINT; v_state TEXT; v_con TEXT;
BEGIN
  BEGIN
    EXECUTE p_stmt;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM qa.rec(p_grp,p_tc,'POS', CASE WHEN v_rows=0 THEN 'FAIL' ELSE 'PASS' END, NULL,
      'statement executed',
      CASE WHEN v_rows=0 THEN 'VACUOUS: accepted but touched 0 rows' ELSE v_rows||' row(s)' END);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE, v_con=CONSTRAINT_NAME;
    PERFORM qa.rec(p_grp,p_tc,'POS','FAIL',NULL,'statement executed',
      format('UNEXPECTEDLY rejected [%s] constraint=%s: %s', v_state, coalesce(v_con,''), SQLERRM));
  END;
END $fn$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Findings that are not pass/fail
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION qa_gap(p_grp TEXT, p_tc TEXT, p_intent TEXT, p_control TEXT, p_result TEXT)
RETURNS void AS $$ SELECT qa.rec(p_grp,p_tc,'GAP','GAP',p_intent,p_control,p_result); $$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION qa_gap(p_grp TEXT, p_tc TEXT, p_intent TEXT, p_result TEXT)
RETURNS void AS $$ SELECT qa.rec(p_grp,p_tc,'GAP','GAP',p_intent,
                                 'accepted where a rule was expected',p_result); $$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION qa_note(p_grp TEXT, p_tc TEXT, p_intent TEXT, p_result TEXT)
RETURNS void AS $$ SELECT qa.rec(p_grp,p_tc,'NOTE','NOTE',p_intent,'observation only',p_result); $$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION qa_pending(p_grp TEXT, p_tc TEXT, p_status TEXT, p_detail TEXT)
RETURNS void AS $$ SELECT qa.rec(p_grp,p_tc,'STUB',p_status,NULL,'open item',p_detail); $$ LANGUAGE sql;

-- three-way verdict grid, for the search_path style probes
CREATE OR REPLACE FUNCTION qa_verdict(p_grp TEXT, p_tc TEXT, p_seen TEXT, p_truth TEXT,
                                      p_verdict TEXT, p_detail TEXT, p_kind TEXT DEFAULT 'live')
RETURNS void AS $$
  SELECT qa.rec(p_grp,p_tc,'POS',p_verdict,NULL,
                'saw: '||coalesce(p_seen,'<null>')||' | truth: '||coalesce(p_truth,'<null>'),
                p_detail,p_kind);
$$ LANGUAGE sql;

-- ---------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION qa_lint()
RETURNS TABLE(issue TEXT, detail TEXT) AS $fn$
BEGIN
  RETURN QUERY
    SELECT 'unpaired negative'::TEXT,
           format('%s | %s -- rejection recorded with no positive control', grp, tc)
    FROM qa.results WHERE role='NEG' AND paired IS NOT TRUE;

  RETURN QUERY
    SELECT 'vacuous statement'::TEXT, format('%s | %s -- %s', grp, tc, result)
    FROM qa.results WHERE result ILIKE '%VACUOUS%';

  -- A suite proves its premises either with explicit qa_pre() rows or by
  -- using qa_pair(), which carries the control inside the case. Only the
  -- absence of BOTH is worth flagging -- the earlier version of this rule
  -- fired on every pair-only suite, which is a lint that cries wolf.
  RETURN QUERY
    SELECT 'suite proves no premises'::TEXT,
           format('%s -- no qa_pre() rows and no paired negatives', qa._suite())
    WHERE NOT EXISTS (SELECT 1 FROM qa.results WHERE role='PRE')
      AND NOT EXISTS (SELECT 1 FROM qa.results WHERE role='NEG' AND paired);

  RETURN QUERY
    SELECT 'gap without evidence'::TEXT, format('%s | %s -- no control recorded', grp, tc)
    FROM qa.results WHERE status='GAP' AND coalesce(control,'')='';
END $fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION qa_summary()
RETURNS TABLE(grp TEXT, pass BIGINT, fail BIGINT, gap BIGINT, note BIGINT, pending BIGINT, total BIGINT) AS $$
  SELECT r.grp,
         count(*) FILTER (WHERE r.status='PASS'),
         count(*) FILTER (WHERE r.status='FAIL' AND r.kind='live'),
         count(*) FILTER (WHERE r.status='GAP'),
         count(*) FILTER (WHERE r.status='NOTE'),
         count(*) FILTER (WHERE r.status LIKE 'PENDING%'),
         count(*)
  FROM qa.results r GROUP BY r.grp ORDER BY r.grp;
$$ LANGUAGE sql;

-- Raises if any LIVE failure exists. Demos and gaps do not fail the run:
-- a gap is a finding to be decided, not a regression.
CREATE OR REPLACE FUNCTION qa_finish() RETURNS void AS $fn$
DECLARE v_fail INT; v_lint INT; v_gap INT; v_demo INT;
BEGIN
  SELECT count(*) FILTER (WHERE status IN ('FAIL','MISRESOLUTION') AND kind='live'),
         count(*) FILTER (WHERE status='GAP'),
         count(*) FILTER (WHERE kind='demo')
    INTO v_fail, v_gap, v_demo FROM qa.results;
  SELECT count(*) INTO v_lint FROM qa_lint();

  RAISE NOTICE '[%] pass=% live-failures=% gaps=% demos=% lint=%',
    qa._suite(),
    (SELECT count(*) FROM qa.results WHERE status='PASS'),
    v_fail, v_gap, v_demo, v_lint;

  IF v_fail > 0 THEN
    RAISE EXCEPTION '[%] % live failure(s)', qa._suite(), v_fail;
  END IF;
END $fn$ LANGUAGE plpgsql;
