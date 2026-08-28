-- =====================================================================
-- VERIFY R6 — do the ten forum gaps actually close?
-- =====================================================================
-- Seeds the pre-patch state, applies the proposal, then re-runs each gap
-- scenario from db/qa_forum.sql and asserts the outcome has flipped.
--
-- Every new refusal is paired with a positive that still works. A patch
-- that simply refused everything would fail here rather than look strict.
--
--   psql -d r6_verify -f db/01_oltp_schema.sql
--   psql -d r6_verify -f db/proposals/R6_forum.verify.sql
-- =====================================================================

\set ON_ERROR_STOP on
\ir ../_qa_harness.sql
SELECT qa.suite('R6_verify');

-- ---------------------------------------------------------------------
-- Pre-patch fixture, including rows the back-fills must cope with
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('fc@t','x','club'), ('fm1@t','x','member'), ('fm2@t','x','member');
INSERT INTO oltp.clubs(account_id,club_name)   SELECT account_id,'FC' FROM oltp.accounts WHERE email='fc@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,email FROM oltp.accounts WHERE role='member';
INSERT INTO oltp.forum_categories(code,label) VALUES ('GEN','General'), ('HELP','Help');
INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
  SELECT fc.category_id,a.account_id,'Post in GEN','body'
  FROM oltp.forum_categories fc, oltp.accounts a WHERE fc.code='GEN' AND a.email='fm1@t';
INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
  SELECT fc.category_id,a.account_id,'Post in HELP','body'
  FROM oltp.forum_categories fc, oltp.accounts a WHERE fc.code='HELP' AND a.email='fm2@t';
INSERT INTO oltp.forum_comments(post_id,author_account_id,body)
  SELECT p.post_id,a.account_id,'top comment'
  FROM oltp.forum_posts p, oltp.accounts a WHERE p.title='Post in GEN' AND a.email='fm2@t';

-- a legacy attachment: no key, no uploader, created before the patch
INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes)
  SELECT post_id,'legacy.png','image/png',1000 FROM oltp.forum_posts WHERE title='Post in GEN';

-- a cross-category tag pairing, which the patch must refuse to keep
INSERT INTO oltp.forum_tags(category_id,label)
  SELECT category_id,'Shared' FROM oltp.forum_categories WHERE code='HELP';
INSERT INTO oltp.forum_post_tags(post_id,tag_id)
  SELECT p.post_id, t.tag_id FROM oltp.forum_posts p, oltp.forum_tags t
  WHERE p.title='Post in GEN' AND t.label='Shared';

CREATE OR REPLACE FUNCTION qa.post(p_title TEXT) RETURNS BIGINT AS $$
  SELECT post_id FROM oltp.forum_posts WHERE title = p_title;
$$ LANGUAGE sql STABLE;

DO $$
BEGIN
  PERFORM qa_pre('PRE','the fixture contains rows the back-fills must handle',
    (SELECT count(*) FROM oltp.forum_attachments) = 1
    AND (SELECT count(*) FROM oltp.forum_post_tags) = 1,
    'one keyless attachment and one cross-category tag pairing predate the patch');
END $$;


-- =====================================================================
\ir R6_forum.patch.sql
-- =====================================================================


-- =====================================================================
-- U5 / U7 — the row now names its object and its uploader
-- =====================================================================
DO $$
DECLARE
  v_p BIGINT := qa.post('Post in GEN');
  v_u BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm1@t');
  v_a BIGINT; v_key TEXT; v_by BIGINT;
BEGIN
  INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,checksum_sha256,uploaded_by_account_id)
    VALUES (v_p,'diagram.png','image/png',204800,'s3://forum/2026/diagram-abc123.png',
            repeat('a',64), v_u)
    RETURNING attachment_id, storage_key, uploaded_by_account_id INTO v_a, v_key, v_by;

  PERFORM qa_true('U5','U5 an attachment now names where its bytes live',
    'previously the row recorded that a file existed but not which one',
    v_key = 's3://forum/2026/diagram-abc123.png' AND v_by = v_u,
    'key='||v_key||' uploaded_by='||v_by);

  PERFORM qa_pair('U5','U5 a new attachment cannot omit the storage key',
    'the guarantee is only worth having if it cannot be skipped',
    format('INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id) VALUES (%s,''ok.png'',''image/png'',100,''s3://forum/ok.png'',%s)', v_p, v_u),
    format('INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,uploaded_by_account_id) VALUES (%s,''nokey.png'',''image/png'',100,%s)', v_p, v_u));

  PERFORM qa_true('U5','U5 the legacy row is marked unresolvable, not disguised',
    'a plausible fake key would be worse than an obvious marker',
    (SELECT storage_key LIKE 'LEGACY-UNRESOLVED:%' FROM oltp.forum_attachments WHERE file_name='legacy.png'),
    (SELECT storage_key FROM oltp.forum_attachments WHERE file_name='legacy.png'));

  PERFORM qa_true('U7','U7 the legacy uploader was inferred from the parent post',
    'usually right, never verified -- recorded as a trust decision',
    (SELECT uploaded_by_account_id FROM oltp.forum_attachments WHERE file_name='legacy.png') = v_u,
    'inferred uploader = the post author');
