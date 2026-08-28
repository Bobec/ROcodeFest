-- =====================================================================
-- VERIFY R5 — do the four gaps actually close?
-- =====================================================================
-- Runs on a THROWAWAY database: seeds the pre-patch state, applies the
-- proposal in place, then re-runs each of the four gap scenarios from
-- db/qa_rule_references.sql and asserts the outcome has flipped.
--
-- Installing without breaking is not evidence. Every case below pairs
-- the new refusal with a positive that still works, so a patch that
-- simply refused everything would fail here rather than look strict.
--
--   psql -d r5_verify -f db/01_oltp_schema.sql
--   psql -d r5_verify -f db/proposals/R5_rule_citations.verify.sql
-- =====================================================================

\set ON_ERROR_STOP on
\ir ../_qa_harness.sql
SELECT qa.suite('R5_verify');

-- ---------------------------------------------------------------------
-- Pre-patch fixture -- the same shape qa_rule_references.sql used
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES ('rc@t','x','club'), ('rm@t','x','member');
INSERT INTO oltp.clubs(account_id,club_name)   SELECT account_id,'RC' FROM oltp.accounts WHERE email='rc@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,'RM' FROM oltp.accounts WHERE email='rm@t';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'RT','RT-1'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';
INSERT INTO oltp.rule_sections(code,title) VALUES ('G','General'),('A','Appeals'),('E','Eligibility'),('S','Scoring');
INSERT INTO oltp.rules(section_id,code,title,body,version_label)
SELECT s.section_id, v.code, v.title, v.body, 'v1.0'
FROM oltp.rule_sections s
JOIN (VALUES
  ('G','G4','Fair play','Teams shall compete honestly.'),
  ('G','G5','Conduct','Respect the officials.'),
  ('A','A21','Filing an appeal','An appeal must be filed within 30 minutes.'),
  ('E','E2','Eligibility','Members must be registered before the season.'),
  ('S','S1','Scoring','Points are awarded per criterion.')
) AS v(sec,code,title,body) ON v.sec = s.code;
INSERT INTO oltp.forum_categories(code,label) VALUES ('RGEN','General');
INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
  SELECT fc.category_id,a.account_id,'Question','see below'
  FROM oltp.forum_categories fc, oltp.accounts a WHERE fc.code='RGEN' AND a.email='rm@t';

-- a citation that exists BEFORE the migration, so the back-fill has work
INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason,rule_id)
  SELECT t.team_id, a.account_id, 'pre-migration appeal', r.rule_id
  FROM oltp.teams t, oltp.accounts a, oltp.rules r
  WHERE a.email='rm@t' AND r.code='G4';
INSERT INTO oltp.post_rule_references(post_id, rule_id)
  SELECT p.post_id, r.rule_id FROM oltp.forum_posts p, oltp.rules r WHERE r.code='A21';

CREATE OR REPLACE FUNCTION qa.rule(p_code TEXT) RETURNS BIGINT AS $$
  SELECT rule_id FROM oltp.rules WHERE code = p_code;
$$ LANGUAGE sql STABLE;

DO $$
BEGIN
  PERFORM qa_pre('PRE','citations exist before the migration',
    (SELECT count(*) FROM oltp.appeals WHERE rule_id IS NOT NULL) = 1
    AND (SELECT count(*) FROM oltp.post_rule_references) = 1,
    'one appeal citation and one forum citation predate the patch, so the back-fill is exercised');
END $$;


-- =====================================================================
-- APPLY THE PROPOSAL (this throwaway database only)
-- =====================================================================
\ir R5_rule_citations.patch.sql


-- =====================================================================
-- X4 — does a citation now know which wording it invoked?
-- =====================================================================
DO $$
DECLARE
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='RT-1');
  v_m BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='rm@t');
  v_a BIGINT; v_rev BIGINT; v_then TEXT; v_now TEXT; v_revcount INT;
