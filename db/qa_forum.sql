-- =====================================================================
-- QA — the forum: uploads first, then the rest of the domain
-- =====================================================================
-- Groups:
--   U  attachments / uploads   (the priority)
--   P  posts and soft delete
--   C  comments and nesting
--   T  tags
--
-- 6 assertions in 99_tests touched this domain. post_rule_references is
-- covered separately by db/qa_rule_references.sql and not repeated here.
--
--   psql -d qa_forum -f db/01_oltp_schema.sql
--   psql -d qa_forum -f db/qa_forum.sql
-- =====================================================================

\set ON_ERROR_STOP on
\ir _qa_harness.sql
SELECT qa.suite('forum');

-- ---------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------
INSERT INTO oltp.accounts(email,password_hash,role) VALUES
  ('fc@t','x','club'), ('fm1@t','x','member'), ('fm2@t','x','member');
INSERT INTO oltp.clubs(account_id,club_name)   SELECT account_id,'FC' FROM oltp.accounts WHERE email='fc@t';
INSERT INTO oltp.members(account_id,full_name) SELECT account_id,email FROM oltp.accounts WHERE role='member';
INSERT INTO oltp.forum_categories(code,label) VALUES ('GEN','General'), ('HELP','Help'), ('RULES','Rules');
INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
  SELECT fc.category_id,a.account_id,'Post in GEN','body'
  FROM oltp.forum_categories fc, oltp.accounts a WHERE fc.code='GEN' AND a.email='fm1@t';
INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
  SELECT fc.category_id,a.account_id,'Post in HELP','body'
  FROM oltp.forum_categories fc, oltp.accounts a WHERE fc.code='HELP' AND a.email='fm2@t';
-- Two more posts so the quota limbs each start from an empty post, and
-- U9 has a post it can delete without taking another group's fixture
-- with it. Sharing one post would make a quota refusal depend on how
-- many files an earlier group happened to leave behind.
INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
  SELECT fc.category_id,a.account_id,'Post in RULES','body'
  FROM oltp.forum_categories fc, oltp.accounts a WHERE fc.code='RULES' AND a.email='fm1@t';
INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
  SELECT fc.category_id,a.account_id,'Post to be deleted','body'
  FROM oltp.forum_categories fc, oltp.accounts a WHERE fc.code='HELP' AND a.email='fm2@t';
INSERT INTO oltp.forum_comments(post_id,author_account_id,body)
  SELECT p.post_id,a.account_id,'top-level comment'
  FROM oltp.forum_posts p, oltp.accounts a WHERE p.title='Post in GEN' AND a.email='fm2@t';

CREATE OR REPLACE FUNCTION qa.post(p_title TEXT) RETURNS BIGINT AS $$
  SELECT post_id FROM oltp.forum_posts WHERE title = p_title;
$$ LANGUAGE sql STABLE;

-- A post that starts with no attachments. Since R6 caps a post at 10
-- files and 8 MB, cases that are not ABOUT the quota must not share a
-- post with each other -- otherwise the tenth unrelated upload starts
-- failing and the refusal gets attributed to whatever case ran last.
CREATE OR REPLACE FUNCTION qa.fresh_post(p_label TEXT) RETURNS BIGINT AS $$
  INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
  SELECT fc.category_id, a.account_id, p_label, 'body'
  FROM oltp.forum_categories fc, oltp.accounts a
  WHERE fc.code='GEN' AND a.email='fm1@t'
  RETURNING post_id;
$$ LANGUAGE sql VOLATILE;


-- =====================================================================
-- U — uploads / attachments
-- =====================================================================
-- Every attachment now carries a storage key and an uploader, both NOT
-- NULL, so the statements below spell them out. qa.att() builds the SQL
-- text once rather than repeating two extra columns twenty times -- and
-- because it takes the storage key as an argument, the cases that are
-- ABOUT the key (U5) can still set it explicitly.
CREATE OR REPLACE FUNCTION qa.att(p_cols TEXT, p_vals TEXT, p_key TEXT DEFAULT NULL)
RETURNS TEXT AS $$
  SELECT format(
    'INSERT INTO oltp.forum_attachments(%s,storage_key,uploaded_by_account_id) VALUES (%s,%L,%s)',
    p_cols, p_vals,
    coalesce(p_key, 's3://forum/'||md5(p_vals||clock_timestamp()::text)),
    (SELECT account_id FROM oltp.accounts WHERE email='fm1@t'));
$$ LANGUAGE sql VOLATILE;

DO $$
DECLARE
  v_p BIGINT := qa.post('Post in GEN');
  v_c BIGINT := (SELECT comment_id FROM oltp.forum_comments LIMIT 1);
  v_up BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm1@t');
  v_a BIGINT; v_cols TEXT; v_n INT; v_bytes BIGINT;
  v_p5 BIGINT; v_p6 BIGINT; v_p7 BIGINT;
