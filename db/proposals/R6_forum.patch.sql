-- =====================================================================
-- PROPOSAL R6 — the forum: uploads, threads, moderation, tags
-- =====================================================================
-- STATUS: ADOPTED on 2026-08-27. This file is now a RECORD, not a
-- migration: its contents were folded into 01_oltp_schema.sql and the
-- pipeline builds them from there. Do NOT run it against a current
-- database -- it would fail on objects that already exist. It is kept
-- because the reasoning here is the reasoning behind the schema, and
-- 01_ carries only the short form of it.
-- Evidence:  db/qa_forum.sql -- 10 gaps on a throwaway database.
-- Verified:  db/proposals/R6_forum.verify.sql
--
-- The ten gaps are four problems seen from several angles:
--
--   Part 1  the attachment row is not tied to the stored object
--           -> closes U5, U6, U7, U9
--   Part 2  a per-file limit is not a per-post limit
--           -> closes U8
--   Part 3  the thread has no integrity
--           -> closes C2, C3
--   Part 4  flags and copies nobody enforces
--           -> closes P2, P4, T5
--
-- Each part stands alone; rejecting one does not break the others.
-- =====================================================================


-- =====================================================================
-- Part 1 — bind the attachment row to the object it describes
-- =====================================================================
-- U5, U6, U7 and U9 are one defect from four angles: the row records
-- that a file exists but not WHICH file. Without a key you cannot fetch
-- it (U5), cannot verify what it really is (U6), cannot say who put it
-- there (U7), and cannot clean it up when the row goes (U9).
--
-- Nullable first, then back-filled, then NOT NULL -- the ordering is
-- load-bearing for the same reason as R2 step 2: adding NOT NULL to a
-- populated table fails outright.
ALTER TABLE oltp.forum_attachments ADD COLUMN storage_key    TEXT;
ALTER TABLE oltp.forum_attachments ADD COLUMN checksum_sha256 CHAR(64);
ALTER TABLE oltp.forum_attachments ADD COLUMN uploaded_by_account_id BIGINT
  REFERENCES oltp.accounts(account_id);

-- Back-fill, stated honestly rather than papered over.
--   storage_key: pre-existing rows have no key and none can be derived.
--     They get a marker that is deliberately greppable and deliberately
--     resolves to nothing, so an operator can find and reconcile them.
--     A plausible-looking fake key would be worse than an obvious one.
UPDATE oltp.forum_attachments
   SET storage_key = 'LEGACY-UNRESOLVED:' || attachment_id
 WHERE storage_key IS NULL;

--   uploaded_by: inferred from the author of the parent post or comment.
--     Usually right, never verified. Same trust shape as the R2 and R5
--     back-fills: a decision the reviewer takes on, not a fact the
--     migration establishes.
UPDATE oltp.forum_attachments a
   SET uploaded_by_account_id = COALESCE(
        (SELECT p.author_account_id FROM oltp.forum_posts p    WHERE p.post_id    = a.post_id),
        (SELECT c.author_account_id FROM oltp.forum_comments c WHERE c.comment_id = a.comment_id))
 WHERE a.uploaded_by_account_id IS NULL;

ALTER TABLE oltp.forum_attachments ALTER COLUMN storage_key SET NOT NULL;
ALTER TABLE oltp.forum_attachments ALTER COLUMN uploaded_by_account_id SET NOT NULL;
CREATE INDEX ix_forum_attachments_uploaded_by ON oltp.forum_attachments(uploaded_by_account_id);
CREATE INDEX ix_forum_attachments_storage_key ON oltp.forum_attachments(storage_key);

COMMENT ON COLUMN oltp.forum_attachments.storage_key IS
  'Where the bytes actually live. Rows carrying a LEGACY-UNRESOLVED: prefix predate this column and '
  'cannot be resolved -- reconcile against the bucket before trusting them.';

-- ---- U6: the declared type must at least be a type -------------------
-- A format CHECK is objective and costs nothing. WHICH types are allowed
-- is a product decision, so it lives in an editable lookup table in the
-- style this schema already uses for such vocabularies.
ALTER TABLE oltp.forum_attachments
  ADD CONSTRAINT ck_forum_attachments_mime_shape
  CHECK (mime_type ~ '^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$');

CREATE TABLE oltp.forum_allowed_mime_types (
  mime_type   VARCHAR(100) PRIMARY KEY,
  extensions  TEXT[] NOT NULL,        -- lower-case, no dot
  label       VARCHAR(60) NOT NULL
);

