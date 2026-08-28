-- =====================================================================
-- QA — citing the rulebook
-- =====================================================================
-- Two ways a rule gets cited, and they are modelled differently:
--
--   appeals.rule_id            a single nullable FK   -> 0..1 rule
--   post_rule_references       a junction table       -> 0..N rules
--
-- Same human act ("I am invoking rule G4"), two shapes. This suite maps
-- what each one guarantees, and where they disagree.
--
-- Thinnest domain in the project: 1 assertion in 99_tests touched rules.
--
--   psql -d qa_rules -f db/01_oltp_schema.sql
--   psql -d qa_rules -f db/qa_rule_references.sql
-- =====================================================================

\set ON_ERROR_STOP on
\ir _qa_harness.sql
SELECT qa.suite('rule_references');

-- ---------------------------------------------------------------------
-- Fixture. Rules are deliberately split by who cites them, so deletion
-- behaviour can be observed per path without one case masking another.
--   G4  cited by an appeal only
--   A21 cited by a forum post only
--   E2  cited by BOTH
--   S1  cited by nobody          (the deletion control)
--   G5, G6 spare, for the multi-citation case
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('rc@t','x','club'), ('rm@t','x','member');
INSERT INTO oltp.clubs(account_id,club_name)   SELECT account_id,'RC' FROM oltp.accounts WHERE email='rc@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,'RM' FROM oltp.accounts WHERE email='rm@t';
INSERT INTO oltp.teams(club_id,category_id,team_name,participation_code)
  SELECT c.account_id,tc.category_id,'RT','RT-1'
  FROM oltp.clubs c, oltp.team_categories tc WHERE tc.code='ROBOTICS';

INSERT INTO oltp.rule_sections(code,title) VALUES
  ('G','General'), ('A','Appeals'), ('E','Eligibility'), ('S','Scoring');

INSERT INTO oltp.rules(section_id,code,title,body,version_label)
SELECT s.section_id, v.code, v.title, v.body, 'v1.0'
FROM oltp.rule_sections s
JOIN (VALUES
  ('G','G4','Fair play','Teams shall compete honestly.'),
  ('G','G5','Conduct','Respect the officials.'),
  ('G','G6','Safety','Wear eye protection in the pit.'),
  ('A','A21','Filing an appeal','An appeal must be filed within 30 minutes.'),
  ('E','E2','Eligibility','Members must be registered before the season.'),
  ('S','S1','Scoring','Points are awarded per criterion.')
) AS v(sec,code,title,body) ON v.sec = s.code;

INSERT INTO oltp.forum_categories(code,label) VALUES ('RGEN','General');
INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
  SELECT fc.category_id,a.account_id,'Question about the rules','see below'
  FROM oltp.forum_categories fc, oltp.accounts a WHERE fc.code='RGEN' AND a.email='rm@t';

CREATE OR REPLACE FUNCTION qa.rule(p_code TEXT) RETURNS BIGINT AS $$
  SELECT rule_id FROM oltp.rules WHERE code = p_code;
$$ LANGUAGE sql STABLE;