BEGIN
  -- U1 / U2 both parents are usable, one at a time
  INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id)
    VALUES (v_p,'diagram.png','image/png',204800,'s3://forum/diagram.png',v_up) RETURNING attachment_id INTO v_a;
  PERFORM qa_true('U','U1 an attachment hangs off a post and reads back',
    'the ordinary upload path',
    (SELECT file_name FROM oltp.forum_attachments WHERE attachment_id=v_a) = 'diagram.png',
    (SELECT file_name||' / '||mime_type||' / '||size_bytes||' bytes'
     FROM oltp.forum_attachments WHERE attachment_id=v_a));

  PERFORM qa_accept('U','U2 an attachment can hang off a comment instead',
    qa.att('comment_id,file_name,mime_type,size_bytes', format('%s,''log.txt'',''text/plain'',512', v_c)));

  -- U3 exactly one parent
  PERFORM qa_pair('U','U3 an attachment cannot belong to BOTH a post and a comment',
    'num_nonnulls keeps the two FKs mutually exclusive rather than polymorphic',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''ok.png'',''image/png'',100', v_p)),
    qa.att('post_id,comment_id,file_name,mime_type,size_bytes', format('%s,%s,''both.png'',''image/png'',100', v_p, v_c)));

  PERFORM qa_pair('U','U3 nor to NEITHER',
    'an orphan attachment would be unreachable from any thread',
    qa.att('comment_id,file_name,mime_type,size_bytes', format('%s,''ok2.txt'',''text/plain'',100', v_c)),
    qa.att('file_name,mime_type,size_bytes', '''orphan.png'',''image/png'',100'));

  -- U4 the 1 MB rule, at every edge
  PERFORM qa_pair('U','U4 one byte over 1 MB is refused',
    'the limit is enforced in the database, not only in an uploader',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''exactly-1mb.zip'',''application/zip'',1048576', v_p)),
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''too-big.zip'',''application/zip'',1048577', v_p)));

  PERFORM qa_pair('U','U4 a zero-byte file is refused',
    'an empty upload is a failed upload, not a valid attachment',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''one-byte.txt'',''text/plain'',1', v_p)),
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''empty.txt'',''text/plain'',0', v_p)));

  PERFORM qa_pair('U','U4 a negative size is refused',
    'guards against an uploader reporting a bogus length',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''small.txt'',''text/plain'',10', v_p)),
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''negative.txt'',''text/plain'',-1', v_p)));

  -- U5 THE ONE THAT MATTERED: where are the bytes?
  --
  -- Was U5-GAP: there was no storage key, URL, bucket path or checksum.
  -- The schema comment claimed the bytes lived in object storage
  -- "referenced elsewhere by the app", but nothing in the row referenced
  -- them, so an attachment could not be resolved to content by anyone
  -- reading the database, and two rows with the same file_name were
  -- indistinguishable. R6 added storage_key (NOT NULL) and checksum_sha256.
  SELECT string_agg(column_name,', ' ORDER BY ordinal_position) INTO v_cols
    FROM information_schema.columns
   WHERE table_schema='oltp' AND table_name='forum_attachments';
  PERFORM qa_true('U','U5 an attachment says where the file is',
    'the row must be resolvable to content, the way certificates.file_url already was',
    (SELECT storage_key FROM oltp.forum_attachments WHERE attachment_id=v_a) IS NOT NULL,
    'columns: '||v_cols);

  PERFORM qa_pair('U','U5 a storage key is mandatory, not optional',
    'a row without one would be a record of a file nobody can fetch',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''keyed.png'',''image/png'',100', v_p)),
    format('INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,uploaded_by_account_id) '
           ||'VALUES (%s,''keyless.png'',''image/png'',100,%s)', v_p, v_up));

  -- Deliberately NOT a uniqueness test. Two rows may legitimately point at
  -- the same stored object -- that is what content-addressed storage does
  -- with a shared checksum -- so a UNIQUE on storage_key would be wrong.
  -- What U5 actually needed was that two rows sharing a file_name are
  -- separately resolvable, which the key gives without being unique.
  v_p5 := qa.fresh_post('U5 same-name post');
  EXECUTE qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''same-name.png'',''image/png'',100', v_p5), 's3://forum/copy-a');
  EXECUTE qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''same-name.png'',''image/png'',100', v_p5), 's3://forum/copy-b');
  PERFORM qa_true('U','U5 two files with the same name are no longer indistinguishable',
    'file_name was never unique; the storage key is what tells the rows apart',
    (SELECT count(DISTINCT storage_key) FROM oltp.forum_attachments
      WHERE post_id=v_p5 AND file_name='same-name.png') = 2,
    (SELECT 'same-name.png resolves to '||string_agg(storage_key,' and ' ORDER BY storage_key)
       FROM oltp.forum_attachments WHERE post_id=v_p5 AND file_name='same-name.png'));

  -- U6 the declared type is now checked against an allowlist
  --
  -- Was U6-GAP: mime_type was VARCHAR(100) with no format check and no
  -- allowlist, so a caller could declare an executable type on a .png name,
  -- or text that is not a MIME type at all. Since U5 meant nobody could
  -- inspect the bytes from the database, the declared type was the only
  -- signal available -- and it was unverified.
  PERFORM qa_pre('U','U6 the allowlist is populated',
    (SELECT count(*) FROM oltp.forum_allowed_mime_types) > 0,
    (SELECT 'allowlist holds: '||string_agg(mime_type,', ' ORDER BY mime_type)
       FROM oltp.forum_allowed_mime_types));
  v_p6 := qa.fresh_post('U6 mime post');
  PERFORM qa_pair('U','U6 a type outside the allowlist is refused',
    'an executable type on a .png name is exactly the case the allowlist exists for',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''photo.png'',''image/png'',1000', v_p6)),
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''photo.png'',''application/x-msdownload'',1000', v_p6)));
  PERFORM qa_pair('U','U6 text that is not a MIME type at all is refused',
    'the shape is checked as well as the membership, so a typo cannot slip past as a new type',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''thing.pdf'',''application/pdf'',1000', v_p6)),
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''thing.dat'',''not-a-mime-type'',1000', v_p6)));

  -- U7 the uploader is recorded
  --
  -- Was U7-GAP: the parent post or comment had an author but the attachment
  -- did not, so if a moderator or a second member added a file to an
  -- existing thread the database could not say who did -- unlike every
  -- other actor-bearing table in this schema.
  PERFORM qa_true('U','U7 an attachment records who uploaded it',
    'attribution for a file is not the same as authorship of the post',
    (SELECT uploaded_by_account_id FROM oltp.forum_attachments WHERE attachment_id=v_a) = v_up,
    'attachment '||v_a||' is attributed to account '||v_up);
  v_p7 := qa.fresh_post('U7 uploader post');
  PERFORM qa_pair('U','U7 the uploader must be a real account',
    'an unattributable file is the case U7 was opened for',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''attributed.png'',''image/png'',100', v_p7)),
    format('INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id) '
           ||'VALUES (%s,''ghost.png'',''image/png'',100,''s3://forum/ghost'',999999)', v_p));

  -- U8 the per-post quota
  --
  -- Was U8-GAP: the CHECK capped a single file at 1 MB and nothing capped
  -- the count, so a QA run put 25 MB on one post. The 1 MB rule read as a
  -- storage-protection measure and, per-file only, did not achieve that.
  -- R6 added enforce_attachment_quota: at most 10 files and 8 MB per post,
  -- both limits INCLUSIVE.
  SELECT count(*), coalesce(sum(size_bytes),0) INTO v_n, v_bytes
    FROM oltp.forum_attachments WHERE post_id=v_p;
  PERFORM qa_true('U','U8 the quota held through every case above',
    'the limit is not a fresh-post special case -- it applied to all of U1..U7',
    v_n <= 10 AND v_bytes <= 8*1048576,
    format('post %s carries %s file(s), %s bytes', v_p, v_n, v_bytes));
END $$;

-- U8 continued, on a post of its own so the quota starts from zero
DO $$
DECLARE
  v_p BIGINT := qa.post('Post in HELP');
  v_up BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm1@t');
  v_n INT;
BEGIN
  -- the BYTE ceiling: 8 MB exactly is accepted, one byte past is not.
  -- Getting there needs 8 files of 1 MB, which also stays under the count
  -- limit -- the two limbs have to be tested without tripping each other.
  FOR v_n IN 1..7 LOOP
    EXECUTE qa.att('post_id,file_name,mime_type,size_bytes',
                   format('%s,''fill-%s.zip'',''application/zip'',1048576', v_p, v_n));
  END LOOP;
  PERFORM qa_pre('U','U8 the post sits one file short of 8 MB',
    (SELECT sum(size_bytes) FROM oltp.forum_attachments WHERE post_id=v_p) = 7*1048576,
    format('%s bytes so far, so the next 1 MB file lands exactly on the ceiling',
      (SELECT sum(size_bytes) FROM oltp.forum_attachments WHERE post_id=v_p)));
  PERFORM qa_pair('U','U8 exactly 8 MB is accepted, one byte past is refused',
    'the quota is inclusive, matching the per-file CHECK it extends',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''last-mb.zip'',''application/zip'',1048576', v_p)),
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''one-byte-over.txt'',''text/plain'',1', v_p)));
END $$;

DO $$
DECLARE
  v_p BIGINT := qa.post('Post in RULES');
  v_n INT;
BEGIN
  -- the COUNT limb, kept apart from the byte limb: ten tiny files stay far
  -- below 8 MB, so a refusal here can only be about the file count
  FOR v_n IN 1..9 LOOP
    EXECUTE qa.att('post_id,file_name,mime_type,size_bytes',
                   format('%s,''tiny-%s.txt'',''text/plain'',10', v_p, v_n));
  END LOOP;
  PERFORM qa_pre('U','U8 nine small files, nowhere near the byte ceiling',
    (SELECT count(*) FROM oltp.forum_attachments WHERE post_id=v_p) = 9
    AND (SELECT sum(size_bytes) FROM oltp.forum_attachments WHERE post_id=v_p) < 1048576,
    format('%s file(s), %s bytes -- only the count can bite',
      (SELECT count(*) FROM oltp.forum_attachments WHERE post_id=v_p),
      (SELECT sum(size_bytes) FROM oltp.forum_attachments WHERE post_id=v_p)));
  PERFORM qa_pair('U','U8 the tenth file is accepted, the eleventh is refused',
    'a count limit and a byte limit are different rules; each needs its own edge',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''tenth.txt'',''text/plain'',10', v_p)),
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''eleventh.txt'',''text/plain'',10', v_p)));
END $$;

-- U9 cascade, and what it now leaves behind
DO $$
DECLARE
  v_p BIGINT := qa.post('Post to be deleted');
  v_up BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm1@t');
  v_before INT; v_after INT; v_key TEXT := 's3://forum/doomed-'||md5(now()::text);
BEGIN
  INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id)
    VALUES (v_p,'attached-to-doomed-post.pdf','application/pdf',5000,v_key,v_up);
  SELECT count(*) INTO v_before FROM oltp.forum_attachments WHERE post_id=v_p;
  PERFORM qa_pre('U','U9 the doomed post carries an attachment', v_before = 1,
    'so the cascade below has something to remove');

  DELETE FROM oltp.forum_posts WHERE post_id = v_p;
  SELECT count(*) INTO v_after FROM oltp.forum_attachments WHERE post_id=v_p;
  PERFORM qa_true('U','U9 deleting a post removes its attachment rows',
    'ON DELETE CASCADE keeps the metadata consistent',
    v_after = 0, v_before||' -> '||v_after||' attachment row(s)');

  -- Was U9-GAP: the row was the sole reference to the stored object, and
  -- CASCADE removed it without leaving anything to reconcile against --
  -- the bytes became unreferenced and unfindable, with no deletion queue,
  -- no tombstone and no storage key to sweep. R6 records a tombstone
  -- BEFORE the row goes, which is the thing a cleanup job can act on.
  PERFORM qa_true('U','U9 the cascade leaves a tombstone for the bytes',
    'a cleanup job needs something to reconcile object storage against',
    EXISTS (SELECT 1 FROM oltp.forum_attachment_deletions WHERE storage_key = v_key),
    (SELECT format('deletion %s recorded key %s (%s bytes) at %s, purged_at %s',
        deletion_id, storage_key, size_bytes, deleted_at, coalesce(purged_at::text,'NULL'))
     FROM oltp.forum_attachment_deletions WHERE storage_key = v_key));

  PERFORM qa_true('U','U9 the tombstone starts unpurged',
    'purged_at is the sweeper''s own bookkeeping, so it must begin NULL',
    (SELECT purged_at FROM oltp.forum_attachment_deletions WHERE storage_key = v_key) IS NULL,
    'the row is queued for a sweep, not marked as already swept');
END $$;


-- =====================================================================
-- P — posts and soft delete
-- =====================================================================
DO $$
DECLARE v_p BIGINT := qa.post('Post in GEN'); v_visible INT; v_views INT;
BEGIN
  UPDATE oltp.forum_posts SET is_deleted = TRUE WHERE post_id = v_p;
  PERFORM qa_true('P','P1 a soft-deleted post keeps its row',
    'soft delete preserves thread integrity for moderation, per the schema note',
    (SELECT is_deleted FROM oltp.forum_posts WHERE post_id=v_p),
    'the row survives with is_deleted = true');

  -- Was P2-GAP: is_deleted was a flag with no reader -- no view, no RLS
  -- policy, no default filter -- so every caller had to remember
  -- `WHERE NOT is_deleted` and the one that forgot showed moderated
  -- content. R6 added vw_forum_posts_visible so the safe path is a
  -- readable default rather than a convention.
  SELECT count(*) INTO v_visible FROM oltp.forum_posts WHERE post_id = v_p;
  SELECT count(*) INTO v_views FROM information_schema.views
   WHERE table_schema='oltp' AND table_name LIKE '%post%';
  PERFORM qa_true('P','P2-CONTROL the base table still returns the row',
    'the view must be doing the hiding -- if the row vanished outright, P2 would prove nothing',
    v_visible = 1,
    format('a plain SELECT still returns it (%s row), and oltp now exposes %s post-related view(s)',
           v_visible, v_views));
  PERFORM qa_true('P','P2 a soft-deleted post is hidden by the visible view',
    'the flag now has a reader, so callers do not each have to remember the filter',
    NOT EXISTS (SELECT 1 FROM oltp.vw_forum_posts_visible WHERE post_id = v_p),
    'vw_forum_posts_visible omits post '||v_p||' while forum_posts still holds it');
  PERFORM qa_true('P','P2 the view hides only what is flagged',
    'a filter that hides everything would pass the assertion above and be useless',
    (SELECT count(*) FROM oltp.vw_forum_posts_visible) > 0
    AND (SELECT count(*) FROM oltp.vw_forum_posts_visible)
        = (SELECT count(*) FROM oltp.forum_posts WHERE NOT is_deleted),
    format('%s of %s post(s) remain visible',
      (SELECT count(*) FROM oltp.vw_forum_posts_visible),
      (SELECT count(*) FROM oltp.forum_posts)));

  PERFORM qa_true('P','P3 comments on a soft-deleted post remain fully visible',
    'the flag does not propagate down the thread',
    (SELECT count(*) FROM oltp.forum_comments WHERE post_id=v_p AND NOT is_deleted) > 0,
    (SELECT count(*)::text||' undeleted comment(s) still attached to a deleted post'
     FROM oltp.forum_comments WHERE post_id=v_p));

  UPDATE oltp.forum_posts SET is_deleted = FALSE WHERE post_id = v_p;   -- restore for later groups

  -- Was P4-GAP: nothing ordered created_at and edited_at, so a post could
  -- claim it was edited before it existed. Minor next to U5, but it is the
  -- kind of thing that makes an audit trail unusable. The CHECK is
  -- expressible on a single row and costs nothing, which is why R6 added it.
  PERFORM qa_pair('P','P4 edited_at cannot precede created_at',
    'an edit that predates the post would make the audit trail unreadable',
    format('UPDATE oltp.forum_posts SET edited_at = created_at + interval ''1 hour'' WHERE post_id=%s', v_p),
    format('UPDATE oltp.forum_posts SET edited_at = created_at - interval ''1 day'' WHERE post_id=%s', v_p));
  PERFORM qa_accept('P','P4 an unedited post may leave edited_at NULL',
    format('UPDATE oltp.forum_posts SET edited_at = NULL WHERE post_id=%s', v_p));
  PERFORM qa_accept('P','P4 editing at the very instant of creation is allowed',
    format('UPDATE oltp.forum_posts SET edited_at = created_at WHERE post_id=%s', v_p));
END $$;


-- =====================================================================
-- C — comments and nesting
-- =====================================================================
DO $$
DECLARE
  v_pg BIGINT := qa.post('Post in GEN');
  v_top BIGINT := (SELECT comment_id FROM oltp.forum_comments ORDER BY comment_id LIMIT 1);
  v_m BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm1@t');
  v_reply BIGINT; v_other_post BIGINT; v_foreign BIGINT;
BEGIN
  INSERT INTO oltp.forum_comments(post_id,parent_comment_id,author_account_id,body)
    VALUES (v_pg, v_top, v_m, 'a nested reply') RETURNING comment_id INTO v_reply;
  PERFORM qa_true('C','C1 a comment can reply to another comment',
    'nesting works through parent_comment_id',
    (SELECT parent_comment_id FROM oltp.forum_comments WHERE comment_id=v_reply) = v_top,
    'comment '||v_reply||' replies to '||v_top);

  -- C2 a parent from a DIFFERENT thread
  --
  -- Was C2-GAP: parent_comment_id referenced forum_comments(comment_id)
  -- alone, so nothing tied the parent to the same post and a reply could be
  -- grafted onto a different thread entirely. The fix had a precedent in
  -- this very schema -- scores uses a COMPOSITE FK (match_id, team_id) into
  -- match_teams for exactly this reason -- and R6 applied the same shape:
  -- (post_id, parent_comment_id) into a unique (post_id, comment_id).
  INSERT INTO oltp.forum_posts(category_id,author_account_id,title,body)
    SELECT category_id, v_m, 'Second thread','body' FROM oltp.forum_categories WHERE code='GEN'
    RETURNING post_id INTO v_other_post;

  PERFORM qa_pre('C','C2 the two threads are genuinely different posts',
    v_other_post <> v_pg
    AND (SELECT post_id FROM oltp.forum_comments WHERE comment_id=v_top) = v_pg,
    format('parent comment %s lives on post %s; the reply below targets post %s',
           v_top, v_pg, v_other_post));
  PERFORM qa_pair('C','C2 a reply cannot hang under a comment from another post',
    'the thread must hold together: same statement, differing only in which post the reply claims',
    format('INSERT INTO oltp.forum_comments(post_id,parent_comment_id,author_account_id,body) '
           ||'VALUES (%s,%s,%s,''reply in its own thread'')', v_pg, v_top, v_m),
    format('INSERT INTO oltp.forum_comments(post_id,parent_comment_id,author_account_id,body) '
           ||'VALUES (%s,%s,%s,''reply hanging under another thread''''s comment'')', v_other_post, v_top, v_m));

  PERFORM qa_true('C','C2 the second thread stayed empty',
    'counting the outcome: a refused insert must not leave a grafted comment behind',
    (SELECT count(*) FROM oltp.forum_comments WHERE post_id=v_other_post) = 0,
    'post '||v_other_post||' holds 0 comment(s)');

  -- C3 a comment as its own parent
  --
  -- Was C3-GAP: a self-referencing FK cannot see a cycle -- comment X
  -- pointing at itself is a valid reference -- so any recursive walk of the
  -- thread looped forever unless the caller carried its own visited-set.
  -- R6 added the cheap CHECK for the trivial case and a trigger for the
  -- longer ones, because A->B->A is not expressible as a CHECK.
  PERFORM qa_pair('C','C3 a comment cannot be made its own parent',
    'the trivial cycle, stopped by a CHECK on the row itself',
    format('UPDATE oltp.forum_comments SET body = ''control: a harmless edit'' WHERE comment_id = %s', v_reply),
    format('UPDATE oltp.forum_comments SET parent_comment_id = comment_id WHERE comment_id = %s', v_reply));

  -- the two-step cycle: reply already points at v_top, so pointing v_top
  -- back at reply would close A->B->A. A CHECK cannot see this one -- it
  -- involves a second row -- which is why the trigger exists.
  PERFORM qa_pre('C','C3 a two-step cycle is reachable',
    (SELECT parent_comment_id FROM oltp.forum_comments WHERE comment_id=v_reply) = v_top,
    format('comment %s already points at %s, so pointing %s back would close the loop',
           v_reply, v_top, v_top));
  PERFORM qa_pair('C','C3 a longer cycle is refused too',
    'A->B->A needs a trigger, since a CHECK can only see the row in front of it',
    format('UPDATE oltp.forum_comments SET body = ''control: still a working UPDATE'' WHERE comment_id = %s', v_top),
    format('UPDATE oltp.forum_comments SET parent_comment_id = %s WHERE comment_id = %s', v_reply, v_top));

  PERFORM qa_true('C','C3 the thread is still a walkable tree',
    'the point of refusing cycles is that a recursive walk terminates',
    (WITH RECURSIVE walk(comment_id, depth) AS (
       SELECT comment_id, 1 FROM oltp.forum_comments WHERE parent_comment_id IS NULL AND post_id=v_pg
       UNION ALL
       SELECT c.comment_id, w.depth+1 FROM oltp.forum_comments c
       JOIN walk w ON c.parent_comment_id = w.comment_id
       WHERE w.depth < 50)
     SELECT max(depth) FROM walk) < 50,
    'a recursive walk of post '||v_pg||' terminates on its own');