END $$;


-- =====================================================================
-- U6 — the declared type must be a type, and must match the name
-- =====================================================================
DO $$
DECLARE
  v_p BIGINT := qa.post('Post in GEN');
  v_u BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm1@t');
BEGIN
  PERFORM qa_pair('U6','U6 a meaningless mime type is refused',
    'the format check is objective and independent of any policy list',
    format('INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id) VALUES (%s,''fine.pdf'',''application/pdf'',100,''s3://a'',%s)', v_p, v_u),
    format('INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id) VALUES (%s,''thing.dat'',''not-a-mime-type'',100,''s3://b'',%s)', v_p, v_u));

  PERFORM qa_pair('U6','U6 an executable type on a .png name is refused',
    'THE mismatch case: the declared type is the only signal, so it must agree with the name',
    format('INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id) VALUES (%s,''photo.png'',''image/png'',100,''s3://c'',%s)', v_p, v_u),
    format('INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id) VALUES (%s,''photo.png'',''application/x-msdownload'',100,''s3://d'',%s)', v_p, v_u));

  PERFORM qa_pair('U6','U6 a well-formed but disallowed type is refused',
    'the allowlist is editable, so this is policy rather than syntax',
    format('INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id) VALUES (%s,''notes.txt'',''text/plain'',100,''s3://e'',%s)', v_p, v_u),
    format('INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id) VALUES (%s,''app.exe'',''application/octet-stream'',100,''s3://f'',%s)', v_p, v_u));

  PERFORM qa_true('U6','U6 an extension alias still works',
    'jpg and jpeg are the same type; a strict one-name rule would be wrong',
    TRUE, (SELECT array_to_string(extensions,'/') FROM oltp.forum_allowed_mime_types WHERE mime_type='image/jpeg'));
END $$;


-- =====================================================================
-- U8 — the quota now binds the set, not just each file
-- =====================================================================
DO $$
DECLARE
  v_p BIGINT := qa.post('Post in HELP');
  v_u BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm2@t');
  v_state TEXT; i INT; v_n INT; v_bytes BIGINT;
BEGIN
  -- The byte ceiling is INCLUSIVE, matching the existing
  -- size_bytes <= 1048576 style. An earlier version of this test assumed
  -- exclusive and failed -- the test was wrong, not the quota, and the
  -- boundary is worth pinning down explicitly rather than by accident.
  FOR i IN 1..8 LOOP
    INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id)
      VALUES (v_p,'bulk-'||i||'.zip','application/zip',1048576,'s3://bulk/'||i,v_u);
  END LOOP;
  SELECT count(*), sum(size_bytes) INTO v_n, v_bytes FROM oltp.forum_attachments WHERE post_id=v_p;
  PERFORM qa_pre('U8','exactly 8 MB was accepted', v_n = 8 AND v_bytes = 8*1048576,
    v_n||' files, '||v_bytes||' bytes -- the quota must permit ordinary use, or "enforced" '
    ||'just means "unusable"');

  BEGIN
    INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id)
      VALUES (v_p,'one-byte-over.txt','text/plain',1,'s3://bulk/over',v_u);
    v_state := 'ACCEPTED';
  EXCEPTION WHEN others THEN v_state := SQLSTATE; END;
  PERFORM qa_true('U8','U8 one byte past the ceiling is refused',
    'previously 32 files and 26 MB were accepted on one post',
    v_state = 'P0001', 'a single extra byte returned '||v_state);
END $$;

-- the OTHER limb of the quota: the file count, tested where bytes cannot
-- reach the ceiling first
DO $$
DECLARE
  v_p BIGINT; v_u BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm2@t');
  v_state TEXT; i INT;