-- =====================================================================
-- R — the catalogue itself
-- =====================================================================
DO $$
DECLARE v_g BIGINT; v_drift BIGINT;
BEGIN
  v_g := (SELECT section_id FROM oltp.rule_sections WHERE code='G');

  PERFORM qa_true('R','R1 code is the citable business key, and it resolves',
    'staff and users reference rules by code, not by surrogate id',
    qa.rule('G4') IS NOT NULL AND qa.rule('A21') IS NOT NULL,
    'G4 -> '||qa.rule('G4')||', A21 -> '||qa.rule('A21'));

  PERFORM qa_pair('R','R2 a duplicate rule code is refused',
    'uq_rules_code keeps the citation unambiguous across the whole rulebook',
    format('INSERT INTO oltp.rules(section_id,code,title,body) VALUES (%s,''G7'',''New'',''text'')', v_g),
    format('INSERT INTO oltp.rules(section_id,code,title,body) VALUES (%s,''G4'',''Clash'',''text'')', v_g));

  PERFORM qa_pre('R','R3 section 99 does not exist',
    NOT EXISTS (SELECT 1 FROM oltp.rule_sections WHERE section_id=99),
    'so the rejection below is about the FK and nothing else');
  PERFORM qa_reject('R','R3 a rule must belong to a real section',
    format('INSERT INTO oltp.rules(section_id,code,title,body) VALUES (99,''X1'',''Orphan'',''text'')'),
    '23503');

  -- The deliberate denormalisation, and what it now costs to keep honest.
  --
  -- Was R4-GAP: `code` duplicates the section prefix by design, because
  -- codes are how people actually cite rules -- but nothing enforced the
  -- agreement, so A99 could live under section G and a citation would
  -- resolve to a rule whose code implies a different chapter. A plain
  -- CHECK cannot express it: the section code lives in another table.
  -- R5 added enforce_rule_code_section() as a trigger, which can.
  PERFORM qa_pair('R','R4 a rule code cannot contradict its own section',
    'the denormalised prefix is checked against the section it sits under',
    format('INSERT INTO oltp.rules(section_id,code,title,body) VALUES (%s,''G98'',''General rule under General'',''text'')', v_g),
    format('INSERT INTO oltp.rules(section_id,code,title,body) VALUES (%s,''A99'',''Appeals rule under General'',''text'')', v_g));

  -- the mutation form: moving a rule between sections must be checked too,
  -- or the guard only holds until someone runs an UPDATE
  PERFORM qa_pre('R','R4 drift by UPDATE',
    EXISTS (SELECT 1 FROM oltp.rules WHERE code='G98'),
    'G98 exists (the control above inserted it) and currently agrees with its section');
  PERFORM qa_pair('R','R4 a rule cannot be moved under a contradicting section',
    'the agreement is re-checked on UPDATE, not only at insert time',
    'UPDATE oltp.rules SET title=''control: a non-lineage column'' WHERE code=''G98''',
    format('UPDATE oltp.rules SET section_id=%s WHERE code=''G98''',
           (SELECT section_id FROM oltp.rule_sections WHERE code='A')));
  DELETE FROM oltp.rules WHERE code IN ('G7','G98');
END $$;


-- =====================================================================
-- A — citing a rule when filing an appeal
-- =====================================================================
DO $$
DECLARE
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='RT-1');
  v_m BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='rm@t');
  v_a BIGINT; v_cited BIGINT; v_cols INT;