END $$;


-- =====================================================================
-- T — tags
-- =====================================================================
DO $$
DECLARE
  v_pg BIGINT := qa.post('Post in GEN');
  v_gen SMALLINT := (SELECT category_id FROM oltp.forum_categories WHERE code='GEN');
  v_help SMALLINT := (SELECT category_id FROM oltp.forum_categories WHERE code='HELP');
  v_tag_gen BIGINT; v_tag_help BIGINT;
BEGIN
  INSERT INTO oltp.forum_tags(category_id,label) VALUES (v_gen,'Help Wanted') RETURNING tag_id INTO v_tag_gen;
  INSERT INTO oltp.forum_tags(category_id,label) VALUES (v_help,'Help Wanted') RETURNING tag_id INTO v_tag_help;
  PERFORM qa_true('T','T1 the same label may exist in two categories',
    'tags are category-scoped, so "Help Wanted" need not be globally unique',
    v_tag_gen <> v_tag_help,
    'GEN tag '||v_tag_gen||' and HELP tag '||v_tag_help||' coexist');

  PERFORM qa_pair('T','T2 the same label cannot repeat within one category',
    'uq_forum_tags_category_label keeps a category''s vocabulary unambiguous',
    format('INSERT INTO oltp.forum_tags(category_id,label) VALUES (%s,''Solved'')', v_gen),
    format('INSERT INTO oltp.forum_tags(category_id,label) VALUES (%s,''Help Wanted'')', v_gen));

  -- two more GEN-scoped tags, so the T5 pairs each have a control tag of
  -- their own to apply rather than colliding on the composite PK
  INSERT INTO oltp.forum_tags(category_id,label) VALUES (v_gen,'Answered'), (v_gen,'Pinned');

  -- The junction now carries category_id. It looks like the denormalisation
  -- the original design avoided, but it is the opposite: repeating the
  -- category is what lets ONE composite FK to each side force post and tag
  -- to agree. Leaving it out is what made the rule undeclarable.
  INSERT INTO oltp.forum_post_tags(post_id,category_id,tag_id) VALUES (v_pg, v_gen, v_tag_gen);
  PERFORM qa_true('T','T3 a post can be tagged',
    'the junction resolves post to tag',
    (SELECT count(*) FROM oltp.forum_post_tags WHERE post_id=v_pg) = 1, 'one tag applied');

  PERFORM qa_pair('T','T4 the same tag cannot be applied twice to one post',
    'the composite PK makes the pair itself the recorded fact',
    format('INSERT INTO oltp.forum_post_tags(post_id,category_id,tag_id) SELECT %s, %s, tag_id FROM oltp.forum_tags WHERE label=''Solved''', v_pg, v_gen),
    format('INSERT INTO oltp.forum_post_tags(post_id,category_id,tag_id) VALUES (%s,%s,%s)', v_pg, v_gen, v_tag_gen));

  -- T5 the concern the schema had documented as unenforceable
  --
  -- Was T5-GAP, and the one gap here that CONFIRMED a documented decision
  -- rather than contradicting one: both forum_posts.category_id and
  -- forum_tags.category_id existed, but the junction deliberately did not
  -- repeat the category, so agreement between them could not be declared
  -- and was left to the application -- and with no application, the rule
  -- held nowhere. R6 carries the category into the junction, which makes
  -- the same rule expressible as two composite FKs.
  PERFORM qa_pre('T','T5 the two tags really are in different categories',
    (SELECT category_id FROM oltp.forum_tags WHERE tag_id=v_tag_gen) = v_gen
    AND (SELECT category_id FROM oltp.forum_tags WHERE tag_id=v_tag_help) <> v_gen,
    format('tag %s is in GEN, tag %s is in HELP, and the post is in GEN', v_tag_gen, v_tag_help));
  PERFORM qa_pair('T','T5 a post cannot use a tag from a different category',
    'the agreement the schema comment left to the application is now declared',
    format('INSERT INTO oltp.forum_post_tags(post_id,category_id,tag_id) SELECT %s, %s, tag_id FROM oltp.forum_tags WHERE label=''Answered''', v_pg, v_gen),
    format('INSERT INTO oltp.forum_post_tags(post_id,category_id,tag_id) VALUES (%s,%s,%s)', v_pg, v_gen, v_tag_help));

  -- and the other way round: claiming the tag's category instead of the
  -- post's does not buy a way past it -- the other composite FK catches it
  PERFORM qa_pair('T','T5 nor by declaring the tag''s category on the junction row',
    'both edges are checked, so neither side can be the one that bends',
    format('INSERT INTO oltp.forum_post_tags(post_id,category_id,tag_id) SELECT %s, %s, tag_id FROM oltp.forum_tags WHERE label=''Pinned''', v_pg, v_gen),
    format('INSERT INTO oltp.forum_post_tags(post_id,category_id,tag_id) VALUES (%s,%s,%s)',
           v_pg, (SELECT category_id FROM oltp.forum_tags WHERE tag_id=v_tag_help), v_tag_help));