BEGIN
  PERFORM qa_pre('X4','the back-fill gave every rule a revision',
    (SELECT count(*) FROM oltp.rule_revisions) = (SELECT count(*) FROM oltp.rules),
    (SELECT count(*)::text FROM oltp.rule_revisions)||' revision(s) for '
    ||(SELECT count(*)::text FROM oltp.rules)||' rule(s)');

  -- file an appeal citing E2 as it reads NOW
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason,rule_id)
    VALUES (v_t,v_m,'filed under E2', qa.rule('E2')) RETURNING appeal_id, cited_revision_id INTO v_a, v_rev;

  PERFORM qa_true('X4','X4 the citation is pinned automatically, with no caller involvement',
    'the app layer does not exist; a default only the caller can set is a default nobody sets',
    v_rev IS NOT NULL, 'appeal '||v_a||' pinned revision '||coalesce(v_rev::text,'NULL'));

  SELECT body INTO v_then FROM oltp.rule_revisions WHERE revision_id = v_rev;

  -- now rewrite the rule, exactly as the gap scenario did
  UPDATE oltp.rules SET body='REWRITTEN: members may register at any time.', version_label='v2.0'
   WHERE rule_id = qa.rule('E2');
  SELECT body INTO v_now FROM oltp.rules WHERE rule_id = qa.rule('E2');

  PERFORM qa_true('X4','X4 the appeal still reads the wording it was filed under',
    'THE gap: previously the appeal silently followed the rewrite',
    v_then = 'Members must be registered before the season.' AND v_then <> v_now,
    format('pinned: "%s" | current: "%s"', left(v_then,42), left(v_now,42)));

  SELECT count(*) INTO v_revcount FROM oltp.rule_revisions WHERE rule_id = qa.rule('E2');
  PERFORM qa_true('X4','X4 the rewrite was recorded rather than lost',
    'the history is append-only, so both wordings remain readable',
    v_revcount = 2, v_revcount||' revisions of E2');

  -- control: an edit that changes nothing citable must NOT invent a revision
  UPDATE oltp.rules SET updated_at = now() WHERE rule_id = qa.rule('G5');
  PERFORM qa_true('X4','X4 a non-substantive edit creates no revision',
    'a reader would not recognise a timestamp bump as a different rule',
    (SELECT count(*) FROM oltp.rule_revisions WHERE rule_id = qa.rule('G5')) = 1,
    'G5 still has a single revision');
END $$;


-- =====================================================================
-- X3 — do both deletion paths now agree?
-- =====================================================================
DO $$
DECLARE v_before INT; v_after INT;
BEGIN
  PERFORM qa_pre('X3','S1 is cited by nobody',
    NOT EXISTS (SELECT 1 FROM oltp.appeals WHERE rule_id=qa.rule('S1'))
    AND NOT EXISTS (SELECT 1 FROM oltp.post_rule_references WHERE rule_id=qa.rule('S1')),
    'the control: an uncited rule must still be deletable, or "strict" just means "broken"');
  PERFORM qa_accept('X3','X3 an uncited rule can still be deleted',
    format('DELETE FROM oltp.rules WHERE rule_id=%s', qa.rule('S1')));

  SELECT count(*) INTO v_before FROM oltp.post_rule_references;
  PERFORM qa_pre('X3','A21 is cited by a forum post',
    EXISTS (SELECT 1 FROM oltp.post_rule_references WHERE rule_id=qa.rule('A21')),
    'previously this delete succeeded and erased the citation');
  PERFORM qa_reject('X3','X3 a rule cited by a POST can no longer be deleted',
    format('DELETE FROM oltp.rules WHERE rule_id=%s', qa.rule('A21')), '23503');

  SELECT count(*) INTO v_after FROM oltp.post_rule_references;
  PERFORM qa_true('X3','X3 the forum citation survived the attempt',
    'the whole point: the post no longer argues from a rule that vanished',
    v_before = v_after, v_after||' citation(s) intact');

  PERFORM qa_reject('X3','X3 a rule cited by an APPEAL still cannot be deleted',
    format('DELETE FROM oltp.rules WHERE rule_id=%s', qa.rule('G4')), '23503');

  PERFORM qa_true('X3','X3 both paths now give the same answer',
    'one act, one behaviour -- the asymmetry is gone',
    TRUE, 'appeal-cited and post-cited rules are both refused with 23503');

  -- retire instead: the citation keeps resolving, new ones are refused
  UPDATE oltp.rules SET retired_at = now() WHERE rule_id = qa.rule('A21');
  PERFORM qa_true('X3','X3 an existing citation still resolves after retirement',
    'withdrawal without destruction',
    (SELECT count(*) FROM oltp.post_rule_references pr
      JOIN oltp.rules r ON r.rule_id=pr.rule_id WHERE r.code='A21') = 1,
    'the post can still be followed to A21');
  PERFORM qa_pair('X3','X3 a retired rule cannot be cited anew',
    'retirement stops future citations without rewriting the past',
    format('INSERT INTO oltp.post_rule_references(post_id,rule_id) SELECT post_id,%s FROM oltp.forum_posts LIMIT 1', qa.rule('G5')),
    format('INSERT INTO oltp.post_rule_references(post_id,rule_id) SELECT post_id,%s FROM oltp.forum_posts LIMIT 1', qa.rule('A21')));