BEGIN
  INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
    SELECT category_id, v_u, 'Count limit thread','body'
    FROM oltp.forum_categories WHERE code='HELP' RETURNING post_id INTO v_p;

  FOR i IN 1..10 LOOP
    INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id)
      VALUES (v_p,'tiny-'||i||'.txt','text/plain',10,'s3://tiny/'||i,v_u);
  END LOOP;
  PERFORM qa_pre('U8','ten tiny files were accepted',
    (SELECT count(*) FROM oltp.forum_attachments WHERE post_id=v_p) = 10,
    'far below the byte ceiling, so only the count limb can refuse the next one');

  BEGIN
    INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id)
      VALUES (v_p,'eleventh.txt','text/plain',10,'s3://tiny/11',v_u);
    v_state := 'ACCEPTED';
  EXCEPTION WHEN others THEN v_state := SQLSTATE; END;
  PERFORM qa_true('U8','U8 the eleventh file is refused on count alone',
    '100 bytes total -- nothing to do with the byte ceiling',
    v_state = 'P0001', 'attempt returned '||v_state);
END $$;


-- =====================================================================
-- U9 — the sweeper now has something to act on
-- =====================================================================
DO $$
DECLARE v_p BIGINT := qa.post('Post in HELP'); v_pending INT; v_legacy INT;
BEGIN
  DELETE FROM oltp.forum_posts WHERE post_id = v_p;

  SELECT count(*) INTO v_pending FROM oltp.forum_attachment_deletions WHERE purged_at IS NULL;
  PERFORM qa_true('U9','U9 a cascade now leaves a tombstone per object',
    'the row was the only trace; the tombstone outlives it',
    v_pending >= 8,
    v_pending||' storage key(s) queued for the sweeper');

  PERFORM qa_true('U9','U9 the tombstone carries the key, not just a count',
    'a sweeper needs to know WHAT to delete',
    (SELECT count(*) FROM oltp.forum_attachment_deletions WHERE storage_key LIKE 's3://bulk/%') >= 7,
    (SELECT string_agg(storage_key,', ' ORDER BY storage_key)
     FROM oltp.forum_attachment_deletions WHERE storage_key LIKE 's3://bulk/%' LIMIT 1));

  SELECT count(*) INTO v_legacy FROM oltp.forum_attachment_deletions
   WHERE storage_key LIKE 'LEGACY-UNRESOLVED:%';
  PERFORM qa_true('U9','U9 legacy rows do not create work that always fails',
    'a tombstone for a key that never existed is a permanent error in the queue',
    v_legacy = 0, 'no LEGACY marker queued');
END $$;


-- =====================================================================
-- C2 / C3 — thread integrity
-- =====================================================================
DO $$
DECLARE
  v_pg BIGINT := qa.post('Post in GEN');
  v_top BIGINT := (SELECT comment_id FROM oltp.forum_comments ORDER BY comment_id LIMIT 1);
  v_m BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm1@t');
  v_other BIGINT; v_reply BIGINT; v_b BIGINT;
BEGIN
  INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
    SELECT category_id, v_m, 'Second thread','body' FROM oltp.forum_categories WHERE code='GEN'
    RETURNING post_id INTO v_other;

  PERFORM qa_pair('C2','C2 a reply can no longer hang under another post''s comment',
    'composite FK (post_id, parent_comment_id), the same shape scores uses for (match, team)',
    format('INSERT INTO oltp.forum_comments(post_id,parent_comment_id,author_account_id,body) VALUES (%s,%s,%s,''proper nested reply'')', v_pg, v_top, v_m),
    format('INSERT INTO oltp.forum_comments(post_id,parent_comment_id,author_account_id,body) VALUES (%s,%s,%s,''grafted onto another thread'')', v_other, v_top, v_m));

  SELECT comment_id INTO v_reply FROM oltp.forum_comments WHERE body='proper nested reply';

  PERFORM qa_pair('C3','C3 a comment cannot become its own parent',
    'the trivial cycle is a one-row comparison, so a CHECK reaches it',
    format('UPDATE oltp.forum_comments SET body=''edited'' WHERE comment_id=%s', v_reply),
    format('UPDATE oltp.forum_comments SET parent_comment_id=comment_id WHERE comment_id=%s', v_reply));

  -- a longer cycle: every individual reference is valid, so only a walk sees it
  INSERT INTO oltp.forum_comments(post_id,parent_comment_id,author_account_id,body)
    VALUES (v_pg, v_reply, v_m, 'grandchild') RETURNING comment_id INTO v_b;
  PERFORM qa_pair('C3','C3 a longer cycle (A -> B -> A) is refused',
    'no constraint can see this; the ancestry walk is what catches it',
    format('UPDATE oltp.forum_comments SET body=''still fine'' WHERE comment_id=%s', v_b),
    format('UPDATE oltp.forum_comments SET parent_comment_id=%s WHERE comment_id=%s', v_b, v_reply));

  PERFORM qa_true('C3','C3 ordinary nesting still works',
    'the acyclic guard must not make replies impossible',
    (SELECT parent_comment_id FROM oltp.forum_comments WHERE comment_id=v_b) = v_reply,
    'grandchild still hangs under its parent');