BEGIN
  -- A1 happy path
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason,rule_id)
    VALUES (v_t,v_m,'Scoring seems to breach G4', qa.rule('G4'))
    RETURNING appeal_id INTO v_a;
  SELECT rule_id INTO v_cited FROM oltp.appeals WHERE appeal_id=v_a;
  PERFORM qa_true('A','A1 an appeal carries the rule it invokes',
    'the citation must survive the write and resolve back to the rulebook',
    v_cited = qa.rule('G4'),
    (SELECT 'appeal '||v_a||' cites '||code||' ('||title||')' FROM oltp.rules WHERE rule_id=v_cited));

  -- A2 the citation is optional
  PERFORM qa_accept('A','A2 an appeal may cite no rule at all',
    format('INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (%s,%s,''no rule cited'')', v_t, v_m));

  -- A3 but a cited rule must exist
  PERFORM qa_pre('A','A3 rule 999999 does not exist',
    NOT EXISTS (SELECT 1 FROM oltp.rules WHERE rule_id=999999),
    'the rejection below is the FK, not a typo');
  PERFORM qa_reject('A','A3 an appeal cannot invoke a rule that does not exist',
    format('INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason,rule_id) VALUES (%s,%s,''ghost'',999999)', v_t, v_m),
    '23503');

  -- A4 cardinality: several rules per appeal
  --
  -- Was A4-GAP: appeals carried a single nullable FK, so citing "G4 and
  -- A21" was not expressible -- the filer had to pick one and put the rest
  -- in free-text `reason`, where nothing could query them. A forum post
  -- could already cite any number through post_rule_references, so the same
  -- human act was modelled two different ways depending on where it
  -- happened. R5 added appeal_rule_references, the mirror of the forum
  -- junction, and the two paths now agree.
  INSERT INTO oltp.appeal_rule_references(appeal_id,rule_id) VALUES
    (v_a, qa.rule('A21')), (v_a, qa.rule('E2'));
  SELECT count(*) INTO v_cols FROM oltp.appeal_rule_references WHERE appeal_id=v_a;
  PERFORM qa_true('A','A4 an appeal can invoke SEVERAL rules',
    'a real dispute often breaches more than one rule at once',
    v_cols = 2,
    (SELECT 'appeal '||v_a||' additionally cites '||string_agg(r.code,', ' ORDER BY r.code)
     FROM oltp.appeal_rule_references ar JOIN oltp.rules r ON r.rule_id=ar.rule_id
     WHERE ar.appeal_id=v_a));

  PERFORM qa_pre('A','A4 A21 is already cited by this appeal',
    EXISTS (SELECT 1 FROM oltp.appeal_rule_references WHERE appeal_id=v_a AND rule_id=qa.rule('A21')),
    'so the duplicate below has something to collide with');
  PERFORM qa_pair('A','A4 the same rule cannot be cited twice on one appeal',
    'the composite PK makes the (appeal, rule) pair itself the recorded fact -- same shape as the forum side',
    format('INSERT INTO oltp.appeal_rule_references(appeal_id,rule_id) VALUES (%s,%s)', v_a, qa.rule('G5')),
    format('INSERT INTO oltp.appeal_rule_references(appeal_id,rule_id) VALUES (%s,%s)', v_a, qa.rule('A21')));

  PERFORM qa_pre('A','A4 rule 999999 still does not exist',
    NOT EXISTS (SELECT 1 FROM oltp.rules WHERE rule_id=999999), 'FK, not a typo');
  PERFORM qa_reject('A','A4 an additional citation needs a real rule',
    format('INSERT INTO oltp.appeal_rule_references(appeal_id,rule_id) VALUES (%s,999999)', v_a),
    '23503');
END $$;


-- =====================================================================
-- F — citing rules from a forum post
-- =====================================================================
DO $$
DECLARE
  v_p BIGINT := (SELECT post_id FROM oltp.forum_posts LIMIT 1);
  v_n INT;
BEGIN
  -- F1 / F2 one post, several rules
  INSERT INTO oltp.post_rule_references(post_id,rule_id) VALUES
    (v_p, qa.rule('A21')), (v_p, qa.rule('E2')), (v_p, qa.rule('G5'));
  SELECT count(*) INTO v_n FROM oltp.post_rule_references WHERE post_id=v_p;
  PERFORM qa_true('F','F1 a post can cite SEVERAL rules',
    'the junction models the many-to-many the appeal path cannot',
    v_n = 3,
    (SELECT 'post '||v_p||' cites '||string_agg(r.code,', ' ORDER BY r.code)
     FROM oltp.post_rule_references pr JOIN oltp.rules r ON r.rule_id=pr.rule_id
     WHERE pr.post_id=v_p));

  -- F3 the same rule twice on one post
  PERFORM qa_pre('F','F3 A21 is already cited by this post',
    EXISTS (SELECT 1 FROM oltp.post_rule_references WHERE post_id=v_p AND rule_id=qa.rule('A21')),
    'so the duplicate below has something to collide with');
  PERFORM qa_pair('F','F3 the same rule cannot be cited twice on one post',
    'the composite PK makes the pair itself the recorded fact',
    format('INSERT INTO oltp.post_rule_references(post_id,rule_id) VALUES (%s,%s)', v_p, qa.rule('G6')),
    format('INSERT INTO oltp.post_rule_references(post_id,rule_id) VALUES (%s,%s)', v_p, qa.rule('A21')));

  -- F4 both ends must exist
  PERFORM qa_pre('F','F4 post 999999 does not exist',
    NOT EXISTS (SELECT 1 FROM oltp.forum_posts WHERE post_id=999999), 'FK, not a typo');
  PERFORM qa_reject('F','F4 a citation needs a real post',
    format('INSERT INTO oltp.post_rule_references(post_id,rule_id) VALUES (999999,%s)', qa.rule('G4')),
    '23503');
  PERFORM qa_reject('F','F4 a citation needs a real rule',
    format('INSERT INTO oltp.post_rule_references(post_id,rule_id) VALUES (%s,999999)', v_p),
    '23503');