END $$;


-- =====================================================================
-- D — the R6 guards at depth
-- =====================================================================
-- Everything above tests these guards through the case that motivated
-- them. This group tests them where a WEAKER implementation would still
-- pass every assertion above -- which is the only way to tell that the
-- guard is the shape it claims to be, rather than a special case that
-- happens to cover the example in the proposal.
-- =====================================================================
DO $$
DECLARE
  v_p BIGINT := qa.fresh_post('D group post');
  v_up BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm1@t');
BEGIN
  -- D1 enforce_attachment_type has TWO limbs, and U6 only ever fired one.
  -- U6's negatives were types absent from the allowlist, so they were
  -- refused at the membership check and never reached the second one:
  -- that the file EXTENSION must match the declared type. A trigger that
  -- did nothing but check membership would pass all of U6.
  PERFORM qa_pre('D','D1 both parts of the pair are allowlisted types',
    (SELECT count(*) FROM oltp.forum_allowed_mime_types WHERE mime_type IN ('image/png','application/pdf')) = 2,
    'image/png and application/pdf are both permitted, so only the NAME can decide');
  PERFORM qa_pair('D','D1 the file name must match the declared type',
    'the original U6 concern was an executable disguised as a .png -- membership alone never checked that',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''chart.png'',''image/png'',100', v_p)),
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''chart.pdf'',''image/png'',100', v_p)));

  PERFORM qa_pair('D','D1 a file with no extension at all is refused',
    'substring() returns NULL rather than a mismatch, which is the branch a naive check would miss',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''notes.txt'',''text/plain'',100', v_p)),
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''README'',''text/plain'',100', v_p)));

  PERFORM qa_pair('D','D1 the extension check is case-insensitive',
    'refusing PHOTO.PNG would be a false positive that only shows up on real uploads',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''PHOTO.PNG'',''image/png'',100', v_p)),
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''PHOTO.GIF'',''image/png'',100', v_p)));

  PERFORM qa_true('D','D1 a type may permit SEVERAL extensions',
    'text/plain allows txt, log and csv -- a single-value comparison would break two of them',
    (SELECT count(*) FROM oltp.forum_allowed_mime_types
      WHERE mime_type='text/plain' AND array_length(extensions,1) > 1) = 1,
    (SELECT 'text/plain permits '||array_to_string(extensions,', ')
       FROM oltp.forum_allowed_mime_types WHERE mime_type='text/plain'));
  PERFORM qa_accept('D','D1 a secondary extension of the same type is accepted',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''server.log'',''text/plain'',100', v_p)));
END $$;

-- D2 the allowlist is DATA, not a list baked into the trigger
DO $$
DECLARE
  v_p BIGINT := qa.fresh_post('D2 allowlist post');
  v_stmt TEXT;
BEGIN
  -- A hardcoded list would satisfy every assertion in U6 and D1. The only
  -- way to tell the difference is to change the TABLE and watch the
  -- verdict follow.
  --
  -- The evidence is therefore temporal: ONE statement, run three times,
  -- flipping refused -> accepted -> refused as a single row appears and
  -- disappears from forum_allowed_mime_types. Each run is still a proper
  -- side-by-side pair against a type whose listing did NOT change, so the
  -- harness lint can see the control -- a temporal pair alone would be
  -- recorded as an unpaired rejection, and rightly: it proves the verdict
  -- moved, not that the mechanism under test is the one that moved it.
  v_stmt := qa.att('post_id,file_name,mime_type,size_bytes',
                   format('%s,''backup.tar'',''application/x-tar'',100', v_p));

  PERFORM qa_pre('D','D2 application/x-tar is not permitted yet',
    NOT EXISTS (SELECT 1 FROM oltp.forum_allowed_mime_types WHERE mime_type='application/x-tar'),
    'the allowlist has no row for it, so the refusal below is about the table');
  PERFORM qa_pair('D','D2 run 1 of 3: the type is refused BEFORE the row is added',
    'application/pdf is listed and stays listed throughout, so it holds the verdict still',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''control-a.pdf'',''application/pdf'',100', v_p)),
    v_stmt);

  INSERT INTO oltp.forum_allowed_mime_types(mime_type,label,extensions)
    VALUES ('application/x-tar','TAR archive','{tar}');

  -- the crux: the statement that was the NEGATIVE a moment ago is now the
  -- POSITIVE, and nothing changed but one row in the allowlist
  PERFORM qa_pair('D','D2 run 2 of 3: the SAME statement is accepted once the row exists',
    'a list compiled into the trigger cannot follow an INSERT into the table',
    v_stmt,
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''still-unlisted.7z'',''application/x-7z-compressed'',100', v_p)));

  -- and back the other way, so the verdict tracks the table in both
  -- directions rather than merely loosening once
  DELETE FROM oltp.forum_allowed_mime_types WHERE mime_type='application/x-tar';
  PERFORM qa_pair('D','D2 run 3 of 3: removing the row refuses it again',
    'the same pdf control, so only the x-tar half of the comparison moved',
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''control-b.pdf'',''application/pdf'',100', v_p)),
    qa.att('post_id,file_name,mime_type,size_bytes', format('%s,''second.tar'',''application/x-tar'',100', v_p)));
END $$;

-- D3 cycles longer than the two the C group covered
DO $$
DECLARE
  v_p BIGINT := qa.fresh_post('D3 cycle post');
  v_m BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm1@t');
  v_a BIGINT; v_b BIGINT; v_c BIGINT;
BEGIN
  -- C3 tested depth 1 (self) and depth 2 (A->B->A). A guard that looked
  -- only at the parent and the grandparent would pass both and fail here,
  -- so this is where the difference between "checks two levels" and
  -- "walks the chain" becomes visible.
  INSERT INTO oltp.forum_comments(post_id,author_account_id,body)
    VALUES (v_p, v_m, 'A') RETURNING comment_id INTO v_a;
  INSERT INTO oltp.forum_comments(post_id,parent_comment_id,author_account_id,body)
    VALUES (v_p, v_a, v_m, 'B') RETURNING comment_id INTO v_b;
  INSERT INTO oltp.forum_comments(post_id,parent_comment_id,author_account_id,body)
    VALUES (v_p, v_b, v_m, 'C') RETURNING comment_id INTO v_c;

  PERFORM qa_pre('D','D3 a three-deep chain exists',
    (SELECT parent_comment_id FROM oltp.forum_comments WHERE comment_id=v_c) = v_b
    AND (SELECT parent_comment_id FROM oltp.forum_comments WHERE comment_id=v_b) = v_a,
    format('A=%s <- B=%s <- C=%s, so pointing A at C closes a three-step loop', v_a, v_b, v_c));

  PERFORM qa_pair('D','D3 a three-step cycle A->B->C->A is refused',
    'the guard walks the whole ancestry, not a fixed number of levels',
    format('UPDATE oltp.forum_comments SET body=''control: a harmless edit'' WHERE comment_id=%s', v_a),
    format('UPDATE oltp.forum_comments SET parent_comment_id=%s WHERE comment_id=%s', v_c, v_a));

  PERFORM qa_true('D','D3 the legitimate three-deep chain survived',
    'refusing cycles must not also refuse ordinary nesting',
    (SELECT count(*) FROM oltp.forum_comments WHERE post_id=v_p) = 3
    AND (SELECT parent_comment_id FROM oltp.forum_comments WHERE comment_id=v_a) IS NULL,
    'three comments, A still a root');
END $$;

-- D4 the tombstone is on the DELETE, not on the cascade
DO $$
DECLARE
  v_p BIGINT := qa.fresh_post('D4 tombstone post');
  v_up BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='fm1@t');
  v_key TEXT := 's3://forum/direct-'||md5(clock_timestamp()::text);
  v_att BIGINT;
BEGIN
  -- U9 removed the parent post and found a tombstone. That leaves open
  -- whether the tombstone is recorded by the DELETE itself or only along
  -- the cascade path -- and moderators remove single files far more often
  -- than whole threads, so the direct path is the common one.
  INSERT INTO oltp.forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id)
    VALUES (v_p,'removed-by-hand.pdf','application/pdf',4096,v_key,v_up)
    RETURNING attachment_id INTO v_att;

  PERFORM qa_pre('D','D4 no tombstone exists for this key yet',
    NOT EXISTS (SELECT 1 FROM oltp.forum_attachment_deletions WHERE storage_key=v_key),
    'so the row found afterwards was written by this DELETE and not by an earlier case');

  DELETE FROM oltp.forum_attachments WHERE attachment_id = v_att;

  PERFORM qa_true('D','D4 deleting one attachment directly still records a tombstone',
    'removing a single file is the common moderator action, not deleting the thread',
    EXISTS (SELECT 1 FROM oltp.forum_attachment_deletions WHERE storage_key=v_key),
    'tombstone written for '||v_key);

  PERFORM qa_true('D','D4 the tombstone carries what a sweeper needs',
    'a key with no size or name cannot be reconciled against object storage',
    (SELECT file_name='removed-by-hand.pdf' AND size_bytes=4096 AND deleted_at IS NOT NULL
       FROM oltp.forum_attachment_deletions WHERE storage_key=v_key),
    (SELECT format('%s, %s bytes, deleted_at %s', file_name, size_bytes, deleted_at)
       FROM oltp.forum_attachment_deletions WHERE storage_key=v_key));
END $$;


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
\echo '--- harness lint ---'
SELECT * FROM qa_lint();
\echo ''
\echo '========== SCHEMA GAPS DISCOVERED =========='
SELECT seq, grp, tc, result FROM qa.results WHERE status='GAP' ORDER BY seq;
SELECT qa_finish();