-- STARTING POINT, NOT A RULING. These rows are a reasonable default for
-- a robotics festival forum; the reviewer should confirm the list before
-- adoption. Adding or removing a type is an UPDATE, not a migration --
-- which is the whole reason this is a table and not a CHECK.
INSERT INTO oltp.forum_allowed_mime_types(mime_type, extensions, label) VALUES
  ('image/png',       ARRAY['png'],               'PNG image'),
  ('image/jpeg',      ARRAY['jpg','jpeg'],        'JPEG image'),
  ('image/gif',       ARRAY['gif'],               'GIF image'),
  ('application/pdf', ARRAY['pdf'],               'PDF document'),
  ('text/plain',      ARRAY['txt','log','csv'],   'Plain text'),
  ('application/zip', ARRAY['zip'],               'ZIP archive'),
  ('video/mp4',       ARRAY['mp4'],               'MP4 video');

-- The mismatch half of U6: an executable type declared on a .png name.
-- Neither a CHECK nor an FK can express "the extension must agree with
-- the declared type", because it compares a substring of one column
-- against an array in another table.
CREATE OR REPLACE FUNCTION oltp.enforce_attachment_type() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
DECLARE v_ext TEXT; v_allowed TEXT[];
BEGIN
  SELECT extensions INTO v_allowed
  FROM oltp.forum_allowed_mime_types WHERE mime_type = NEW.mime_type;

  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'mime type % is not permitted for forum attachments', NEW.mime_type
      USING HINT = 'see oltp.forum_allowed_mime_types';
  END IF;

  v_ext := lower(substring(NEW.file_name from '\.([^.]+)$'));
  IF v_ext IS NULL OR NOT (v_ext = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'file name % does not match declared type % (expected one of %)',
      NEW.file_name, NEW.mime_type, v_allowed
      USING HINT = 'the declared type is the only signal available, so it must agree with the name';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_forum_attachments_type
  BEFORE INSERT OR UPDATE ON oltp.forum_attachments
  FOR EACH ROW EXECUTE FUNCTION oltp.enforce_attachment_type();

-- ---- U9: give a cleanup job something to act on ----------------------
-- Today CASCADE removes the only reference to the stored object, leaving
-- bytes that nothing can find. A tombstone survives the cascade.
CREATE TABLE oltp.forum_attachment_deletions (
  deletion_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  storage_key  TEXT NOT NULL,
  file_name    VARCHAR(255) NOT NULL,
  size_bytes   INTEGER NOT NULL,
  deleted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  purged_at    TIMESTAMPTZ                    -- set by the storage sweeper
);
CREATE INDEX ix_forum_attachment_deletions_pending
  ON oltp.forum_attachment_deletions(deleted_at) WHERE purged_at IS NULL;

COMMENT ON TABLE oltp.forum_attachment_deletions IS
  'Outbox for the storage sweeper. A row appears whenever an attachment is deleted -- including by '
  'CASCADE from a post -- and is stamped purged_at once the object is actually gone from the bucket.';

CREATE OR REPLACE FUNCTION oltp.record_attachment_deletion() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
BEGIN
  -- legacy rows have no real key, so there is nothing for a sweeper to
  -- delete; recording them would only produce work that always fails
  IF OLD.storage_key NOT LIKE 'LEGACY-UNRESOLVED:%' THEN
    INSERT INTO oltp.forum_attachment_deletions(storage_key, file_name, size_bytes)
      VALUES (OLD.storage_key, OLD.file_name, OLD.size_bytes);
  END IF;
  RETURN OLD;
END;
$fn$;

CREATE TRIGGER trg_forum_attachments_deletion
  AFTER DELETE ON oltp.forum_attachments
  FOR EACH ROW EXECUTE FUNCTION oltp.record_attachment_deletion();


-- =====================================================================
-- Part 2 — a per-file limit is not a per-post limit (closes U8)
-- =====================================================================
-- Measured: 32 files of 1 MB each accepted on a single post, ~26 MB in
-- total. The CHECK caps one file and nothing caps the set, so the rule
-- does not achieve what it reads as achieving.
--
-- Neither a count nor a running sum is expressible as a row-level CHECK,
-- so this is a trigger -- the same category as enforce_team_capacity.
--
-- THE NUMBERS BELOW ARE A PROPOSAL, NOT A MEASUREMENT. 10 files and
-- 8 MB per thread item are a starting point for the reviewer to confirm
-- or replace; they are stated here rather than hidden in a constant so
-- that changing them is an obvious edit.
CREATE OR REPLACE FUNCTION oltp.enforce_attachment_quota() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
DECLARE
  c_max_files INT := 10;
  c_max_bytes BIGINT := 8 * 1048576;
  v_count INT; v_bytes BIGINT; v_scope TEXT;
BEGIN
  IF NEW.post_id IS NOT NULL THEN
    SELECT count(*), coalesce(sum(size_bytes),0) INTO v_count, v_bytes
      FROM oltp.forum_attachments WHERE post_id = NEW.post_id;
    v_scope := 'post ' || NEW.post_id;
  ELSE
    SELECT count(*), coalesce(sum(size_bytes),0) INTO v_count, v_bytes
      FROM oltp.forum_attachments WHERE comment_id = NEW.comment_id;
    v_scope := 'comment ' || NEW.comment_id;
  END IF;

  IF v_count >= c_max_files THEN
    RAISE EXCEPTION '% already carries % attachment(s), the limit is %', v_scope, v_count, c_max_files;
  END IF;
  IF v_bytes + NEW.size_bytes > c_max_bytes THEN
    RAISE EXCEPTION '% would reach % bytes, the limit is %', v_scope, v_bytes + NEW.size_bytes, c_max_bytes;
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_forum_attachments_quota
  BEFORE INSERT ON oltp.forum_attachments
  FOR EACH ROW EXECUTE FUNCTION oltp.enforce_attachment_quota();


-- =====================================================================
-- Part 3 — thread integrity (closes C2, C3)
-- =====================================================================
-- C2: a reply could hang under a comment belonging to a different post,
-- because parent_comment_id referenced comment_id alone.
--
-- The fix has a precedent in this schema: oltp.scores uses a composite
-- FK (match_id, team_id) into match_teams so a score cannot be recorded
-- for a team that is not in that match. Same shape here.
ALTER TABLE oltp.forum_comments
  ADD CONSTRAINT uq_forum_comments_post_comment UNIQUE (post_id, comment_id);

ALTER TABLE oltp.forum_comments
  DROP CONSTRAINT forum_comments_parent_comment_id_fkey;

ALTER TABLE oltp.forum_comments
  ADD CONSTRAINT fk_forum_comments_parent_same_post
  FOREIGN KEY (post_id, parent_comment_id)
  REFERENCES oltp.forum_comments(post_id, comment_id) ON DELETE CASCADE;

-- C3: the trivial cycle is a one-row comparison, so a CHECK reaches it.
ALTER TABLE oltp.forum_comments
  ADD CONSTRAINT ck_forum_comments_not_self_parent
  CHECK (parent_comment_id IS DISTINCT FROM comment_id);

-- Longer cycles (A -> B -> A) cannot be seen by any constraint: every
-- individual reference is valid. Walking the ancestry is the only way.
CREATE OR REPLACE FUNCTION oltp.enforce_comment_acyclic() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $fn$
DECLARE v_cursor BIGINT; v_depth INT := 0;
BEGIN
  IF NEW.parent_comment_id IS NULL THEN RETURN NEW; END IF;
  v_cursor := NEW.parent_comment_id;
  WHILE v_cursor IS NOT NULL LOOP
    IF v_cursor = NEW.comment_id THEN
      RAISE EXCEPTION 'comment % cannot descend from itself', NEW.comment_id
        USING HINT = 'a cycle would make any recursive walk of the thread run forever';
    END IF;
    v_depth := v_depth + 1;
    IF v_depth > 100 THEN
      RAISE EXCEPTION 'reply chain deeper than 100 above comment %', NEW.comment_id;
    END IF;
    SELECT parent_comment_id INTO v_cursor FROM oltp.forum_comments WHERE comment_id = v_cursor;
  END LOOP;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_forum_comments_acyclic
  BEFORE INSERT OR UPDATE ON oltp.forum_comments
  FOR EACH ROW EXECUTE FUNCTION oltp.enforce_comment_acyclic();


-- =====================================================================
-- Part 4 — flags and copies nobody enforces (closes P2, P4, T5)
-- =====================================================================

-- ---- P4: an edit cannot precede the thing it edits -------------------
ALTER TABLE oltp.forum_posts
  ADD CONSTRAINT ck_forum_posts_edited_after_created
  CHECK (edited_at IS NULL OR edited_at >= created_at);
ALTER TABLE oltp.forum_comments
  ADD CONSTRAINT ck_forum_comments_edited_after_created
  CHECK (edited_at IS NULL OR edited_at >= created_at);

-- ---- P2: make the safe read the easy one -----------------------------
-- HONEST LIMIT: a view does not PREVENT anyone selecting the base table.
-- It removes the excuse -- the filtered path becomes the obvious one and
-- the one to point new code at. Genuinely preventing it needs RLS, which
-- is an authorisation decision the project has not taken (the RLS
-- example in 01_oltp_schema.sql is still commented out).
CREATE VIEW oltp.vw_forum_posts_visible AS
  SELECT * FROM oltp.forum_posts WHERE NOT is_deleted;

CREATE VIEW oltp.vw_forum_comments_visible AS
  SELECT c.* FROM oltp.forum_comments c
  JOIN oltp.forum_posts p ON p.post_id = c.post_id
  WHERE NOT c.is_deleted AND NOT p.is_deleted;

COMMENT ON VIEW oltp.vw_forum_comments_visible IS
  'Comments that are themselves undeleted AND whose post is undeleted. The flag did not propagate down '
  'the thread, so a moderated post kept showing its replies; this view closes that.';

-- ---- T5: a post may only wear tags from its own category -------------
-- The junction deliberately did not repeat category_id, on the grounds
-- that a bare copy could drift from its two parents.
--
-- That reasoning was right about a BARE copy and wrong about the fix. A
-- copy pinned by two composite FKs cannot drift: both parents must agree
-- with it, so disagreement is unrepresentable rather than merely
-- discouraged. This replaces the earlier comment in 01_oltp_schema.sql.
ALTER TABLE oltp.forum_posts ADD CONSTRAINT uq_forum_posts_category_post UNIQUE (category_id, post_id);
ALTER TABLE oltp.forum_tags  ADD CONSTRAINT uq_forum_tags_category_tag   UNIQUE (category_id, tag_id);

ALTER TABLE oltp.forum_post_tags ADD COLUMN category_id SMALLINT;
UPDATE oltp.forum_post_tags pt
   SET category_id = (SELECT p.category_id FROM oltp.forum_posts p WHERE p.post_id = pt.post_id)
 WHERE pt.category_id IS NULL;

-- Any row where the post and the tag disagreed cannot satisfy both FKs.
-- Removing them is the migration's decision to make explicit, not to
-- perform silently: they are reported first.
DO $$
DECLARE v_bad INT;
BEGIN
  SELECT count(*) INTO v_bad
  FROM oltp.forum_post_tags pt
  JOIN oltp.forum_tags t ON t.tag_id = pt.tag_id
  WHERE t.category_id IS DISTINCT FROM pt.category_id;
  IF v_bad > 0 THEN
    RAISE NOTICE 'R6: % cross-category post/tag pairing(s) will be removed -- they were never valid', v_bad;
    DELETE FROM oltp.forum_post_tags pt
     USING oltp.forum_tags t
     WHERE t.tag_id = pt.tag_id AND t.category_id IS DISTINCT FROM pt.category_id;
  END IF;
END $$;

ALTER TABLE oltp.forum_post_tags ALTER COLUMN category_id SET NOT NULL;
ALTER TABLE oltp.forum_post_tags DROP CONSTRAINT forum_post_tags_post_id_fkey;
ALTER TABLE oltp.forum_post_tags DROP CONSTRAINT forum_post_tags_tag_id_fkey;
ALTER TABLE oltp.forum_post_tags
  ADD CONSTRAINT fk_forum_post_tags_post FOREIGN KEY (category_id, post_id)
  REFERENCES oltp.forum_posts(category_id, post_id) ON DELETE CASCADE;
ALTER TABLE oltp.forum_post_tags
  ADD CONSTRAINT fk_forum_post_tags_tag FOREIGN KEY (category_id, tag_id)
  REFERENCES oltp.forum_tags(category_id, tag_id) ON DELETE CASCADE;


-- =====================================================================
-- WHAT THIS DOES NOT ESTABLISH -- read before approving
-- =====================================================================
--   * storage_key back-fill: pre-existing attachments get a marker that
--     resolves to nothing. They are unreconcilable from the database
--     alone; someone has to compare against the bucket. Deliberately
--     obvious rather than plausible.
--   * uploaded_by back-fill: inferred from the parent's author. Usually
--     right, never verified -- the same trust shape as R2 and R5.
--   * The mime allowlist CONTENTS and the quota NUMBERS (10 files,
--     8 MB) are proposals. Both are editable without a migration, which
--     is why they are a table and a pair of named constants.
--   * P2's views make the safe path easy, not mandatory. Only RLS makes
--     it mandatory, and that decision is still open.
--
-- KNOCK-ON -- MEASURED, see R6_forum.verify.sql:
--   * db/qa_forum.sql now fails at its own GAP demonstrations (U6, U8,
--     C2, C3, T5 deliberately do what this patch forbids). Those cases
--     should be rewritten as paired negatives, which the verify file
--     already does.
--   * db/99_tests.sql: the schema-drift manifest will list every new
--     column and table. Adopting R6 means adding them with an origin --
--     the review step the manifest exists to force.
--   * Part 1 changes the attachment INSERT shape: storage_key and
--     uploaded_by_account_id are now required. Every fixture that
--     inserts an attachment needs both.
-- =====================================================================