END $$;


-- =====================================================================
-- X — where the two paths disagree
-- =====================================================================
DO $$
DECLARE
  v_p BIGINT := (SELECT post_id FROM oltp.forum_posts LIMIT 1);
  v_before INT; v_after INT; v_state TEXT;
  v_body_then TEXT; v_body_now TEXT; v_a BIGINT;
BEGIN
  -- ---- X1 deleting an UNCITED rule: the control ------------------------
  PERFORM qa_pre('X','X1 S1 is cited by nobody',
    NOT EXISTS (SELECT 1 FROM oltp.appeals WHERE rule_id=qa.rule('S1'))
    AND NOT EXISTS (SELECT 1 FROM oltp.post_rule_references WHERE rule_id=qa.rule('S1')),
    'the control: an unreferenced rule must be deletable, or the blocks below prove nothing');
  PERFORM qa_accept('X','X1 an uncited rule can be deleted',
    format('DELETE FROM oltp.rules WHERE rule_id=%s', qa.rule('S1')));

  -- ---- X2 deleting a rule cited by an APPEAL: blocked ------------------
  PERFORM qa_pre('X','X2 G4 is cited by an appeal',
    EXISTS (SELECT 1 FROM oltp.appeals WHERE rule_id=qa.rule('G4')),
    'and by no forum post, so only the appeal path is under test');
  PERFORM qa_reject('X','X2 a rule cited by an appeal cannot be deleted',
    format('DELETE FROM oltp.rules WHERE rule_id=%s', qa.rule('G4')),
    '23503');

  -- ---- X3 deleting a rule cited by a POST: now blocked too --------------
  --
  -- Was X3-GAP: post_rule_references.rule_id carried ON DELETE CASCADE, so
  -- removing a rule SILENTLY deleted every forum citation of it -- the post
  -- kept text referring to a rule the reader could no longer follow --
  -- while appeals.rule_id refused the identical DELETE. One act, two
  -- behaviours, neither recorded as a decision. R5 dropped the CASCADE, so
  -- both paths now refuse, and withdrawing a rule is done with retired_at.
  SELECT count(*) INTO v_before FROM oltp.post_rule_references WHERE post_id=v_p;
  PERFORM qa_pre('X','X3 A21 is cited by a post and by no appeal',
    EXISTS (SELECT 1 FROM oltp.post_rule_references WHERE rule_id=qa.rule('A21'))
    AND NOT EXISTS (SELECT 1 FROM oltp.appeals WHERE rule_id=qa.rule('A21')),
    'so only the forum path decides what happens');

  -- The control is a rule nothing cites, which is exactly X1's case: if
  -- DELETE were broken outright the control would fail and the rejection
  -- below would prove nothing about citations.
  PERFORM qa_pair('X','X3 a rule cited by a post cannot be deleted either',
    'the forum path and the appeal path answer the same act the same way',
    format('INSERT INTO oltp.rules(section_id,code,title,body) VALUES (%s,''S9'',''Uncited'',''text''); '
           ||'DELETE FROM oltp.rules WHERE code=''S9''',
           (SELECT section_id FROM oltp.rule_sections WHERE code='S')),
    format('DELETE FROM oltp.rules WHERE rule_id=%s', qa.rule('A21')));

  SELECT count(*) INTO v_after FROM oltp.post_rule_references WHERE post_id=v_p;
  PERFORM qa_true('X','X3 the refused delete left every citation standing',
    'counting the outcome, not just the exception -- a silent cascade would show up here',
    v_after = v_before,
    format('the post held %s citations before and %s after', v_before, v_after));

  PERFORM qa_true('X','X3 withdrawing a rule is expressed by retired_at, not by DELETE',
    'the rulebook keeps its history: a retired rule stays citable in the past and refuses new citations',
    (SELECT count(*) FROM information_schema.columns
      WHERE table_schema='oltp' AND table_name='rules' AND column_name='retired_at') = 1,
    'rules.retired_at exists, so withdrawal no longer needs a destructive DELETE');

  -- ---- X4 citation drift: the rule text moves under the citation -------
  SELECT body INTO v_body_then FROM oltp.rules WHERE rule_id = qa.rule('E2');
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason,rule_id)
    SELECT t.team_id, a.account_id, 'filed under E2 as written today', qa.rule('E2')
    FROM oltp.teams t, oltp.accounts a WHERE a.email='rm@t'
    RETURNING appeal_id INTO v_a;

  UPDATE oltp.rules
     SET body = 'REWRITTEN: members may register at any time.',
         version_label = 'v2.0', updated_at = now()
   WHERE rule_id = qa.rule('E2');
  SELECT body INTO v_body_now FROM oltp.rules WHERE rule_id = qa.rule('E2');

  PERFORM qa_true('X','X4 the citation still resolves after the rule is rewritten',
    'the control: the link is intact, so the finding below is about CONTENT, not a broken FK',
    (SELECT rule_id FROM oltp.appeals WHERE appeal_id=v_a) = qa.rule('E2'),
    'appeal '||v_a||' still points at E2');

  -- Was X4-GAP, and the sharpest of the four: the appeal cited text that
  -- did not exist when it was filed, and nothing recorded which wording had
  -- been invoked -- a dispute could be decided against wording the filer
  -- never saw. R5 made every rule write append a rule_revisions row, and
  -- pin_cited_revision() stamps the citation with the revision current at
  -- filing time. The rule text still moves; the citation no longer does.
  PERFORM qa_true('X','X4 the rule text really did change under the citation',
    'the fixture must actually drift, or the pinning assertion below is vacuous',
    v_body_now IS DISTINCT FROM v_body_then,
    format('body at filing: "%s" | body now: "%s"', left(v_body_then,45), left(v_body_now,45)));

  PERFORM qa_true('X','X4 the appeal pinned the revision it was filed under',
    'a citation records the wording invoked, not just which rule',
    (SELECT cited_revision_id FROM oltp.appeals WHERE appeal_id=v_a) IS NOT NULL,
    format('appeal %s carries cited_revision_id %s', v_a,
      (SELECT cited_revision_id FROM oltp.appeals WHERE appeal_id=v_a)));

  PERFORM qa_true('X','X4 the pinned revision still holds the ORIGINAL wording',
    'this is the whole point: the filer''s text is recoverable after the rewrite',
    (SELECT rv.body FROM oltp.appeals ap JOIN oltp.rule_revisions rv
        ON rv.revision_id = ap.cited_revision_id WHERE ap.appeal_id=v_a) = v_body_then,
    format('pinned body: "%s"',
      left((SELECT rv.body FROM oltp.appeals ap JOIN oltp.rule_revisions rv
              ON rv.revision_id = ap.cited_revision_id WHERE ap.appeal_id=v_a), 45)));

  PERFORM qa_true('X','X4 the rewrite was recorded as a new revision',
    'the rulebook keeps a history, so both wordings remain addressable',
    (SELECT count(*) FROM oltp.rule_revisions WHERE rule_id=qa.rule('E2')) >= 2,
    format('E2 has %s revision(s): %s',
      (SELECT count(*) FROM oltp.rule_revisions WHERE rule_id=qa.rule('E2')),
      (SELECT string_agg(coalesce(version_label,'(none)'), ' -> ' ORDER BY revision_id)
         FROM oltp.rule_revisions WHERE rule_id=qa.rule('E2'))));