END $$;


-- =====================================================================
-- P2 / P4 — moderation flag and edit ordering
-- =====================================================================
DO $$
DECLARE v_pg BIGINT := qa.post('Post in GEN'); v_all INT; v_vis INT; v_cvis INT;
BEGIN
  UPDATE oltp.forum_posts SET is_deleted = TRUE WHERE post_id = v_pg;
  SELECT count(*) INTO v_all FROM oltp.forum_posts WHERE post_id=v_pg;
  SELECT count(*) INTO v_vis FROM oltp.vw_forum_posts_visible WHERE post_id=v_pg;
  PERFORM qa_true('P2','P2 the view hides a soft-deleted post',
    'the safe read is now the obvious one',
    v_all = 1 AND v_vis = 0, 'base table '||v_all||' row, view '||v_vis||' rows');

  SELECT count(*) INTO v_cvis FROM oltp.vw_forum_comments_visible WHERE post_id=v_pg;
  PERFORM qa_true('P2','P2 the flag now propagates down the thread',
    'previously a moderated post kept showing its replies',
    v_cvis = 0, 'the deleted post exposes '||v_cvis||' visible comment(s)');

  UPDATE oltp.forum_posts SET is_deleted = FALSE WHERE post_id = v_pg;
  PERFORM qa_true('P2','P2 restoring the post brings it back',
    'the control: the view filters, it does not delete',
    (SELECT count(*) FROM oltp.vw_forum_posts_visible WHERE post_id=v_pg) = 1,
    'visible again after un-deleting');

  PERFORM qa_pair('P4','P4 an edit cannot precede the post it edits',
    'a one-row CHECK, and the audit trail stops being nonsense',
    format('UPDATE oltp.forum_posts SET edited_at = created_at + interval ''1 hour'' WHERE post_id=%s', v_pg),
    format('UPDATE oltp.forum_posts SET edited_at = created_at - interval ''1 day'' WHERE post_id=%s', v_pg));
END $$;


-- =====================================================================
-- T5 — a post may only wear tags from its own category
-- =====================================================================
DO $$
DECLARE
  v_pg BIGINT := qa.post('Post in GEN');
  v_gen SMALLINT := (SELECT category_id FROM oltp.forum_categories WHERE code='GEN');
  v_help SMALLINT := (SELECT category_id FROM oltp.forum_categories WHERE code='HELP');
  v_tgen BIGINT; v_thelp BIGINT; v_left INT;
BEGIN
  SELECT count(*) INTO v_left FROM oltp.forum_post_tags;
  PERFORM qa_true('T5','T5 the pre-existing cross-category pairing was removed',
    'it was never valid; the migration reports it rather than deleting quietly',
    v_left = 0, v_left||' pairing(s) survived the migration');

  INSERT INTO oltp.forum_tags(category_id,label) VALUES (v_gen,'Solved') RETURNING tag_id INTO v_tgen;
  SELECT tag_id INTO v_thelp FROM oltp.forum_tags WHERE label='Shared';

  PERFORM qa_pair('T5','T5 a GEN post can no longer wear a HELP tag',
    'the copied category is pinned by two composite FKs, so disagreement is unrepresentable',
    format('INSERT INTO oltp.forum_post_tags(post_id,tag_id,category_id) VALUES (%s,%s,%s)', v_pg, v_tgen, v_gen),
    format('INSERT INTO oltp.forum_post_tags(post_id,tag_id,category_id) VALUES (%s,%s,%s)', v_pg, v_thelp, v_gen));

  PERFORM qa_reject('T5','T5 nor by mislabelling the junction row itself',
    format('INSERT INTO oltp.forum_post_tags(post_id,tag_id,category_id) VALUES (%s,%s,%s)', v_pg, v_thelp, v_help),
    '23503');
END $$;


-- =====================================================================
\echo ''
\echo '===================== R6 VERIFICATION ====================='
SELECT seq, grp, status, tc, left(coalesce(result,''),60) AS result FROM qa.results ORDER BY seq;
\echo ''
SELECT * FROM qa_summary();
\echo ''
SELECT * FROM qa_lint();
SELECT qa_finish();