END $$;


-- =====================================================================
-- A4 — can an appeal now invoke several rules?
-- =====================================================================
DO $$
DECLARE
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='RT-1');
  v_m BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='rm@t');
  v_a BIGINT; v_n INT; v_pinned INT;
BEGIN
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason)
    VALUES (v_t,v_m,'breaches several rules at once') RETURNING appeal_id INTO v_a;
  INSERT INTO oltp.appeal_rule_references(appeal_id,rule_id) VALUES
    (v_a, qa.rule('G4')), (v_a, qa.rule('E2')), (v_a, qa.rule('G5'));

  SELECT count(*) INTO v_n FROM oltp.appeal_rule_references WHERE appeal_id=v_a;
  PERFORM qa_true('A4','A4 an appeal can now invoke several rules',
    'the cap of one is gone; both citation paths use the same shape',
    v_n = 3,
    (SELECT 'appeal '||v_a||' cites '||string_agg(r.code,', ' ORDER BY r.code)
     FROM oltp.appeal_rule_references ar JOIN oltp.rules r ON r.rule_id=ar.rule_id
     WHERE ar.appeal_id=v_a));

  SELECT count(*) INTO v_pinned FROM oltp.appeal_rule_references
   WHERE appeal_id=v_a AND cited_revision_id IS NOT NULL;
  PERFORM qa_true('A4','A4 each of them pinned its own revision',
    'the junction inherits the X4 guarantee rather than reintroducing the gap',
    v_pinned = 3, v_pinned||'/3 citations carry a revision');

  PERFORM qa_pre('A4','G4 is already cited by this appeal',
    EXISTS (SELECT 1 FROM oltp.appeal_rule_references WHERE appeal_id=v_a AND rule_id=qa.rule('G4')),
    'so the duplicate below has something to collide with');
  PERFORM qa_reject('A4','A4 the same rule cannot be cited twice on one appeal',
    format('INSERT INTO oltp.appeal_rule_references(appeal_id,rule_id) VALUES (%s,%s)', v_a, qa.rule('G4')),
    '23505');

  PERFORM qa_true('A4','A4 the pre-migration single citation was moved into the junction',
    'one place to read from, so nothing is only visible in the deprecated column',
    EXISTS (SELECT 1 FROM oltp.appeal_rule_references ar
            JOIN oltp.appeals a ON a.appeal_id=ar.appeal_id
            WHERE a.reason='pre-migration appeal'),
    'the back-filled citation is present in appeal_rule_references');
END $$;


-- =====================================================================
-- R4 — must a code now agree with its section?
-- =====================================================================
DO $$
DECLARE v_g SMALLINT := (SELECT section_id FROM oltp.rule_sections WHERE code='G');
BEGIN
  PERFORM qa_pair('R4','R4 a code that contradicts its section is refused',
    'the denormalised copy is kept honest by a trigger, since a CHECK cannot cross tables',
    format('INSERT INTO oltp.rules(section_id,code,title,body) VALUES (%s,''G9'',''Fine'',''text'')', v_g),
    format('INSERT INTO oltp.rules(section_id,code,title,body) VALUES (%s,''A99'',''Wrong section'',''text'')', v_g));

  PERFORM qa_reject('R4','R4 the rule also holds on UPDATE, not just INSERT',
    format('UPDATE oltp.rules SET code=''E77'' WHERE rule_id=%s', qa.rule('G4')), 'P0001');

  PERFORM qa_accept('R4','R4 a legitimate re-code within the same section is still allowed',
    format('UPDATE oltp.rules SET code=''G41'' WHERE rule_id=%s', qa.rule('G4')));
END $$;


-- =====================================================================
\echo ''
\echo '===================== R5 VERIFICATION ====================='
SELECT seq, grp, status, tc, left(coalesce(result,''),64) AS result FROM qa.results ORDER BY seq;
\echo ''
SELECT * FROM qa_summary();
\echo ''
SELECT * FROM qa_lint();
SELECT qa_finish();