END $$;


-- =====================================================================
-- Y — retirement and revision history, at depth
-- =====================================================================
-- X3 asserted only that rules.retired_at EXISTS. Nothing in this suite
-- ever SET it, so refuse_retired_rule_citation() had never run: the
-- column was documented, the trigger was shipped, and the behaviour was
-- unverified. That is the exact shape of a guard that looks covered
-- because the thing it guards is mentioned nearby.
-- =====================================================================
DO $$
DECLARE
  v_t BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='RT-1');
  v_m BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='rm@t');
  v_p BIGINT := (SELECT post_id FROM oltp.forum_posts LIMIT 1);
  v_g BIGINT := (SELECT section_id FROM oltp.rule_sections WHERE code='G');
  v_dead BIGINT; v_live BIGINT; v_ap BIGINT; v_before INT; v_after INT;
BEGIN
  INSERT INTO oltp.rules(section_id,code,title,body) VALUES (v_g,'G80','To be retired','text')
    RETURNING rule_id INTO v_dead;
  INSERT INTO oltp.rules(section_id,code,title,body) VALUES (v_g,'G81','Stays current','text')
    RETURNING rule_id INTO v_live;

  -- an appeal filed while the rule was still current: it must SURVIVE the
  -- retirement, because outliving a withdrawn rule is the entire reason
  -- retirement exists instead of DELETE (see X3)
  INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason,rule_id)
    VALUES (v_t,v_m,'filed while G80 was current',v_dead) RETURNING appeal_id INTO v_ap;

  UPDATE oltp.rules SET retired_at = now() WHERE rule_id = v_dead;
  PERFORM qa_pre('Y','Y1 G80 is retired and G81 is not',
    (SELECT retired_at FROM oltp.rules WHERE rule_id=v_dead) IS NOT NULL
    AND (SELECT retired_at FROM oltp.rules WHERE rule_id=v_live) IS NULL,
    'the two rules differ in exactly one column, which is what the pairs below rest on');

  -- the trigger sits on THREE tables. Testing one and assuming the others
  -- would repeat the C2/X3 mistake: a rule enforced on one path and not
  -- another is worse than one enforced nowhere, because it reads as safe.
  PERFORM qa_pair('Y','Y1 a retired rule cannot be cited by a new appeal',
    'appeals.rule_id -- trg_appeals_no_retired_rule',
    format('INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason,rule_id) VALUES (%s,%s,''cites a current rule'',%s)', v_t, v_m, v_live),
    format('INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason,rule_id) VALUES (%s,%s,''cites a retired rule'',%s)', v_t, v_m, v_dead));

  PERFORM qa_pair('Y','Y1 nor by a new forum-post citation',
    'post_rule_references -- trg_post_rule_references_no_retired_rule',
    format('INSERT INTO oltp.post_rule_references(post_id,rule_id) VALUES (%s,%s)', v_p, v_live),
    format('INSERT INTO oltp.post_rule_references(post_id,rule_id) VALUES (%s,%s)', v_p, v_dead));

  PERFORM qa_pair('Y','Y1 nor by an additional citation on an appeal',
    'appeal_rule_references -- trg_appeal_rule_references_no_retired_rule',
    format('INSERT INTO oltp.appeal_rule_references(appeal_id,rule_id) VALUES (%s,%s)', v_ap, v_live),
    format('INSERT INTO oltp.appeal_rule_references(appeal_id,rule_id) VALUES (%s,%s)', v_ap, v_dead));

  -- Y2 the point of retiring rather than deleting
  PERFORM qa_true('Y','Y2 a citation made BEFORE retirement still resolves',
    'a dispute filed under a rule that was later withdrawn must remain readable',
    (SELECT rule_id FROM oltp.appeals WHERE appeal_id=v_ap) = v_dead
    AND (SELECT code FROM oltp.rules WHERE rule_id=v_dead) = 'G80',
    format('appeal %s still cites G80, and G80 is still in the rulebook with retired_at set', v_ap));

  PERFORM qa_true('Y','Y2 the retired rule kept its pinned revision too',
    'retirement must not orphan the wording the filer actually argued from',
    (SELECT rv.body FROM oltp.appeals ap JOIN oltp.rule_revisions rv
        ON rv.revision_id = ap.cited_revision_id WHERE ap.appeal_id=v_ap) IS NOT NULL,
    'the pinned revision survives the retirement of its rule');

  -- Y3 un-retiring is how a withdrawal is reversed
  UPDATE oltp.rules SET retired_at = NULL WHERE rule_id = v_dead;
  PERFORM qa_accept('Y','Y3 clearing retired_at makes the rule citable again',
    format('INSERT INTO oltp.post_rule_references(post_id,rule_id) VALUES (%s,%s)', v_p, v_dead));
END $$;

DO $$
DECLARE
  v_g BIGINT := (SELECT section_id FROM oltp.rule_sections WHERE code='G');
  v_r BIGINT; v_before INT; v_after INT;
BEGIN
  -- Y4 record_rule_revision fires on content, not on every write. If it
  -- appended a row for any UPDATE, ordinary housekeeping -- touching
  -- updated_at, setting retired_at -- would bury the real revisions in
  -- noise and make the history useless for the thing X4 needs it for.
  INSERT INTO oltp.rules(section_id,code,title,body,version_label)
    VALUES (v_g,'G82','Revision counting','original body','v1.0') RETURNING rule_id INTO v_r;

  PERFORM qa_true('Y','Y4 creating a rule records its first revision',
    'the history must start at creation, or the original wording is unrecoverable',
    (SELECT count(*) FROM oltp.rule_revisions WHERE rule_id=v_r) = 1,
    'G82 has 1 revision immediately after INSERT');

  SELECT count(*) INTO v_before FROM oltp.rule_revisions WHERE rule_id=v_r;
  UPDATE oltp.rules SET updated_at = now() WHERE rule_id=v_r;
  UPDATE oltp.rules SET retired_at = now() WHERE rule_id=v_r;
  UPDATE oltp.rules SET retired_at = NULL WHERE rule_id=v_r;
  UPDATE oltp.rules SET body = 'original body' WHERE rule_id=v_r;   -- same value
  SELECT count(*) INTO v_after FROM oltp.rule_revisions WHERE rule_id=v_r;

  PERFORM qa_true('Y','Y4 writes that change no wording record no revision',
    'four UPDATEs that touch timestamps or rewrite a column with its own value',
    v_after = v_before,
    format('revisions stayed at %s across 4 non-content UPDATEs', v_after));

  -- the control: the counter is not simply stuck
  UPDATE oltp.rules SET body = 'genuinely different body' WHERE rule_id=v_r;
  SELECT count(*) INTO v_after FROM oltp.rule_revisions WHERE rule_id=v_r;
  PERFORM qa_true('Y','Y4 a real change DOES record a revision',
    'without this control, Y4 above would pass just as well if the trigger never fired at all',
    v_after = v_before + 1,
    format('revisions %s -> %s on a genuine rewrite', v_before, v_after));

  PERFORM qa_true('Y','Y4 each revision holds the wording of its own moment',
    'a history that stores the current text in every row records nothing',
    (SELECT count(DISTINCT body) FROM oltp.rule_revisions WHERE rule_id=v_r) = 2,
    (SELECT string_agg(left(body,24),' | ' ORDER BY revision_id)
       FROM oltp.rule_revisions WHERE rule_id=v_r));
END $$;


-- =====================================================================
-- Report
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
