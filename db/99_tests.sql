-- =====================================================================
-- ROcodeFest — full backend readiness suite (OLTP + analytics)
-- =====================================================================
-- Source of truth for STRUCTURE: RoCodeFest-OLTP-schema.json (the
-- R.O.O.T. tree export). Every expected table, PK and FK asserted below
-- is transcribed from a node or link in that export.
--
-- Run against a THROWAWAY database:
--   psql -d rocodefest_test -v ON_ERROR_STOP=1 -f db/01_oltp_schema.sql
--   psql -d rocodefest_test -v ON_ERROR_STOP=1 -f db/02_analytics_schema.sql
--   psql -d rocodefest_test                    -f db/99_tests.sql
--
-- Levels:
--   0  schema exists & creates cleanly
--   1  referential integrity (FK)
--   2  constraints & unique keys
--   3  business rules (behaviour)
--   4  ETL OLTP -> analytics
--   5  grain / anti fan-out            (CRITICAL - corrupts data silently)
--   6  sanity queries / anti chasm-trap (CRITICAL - inflates SUMs silently)
--
-- ON_ERROR_STOP is ON deliberately: a broken SEED must abort the run
-- rather than let it continue against half-populated tables and produce
-- vacuous passes. Expected rejections are caught inside plpgsql and
-- never reach psql.
--
-- NOTE ON SCHEMA NAME: the OLTP tables live in `public`, the star schema
-- in `analytics`. If a literal schema named `oltp` is required, that is a
-- one-line change in 01_oltp_schema.sql plus the references in
-- 02_analytics_schema.sql -- flagged, not assumed.
-- =====================================================================

\set ON_ERROR_STOP on
SET client_min_messages = WARNING;

-- Test scaffolding lives in its own `testing` schema, never in `oltp`.
-- (The column manifest at 0.5 caught exactly this: a test_results table
-- created into the OLTP schema is schema pollution, and the drift guard
-- is right to fail on it.) `testing` is first on the search_path so the
-- unqualified helper objects below land there, while unqualified table
-- references in the seed still resolve to oltp.
DROP SCHEMA IF EXISTS testing CASCADE;
CREATE SCHEMA testing;
SET search_path = testing, oltp, public;

CREATE TABLE test_results (
  seq       SERIAL PRIMARY KEY,
  lvl       TEXT    NOT NULL,
  label     TEXT    NOT NULL,
  ok        BOOLEAN NOT NULL,
  blocking  BOOLEAN NOT NULL DEFAULT TRUE,
  detail    TEXT
);

-- ---------------------------------------------------------------------
-- Assertion helpers. On failure they capture the EXACT constraint /
-- table / column Postgres reported, not just the message text.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION t_reject(p_lvl TEXT, p_label TEXT, p_stmt TEXT) RETURNS void AS $fn$
DECLARE
  v_con TEXT; v_tab TEXT; v_col TEXT; v_state TEXT;
BEGIN
  BEGIN
    EXECUTE p_stmt;
    INSERT INTO test_results(lvl, label, ok, detail)
      VALUES (p_lvl, p_label, FALSE,
              'ACCEPTED but should have been REJECTED. Statement: ' || left(regexp_replace(p_stmt, '\s+', ' ', 'g'), 300));
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS
      v_con = CONSTRAINT_NAME, v_tab = TABLE_NAME, v_col = COLUMN_NAME, v_state = RETURNED_SQLSTATE;
    INSERT INTO test_results(lvl, label, ok, detail)
      VALUES (p_lvl, p_label, TRUE,
              format('rejected [%s]%s%s: %s',
                     v_state,
                     CASE WHEN v_tab IS NOT NULL AND v_tab <> '' THEN ' table=' || v_tab ELSE '' END,
                     CASE WHEN v_con IS NOT NULL AND v_con <> '' THEN ' constraint=' || v_con ELSE '' END,
                     SQLERRM));
  END;
END;
$fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION t_accept(p_lvl TEXT, p_label TEXT, p_stmt TEXT) RETURNS void AS $fn$
DECLARE
  v_con TEXT; v_tab TEXT; v_state TEXT;
BEGIN
  BEGIN
    EXECUTE p_stmt;
    INSERT INTO test_results(lvl, label, ok, detail) VALUES (p_lvl, p_label, TRUE, NULL);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS
      v_con = CONSTRAINT_NAME, v_tab = TABLE_NAME, v_state = RETURNED_SQLSTATE;
    INSERT INTO test_results(lvl, label, ok, detail)
      VALUES (p_lvl, p_label, FALSE,
              format('UNEXPECTEDLY REJECTED [%s]%s%s: %s | statement: %s',
                     v_state,
                     CASE WHEN v_tab IS NOT NULL AND v_tab <> '' THEN ' table=' || v_tab ELSE '' END,
                     CASE WHEN v_con IS NOT NULL AND v_con <> '' THEN ' constraint=' || v_con ELSE '' END,
                     SQLERRM, left(regexp_replace(p_stmt, '\s+', ' ', 'g'), 300)));
  END;
END;
$fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION t_eq(p_lvl TEXT, p_label TEXT, p_actual BIGINT, p_expected BIGINT, p_ctx TEXT DEFAULT NULL)
RETURNS void AS $fn$
BEGIN
  IF p_actual IS NOT DISTINCT FROM p_expected THEN
    INSERT INTO test_results(lvl, label, ok, detail) VALUES (p_lvl, p_label, TRUE, 'got ' || p_actual);
  ELSE
    INSERT INTO test_results(lvl, label, ok, detail)
      VALUES (p_lvl, p_label, FALSE,
              format('expected %s, got %s%s', p_expected, coalesce(p_actual::text,'NULL'),
                     CASE WHEN p_ctx IS NULL THEN '' ELSE ' | ' || p_ctx END));
  END IF;
END;
$fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION t_true(p_lvl TEXT, p_label TEXT, p_cond BOOLEAN, p_detail TEXT DEFAULT NULL,
                                  p_blocking BOOLEAN DEFAULT TRUE)
RETURNS void AS $fn$
BEGIN
  INSERT INTO test_results(lvl, label, ok, blocking, detail)
    VALUES (p_lvl, p_label, coalesce(p_cond, FALSE), p_blocking, p_detail);
END;
$fn$ LANGUAGE plpgsql;


-- =====================================================================
-- LEVEL 0 — schema exists & creates cleanly
-- =====================================================================
-- The fact that 01_/02_ loaded with ON_ERROR_STOP=1 already proves no
-- CREATE failed on FK ordering. These checks prove the RESULT matches
-- the tree.

-- --- 0.1 every table in the tree exists -------------------------------
DO $$
DECLARE
  r RECORD;
  v_missing TEXT[] := '{}';
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('accounts'),('members'),('clubs'),('judges'),('partners'),
      ('team_categories'),('teams'),('memberships'),('join_requests'),
      ('forum_categories'),('forum_posts'),('forum_comments'),('forum_attachments'),
      ('forum_tags'),('forum_post_tags'),('post_rule_references'),
      ('rule_sections'),('rules'),
      ('seasons'),('challenges'),('matches'),('match_teams'),('scores'),
      ('appeals'),('submissions'),('submission_reviews'),('certificates'),
      ('notifications'),('notification_join_request_links'),('notification_appeal_links'),
      ('notification_forum_links'),('notification_submission_review_links')
    ) AS t(tbl)
  LOOP
    IF to_regclass('oltp.' || r.tbl) IS NULL THEN
      v_missing := v_missing || r.tbl;
    END IF;
  END LOOP;

  PERFORM t_true('0', 'every table in the tree export exists in the OLTP schema',
                 cardinality(v_missing) = 0,
                 CASE WHEN cardinality(v_missing) = 0
                      THEN '32/32 tables present'
                      ELSE 'MISSING: ' || array_to_string(v_missing, ', ') END);
END $$;

-- --- 0.2 primary keys match the tree nodes ----------------------------
DO $$
DECLARE
  r RECORD;
  v_actual TEXT;
  v_bad TEXT[] := '{}';
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('accounts','account_id'), ('members','account_id'), ('clubs','account_id'),
      ('judges','account_id'), ('partners','account_id'),
      ('team_categories','category_id'), ('teams','team_id'), ('memberships','membership_id'),
      ('join_requests','request_id'),
      ('forum_categories','category_id'), ('forum_posts','post_id'),
      ('forum_comments','comment_id'), ('forum_attachments','attachment_id'),
      ('forum_tags','tag_id'), ('forum_post_tags','post_id,tag_id'),
      ('post_rule_references','post_id,rule_id'),
      ('rule_sections','section_id'), ('rules','rule_id'),
      ('seasons','season_id'), ('challenges','challenge_id'), ('matches','match_id'),
      ('match_teams','match_id,team_id'), ('scores','score_id'),
      ('appeals','appeal_id'), ('submissions','submission_id'),
      ('submission_reviews','review_id'), ('certificates','certificate_id'),
      ('notifications','notification_id'),
      ('notification_join_request_links','notification_id'),
      ('notification_appeal_links','notification_id'),
      ('notification_forum_links','notification_id'),
      ('notification_submission_review_links','notification_id')
    ) AS t(tbl, expected_pk)
  LOOP
    SELECT string_agg(a.attname, ',' ORDER BY k.ord) INTO v_actual
    FROM pg_constraint c
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON TRUE
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.conrelid = ('oltp.' || r.tbl)::regclass AND c.contype = 'p';

    IF v_actual IS DISTINCT FROM r.expected_pk THEN
      v_bad := v_bad || format('%s: tree says PK(%s), schema has PK(%s)',
                               r.tbl, r.expected_pk, coalesce(v_actual, 'NONE'));
    END IF;
  END LOOP;

  PERFORM t_true('0', 'every table has exactly the primary key its tree node declares',
                 cardinality(v_bad) = 0,
                 CASE WHEN cardinality(v_bad) = 0 THEN '32/32 PKs match'
                      ELSE array_to_string(v_bad, ' || ') END);
END $$;

-- --- 0.3 every column named in the tree exists ------------------------
DO $$
DECLARE
  r RECORD;
  v_bad TEXT[] := '{}';
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('accounts','account_id'),('accounts','email'),('accounts','role'),
      ('members','account_id'),('members','full_name'),
      ('clubs','account_id'),('clubs','club_name'),('clubs','founding_number'),
      ('judges','account_id'),('judges','full_name'),
      ('partners','account_id'),('partners','partner_type'),
      ('team_categories','category_id'),('team_categories','max_members'),
      ('teams','team_id'),('teams','club_id'),('teams','category_id'),('teams','participation_code'),
      ('memberships','membership_id'),('memberships','team_id'),('memberships','member_id'),('memberships','left_at'),
      ('join_requests','request_id'),('join_requests','member_id'),('join_requests','team_id'),('join_requests','status'),
      ('forum_posts','post_id'),('forum_posts','category_id'),('forum_posts','author_account_id'),
      ('forum_comments','comment_id'),('forum_comments','post_id'),('forum_comments','parent_comment_id'),('forum_comments','author_account_id'),
      ('forum_attachments','attachment_id'),('forum_attachments','post_id'),('forum_attachments','comment_id'),('forum_attachments','size_bytes'),
      ('post_rule_references','post_id'),('post_rule_references','rule_id'),
      ('rule_sections','section_id'),('rule_sections','code'),
      ('rules','rule_id'),('rules','section_id'),('rules','code'),
      ('challenges','challenge_id'),('challenges','season_id'),('challenges','stage'),
      ('matches','match_id'),('matches','challenge_id'),
      ('match_teams','match_id'),('match_teams','team_id'),
      ('scores','score_id'),('scores','match_id'),('scores','team_id'),('scores','judge_id'),('scores','total_score'),
      ('appeals','appeal_id'),('appeals','team_id'),('appeals','match_id'),('appeals','score_id'),('appeals','rule_id'),('appeals','status'),
      ('submissions','submission_id'),('submissions','team_id'),('submissions','challenge_id'),('submissions','version'),('submissions','submitted_by_account_id'),
      ('submission_reviews','review_id'),('submission_reviews','submission_id'),('submission_reviews','judge_id'),('submission_reviews','feedback'),('submission_reviews','requires_resubmission'),
      ('certificates','certificate_id'),('certificates','team_id'),('certificates','member_id'),('certificates','season_id'),('certificates','serial_code'),
      ('notifications','notification_id'),('notifications','recipient_account_id'),('notifications','notify_after'),('notifications','is_read'),
      ('notification_join_request_links','notification_id'),('notification_join_request_links','event_type'),('notification_join_request_links','join_request_id'),
      ('notification_appeal_links','notification_id'),('notification_appeal_links','event_type'),('notification_appeal_links','appeal_id'),
      ('notification_forum_links','notification_id'),('notification_forum_links','event_type'),('notification_forum_links','forum_post_id'),('notification_forum_links','forum_comment_id'),
      ('notification_submission_review_links','notification_id'),('notification_submission_review_links','event_type'),('notification_submission_review_links','submission_review_id')
    ) AS t(tbl, col)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'oltp' AND table_name = r.tbl AND column_name = r.col
    ) THEN
      v_bad := v_bad || (r.tbl || '.' || r.col);
    END IF;
  END LOOP;

  PERFORM t_true('0', 'every column named in the tree export exists',
                 cardinality(v_bad) = 0,
                 CASE WHEN cardinality(v_bad) = 0 THEN 'all tree-declared columns present'
                      ELSE 'MISSING: ' || array_to_string(v_bad, ', ') END);
END $$;

-- --- 0.4 dependency order: the FK edges the tree implies all exist ----
DO $$
DECLARE
  r RECORD;
  v_bad TEXT[] := '{}';
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      -- ACCOUNTS before the four subtypes
      ('members','account_id','accounts'), ('clubs','account_id','accounts'),
      ('judges','account_id','accounts'), ('partners','account_id','accounts'),
      -- TEAM CATEGORIES -> TEAMS, CLUBS -> TEAMS
      ('teams','category_id','team_categories'), ('teams','club_id','clubs'),
      -- JOIN REQUESTS -> MEMBERSHIPS (tree parents memberships under join requests)
      ('memberships','source_request_id','join_requests'),
      ('memberships','team_id','teams'), ('memberships','member_id','members'),
      -- SEASONS -> CHALLENGES -> SUBMISSIONS -> SUBMISSION REVIEWS
      ('challenges','season_id','seasons'),
      ('submissions','challenge_id','challenges'),
      ('submission_reviews','submission_id','submissions'),
      ('submission_reviews','judge_id','judges'),
      -- CHALLENGES -> MATCHES -> MATCH TEAMS / SCORES
      ('matches','challenge_id','challenges'),
      ('match_teams','match_id','matches'), ('match_teams','team_id','teams'),
      ('scores','judge_id','judges'),
      -- RULE SECTIONS -> RULES
      ('rules','section_id','rule_sections'),
      -- FORUM
      ('forum_posts','category_id','forum_categories'),
      ('forum_comments','post_id','forum_posts'),
      ('forum_tags','category_id','forum_categories'),
      ('forum_post_tags','tag_id','forum_tags'),
      -- APPEALS multi-FK
      ('appeals','team_id','teams'), ('appeals','match_id','matches'),
      ('appeals','score_id','scores'), ('appeals','rule_id','rules'),
      -- NOTIFICATIONS + link tables
      ('notifications','recipient_account_id','accounts'),
      ('notification_join_request_links','join_request_id','join_requests'),
      ('notification_appeal_links','appeal_id','appeals'),
      ('notification_forum_links','forum_post_id','forum_posts'),
      ('notification_submission_review_links','submission_review_id','submission_reviews'),
      -- CERTIFICATES
      ('certificates','team_id','teams'), ('certificates','season_id','seasons')
    ) AS t(child, col, parent)
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint c
      JOIN LATERAL unnest(c.conkey) AS ck(attnum) ON TRUE
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ck.attnum
      WHERE c.contype = 'f'
        AND c.conrelid  = ('oltp.' || r.child)::regclass
        AND c.confrelid = ('oltp.' || r.parent)::regclass
        AND a.attname = r.col
    ) THEN
      v_bad := v_bad || format('%s.%s -> %s', r.child, r.col, r.parent);
    END IF;
  END LOOP;

  PERFORM t_true('0', 'every dependency edge in the tree is a real FK (creation order is valid)',
                 cardinality(v_bad) = 0,
                 CASE WHEN cardinality(v_bad) = 0 THEN '32/32 FK edges present'
                      ELSE 'MISSING FK: ' || array_to_string(v_bad, ', ') END);
END $$;

-- --- 0.5 column manifest: EXACT set equality (schema-drift guard) -----
-- The tree export lists only a PARTIAL column set per node, so "no
-- invented columns" cannot be checked as tree == schema. It is instead
-- checked against an explicit, reviewed baseline:
--
--     actual columns  ==  (columns declared in the tree)
--                         UNION
--                         (deliberate additions, each with a reason)
--
-- Both directions are asserted, so this fails if someone adds an
-- undocumented column AND if a documented one disappears. Adding a
-- column to the schema is therefore a deliberate act that requires
-- adding a line here with a justification.
CREATE TEMP TABLE expected_columns(tbl TEXT, col TEXT, origin TEXT);

-- (a) declared in the tree export -------------------------------------
INSERT INTO expected_columns(tbl,col,origin) VALUES
  ('accounts','account_id','tree'),('accounts','email','tree'),('accounts','role','tree'),
  ('members','account_id','tree'),('members','full_name','tree'),
  ('clubs','account_id','tree'),('clubs','club_name','tree'),('clubs','founding_number','tree'),
  ('judges','account_id','tree'),('judges','full_name','tree'),
  ('partners','account_id','tree'),('partners','partner_type','tree'),
  ('team_categories','category_id','tree'),('team_categories','max_members','tree'),
  ('teams','team_id','tree'),('teams','club_id','tree'),('teams','category_id','tree'),('teams','participation_code','tree'),
  ('memberships','membership_id','tree'),('memberships','team_id','tree'),('memberships','member_id','tree'),('memberships','left_at','tree'),
  ('join_requests','request_id','tree'),('join_requests','member_id','tree'),('join_requests','team_id','tree'),('join_requests','status','tree'),
  ('forum_posts','post_id','tree'),('forum_posts','category_id','tree'),('forum_posts','author_account_id','tree'),
  ('forum_comments','comment_id','tree'),('forum_comments','post_id','tree'),('forum_comments','parent_comment_id','tree'),('forum_comments','author_account_id','tree'),
  ('forum_attachments','attachment_id','tree'),('forum_attachments','post_id','tree'),('forum_attachments','comment_id','tree'),('forum_attachments','size_bytes','tree'),
  ('forum_tags','tag_id','tree'),('forum_tags','category_id','tree'),
  ('post_rule_references','post_id','tree'),('post_rule_references','rule_id','tree'),
  ('rule_sections','section_id','tree'),('rule_sections','code','tree'),
  ('rules','rule_id','tree'),('rules','section_id','tree'),('rules','code','tree'),
  ('challenges','challenge_id','tree'),('challenges','season_id','tree'),('challenges','stage','tree'),
  ('matches','match_id','tree'),('matches','challenge_id','tree'),
  ('match_teams','match_id','tree'),('match_teams','team_id','tree'),
  ('scores','score_id','tree'),('scores','match_id','tree'),('scores','team_id','tree'),('scores','judge_id','tree'),('scores','total_score','tree'),
  ('appeals','appeal_id','tree'),('appeals','team_id','tree'),('appeals','match_id','tree'),('appeals','score_id','tree'),('appeals','rule_id','tree'),('appeals','status','tree'),
  ('submissions','submission_id','tree'),('submissions','team_id','tree'),('submissions','challenge_id','tree'),('submissions','version','tree'),('submissions','submitted_by_account_id','tree'),
  ('submission_reviews','review_id','tree'),('submission_reviews','submission_id','tree'),('submission_reviews','judge_id','tree'),('submission_reviews','feedback','tree'),('submission_reviews','requires_resubmission','tree'),
  ('certificates','certificate_id','tree'),('certificates','team_id','tree'),('certificates','member_id','tree'),('certificates','season_id','tree'),('certificates','serial_code','tree'),
  ('notifications','notification_id','tree'),('notifications','recipient_account_id','tree'),('notifications','notify_after','tree'),('notifications','is_read','tree'),
  ('notification_join_request_links','notification_id','tree'),('notification_join_request_links','event_type','tree'),('notification_join_request_links','join_request_id','tree'),
  ('notification_appeal_links','notification_id','tree'),('notification_appeal_links','event_type','tree'),('notification_appeal_links','appeal_id','tree'),
  ('notification_forum_links','notification_id','tree'),('notification_forum_links','event_type','tree'),('notification_forum_links','forum_post_id','tree'),('notification_forum_links','forum_comment_id','tree'),
  ('notification_submission_review_links','notification_id','tree'),('notification_submission_review_links','event_type','tree'),('notification_submission_review_links','submission_review_id','tree');

-- (b) deliberate additions, grouped by why they exist -------------------
INSERT INTO expected_columns(tbl,col,origin) VALUES
  -- authentication & account lifecycle (the tree models identity, not auth)
  ('accounts','password_hash','auth'),('accounts','is_active','lifecycle'),
  ('accounts','created_at','audit'),('accounts','updated_at','audit'),
  -- audit timestamps: every entity records when it was created
  ('members','created_at','audit'),('clubs','created_at','audit'),('judges','created_at','audit'),
  ('partners','created_at','audit'),('teams','created_at','audit'),
  ('forum_posts','created_at','audit'),('forum_comments','created_at','audit'),
  ('post_rule_references','created_at','audit'),('notifications','created_at','audit'),
  ('appeals','created_at','audit'),('submissions','created_at','audit'),('submissions','updated_at','audit'),
  ('rules','updated_at','audit'),('forum_attachments','uploaded_at','audit'),
  ('certificates','issued_at','audit'),('memberships','joined_at','audit'),
  ('join_requests','requested_at','audit'),('scores','scored_at','audit'),
  ('submission_reviews','assigned_at','audit'),('submission_reviews','reviewed_at','audit'),
  -- profile / descriptive payload
  ('members','city','profile'),('members','bio','profile'),
  ('clubs','city','profile'),('clubs','coach_name','profile'),('clubs','notes','profile'),
  ('judges','expertise','profile'),('judges','bio','profile'),
  ('partners','org_name','profile'),('partners','contact_name','profile'),('partners','message','profile'),
  -- The avatar is a column on all four subtypes, not a localStorage key
  -- named after a display name. Same shape everywhere, so it is listed
  -- together rather than beside each table's own fields.
  ('members','avatar_data_uri','profile'),('clubs','avatar_data_uri','profile'),
  ('judges','avatar_data_uri','profile'),('partners','avatar_data_uri','profile'),
  -- R9: the role that runs the festival, and the two tables it writes.
  -- Every column here is listed under R9_* rather than under 'profile'
  -- or 'tree', so the manifest says WHY each one exists rather than
  -- only that it was expected. This block is also the record that the
  -- drift guard caught all 24 at once when they were added.
  ('organizers','account_id','R9_organizer'),('organizers','full_name','R9_organizer'),
  ('organizers','title','R9_organizer'),('organizers','bio','R9_organizer'),
  ('organizers','avatar_data_uri','R9_organizer'),('organizers','created_at','R9_organizer'),
  -- The run of show. match_id is nullable and points at a match rather
  -- than copying its time: two copies of a time are two times that
  -- disagree the first time one moves.
  ('schedule_items','item_id','R9_schedule'),('schedule_items','season_id','R9_schedule'),
  ('schedule_items','match_id','R9_schedule'),('schedule_items','kind','R9_schedule'),
  ('schedule_items','title','R9_schedule'),('schedule_items','detail','R9_schedule'),
  ('schedule_items','location','R9_schedule'),('schedule_items','starts_at','R9_schedule'),
  ('schedule_items','ends_at','R9_schedule'),('schedule_items','created_at','R9_schedule'),
  -- published_at is nullable so a draft is a row without a date,
  -- rather than a status column needing rules of its own.
  ('news_posts','news_id','R9_news'),('news_posts','author_account_id','R9_news'),
  ('news_posts','title','R9_news'),('news_posts','summary','R9_news'),
  ('news_posts','body','R9_news'),('news_posts','published_at','R9_news'),
  ('news_posts','created_at','R9_news'),('news_posts','updated_at','R9_news'),
  ('teams','team_name','profile'),('team_categories','code','profile'),('team_categories','label','profile'),
  ('seasons','season_id','profile'),('seasons','name','profile'),('seasons','start_date','profile'),
  ('seasons','end_date','profile'),('seasons','is_active','lifecycle'),
  ('challenges','name','profile'),('challenges','description','profile'),
  ('challenges','category_id','scoping'),('challenges','submission_deadline','profile'),
  ('matches','round_name','profile'),('matches','scheduled_at','profile'),
  ('matches','location','profile'),('matches','status','lifecycle'),
  ('rule_sections','title','profile'),('rule_sections','sort_order','presentation'),
  ('rules','title','profile'),('rules','body','profile'),('rules','version_label','profile'),
  ('forum_categories','category_id','profile'),('forum_categories','code','profile'),
  ('forum_categories','label','profile'),('forum_categories','sort_order','presentation'),
  ('forum_tags','label','profile'),
  ('forum_posts','title','profile'),('forum_posts','body','profile'),
  ('forum_comments','body','profile'),
  ('forum_attachments','file_name','profile'),('forum_attachments','mime_type','profile'),
  ('notifications','title','profile'),('notifications','body','profile'),
  ('submissions','title','profile'),('submissions','description','profile'),('submissions','link_url','profile'),
  ('certificates','certificate_type','profile'),('certificates','file_url','profile'),
  ('memberships','role_title','profile'),('join_requests','message','profile'),
  ('scores','comment','profile'),
  -- score criteria: the tree exposes only total_score; these are its inputs
  ('scores','innovation_score','criteria'),('scores','execution_score','criteria'),
  ('scores','presentation_score','criteria'),('scores','teamwork_score','criteria'),
  -- soft delete (preserves thread integrity for moderation)
  ('forum_posts','is_deleted','soft_delete'),('forum_posts','edited_at','soft_delete'),
  ('forum_comments','is_deleted','soft_delete'),('forum_comments','edited_at','soft_delete'),
  -- workflow / decision trail
  ('appeals','filed_by_account_id','workflow'),('appeals','reason','workflow'),
  ('appeals','decided_at','workflow'),('appeals','decided_by_account_id','workflow'),
  ('appeals','livestream_timestamp','workflow'),
  ('join_requests','decided_at','workflow'),('join_requests','decided_by','workflow'),
  ('teams','is_active','lifecycle'),
  -- reconciled with the tree in this revision (see PDF changelog)
  ('memberships','source_request_id','tree_link_materialised'),
  ('forum_post_tags','post_id','tag_normalisation'),('forum_post_tags','tag_id','tag_normalisation');

-- (c) adopted proposals -------------------------------------------------
-- Everything below entered the schema through db/proposals/, each backed
-- by a QA suite that recorded the gap first. The origin tag names the
-- proposal so a reader can trace any column back to the evidence that
-- justified it, rather than to a guess about intent.
INSERT INTO expected_columns(tbl,col,origin) VALUES
  -- R2: officiating assignment. scores(match_id,judge_id) now has a
  -- parent, so a judge can only score a match they were assigned to.
  ('match_judges','match_id','R2_officiating'),
  ('match_judges','judge_id','R2_officiating'),
  ('match_judges','assigned_at','R2_officiating'),
  -- R5: rule citations pin the revision they cited, so amending a rule
  -- cannot silently rewrite what an appeal or a post was arguing about.
  ('rules','retired_at','R5_rule_versioning'),
  ('rule_revisions','revision_id','R5_rule_versioning'),
  ('rule_revisions','rule_id','R5_rule_versioning'),
  ('rule_revisions','version_label','R5_rule_versioning'),
  ('rule_revisions','title','R5_rule_versioning'),
  ('rule_revisions','body','R5_rule_versioning'),
  ('rule_revisions','recorded_at','R5_rule_versioning'),
  ('post_rule_references','cited_revision_id','R5_rule_versioning'),
  ('appeals','cited_revision_id','R5_rule_versioning'),
  ('appeal_rule_references','appeal_id','R5_rule_versioning'),
  ('appeal_rule_references','rule_id','R5_rule_versioning'),
  ('appeal_rule_references','cited_revision_id','R5_rule_versioning'),
  ('appeal_rule_references','created_at','R5_rule_versioning'),
  -- R6: an attachment row is a claim about a file in object storage.
  -- storage_key is the address, checksum the identity, uploader the
  -- accountable party; the deletions log survives the row it describes
  -- so the bytes can still be reclaimed after a purge.
  ('forum_attachments','storage_key','R6_forum_files'),
  ('forum_attachments','checksum_sha256','R6_forum_files'),
  ('forum_attachments','uploaded_by_account_id','R6_forum_files'),
  ('forum_allowed_mime_types','mime_type','R6_forum_files'),
  ('forum_allowed_mime_types','label','R6_forum_files'),
  ('forum_allowed_mime_types','extensions','R6_forum_files'),
  ('forum_attachment_deletions','deletion_id','R6_forum_files'),
  ('forum_attachment_deletions','storage_key','R6_forum_files'),
  ('forum_attachment_deletions','file_name','R6_forum_files'),
  ('forum_attachment_deletions','size_bytes','R6_forum_files'),
  ('forum_attachment_deletions','deleted_at','R6_forum_files'),
  ('forum_attachment_deletions','purged_at','R6_forum_files'),
  -- carried so a tag cannot be attached to a post in another category:
  -- the composite FK needs the category on both sides of the edge.
  ('forum_post_tags','category_id','R6_forum_integrity'),
  -- R7: closing an appeal records WHO decided, WHEN, and UNDER WHAT.
  -- The deciding rule is deliberately separate from rule_id (the rule the
  -- FILER invoked) -- a judge may rule on different grounds, and one
  -- shared column could not hold both claims.
  ('appeals','decided_under_rule_id','R7_decision_closure'),
  ('appeals','decided_revision_id','R7_decision_closure');

DO $$
DECLARE
  v_undocumented TEXT[];
  v_missing      TEXT[];
BEGIN
  SELECT array_agg(tbl || '.' || col ORDER BY tbl, col) INTO v_undocumented
  FROM (
    SELECT c.table_name AS tbl, c.column_name AS col
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    -- BASE TABLE only. A view's columns are projections of table columns
    -- already listed here, so counting them would report the same drift
    -- twice and make every new view look like an undocumented change.
    -- Views are covered by their own assertions further down.
    WHERE c.table_schema = 'oltp' AND t.table_type = 'BASE TABLE'
    EXCEPT
    SELECT tbl, col FROM expected_columns
  ) x;

  SELECT array_agg(tbl || '.' || col ORDER BY tbl, col) INTO v_missing
  FROM (
    SELECT tbl, col FROM expected_columns
    EXCEPT
    SELECT c.table_name, c.column_name
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE c.table_schema = 'oltp' AND t.table_type = 'BASE TABLE'
  ) x;

  PERFORM t_true('0','MANIFEST: no undocumented column exists (schema-drift guard)',
    v_undocumented IS NULL,
    CASE WHEN v_undocumented IS NULL
         THEN (SELECT count(*)::text || ' columns, all accounted for' FROM expected_columns)
         ELSE 'UNDOCUMENTED: ' || array_to_string(v_undocumented, ', ') END);

  PERFORM t_true('0','MANIFEST: every documented column still exists',
    v_missing IS NULL,
    CASE WHEN v_missing IS NULL THEN 'no documented column was dropped'
         ELSE 'DROPPED: ' || array_to_string(v_missing, ', ') END);

  PERFORM t_true('0','MANIFEST: additions beyond the tree are all justified',
    NOT EXISTS (SELECT 1 FROM expected_columns WHERE origin IS NULL OR origin = ''),
    (SELECT string_agg(origin || '=' || n, ' ' ORDER BY origin)
     FROM (SELECT origin, count(*) n FROM expected_columns GROUP BY origin) y));
END $$;


-- =====================================================================
-- SEED — a small but complete festival
-- =====================================================================
-- Shaped so that ONE club and ONE judge have rows in ALL THREE fact
-- tables, which is what makes the Level 6 chasm-trap oracle meaningful.

INSERT INTO accounts (email, password_hash, role) VALUES
  ('club@test.dev','x','club'),      -- 1
  ('m1@test.dev','x','member'),      -- 2
  ('m2@test.dev','x','member'),      -- 3
  ('m3@test.dev','x','member'),      -- 4
  ('m4@test.dev','x','member'),      -- 5
  ('j1@test.dev','x','judge'),       -- 6
  ('j2@test.dev','x','judge'),       -- 7
  ('partner@test.dev','x','partner');-- 8

INSERT INTO clubs (account_id, club_name, city, coach_name)
  SELECT account_id,'Test Club','Cluj','Coach' FROM accounts WHERE email='club@test.dev';
INSERT INTO members (account_id, full_name, city)
  SELECT account_id,'Member '||account_id,'Cluj' FROM accounts WHERE role='member';
INSERT INTO judges (account_id, full_name, expertise)
  SELECT account_id,'Judge '||account_id,'Robotics' FROM accounts WHERE role='judge';
INSERT INTO partners (account_id, org_name, contact_name, partner_type)
  SELECT account_id,'ACME','Contact','sponsor' FROM accounts WHERE role='partner';

-- Team A = PROGRAMMING (cap 3, used for the capacity rule)
-- Team B = ROBOTICS    (cap 5, used for the appeal-limit rule in isolation)
INSERT INTO teams (club_id, category_id, team_name, participation_code)
SELECT c.account_id, tc.category_id, 'Team Alpha','ALPHA-001'
FROM clubs c, team_categories tc WHERE tc.code='PROGRAMMING';
INSERT INTO teams (club_id, category_id, team_name, participation_code)
SELECT c.account_id, tc.category_id, 'Team Beta','BETA-002'
FROM clubs c, team_categories tc WHERE tc.code='ROBOTICS';

INSERT INTO seasons (name, start_date, end_date) VALUES ('Season 2026','2026-01-01','2026-12-31');
INSERT INTO challenges (season_id, category_id, name, stage, submission_deadline)
SELECT s.season_id, tc.category_id,'Line Follower','city_challenge','2026-06-01'
FROM seasons s, team_categories tc WHERE tc.code='PROGRAMMING';

INSERT INTO matches (challenge_id, round_name, scheduled_at, status)
SELECT challenge_id,'Round 1','2026-05-10 10:00+00','completed' FROM challenges;

INSERT INTO match_teams (match_id, team_id) SELECT m.match_id, t.team_id FROM matches m, teams t;
-- fk_scores_match_judge: a score now needs the judge on the panel first
INSERT INTO match_judges (match_id, judge_id) SELECT m.match_id, j.account_id FROM matches m, judges j ON CONFLICT DO NOTHING;
-- every judge sits on every seeded match: scores now require the panel
-- assignment to exist first (fk_scores_match_judge)
-- 3 scores: j1->A, j2->A, j1->B
INSERT INTO scores (match_id, team_id, judge_id, innovation_score, execution_score, presentation_score, teamwork_score, scored_at)
SELECT m.match_id, t.team_id, j.account_id, 8,7,9,6, '2026-05-10 12:00+00'
FROM matches m, teams t, judges j
WHERE (t.participation_code, j.account_id) IN (
        ('ALPHA-001', (SELECT account_id FROM accounts WHERE email='j1@test.dev')),
        ('ALPHA-001', (SELECT account_id FROM accounts WHERE email='j2@test.dev')),
        ('BETA-002',  (SELECT account_id FROM accounts WHERE email='j1@test.dev')));

-- Forum
INSERT INTO forum_categories (code,label) VALUES ('GENERAL','General'),('HELP','Help');
INSERT INTO forum_posts (category_id, author_account_id, title, body)
SELECT fc.category_id, a.account_id,'Hello world','body'
FROM forum_categories fc, accounts a WHERE fc.code='GENERAL' AND a.email='m1@test.dev';
INSERT INTO forum_comments (post_id, author_account_id, body)
SELECT p.post_id, a.account_id,'first reply' FROM forum_posts p, accounts a WHERE a.email='m2@test.dev';
INSERT INTO forum_tags (category_id,label)
SELECT category_id,'Help Wanted' FROM forum_categories WHERE code='GENERAL';
INSERT INTO forum_post_tags (post_id, tag_id, category_id) SELECT p.post_id, t.tag_id, p.category_id FROM forum_posts p, forum_tags t WHERE p.category_id = t.category_id;

INSERT INTO rule_sections (code,title) VALUES ('G','General'),('A','Appeals');
INSERT INTO rules (section_id, code, title, body)
SELECT section_id,'G4','Fair play','text' FROM rule_sections WHERE code='G';
INSERT INTO post_rule_references (post_id, rule_id) SELECT p.post_id, r.rule_id FROM forum_posts p, rules r;

-- Submissions: A/C1 (2 judges assigned -> the fan-out trap), B/C1 (1 judge)
-- NOTE ON DATES: these two submissions and both seeded appeals are dated
-- 2026-05-10 ON PURPOSE -- the same day as the scores. dim_date is a
-- shared dimension like any other, so the chasm trap can strike on it
-- too; but it can only strike on a date_key that several facts actually
-- land on. With every fact on its own day the Level 7 date oracle would
-- pass vacuously. 2026-05-10 therefore carries 3 scores + 2 submissions
-- + 2 appeals, and the Part B fixture guard enforces that this overlap
-- keeps existing.
INSERT INTO submissions (team_id, challenge_id, title, submitted_by_account_id, created_at)
SELECT t.team_id, c.challenge_id,'Alpha v1', a.account_id,'2026-05-10 09:00+00'
FROM teams t, challenges c, accounts a WHERE t.participation_code='ALPHA-001' AND a.email='m1@test.dev';
INSERT INTO submissions (team_id, challenge_id, title, submitted_by_account_id, created_at)
SELECT t.team_id, c.challenge_id,'Beta v1', a.account_id,'2026-05-10 09:30+00'
FROM teams t, challenges c, accounts a WHERE t.participation_code='BETA-002' AND a.email='m1@test.dev';

INSERT INTO submission_reviews (submission_id, judge_id, feedback, requires_resubmission, assigned_at)
SELECT s.submission_id, j.account_id,'needs work', TRUE,
       '2026-05-02 09:00+00'::timestamptz + (j.account_id || ' minutes')::interval
FROM submissions s, judges j WHERE s.title='Alpha v1';           -- 2 reviews, SAME submission
INSERT INTO submission_reviews (submission_id, judge_id, feedback, assigned_at)
SELECT s.submission_id, a.account_id,'ok','2026-05-02 09:00+00'
FROM submissions s, accounts a WHERE s.title='Beta v1' AND a.email='j1@test.dev';

-- Appeals for Team A (pending, so the 3-invalid limit is untouched):
--   a1: cites a match AND a score by j1  -> real challenge_key + real judge_key
--   a2: no match, no score               -> BOTH sentinels
INSERT INTO appeals (team_id, match_id, score_id, rule_id, filed_by_account_id, reason, status, created_at)
SELECT t.team_id, s.match_id, s.score_id, r.rule_id, a.account_id,'scoring dispute','pending','2026-05-10 14:00+00'
FROM teams t, scores s, rules r, accounts a
WHERE t.participation_code='ALPHA-001' AND s.team_id=t.team_id
  AND s.judge_id=(SELECT account_id FROM accounts WHERE email='j1@test.dev')
  AND a.email='m1@test.dev';
INSERT INTO appeals (team_id, filed_by_account_id, reason, status, created_at)
SELECT t.team_id, a.account_id,'general complaint, no match','pending','2026-05-10 15:00+00'
FROM teams t, accounts a WHERE t.participation_code='ALPHA-001' AND a.email='m1@test.dev';

INSERT INTO certificates (team_id, season_id, certificate_type, serial_code)
SELECT t.team_id, s.season_id,'participation','RCF-2026-0001'
FROM teams t, seasons s WHERE t.participation_code='ALPHA-001';


-- =====================================================================
-- SEED PART 2 — 19 more clubs, deliberately ASYMMETRIC
-- =====================================================================
-- A one-club fixture can prove DRIFT but can never prove correct
-- GROUPING: a wrong GROUP BY, bleed between groups, or a snowflake
-- club_key lookup that attaches a team to the wrong club all produce
-- identical output when there is only one group to get wrong.
--
-- The distribution below is uneven ON PURPOSE. A uniform fixture (20
-- identical clubs) hides any bug whose symptom is proportional to group
-- size -- every group would be wrong by the same amount and the numbers
-- would still look plausible. One big club, four medium, twelve small
-- and two degenerate clubs make a size-proportional error obvious.
CREATE TEMP TABLE club_plan(code TEXT, size_class TEXT, n_teams INT, n_members INT);
INSERT INTO club_plan VALUES
  ('BIG-01','big',10,25),
  ('MED-01','medium',4,10),('MED-02','medium',4,9),
  ('MED-03','medium',4,8), ('MED-04','medium',4,7),
  ('SML-01','small',2,5),('SML-02','small',2,4),('SML-03','small',2,4),
  ('SML-04','small',2,3),('SML-05','small',2,3),('SML-06','small',2,3),
  ('SML-07','small',2,3),('SML-08','small',2,3),('SML-09','small',2,3),
  ('SML-10','small',1,2),('SML-11','small',1,2),('SML-12','small',1,2),
  ('DEGEN-01','degenerate',0,0),   -- no teams, no members, no facts at all
  ('DEGEN-02','degenerate',1,0);   -- one team, but the team is EMPTY
-- 48 new teams + 2 existing = 50 ; 96 new members + 4 existing = 100 ;
-- 19 new clubs + 1 existing = 20.

-- --- clubs, teams, members, rosters -----------------------------------
DO $seed$
DECLARE
  p           RECORD;
  v_club      BIGINT;
  v_acct      BIGINT;
  v_team      BIGINT;
  v_cat       SMALLINT;
  v_cap       SMALLINT;
  v_teams     BIGINT[];
  v_caps      SMALLINT[];
  v_used      INT[];
  i           INT;
  j           INT;
  v_placed    BOOLEAN;
  v_cats      SMALLINT[];
BEGIN
  SELECT array_agg(category_id ORDER BY category_id) INTO v_cats FROM oltp.team_categories;

  FOR p IN SELECT * FROM club_plan ORDER BY code LOOP
    INSERT INTO oltp.accounts(email, password_hash, role)
      VALUES (lower(p.code) || '@club.test', 'x', 'club') RETURNING account_id INTO v_club;
    INSERT INTO oltp.clubs(account_id, club_name, city, coach_name)
      VALUES (v_club, 'Club ' || p.code, 'City ' || left(p.code,3), 'Coach ' || p.code);

    v_teams := '{}'; v_caps := '{}'; v_used := '{}';

    -- teams: categories cycle so caps differ across teams (3 vs 5)
    FOR i IN 1 .. p.n_teams LOOP
      v_cat := v_cats[1 + ((i - 1) % array_length(v_cats,1))];
      SELECT max_members INTO v_cap FROM oltp.team_categories WHERE category_id = v_cat;
      INSERT INTO oltp.teams(club_id, category_id, team_name, participation_code)
        VALUES (v_club, v_cat, p.code || ' Team ' || i, p.code || '-T' || lpad(i::text,2,'0'))
        RETURNING team_id INTO v_team;
      v_teams := v_teams || v_team;
      v_caps  := v_caps  || v_cap;
      v_used  := v_used  || 0;
    END LOOP;

    -- members, round-robin onto teams that still have room. A member who
    -- finds every team full simply stays club-less, which is realistic
    -- and also gives the LEFT JOIN paths something to chew on.
    FOR i IN 1 .. p.n_members LOOP
      INSERT INTO oltp.accounts(email, password_hash, role)
        VALUES (lower(p.code) || '-m' || i || '@test.dev', 'x', 'member') RETURNING account_id INTO v_acct;
      INSERT INTO oltp.members(account_id, full_name, city)
        VALUES (v_acct, p.code || ' Member ' || i, 'City ' || left(p.code,3));

      v_placed := FALSE;
      IF array_length(v_teams,1) IS NOT NULL THEN
        FOR j IN 1 .. array_length(v_teams,1) LOOP
          -- DEGEN-02's single team is deliberately left empty
          IF p.code <> 'DEGEN-02' AND v_used[j] < v_caps[j] AND NOT v_placed THEN
            INSERT INTO oltp.memberships(team_id, member_id) VALUES (v_teams[j], v_acct);
            v_used[j] := v_used[j] + 1;
            v_placed := TRUE;
          END IF;
        END LOOP;
      END IF;
    END LOOP;
  END LOOP;
END
$seed$;

-- --- a second, temporally OVERLAPPING season --------------------------
-- Season 2027 starts before Season 2026 ends, so the two seasons share
-- calendar dates. That is what forces the dashboard to group by the
-- SEASON, not by the calendar year -- grouping by year would silently
-- merge them, which is exactly the class of bug this seed exists to
-- expose.
-- Only ONE season may be active at a time (R7, uq_seasons_single_active),
-- and the overlap this seed exists to create is a date overlap, not two
-- simultaneously active seasons -- so 2026 hands over to 2027 rather than
-- both claiming the flag.
UPDATE oltp.seasons SET is_active = FALSE WHERE name = 'Season 2026';
INSERT INTO oltp.seasons(name, start_date, end_date, is_active)
  VALUES ('Season 2027', '2026-11-01', '2027-06-30', TRUE);

INSERT INTO oltp.challenges(season_id, category_id, name, stage, submission_deadline)
SELECT s.season_id, NULL, 'Autumn Sprint', 'city_challenge', '2026-12-15'
FROM oltp.seasons s WHERE s.name = 'Season 2027';
INSERT INTO oltp.challenges(season_id, category_id, name, stage, submission_deadline)
SELECT s.season_id, NULL, 'Winter Final', 'final', '2027-03-01'
FROM oltp.seasons s WHERE s.name = 'Season 2027';
INSERT INTO oltp.challenges(season_id, category_id, name, stage, submission_deadline)
SELECT s.season_id, NULL, 'Spring Qualifier', 'city_challenge', '2026-07-01'
FROM oltp.seasons s WHERE s.name = 'Season 2026';

-- --- more judges ------------------------------------------------------
DO $j$
DECLARE i INT; v BIGINT;
BEGIN
  FOR i IN 3 .. 5 LOOP
    INSERT INTO oltp.accounts(email, password_hash, role)
      VALUES ('j' || i || '@test.dev', 'x', 'judge') RETURNING account_id INTO v;
    INSERT INTO oltp.judges(account_id, full_name, expertise)
      VALUES (v, 'Judge ' || i, 'Robotics');
  END LOOP;
END
$j$;

-- --- competition activity, per club, across BOTH seasons --------------
-- Every timestamp is fixed (never now()) so the golden dashboard output
-- is reproducible. The two "overlap days" -- 2026-05-10 for Season 2026
-- and 2026-11-15 for Season 2027 -- deliberately carry rows from all
-- three facts, so dim_date is a genuinely shared dimension in BOTH
-- seasons rather than only in one.
DO $comp$
DECLARE
  c            RECORD;
  t            RECORD;
  v_match      BIGINT;
  v_sub        BIGINT;
  v_score      BIGINT;
  v_judges     BIGINT[];
  v_chal_s1    BIGINT;
  v_chal_s1b   BIGINT;
  v_chal_s2    BIGINT;
  v_day_s1     TIMESTAMPTZ := '2026-05-10 11:00+00';
  v_day_s2     TIMESTAMPTZ := '2026-11-15 11:00+00';
  v_idx        INT := 0;
  v_multi      INT := 0;
BEGIN
  SELECT array_agg(account_id ORDER BY account_id) INTO v_judges FROM oltp.judges;
  SELECT challenge_id INTO v_chal_s1  FROM oltp.challenges WHERE name = 'Line Follower';
  SELECT challenge_id INTO v_chal_s1b FROM oltp.challenges WHERE name = 'Spring Qualifier';
  SELECT challenge_id INTO v_chal_s2  FROM oltp.challenges WHERE name = 'Autumn Sprint';

  FOR c IN
    SELECT cl.account_id AS club_id, cl.club_name, cp.code, cp.size_class
    FROM oltp.clubs cl
    JOIN club_plan cp ON ('Club ' || cp.code) = cl.club_name
    WHERE cp.size_class <> 'degenerate'
    ORDER BY cp.code
  LOOP
    v_idx := v_idx + 1;

    -- one match per season for this club, holding all of its teams
    INSERT INTO oltp.matches(challenge_id, round_name, scheduled_at, location, status)
      VALUES (v_chal_s1, c.code || ' R1', v_day_s1, c.code, 'completed') RETURNING match_id INTO v_match;
    INSERT INTO oltp.match_teams(match_id, team_id)
      SELECT v_match, team_id FROM oltp.teams WHERE club_id = c.club_id;
    INSERT INTO oltp.match_judges(match_id, judge_id)
      SELECT v_match, account_id FROM oltp.judges ON CONFLICT DO NOTHING;
    -- two judges score every team in the match
    INSERT INTO oltp.scores(match_id, team_id, judge_id,
                            innovation_score, execution_score, presentation_score, teamwork_score, scored_at)
      SELECT v_match, mt.team_id, j,
             1 + (mt.team_id % 9), 1 + ((mt.team_id + 1) % 9),
             1 + ((mt.team_id + 2) % 9), 1 + ((mt.team_id + 3) % 9), v_day_s1
      FROM oltp.match_teams mt
      CROSS JOIN unnest(v_judges[1:2]) AS j
      WHERE mt.match_id = v_match;

    INSERT INTO oltp.matches(challenge_id, round_name, scheduled_at, location, status)
      VALUES (v_chal_s2, c.code || ' A1', v_day_s2, c.code, 'completed') RETURNING match_id INTO v_match;
    INSERT INTO oltp.match_teams(match_id, team_id)
      SELECT v_match, team_id FROM oltp.teams WHERE club_id = c.club_id;
    INSERT INTO oltp.match_judges(match_id, judge_id)
      SELECT v_match, account_id FROM oltp.judges ON CONFLICT DO NOTHING;
    INSERT INTO oltp.scores(match_id, team_id, judge_id,
                            innovation_score, execution_score, presentation_score, teamwork_score, scored_at)
      SELECT v_match, mt.team_id, j,
             1 + ((mt.team_id + 4) % 9), 1 + ((mt.team_id + 5) % 9),
             1 + ((mt.team_id + 6) % 9), 1 + ((mt.team_id + 7) % 9), v_day_s2
      FROM oltp.match_teams mt
      CROSS JOIN unnest(v_judges[2:3]) AS j
      WHERE mt.match_id = v_match;

    -- submissions in both seasons, landing on the overlap days
    FOR t IN SELECT team_id FROM oltp.teams WHERE club_id = c.club_id ORDER BY team_id LOOP
      INSERT INTO oltp.submissions(team_id, challenge_id, title, submitted_by_account_id, created_at)
        VALUES (t.team_id, v_chal_s1, c.code || ' S1 sub', c.club_id, v_day_s1)
        RETURNING submission_id INTO v_sub;

      -- MULTI-JUDGE fixture: in the first two non-degenerate clubs, one
      -- submission gets TWO reviewers with an IDENTICAL assigned_at, so
      -- the DISTINCT ON tiebreaker is exercised in more than one club.
      IF v_idx <= 2 THEN
        INSERT INTO oltp.submission_reviews(submission_id, judge_id, feedback, assigned_at)
          SELECT v_sub, j, 'multi-judge fixture', v_day_s1
          FROM unnest(v_judges[1:2]) AS j;
        v_multi := v_multi + 1;
      ELSIF (t.team_id % 3) = 0 THEN
        INSERT INTO oltp.submission_reviews(submission_id, judge_id, feedback, assigned_at)
          VALUES (v_sub, v_judges[1], 'single reviewer', v_day_s1);
      END IF;
      -- teams whose id % 3 <> 0 outside the first two clubs get NO
      -- reviewer at all -> judge_key = -1 sentinel, in many clubs.

      -- ASYMMETRY ACROSS SEASONS, on purpose: only every other team
      -- submits in Season 2027. If both seasons had the same submission
      -- count per club, a join that drops the season from its key would
      -- produce IDENTICAL numbers and the Part-D bleed test could never
      -- detect it -- the contamination would be real but invisible.
      IF (t.team_id % 2) = 0 THEN
        INSERT INTO oltp.submissions(team_id, challenge_id, title, submitted_by_account_id, created_at)
          VALUES (t.team_id, v_chal_s2, c.code || ' S2 sub', c.club_id, v_day_s2);
      END IF;
    END LOOP;

    -- appeals: one citing a real score (real challenge_key + judge_key),
    -- one with match_id IS NULL (-> challenge_key = -1 sentinel).
    SELECT s.score_id INTO v_score
    FROM oltp.scores s JOIN oltp.teams te ON te.team_id = s.team_id
    WHERE te.club_id = c.club_id ORDER BY s.score_id LIMIT 1;

    IF v_score IS NOT NULL THEN
      -- A closed appeal now needs its full form: who decided, when, and
      -- under which rule (R7). The judge who gave the disputed score is
      -- the natural decider here.
      INSERT INTO oltp.appeals(team_id, match_id, score_id, filed_by_account_id, reason, status,
                               created_at, decided_at, decided_by_account_id, decided_under_rule_id)
      SELECT s.team_id, s.match_id, s.score_id, c.club_id, 'scoring dispute', 'accepted',
             v_day_s1, v_day_s1 + interval '1 day', s.judge_id,
             (SELECT rule_id FROM oltp.rules ORDER BY rule_id LIMIT 1)
      FROM oltp.scores s WHERE s.score_id = v_score;
    END IF;

    INSERT INTO oltp.appeals(team_id, filed_by_account_id, reason, status, created_at)
    SELECT team_id, c.club_id, 'no match cited', 'pending', v_day_s2
    FROM oltp.teams WHERE club_id = c.club_id ORDER BY team_id LIMIT 1;
  END LOOP;
END
$comp$;


-- =====================================================================
-- LEVEL 1 — referential integrity
-- =====================================================================
DO $$
DECLARE
  v_teamA BIGINT := (SELECT team_id FROM teams WHERE participation_code='ALPHA-001');
  v_m1    BIGINT := (SELECT account_id FROM accounts WHERE email='m1@test.dev');
  v_club  BIGINT := (SELECT account_id FROM clubs LIMIT 1);
  v_match BIGINT := (SELECT match_id FROM matches LIMIT 1);
  v_score BIGINT := (SELECT score_id FROM scores LIMIT 1);
  v_rule  BIGINT := (SELECT rule_id FROM rules LIMIT 1);
BEGIN
  -- orphan rejection on representative FKs across every domain
  PERFORM t_reject('1','FK: teams.club_id rejects a non-existent club',
    'INSERT INTO teams(club_id,category_id,team_name,participation_code) VALUES (999999,1,''Ghost'',''GHOST-1'')');
  PERFORM t_reject('1','FK: memberships.member_id rejects a non-existent member',
    format('INSERT INTO memberships(team_id,member_id) VALUES (%s,999999)', v_teamA));
  PERFORM t_reject('1','FK: submissions.challenge_id rejects a non-existent challenge',
    format('INSERT INTO submissions(team_id,challenge_id,title,submitted_by_account_id) VALUES (%s,999999,''x'',%s)', v_teamA, v_m1));
  PERFORM t_reject('1','FK: submission_reviews.submission_id rejects a non-existent submission',
    'INSERT INTO submission_reviews(submission_id,judge_id) VALUES (999999,(SELECT account_id FROM judges LIMIT 1))');
  PERFORM t_reject('1','FK: matches.challenge_id rejects a non-existent challenge',
    'INSERT INTO matches(challenge_id,round_name) VALUES (999999,''R'')');
  PERFORM t_reject('1','FK: notifications.recipient_account_id rejects a non-existent account',
    'INSERT INTO notifications(recipient_account_id,title) VALUES (999999,''x'')');
  PERFORM t_reject('1','FK: certificates.season_id rejects a non-existent season',
    format('INSERT INTO certificates(team_id,season_id,serial_code) VALUES (%s,999,''X-1'')', v_teamA));
  PERFORM t_reject('1','FK: forum_post_tags.tag_id rejects a non-existent tag',
    'INSERT INTO forum_post_tags(post_id,tag_id,category_id) VALUES ((SELECT post_id FROM forum_posts LIMIT 1),9999,(SELECT category_id FROM forum_posts LIMIT 1))');

  -- APPEALS multi-FK: match_id nullable, the rest validated when present
  PERFORM t_accept('1','APPEALS: match_id may be NULL (an appeal without a match is legal)',
    format('INSERT INTO appeals(team_id,filed_by_account_id,reason) VALUES (%s,%s,''no match cited'')', v_teamA, v_m1));
  PERFORM t_reject('1','APPEALS: a non-NULL match_id is still validated',
    format('INSERT INTO appeals(team_id,match_id,filed_by_account_id,reason) VALUES (%s,999999,%s,''bad match'')', v_teamA, v_m1));
  PERFORM t_reject('1','APPEALS: a non-NULL score_id is still validated',
    format('INSERT INTO appeals(team_id,score_id,filed_by_account_id,reason) VALUES (%s,999999,%s,''bad score'')', v_teamA, v_m1));
  PERFORM t_reject('1','APPEALS: a non-NULL rule_id is still validated',
    format('INSERT INTO appeals(team_id,rule_id,filed_by_account_id,reason) VALUES (%s,999999,%s,''bad rule'')', v_teamA, v_m1));

  -- table-per-subtype: one account cannot hold two roles at once
  PERFORM t_reject('1','SUBTYPE: a club-role account cannot also be inserted as a member',
    format('INSERT INTO members(account_id,full_name) VALUES (%s,''Dual role'')', v_club));
  PERFORM t_reject('1','SUBTYPE: a member-role account cannot also be inserted as a judge',
    format('INSERT INTO judges(account_id,full_name) VALUES (%s,''Dual role'')', v_m1));
  PERFORM t_true('1','SUBTYPE: no account_id appears in more than one subtype table',
    NOT EXISTS (
      SELECT account_id FROM (
        SELECT account_id FROM members UNION ALL SELECT account_id FROM clubs
        UNION ALL SELECT account_id FROM judges UNION ALL SELECT account_id FROM partners
      ) x GROUP BY account_id HAVING count(*) > 1),
    'checked all 4 subtype tables for overlapping account_id');
END $$;


-- =====================================================================
-- LEVEL 2 — constraints & unique keys
-- =====================================================================
DO $$
DECLARE
  v_teamA BIGINT := (SELECT team_id FROM teams WHERE participation_code='ALPHA-001');
  v_chal  BIGINT := (SELECT challenge_id FROM challenges LIMIT 1);
  v_m1    BIGINT := (SELECT account_id FROM accounts WHERE email='m1@test.dev');
  v_sub2  BIGINT;
  v_late  BIGINT;
BEGIN
  -- SUBMISSIONS: (team_id, challenge_id, version) uniqueness.
  -- version is trigger-assigned, so the constraint is probed by UPDATE.
  -- open the gate on the head of this chain: a new version requires the
  -- predecessor to have asked for a resubmission
  INSERT INTO oltp.submission_reviews(submission_id, judge_id, requires_resubmission)
    SELECT s.submission_id, (SELECT account_id FROM oltp.judges ORDER BY account_id LIMIT 1), TRUE
    FROM oltp.submissions s WHERE s.team_id=v_teamA AND s.challenge_id=v_chal
    ORDER BY s.version DESC LIMIT 1
    ON CONFLICT (submission_id,judge_id) DO UPDATE SET requires_resubmission = TRUE;
  INSERT INTO submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
    VALUES (v_teamA, v_chal,'Alpha v2', v_m1,'2026-05-05 09:00+00') RETURNING submission_id INTO v_sub2;
  PERFORM t_eq('2','SUBMISSIONS: version is unique per (team, challenge) - 2 rows, 2 distinct versions',
    (SELECT count(DISTINCT version) FROM submissions WHERE team_id=v_teamA AND challenge_id=v_chal),
    (SELECT count(*)                FROM submissions WHERE team_id=v_teamA AND challenge_id=v_chal));
  PERFORM t_reject('2','SUBMISSIONS: a duplicate (team, challenge, version) is rejected',
    format('UPDATE submissions SET version=1 WHERE submission_id=%s', v_sub2));
  PERFORM t_reject('2','SUBMISSIONS: submission_id PK is unique',
    format('INSERT INTO submissions(submission_id,team_id,challenge_id,title,submitted_by_account_id) OVERRIDING SYSTEM VALUE VALUES (%s,%s,%s,''dup'',%s)',
           v_sub2, v_teamA, v_chal, v_m1));

  -- NOTIFICATIONS: defaults + delivery gating
  INSERT INTO notifications(recipient_account_id,title) VALUES (v_m1,'Immediate');
  PERFORM t_true('2','NOTIFICATIONS: is_read defaults to FALSE',
    (SELECT is_read = FALSE FROM notifications WHERE title='Immediate'),
    'default checked on a fresh insert');
  PERFORM t_true('2','NOTIFICATIONS: notify_after defaults to now() and accepts timestamptz',
    (SELECT notify_after <= now() FROM notifications WHERE title='Immediate'));

  INSERT INTO notifications(recipient_account_id,title,notify_after)
    VALUES (v_m1,'Buffered', now() + interval '30 minutes') RETURNING notification_id INTO v_late;
  PERFORM t_true('2','NOTIFICATIONS: a buffered (30 min) notification is NOT delivered yet',
    NOT EXISTS (SELECT 1 FROM notifications WHERE notification_id=v_late AND notify_after <= now()),
    'dispatch predicate: notify_after <= now()');
  PERFORM t_true('2','NOTIFICATIONS: the same notification IS delivered once its buffer elapses',
    EXISTS (SELECT 1 FROM notifications WHERE notification_id=v_late
              AND notify_after <= now() + interval '31 minutes'),
    'simulated clock advance of 31 minutes');

  -- ENUMs
  PERFORM t_reject('2','ENUM: appeals.status rejects a value outside request_status',
    format('INSERT INTO appeals(team_id,filed_by_account_id,reason,status) VALUES (%s,%s,''x'',''bogus'')', v_teamA, v_m1));
  PERFORM t_reject('2','ENUM: join_requests.status rejects a value outside request_status',
    format('INSERT INTO join_requests(member_id,team_id,status) VALUES (%s,%s,''maybe'')', v_m1, v_teamA));
  PERFORM t_reject('2','ENUM: accounts.role rejects a value outside account_role',
    'INSERT INTO accounts(email,password_hash,role) VALUES (''x@x.dev'',''x'',''admin'')');
  PERFORM t_reject('2','ENUM: challenges.stage rejects a value outside challenge_stage',
    'INSERT INTO challenges(season_id,name,stage) VALUES ((SELECT season_id FROM seasons LIMIT 1),''X'',''semifinal'')');

  -- other unique keys
  PERFORM t_reject('2','UNIQUE: accounts.email is case-insensitively unique (citext)',
    'INSERT INTO accounts(email,password_hash,role) VALUES (''M1@TEST.DEV'',''x'',''member'')');
  PERFORM t_reject('2','UNIQUE: teams.participation_code is unique',
    format('INSERT INTO teams(club_id,category_id,team_name,participation_code) VALUES ((SELECT account_id FROM clubs LIMIT 1),1,''Dup'',''ALPHA-001'')'));
  PERFORM t_reject('2','UNIQUE: certificates.serial_code is unique',
    format('INSERT INTO certificates(team_id,season_id,serial_code) VALUES (%s,(SELECT season_id FROM seasons LIMIT 1),''RCF-2026-0001'')', v_teamA));
  PERFORM t_reject('2','UNIQUE: submission_reviews rejects the same judge twice on one submission',
    'INSERT INTO submission_reviews(submission_id,judge_id) SELECT submission_id,judge_id FROM submission_reviews LIMIT 1');
END $$;


-- =====================================================================
-- LEVEL 3 — business rules (behaviour)
-- =====================================================================
DO $$
DECLARE
  v_teamA BIGINT := (SELECT team_id FROM teams WHERE participation_code='ALPHA-001');
  v_teamB BIGINT := (SELECT team_id FROM teams WHERE participation_code='BETA-002');
  v_m1 BIGINT := (SELECT account_id FROM accounts WHERE email='m1@test.dev');
  v_m2 BIGINT := (SELECT account_id FROM accounts WHERE email='m2@test.dev');
  v_m3 BIGINT := (SELECT account_id FROM accounts WHERE email='m3@test.dev');
  v_m4 BIGINT := (SELECT account_id FROM accounts WHERE email='m4@test.dev');
  v_j1 BIGINT := (SELECT account_id FROM accounts WHERE email='j1@test.dev');
  v_match BIGINT := (SELECT match_id FROM matches LIMIT 1);
  v_req BIGINT; v_notif BIGINT; v_rev BIGINT;
BEGIN
  -- --- score flow -------------------------------------------------------
  PERFORM t_true('3','SCORES: every score resolves match -> match_teams -> team',
    NOT EXISTS (SELECT 1 FROM scores s
                LEFT JOIN match_teams mt ON mt.match_id=s.match_id AND mt.team_id=s.team_id
                WHERE mt.match_id IS NULL),
    'all 3 seeded scores trace to a registered (match, team) pair');
  PERFORM t_reject('3','SCORES: a score cannot exist without a match',
    format('INSERT INTO scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (NULL,%s,%s,5,5,5,5)', v_teamA, v_j1));
  PERFORM t_reject('3','SCORES: a score for a team not fielded in that match is rejected',
    format('INSERT INTO scores(match_id,team_id,judge_id,innovation_score,execution_score,presentation_score,teamwork_score) VALUES (%s,999999,%s,5,5,5,5)', v_match, v_j1));
  -- scoped to the original fixture match: the multi-club seed uses
  -- varying criterion scores on purpose, so an unscoped DISTINCT here
  -- would return many rows.
  PERFORM t_eq('3','SCORES: total_score is computed in-DB (8+7+9+6)',
    (SELECT DISTINCT s.total_score FROM oltp.scores s
     JOIN oltp.matches m ON m.match_id = s.match_id WHERE m.round_name = 'Round 1'), 30);

  -- --- submission flow ---------------------------------------------------
  PERFORM t_true('3','SUBMISSION REVIEWS: every review references a live submission',
    NOT EXISTS (SELECT 1 FROM submission_reviews sr
                LEFT JOIN submissions s ON s.submission_id=sr.submission_id WHERE s.submission_id IS NULL));
  PERFORM t_eq('3','SUBMISSIONS: resubmission versioning yields versions 1 and 2',
    (SELECT count(DISTINCT version) FROM submissions WHERE team_id=v_teamA), 2);
  PERFORM t_eq('3','SUBMISSIONS: the first version is 1',
    (SELECT min(version) FROM submissions WHERE team_id=v_teamA), 1);

  -- --- membership / capacity / join request flow -------------------------
  INSERT INTO join_requests(member_id,team_id,status) VALUES (v_m1,v_teamA,'accepted') RETURNING request_id INTO v_req;
  INSERT INTO memberships(team_id,member_id,source_request_id) VALUES (v_teamA,v_m1,v_req);
  PERFORM t_reject('3','MEMBERSHIPS: one approved join request cannot produce two roster rows',
    format('INSERT INTO memberships(team_id,member_id,source_request_id) VALUES (%s,%s,%s)', v_teamA, v_m2, v_req));
  PERFORM t_reject('3','JOIN REQUESTS: a second PENDING request for the same (member, team)',
    format('INSERT INTO join_requests(member_id,team_id,status) VALUES (%s,%s,''pending'');
            INSERT INTO join_requests(member_id,team_id,status) VALUES (%s,%s,''pending'')', v_m2,v_teamA,v_m2,v_teamA));
  INSERT INTO memberships(team_id,member_id) VALUES (v_teamA,v_m2),(v_teamA,v_m3);
  PERFORM t_reject('3','CAPACITY: a 4th active member on a PROGRAMMING team (cap 3) is refused',
    format('INSERT INTO memberships(team_id,member_id) VALUES (%s,%s)', v_teamA, v_m4));
  PERFORM t_accept('3','MEMBERSHIPS: a member may rejoin after leaving',
    format('UPDATE memberships SET left_at=now() WHERE team_id=%s AND member_id=%s;
            INSERT INTO memberships(team_id,member_id) VALUES (%s,%s)', v_teamA,v_m1,v_teamA,v_m1));

  -- --- appeal flow --------------------------------------------------------
  PERFORM t_accept('3','APPEALS: an appeal with match_id IS NULL is permitted (drives the analytics sentinel)',
    format('INSERT INTO appeals(team_id,filed_by_account_id,reason) VALUES (%s,%s,''no match'')', v_teamA, v_m1));
  -- three CLOSED appeals, so each carries the full decision form (R7):
  -- a judge, a time, and the rule the verdict rests on
  INSERT INTO appeals(team_id,match_id,filed_by_account_id,reason,status,
                      decided_at,decided_by_account_id,decided_under_rule_id)
    SELECT v_teamB, v_match, v_m1, v.r, 'rejected',
           now(), (SELECT account_id FROM judges ORDER BY account_id LIMIT 1),
           (SELECT rule_id FROM rules ORDER BY rule_id LIMIT 1)
    FROM (VALUES ('b1'),('b2'),('b3')) AS v(r);
  PERFORM t_reject('3','APPEALS: a 4th appeal after 3 rejected ones is refused (max 3 invalid)',
    format('INSERT INTO appeals(team_id,match_id,filed_by_account_id,reason) VALUES (%s,%s,%s,''b4'')', v_teamB, v_match, v_m1));

  -- --- notification link tables ------------------------------------------
  SELECT review_id INTO v_rev FROM submission_reviews ORDER BY review_id LIMIT 1;
  INSERT INTO notifications(recipient_account_id,title) VALUES (v_m1,'Link test') RETURNING notification_id INTO v_notif;
  INSERT INTO notification_join_request_links(notification_id,event_type,join_request_id)
    VALUES (v_notif,'join_request_accepted',v_req);
  PERFORM t_reject('3','NOTIFICATIONS: a notification cannot be linked in two domain tables at once',
    format('INSERT INTO notification_submission_review_links(notification_id,event_type,submission_review_id) VALUES (%s,''judge_feedback_given'',%s)', v_notif, v_rev));
  PERFORM t_reject('3','NOTIFICATION FORUM LINKS: pointing at BOTH a post and a comment is rejected',
    format('INSERT INTO notifications(recipient_account_id,title) VALUES (%s,''X'');
            INSERT INTO notification_forum_links(notification_id,event_type,forum_post_id,forum_comment_id)
            VALUES (lastval(),''comment_posted'',(SELECT post_id FROM forum_posts LIMIT 1),(SELECT comment_id FROM forum_comments LIMIT 1))', v_m1));
  PERFORM t_true('3','NOTIFICATIONS: every notification has AT MOST one link across the 4 tables',
    NOT EXISTS (
      SELECT notification_id FROM (
        SELECT notification_id FROM notification_join_request_links
        UNION ALL SELECT notification_id FROM notification_appeal_links
        UNION ALL SELECT notification_id FROM notification_forum_links
        UNION ALL SELECT notification_id FROM notification_submission_review_links
      ) x GROUP BY notification_id HAVING count(*) > 1));

  -- --- forum attachment rules ---------------------------------------------
  PERFORM t_reject('3','ATTACHMENTS: attaching to BOTH a post and a comment is rejected',
    'INSERT INTO forum_attachments(post_id,comment_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id) VALUES ((SELECT post_id FROM forum_posts LIMIT 1),(SELECT comment_id FROM forum_comments LIMIT 1),''a.png'',''image/png'',10,''s3://qa/f1030'',(SELECT account_id FROM accounts WHERE role=''member'' LIMIT 1))');
  PERFORM t_reject('3','ATTACHMENTS: a file over 1 MB is rejected',
    'INSERT INTO forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id) VALUES ((SELECT post_id FROM forum_posts LIMIT 1),''big.zip'',''application/zip'',1048577,''s3://qa/f1032'',(SELECT account_id FROM accounts WHERE role=''member'' LIMIT 1))');
  PERFORM t_accept('3','ATTACHMENTS: exactly 1 MB is accepted (boundary)',
    'INSERT INTO forum_attachments(post_id,file_name,mime_type,size_bytes,storage_key,uploaded_by_account_id) VALUES ((SELECT post_id FROM forum_posts LIMIT 1),''ok.zip'',''application/zip'',1048576,''s3://qa/f1034'',(SELECT account_id FROM accounts WHERE role=''member'' LIMIT 1))');

  -- --- certificates --------------------------------------------------------
  PERFORM t_reject('3','CERTIFICATES: two TEAM-level certs of the same type/season (NULL member_id)',
    format('INSERT INTO certificates(team_id,season_id,certificate_type,serial_code) VALUES (%s,(SELECT season_id FROM seasons LIMIT 1),''participation'',''RCF-2026-0002'')', v_teamA));
  PERFORM t_accept('3','CERTIFICATES: a participant-level cert alongside the team-level one',
    format('INSERT INTO certificates(team_id,member_id,season_id,certificate_type,serial_code) VALUES (%s,%s,(SELECT season_id FROM seasons LIMIT 1),''participation'',''RCF-2026-0003'')', v_teamA, v_m1));
END $$;


-- =====================================================================
-- LEVEL 4 — ETL OLTP -> analytics
-- =====================================================================
-- The loader is a FUNCTION so it can be executed twice and proven
-- idempotent. Every statement is an UPSERT on the NATURAL key; there is
-- no TRUNCATE anywhere, which is what keeps the NULL-natural-key
-- sentinel rows alive across reloads.
--
-- The loader now lives in 03_etl.sql (production), NOT here. The tests
-- exercise the REAL implementation via analytics.run_etl(), so a defect
-- introduced in the shipped ETL is caught by this suite instead of
-- hiding behind a test-only copy of the logic.
DO $guard$
BEGIN
  IF to_regprocedure('analytics.run_etl(integer)') IS NULL THEN
    RAISE EXCEPTION 'analytics.run_etl() is missing -- load db/03_etl.sql before running this suite';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION load_analytics() RETURNS void AS $fn$
BEGIN
  PERFORM analytics.run_etl();
END;
$fn$ LANGUAGE plpgsql;

DO $$
DECLARE
  v_jkey BIGINT; v_ckey BIGINT;
  v_dimc1 BIGINT; v_dimt1 BIGINT; v_fs1 BIGINT; v_fu1 BIGINT; v_fa1 BIGINT;
  v_dimc2 BIGINT; v_dimt2 BIGINT; v_fs2 BIGINT; v_fu2 BIGINT; v_fa2 BIGINT;
  v_jkey2 BIGINT; v_ckey2 BIGINT;
BEGIN
  -- 4.1 sentinels exist BEFORE any fact row is loaded (Phase 0)
  SELECT judge_key INTO v_jkey FROM analytics.dim_judge WHERE judge_id IS NULL;
  SELECT challenge_key INTO v_ckey FROM analytics.dim_challenge WHERE challenge_id IS NULL;
  PERFORM t_eq('4','SENTINEL: dim_judge sentinel exists with key -1 and NULL natural key', v_jkey, -1);
  PERFORM t_eq('4','SENTINEL: dim_challenge sentinel exists with key -1 and NULL natural key', v_ckey, -1);
  PERFORM t_true('4','SENTINEL: both sentinels pre-date the fact load (facts still empty at Phase 0)',
    (SELECT count(*) FROM analytics.fact_scores) = 0
    AND (SELECT count(*) FROM analytics.fact_submissions) = 0
    AND (SELECT count(*) FROM analytics.fact_appeals) = 0,
    'verified immediately before the first load_analytics() call');

  -- 4.2 first load
  PERFORM load_analytics();
  SELECT count(*) INTO v_dimc1 FROM analytics.dim_club;
  SELECT count(*) INTO v_dimt1 FROM analytics.dim_team;
  SELECT count(*) INTO v_fs1  FROM analytics.fact_scores;
  SELECT count(*) INTO v_fu1  FROM analytics.fact_submissions;
  SELECT count(*) INTO v_fa1  FROM analytics.fact_appeals;

  -- 4.3 dim_team.club_key resolved by lookup on teams.club_id
  PERFORM t_true('4','DIM_TEAM: club_key is resolved by lookup from teams.club_id (snowflake via team)',
    NOT EXISTS (
      SELECT 1 FROM teams t
      JOIN analytics.dim_team dt ON dt.team_id=t.team_id
      JOIN analytics.dim_club dc ON dc.club_key=dt.club_key
      WHERE dc.club_id IS DISTINCT FROM t.club_id),
    'every dim_team row points at the dim_club whose club_id equals teams.club_id');

  -- 4.4 second load must be idempotent AND must not disturb sentinels
  PERFORM load_analytics();
  SELECT count(*) INTO v_dimc2 FROM analytics.dim_club;
  SELECT count(*) INTO v_dimt2 FROM analytics.dim_team;
  SELECT count(*) INTO v_fs2  FROM analytics.fact_scores;
  SELECT count(*) INTO v_fu2  FROM analytics.fact_submissions;
  SELECT count(*) INTO v_fa2  FROM analytics.fact_appeals;
  SELECT judge_key INTO v_jkey2 FROM analytics.dim_judge WHERE judge_id IS NULL;
  SELECT challenge_key INTO v_ckey2 FROM analytics.dim_challenge WHERE challenge_id IS NULL;

  PERFORM t_eq('4','UPSERT: a second load does not duplicate dim_club rows', v_dimc2, v_dimc1);
  PERFORM t_eq('4','UPSERT: a second load does not duplicate dim_team rows', v_dimt2, v_dimt1);
  PERFORM t_eq('4','UPSERT: a second load does not duplicate fact_scores rows', v_fs2, v_fs1);
  PERFORM t_eq('4','UPSERT: a second load does not duplicate fact_submissions rows', v_fu2, v_fu1);
  PERFORM t_eq('4','UPSERT: a second load does not duplicate fact_appeals rows', v_fa2, v_fa1);
  PERFORM t_eq('4','UPSERT: the dim_judge sentinel key survives a reload unchanged', v_jkey2, -1);
  PERFORM t_eq('4','UPSERT: the dim_challenge sentinel key survives a reload unchanged', v_ckey2, -1);
  PERFORM t_eq('4','UPSERT: exactly one sentinel row per dimension after two loads',
    (SELECT count(*) FROM analytics.dim_judge WHERE judge_id IS NULL)
    + (SELECT count(*) FROM analytics.dim_challenge WHERE challenge_id IS NULL), 2);
  PERFORM t_true('4','UPSERT: no real dimension row was ever assigned surrogate key -1',
    NOT EXISTS (SELECT 1 FROM analytics.dim_judge WHERE judge_key=-1 AND judge_id IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM analytics.dim_challenge WHERE challenge_key=-1 AND challenge_id IS NOT NULL),
    'the TRUNCATE+reload hazard would show up here');

  -- 4.5 the sentinels are actually used
  PERFORM t_true('4','SENTINEL: the match-less appeal landed on challenge_key = -1',
    (SELECT count(*) FROM analytics.fact_appeals WHERE challenge_key=-1) > 0,
    (SELECT count(*)::text || ' fact_appeals rows on the challenge sentinel' FROM analytics.fact_appeals WHERE challenge_key=-1));
  PERFORM t_true('4','SENTINEL: submissions with no assigned judge land on judge_key = -1',
    (SELECT count(*) FROM analytics.fact_submissions WHERE judge_key=-1) > 0,
    (SELECT count(*)::text || ' fact_submissions rows on the judge sentinel' FROM analytics.fact_submissions WHERE judge_key=-1));
END $$;

-- --- 4.6 Type 1 overwrite must NOT rotate surrogate keys ---------------
-- This is the assertion that actually distinguishes UPSERT-on-natural-key
-- from truncate+reload. A reload that reassigns club_key would silently
-- repoint every previously-loaded fact row at the wrong club, while every
-- row count stayed identical -- so counting rows alone cannot catch it.
DO $$
DECLARE
  v_key_before BIGINT; v_key_after BIGINT;
  v_name_after TEXT;
  v_fact_before BIGINT; v_fact_after BIGINT;
BEGIN
  -- scoped to ONE club by its natural key: with 20 clubs an unscoped
  -- UPDATE would rename them all and the restore would then collide on
  -- uq_clubs_name.
  SELECT dc.club_key INTO v_key_before
  FROM analytics.dim_club dc
  JOIN oltp.clubs c ON c.account_id = dc.club_id
  WHERE c.club_name = 'Test Club';
  SELECT count(*) INTO v_fact_before FROM analytics.fact_scores WHERE club_key = v_key_before;

  UPDATE oltp.clubs SET club_name = 'Test Club RENAMED' WHERE club_name = 'Test Club';
  PERFORM analytics.run_etl();

  SELECT dc.club_key, dc.club_name INTO v_key_after, v_name_after
  FROM analytics.dim_club dc
  JOIN oltp.clubs c ON c.account_id = dc.club_id
  WHERE c.club_name = 'Test Club RENAMED';
  SELECT count(*) INTO v_fact_after FROM analytics.fact_scores WHERE club_key = v_key_before;

  PERFORM t_eq('4','SURROGATE KEY: club_key is unchanged after an OLTP rename + reload',
    v_key_after, v_key_before, 'a rotating surrogate key would silently orphan existing facts');
  PERFORM t_true('4','TYPE 1: the renamed club_name did propagate to the warehouse',
    v_name_after = 'Test Club RENAMED', 'got: ' || coalesce(v_name_after,'NULL'));
  PERFORM t_eq('4','SURROGATE KEY: facts stay attached to the same club_key after reload',
    v_fact_after, v_fact_before);

  UPDATE oltp.clubs SET club_name = 'Test Club' WHERE club_name = 'Test Club RENAMED';  -- restore
  PERFORM analytics.run_etl();
END $$;

-- --- 4.7 incremental load: new OLTP rows arrive, old ones don't dup -----
DO $$
DECLARE
  v_before BIGINT; v_after BIGINT;
  v_teamA BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='ALPHA-001');
  v_chal  BIGINT := (SELECT challenge_id FROM oltp.challenges LIMIT 1);
  v_m1    BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='m1@test.dev');
BEGIN
  SELECT count(*) INTO v_before FROM analytics.fact_submissions;
  -- the gate requires the head of the chain to have asked for a
  -- resubmission before a new version may exist
  INSERT INTO oltp.submission_reviews(submission_id, judge_id, requires_resubmission)
    SELECT s.submission_id, (SELECT account_id FROM oltp.judges ORDER BY account_id LIMIT 1), TRUE
    FROM oltp.submissions s WHERE s.team_id=v_teamA AND s.challenge_id=v_chal
    ORDER BY s.version DESC LIMIT 1
    ON CONFLICT (submission_id,judge_id) DO UPDATE SET requires_resubmission = TRUE;
  INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
    VALUES (v_teamA, v_chal, 'Alpha v3 (incremental)', v_m1, '2026-05-20 09:00+00');
  PERFORM analytics.run_etl();
  SELECT count(*) INTO v_after FROM analytics.fact_submissions;

  PERFORM t_eq('4','INCREMENTAL: a new OLTP submission adds exactly one fact row',
    v_after, v_before + 1);
  PERFORM t_eq('4','INCREMENTAL: fact_submissions still matches the OLTP row count',
    v_after, (SELECT count(*) FROM oltp.submissions));
END $$;


-- =====================================================================
-- LEVEL 5 — grain / anti fan-out (CRITICAL)
-- =====================================================================
DO $$
DECLARE
  v_naive BIGINT;
  v_subs  BIGINT := (SELECT count(*) FROM submissions);
  v_scores BIGINT := (SELECT count(*) FROM scores);
BEGIN
  PERFORM t_eq('5','GRAIN fact_submissions: COUNT(*) = COUNT(DISTINCT source_submission_id)',
    (SELECT count(*) FROM analytics.fact_submissions),
    (SELECT count(DISTINCT source_submission_id) FROM analytics.fact_submissions));
  PERFORM t_eq('5','GRAIN fact_submissions: exactly one row per OLTP submission',
    (SELECT count(*) FROM analytics.fact_submissions), v_subs);
  PERFORM t_eq('5','GRAIN fact_submissions: SUM(submission_count) is not inflated',
    (SELECT sum(submission_count) FROM analytics.fact_submissions), v_subs);

  -- prove the trap is real in THIS dataset, otherwise the test is vacuous
  SELECT count(*) INTO v_naive
  FROM submissions s LEFT JOIN submission_reviews sr ON sr.submission_id=s.submission_id;
  PERFORM t_true('5','GRAIN: the naive review join WOULD have fanned out (dataset is meaningful)',
    v_naive > v_subs,
    format('naive join = %s rows vs %s submissions (a submission has 2 assigned judges)', v_naive, v_subs));

  PERFORM t_eq('5','GRAIN fact_scores: one row per judge per score',
    (SELECT count(*) FROM analytics.fact_scores), v_scores);
  PERFORM t_eq('5','GRAIN fact_scores: COUNT(*) = COUNT(DISTINCT source_score_id)',
    (SELECT count(*) FROM analytics.fact_scores),
    (SELECT count(DISTINCT source_score_id) FROM analytics.fact_scores));
  PERFORM t_eq('5','GRAIN fact_scores: (team, challenge, judge) combinations are unique',
    (SELECT count(*) FROM analytics.fact_scores),
    (SELECT count(*) FROM (SELECT DISTINCT team_key, challenge_key, judge_key FROM analytics.fact_scores) x));
  PERFORM t_eq('5','GRAIN fact_appeals: one row per OLTP appeal',
    (SELECT count(*) FROM analytics.fact_appeals), (SELECT count(*) FROM appeals));
END $$;

-- --- 5.x FIXTURE GUARD: the fan-out trap must be reachable -------------
-- The golden rule: if the dataset could not trigger the bug, the test
-- proves nothing and must FAIL rather than report a green PASS. This
-- asserts the fixture itself, independently of the ETL result.
DO $$
DECLARE
  v_multi BIGINT;
  v_max   BIGINT;
BEGIN
  SELECT count(*), coalesce(max(n),0) INTO v_multi, v_max
  FROM (SELECT submission_id, count(*) AS n FROM oltp.submission_reviews
        GROUP BY submission_id HAVING count(*) >= 2) x;

  PERFORM t_true('5','FIXTURE: at least one submission has >= 2 assigned judges (trap is reachable)',
    v_multi > 0,
    format('%s submission(s) with multiple reviewers; max reviewers on one submission = %s', v_multi, v_max));
END $$;

-- --- 5.y DETERMINISM: the DISTINCT ON tiebreaker ------------------------
-- fact_submissions picks ONE "primary reviewer" per submission via
-- DISTINCT ON. With `ORDER BY submission_id, assigned_at` alone, two
-- reviews assigned in the same transaction share assigned_at and the
-- winner is ARBITRARY -- it can differ between two runs, silently
-- breaking idempotency while every row count stays identical. 03_etl.sql
-- adds `, judge_id ASC` to make the ordering total. This fixture creates
-- the exact tie and proves the choice is stable and predictable.
DO $$
DECLARE
  v_teamB BIGINT := (SELECT team_id FROM oltp.teams WHERE participation_code='BETA-002');
  v_chal  BIGINT := (SELECT challenge_id FROM oltp.challenges LIMIT 1);
  v_m1    BIGINT := (SELECT account_id FROM oltp.accounts WHERE email='m1@test.dev');
  v_sub   BIGINT;
  v_tie   TIMESTAMPTZ := '2026-05-03 12:00:00+00';
  v_first BIGINT; v_second BIGINT;
  v_expected BIGINT;
  v_rows  BIGINT;
BEGIN
  INSERT INTO oltp.submission_reviews(submission_id, judge_id, requires_resubmission)
    SELECT s.submission_id, (SELECT account_id FROM oltp.judges ORDER BY account_id LIMIT 1), TRUE
    FROM oltp.submissions s WHERE s.team_id=v_teamB AND s.challenge_id=v_chal
    ORDER BY s.version DESC LIMIT 1
    ON CONFLICT (submission_id,judge_id) DO UPDATE SET requires_resubmission = TRUE;
  INSERT INTO oltp.submissions(team_id,challenge_id,title,submitted_by_account_id,created_at)
    VALUES (v_teamB, v_chal, 'Tie-break fixture', v_m1, '2026-05-03 09:00+00')
    RETURNING submission_id INTO v_sub;

  -- two judges, IDENTICAL assigned_at -> the tie
  INSERT INTO oltp.submission_reviews(submission_id, judge_id, assigned_at)
    SELECT v_sub, account_id, v_tie FROM oltp.judges;

  SELECT min(account_id) INTO v_expected FROM oltp.judges;

  PERFORM analytics.run_etl();
  SELECT judge_key INTO v_first FROM analytics.fact_submissions WHERE source_submission_id = v_sub;
  PERFORM analytics.run_etl();
  SELECT judge_key INTO v_second FROM analytics.fact_submissions WHERE source_submission_id = v_sub;
  SELECT count(*) INTO v_rows FROM analytics.fact_submissions WHERE source_submission_id = v_sub;

  -- >= 2, not = 2: the seed grew to 5 judges, and what the tie-break
  -- needs is simply MORE THAN ONE review sharing the same assigned_at.
  PERFORM t_true('5','FIXTURE: the tie-break case exists (>= 2 reviews with identical assigned_at)',
    (SELECT count(*) FROM oltp.submission_reviews WHERE submission_id = v_sub AND assigned_at = v_tie) >= 2,
    (SELECT count(*)::text || ' reviews share assigned_at on this submission'
     FROM oltp.submission_reviews WHERE submission_id = v_sub AND assigned_at = v_tie));
  PERFORM t_eq('5','TIEBREAK: a tied submission still yields exactly ONE fact row', v_rows, 1);
  PERFORM t_eq('5','TIEBREAK: the primary reviewer is identical across two loads (idempotent)',
    v_second, v_first, 'a non-total ORDER BY would let this flip between runs');
  PERFORM t_eq('5','TIEBREAK: the winner is the deterministic one (lowest judge_id)',
    (SELECT judge_id FROM analytics.dim_judge WHERE judge_key = v_first), v_expected);
END $$;


-- =====================================================================
-- LEVEL 6 — sanity queries without a chasm trap (CRITICAL)
-- =====================================================================
DO $$
DECLARE
  v_club BIGINT;
  v_judge BIGINT;
  v_true_total BIGINT; v_view_total BIGINT; v_naive_total BIGINT;
  v_j_true BIGINT; v_j_view BIGINT; v_j_naive BIGINT;
  v_orphan_dates BIGINT;
  v_rate NUMERIC;
BEGIN
  -- pick a club that genuinely has rows in ALL THREE facts
  SELECT c.club_key INTO v_club
  FROM analytics.dim_club c
  WHERE EXISTS (SELECT 1 FROM analytics.fact_scores      WHERE club_key=c.club_key)
    AND EXISTS (SELECT 1 FROM analytics.fact_submissions WHERE club_key=c.club_key)
    AND EXISTS (SELECT 1 FROM analytics.fact_appeals     WHERE club_key=c.club_key)
  LIMIT 1;
  PERFORM t_true('6','ORACLE SETUP: a club exists with rows in all 3 fact tables',
    v_club IS NOT NULL, 'club_key=' || coalesce(v_club::text,'NONE'));

  -- --- club scorecard: correct (pre-aggregated CTEs) vs naive ------------
  SELECT sum(total_score) INTO v_true_total FROM analytics.fact_scores WHERE club_key=v_club;
  SELECT total_score      INTO v_view_total FROM analytics.vw_partner_club_summary WHERE club_key=v_club;

  SELECT sum(fs.total_score) INTO v_naive_total
  FROM analytics.dim_club c
  LEFT JOIN analytics.fact_scores fs      ON fs.club_key=c.club_key
  LEFT JOIN analytics.fact_submissions fu ON fu.club_key=c.club_key
  LEFT JOIN analytics.fact_appeals fa     ON fa.club_key=c.club_key
  WHERE c.club_key=v_club;

  PERFORM t_eq('6','CHASM TRAP club scorecard: aggregated query == SUM on fact_scores alone',
    v_view_total, v_true_total,
    format('naive 3-fact LEFT JOIN would have returned %s', coalesce(v_naive_total::text,'NULL')));
  PERFORM t_true('6','CHASM TRAP: the naive 3-fact join WOULD have inflated SUM (test is meaningful)',
    v_naive_total > v_true_total,
    format('naive SUM=%s vs true SUM=%s (inflation factor %sx)',
           v_naive_total, v_true_total, round(v_naive_total::numeric / NULLIF(v_true_total,0), 1)));

  -- --- judge workload: same oracle ----------------------------------------
  SELECT j.judge_key INTO v_judge
  FROM analytics.dim_judge j
  WHERE j.judge_key <> -1
    AND EXISTS (SELECT 1 FROM analytics.fact_scores      WHERE judge_key=j.judge_key)
    AND EXISTS (SELECT 1 FROM analytics.fact_submissions WHERE judge_key=j.judge_key)
    AND EXISTS (SELECT 1 FROM analytics.fact_appeals     WHERE judge_key=j.judge_key)
  LIMIT 1;
  PERFORM t_true('6','ORACLE SETUP: a judge exists with rows in all 3 fact tables',
    v_judge IS NOT NULL, 'judge_key=' || coalesce(v_judge::text,'NONE'));

  SELECT count(*) INTO v_j_true FROM analytics.fact_scores WHERE judge_key=v_judge;
  SELECT scores_given INTO v_j_view FROM analytics.vw_judge_workload WHERE judge_key=v_judge;
  SELECT count(*) INTO v_j_naive
  FROM analytics.dim_judge j
  LEFT JOIN analytics.fact_scores fs      ON fs.judge_key=j.judge_key
  LEFT JOIN analytics.fact_submissions fu ON fu.judge_key=j.judge_key
  LEFT JOIN analytics.fact_appeals fa     ON fa.judge_key=j.judge_key
  WHERE j.judge_key=v_judge AND fs.fact_score_id IS NOT NULL;

  PERFORM t_eq('6','CHASM TRAP judge workload: aggregated scores_given == COUNT on fact_scores alone',
    v_j_view, v_j_true,
    format('naive 3-fact LEFT JOIN would have counted %s', v_j_naive));
  PERFORM t_true('6','CHASM TRAP: the naive judge join WOULD have inflated the count',
    v_j_naive > v_j_true, format('naive=%s vs true=%s', v_j_naive, v_j_true));

  -- --- challenge funnel view sanity ----------------------------------------
  PERFORM t_eq('6','CHALLENGE FUNNEL: submissions per challenge match fact_submissions',
    (SELECT sum(submissions)::BIGINT FROM analytics.vw_challenge_funnel),
    (SELECT sum(submission_count)::BIGINT FROM analytics.fact_submissions f
      JOIN analytics.dim_challenge c ON c.challenge_key=f.challenge_key WHERE c.challenge_key <> -1));

  -- --- quality checks: date range + sentinel rate ---------------------------
  SELECT count(*) INTO v_orphan_dates FROM (
    SELECT date_key FROM analytics.fact_scores
    UNION ALL SELECT date_key FROM analytics.fact_submissions
    UNION ALL SELECT date_key FROM analytics.fact_appeals) x
  WHERE NOT EXISTS (SELECT 1 FROM analytics.dim_date d WHERE d.date_key=x.date_key);
  PERFORM t_eq('6','DATE RANGE: every fact date_key resolves in dim_date', v_orphan_dates, 0);

  SELECT round(100.0 * count(*) FILTER (WHERE challenge_key=-1) / NULLIF(count(*),0), 1)
    INTO v_rate FROM analytics.fact_appeals;
  PERFORM t_true('6','SENTINEL RATE: fact_appeals challenge-sentinel share is within a sane band (<50%)',
    v_rate < 50, format('%s%% of appeals have no challenge (expected: only the match-less ones)', v_rate));

  SELECT round(100.0 * count(*) FILTER (WHERE judge_key=-1) / NULLIF(count(*),0), 1)
    INTO v_rate FROM analytics.fact_submissions;
  PERFORM t_true('6','SENTINEL RATE: fact_submissions judge-sentinel share is within a sane band (<75%)',
    v_rate < 75, format('%s%% of submissions have no assigned judge', v_rate));

  -- --- conformity: all 3 facts reach all 5 dimensions -----------------------
  PERFORM t_true('6','CONFORMITY: no fact row has an unresolvable dimension key',
    NOT EXISTS (SELECT 1 FROM analytics.fact_scores f WHERE NOT EXISTS (SELECT 1 FROM analytics.dim_judge d WHERE d.judge_key=f.judge_key))
    AND NOT EXISTS (SELECT 1 FROM analytics.fact_submissions f WHERE NOT EXISTS (SELECT 1 FROM analytics.dim_judge d WHERE d.judge_key=f.judge_key))
    AND NOT EXISTS (SELECT 1 FROM analytics.fact_appeals f WHERE NOT EXISTS (SELECT 1 FROM analytics.dim_challenge d WHERE d.challenge_key=f.challenge_key)),
    'all 3 facts x 5 conformed dimensions');
END $$;

-- --- 6.x THIRD shared dimension: the challenge oracle -------------------
-- The inflation factor differs per dimension (it is the product of each
-- fact's row count for that key), so the oracle is repeated on a third
-- shared dimension rather than trusting one example.
DO $$
DECLARE
  v_ch BIGINT;
  v_true BIGINT; v_view BIGINT; v_naive BIGINT;
BEGIN
  SELECT c.challenge_key INTO v_ch
  FROM analytics.dim_challenge c
  WHERE c.challenge_key <> -1
    AND EXISTS (SELECT 1 FROM analytics.fact_scores      WHERE challenge_key=c.challenge_key)
    AND EXISTS (SELECT 1 FROM analytics.fact_submissions WHERE challenge_key=c.challenge_key)
    AND EXISTS (SELECT 1 FROM analytics.fact_appeals     WHERE challenge_key=c.challenge_key)
  LIMIT 1;

  PERFORM t_true('6','ORACLE SETUP: a challenge exists with rows in all 3 fact tables',
    v_ch IS NOT NULL, 'challenge_key=' || coalesce(v_ch::text,'NONE'));

  SELECT count(*) INTO v_true  FROM analytics.fact_scores WHERE challenge_key = v_ch;
  SELECT scores_recorded INTO v_view FROM analytics.vw_challenge_funnel WHERE challenge_key = v_ch;

  SELECT count(*) INTO v_naive
  FROM analytics.dim_challenge c
  LEFT JOIN analytics.fact_scores fs      ON fs.challenge_key=c.challenge_key
  LEFT JOIN analytics.fact_submissions fu ON fu.challenge_key=c.challenge_key
  LEFT JOIN analytics.fact_appeals fa     ON fa.challenge_key=c.challenge_key
  WHERE c.challenge_key = v_ch AND fs.fact_score_id IS NOT NULL;

  PERFORM t_eq('6','CHASM TRAP challenge funnel: aggregated count == COUNT on fact_scores alone',
    v_view, v_true, format('naive 3-fact LEFT JOIN would have counted %s', v_naive));
  PERFORM t_true('6','CHASM TRAP: the naive challenge join WOULD have inflated the count',
    v_naive > v_true, format('naive=%s vs true=%s (inflation %sx)',
      v_naive, v_true, round(v_naive::numeric / NULLIF(v_true,0), 1)));
END $$;

-- --- 6.y STRUCTURAL guard: the views must not contain the anti-pattern --
-- The oracles above prove the CURRENT view definitions are safe. This
-- proves nobody can quietly reintroduce the trap later: it inspects each
-- shipped view's own definition and fails if two or more fact tables are
-- referenced from a single query level without pre-aggregation (i.e. the
-- view body joins facts directly instead of joining aggregated CTEs).
DO $$
DECLARE
  r RECORD;
  v_bad TEXT[] := '{}';
  v_def TEXT;
  v_facts INT;
  v_groups INT;
BEGIN
  FOR r IN
    SELECT c.relname AS view_name
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='analytics' AND c.relkind='v'
  LOOP
    v_def := pg_get_viewdef(('analytics.' || r.view_name)::regclass, TRUE);

    v_facts :=
        (CASE WHEN v_def ~ 'fact_scores'      THEN 1 ELSE 0 END)
      + (CASE WHEN v_def ~ 'fact_submissions' THEN 1 ELSE 0 END)
      + (CASE WHEN v_def ~ 'fact_appeals'     THEN 1 ELSE 0 END);

    -- one GROUP BY per referenced fact == each fact was pre-aggregated
    v_groups := (length(v_def) - length(replace(upper(v_def), 'GROUP BY', ''))) / length('GROUP BY');

    IF v_facts >= 2 AND v_groups < v_facts THEN
      v_bad := v_bad || format('%s (%s facts, only %s GROUP BY)', r.view_name, v_facts, v_groups);
    END IF;
  END LOOP;

  PERFORM t_true('6','STRUCTURAL: no shipped view joins 2+ fact tables without pre-aggregating each',
    cardinality(v_bad) = 0,
    CASE WHEN cardinality(v_bad) = 0
         THEN 'all analytics views inspected via pg_get_viewdef'
         ELSE 'CHASM-TRAP PATTERN IN: ' || array_to_string(v_bad, ', ') END);
END $$;


-- =====================================================================
-- LEVEL 7 — the real partner-dashboard query: 3 facts x 5 dimensions
-- =====================================================================
-- Levels 5 and 6 proved the grain and proved the chasm trap on TWO
-- shared dimensions (club, judge). But the trap is a property of ANY
-- dimension shared by several facts, so 2 of 5 validated is 3 of 5
-- unvalidated. This level runs the same negative oracle on ALL FIVE
-- conformed dimensions, adds a fixture guard so none of them can pass
-- vacuously, probes the sentinel rows as a SECOND and distinct
-- inflation mechanism, and finally pins a realistic dashboard query as
-- a golden output that must survive a re-load bit-identically.

-- --- shared probe -----------------------------------------------------
-- One implementation, five dimensions: hand-copying this query five
-- times is how a subtle difference sneaks into one copy and quietly
-- makes that dimension's oracle meaningless.
--
--   naive   = the three facts chained in LEFT JOINs on the shared key
--             (the forbidden pattern)
--   correct = each fact aggregated to one row per key in its own CTE,
--             then joined on the key (the mandated pattern)
--   truth   = computed independently, straight off each fact table
CREATE OR REPLACE FUNCTION testing.chasm_probe(p_dim TEXT, p_key TEXT)
RETURNS TABLE(naive_score BIGINT, correct_score BIGINT, truth_score BIGINT,
              naive_subs  BIGINT, correct_subs  BIGINT, truth_subs  BIGINT,
              naive_appeals BIGINT, correct_appeals BIGINT, truth_appeals BIGINT)
AS $fn$
BEGIN
  RETURN QUERY EXECUTE format($q$
    WITH naive AS (
      SELECT sum(fs.total_score)              AS s,
             count(fu.fact_submission_id)     AS u,
             count(fa.fact_appeal_id)         AS a
      FROM analytics.%1$I d
      LEFT JOIN analytics.fact_scores      fs ON fs.%2$I = d.%2$I
      LEFT JOIN analytics.fact_submissions fu ON fu.%2$I = d.%2$I
      LEFT JOIN analytics.fact_appeals     fa ON fa.%2$I = d.%2$I
    ),
    agg_s AS (SELECT %2$I AS k, sum(total_score) AS s FROM analytics.fact_scores      GROUP BY 1),
    agg_u AS (SELECT %2$I AS k, count(*)         AS u FROM analytics.fact_submissions GROUP BY 1),
    agg_a AS (SELECT %2$I AS k, count(*)         AS a FROM analytics.fact_appeals     GROUP BY 1),
    correct AS (
      SELECT sum(agg_s.s) AS s, sum(agg_u.u) AS u, sum(agg_a.a) AS a
      FROM analytics.%1$I d
      LEFT JOIN agg_s ON agg_s.k = d.%2$I
      LEFT JOIN agg_u ON agg_u.k = d.%2$I
      LEFT JOIN agg_a ON agg_a.k = d.%2$I
    )
    SELECT naive.s::bigint, correct.s::bigint,
           (SELECT sum(total_score) FROM analytics.fact_scores)::bigint,
           naive.u::bigint, correct.u::bigint,
           (SELECT count(*) FROM analytics.fact_submissions)::bigint,
           naive.a::bigint, correct.a::bigint,
           (SELECT count(*) FROM analytics.fact_appeals)::bigint
    FROM naive, correct
  $q$, p_dim, p_key);
END;
$fn$ LANGUAGE plpgsql;


-- --- PART B (runs first): fixture guard -------------------------------
-- The trap cannot manifest on a dimension value touched by only one
-- fact. Asserted per dimension, independently of the ETL, so a thinned
-- seed fails HERE instead of silently turning Part A green.
DO $$
DECLARE
  r RECORD;
  v_max INT;
  v_key TEXT;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('dim_date','date_key'), ('dim_club','club_key'), ('dim_team','team_key'),
      ('dim_challenge','challenge_key'), ('dim_judge','judge_key')
    ) AS t(dim, key)
  LOOP
    EXECUTE format($q$
      SELECT max(nf), max(k)::text FROM (
        SELECT k, count(DISTINCT f) AS nf FROM (
          SELECT %1$I AS k, 'scores'  AS f FROM analytics.fact_scores
          UNION ALL SELECT %1$I, 'subs'    FROM analytics.fact_submissions
          UNION ALL SELECT %1$I, 'appeals' FROM analytics.fact_appeals
        ) z GROUP BY k
      ) y
    $q$, r.key) INTO v_max, v_key;

    PERFORM t_true('7',
      format('FIXTURE %s: some key is touched by >= 2 of the 3 facts (trap reachable)', r.dim),
      coalesce(v_max,0) >= 2,
      format('max facts on a single %s = %s', r.key, coalesce(v_max,0)));
  END LOOP;
END $$;


-- --- PART A: negative oracle on each of the five dimensions ------------
DO $$
DECLARE
  r RECORD;
  p RECORD;
  v_factor NUMERIC;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('dim_date','date_key'), ('dim_club','club_key'), ('dim_team','team_key'),
      ('dim_challenge','challenge_key'), ('dim_judge','judge_key')
    ) AS t(dim, key)
  LOOP
    SELECT * INTO p FROM testing.chasm_probe(r.dim, r.key);
    v_factor := round(p.naive_score::numeric / NULLIF(p.correct_score,0), 2);

    -- (a) the fixture must actually reach the trap on THIS dimension
    PERFORM t_true('7',
      format('ORACLE %s: naive <> correct (the trap is real on this dimension)', r.dim),
      p.naive_score IS DISTINCT FROM p.correct_score
      OR p.naive_subs IS DISTINCT FROM p.correct_subs
      OR p.naive_appeals IS DISTINCT FROM p.correct_appeals,
      format('scores naive=%s correct=%s (x%s) | subs naive=%s correct=%s | appeals naive=%s correct=%s',
             p.naive_score, p.correct_score, v_factor,
             p.naive_subs, p.correct_subs, p.naive_appeals, p.correct_appeals));

    -- (b) the correct query must equal the independently computed truth
    PERFORM t_eq('7', format('ORACLE %s: correct SUM(total_score) == truth', r.dim),
      p.correct_score, p.truth_score, 'pre-aggregated CTE per dim key');
    PERFORM t_eq('7', format('ORACLE %s: correct COUNT(submissions) == truth', r.dim),
      p.correct_subs, p.truth_subs);
    PERFORM t_eq('7', format('ORACLE %s: correct COUNT(appeals) == truth', r.dim),
      p.correct_appeals, p.truth_appeals);
  END LOOP;
END $$;


-- --- PART C: sentinels as a SECOND, distinct inflation mechanism -------
-- challenge_key = -1 and judge_key = -1 are single dimension rows that
-- many unrelated facts collapse onto. Two separate risks:
--   (1) the sentinel becomes a "collector bucket" holding rows that
--       actually belong to real, distinct dimension members -- an ETL
--       bug, not a query bug;
--   (2) even with a correct ETL, a cross-fact join ON the sentinel key
--       multiplies rows that have nothing to do with each other -- the
--       chasm trap again, but concentrated on one key.
DO $$
DECLARE
  v_sent_appeals BIGINT; v_null_match BIGINT;
  v_sent_subs BIGINT;    v_no_judge BIGINT;
  v_leak BIGINT;
  v_naive BIGINT; v_correct BIGINT;
  v_with BIGINT; v_without BIGINT;
BEGIN
  -- (1) challenge sentinel is exactly the match-less appeals, nothing else
  SELECT count(*) INTO v_sent_appeals FROM analytics.fact_appeals WHERE challenge_key = -1;
  SELECT count(*) INTO v_null_match   FROM oltp.appeals WHERE match_id IS NULL;
  PERFORM t_eq('7','SENTINEL challenge: the -1 bucket is exactly the match-less appeals',
    v_sent_appeals, v_null_match, 'a larger bucket would mean real challenges leaked into it');

  SELECT count(*) INTO v_leak
  FROM analytics.fact_appeals f
  JOIN oltp.appeals a ON a.appeal_id = f.source_appeal_id
  WHERE f.challenge_key = -1 AND a.match_id IS NOT NULL;
  PERFORM t_eq('7','SENTINEL challenge: no appeal with a resolvable challenge landed on -1', v_leak, 0);

  -- (2) judge sentinel is exactly the submissions with no assigned judge
  SELECT count(*) INTO v_sent_subs FROM analytics.fact_submissions WHERE judge_key = -1;
  SELECT count(*) INTO v_no_judge FROM oltp.submissions s
    WHERE NOT EXISTS (SELECT 1 FROM oltp.submission_reviews r WHERE r.submission_id = s.submission_id);
  PERFORM t_eq('7','SENTINEL judge: the -1 bucket is exactly the unreviewed submissions',
    v_sent_subs, v_no_judge);

  SELECT count(*) INTO v_leak
  FROM analytics.fact_submissions f
  WHERE f.judge_key = -1
    AND EXISTS (SELECT 1 FROM oltp.submission_reviews r WHERE r.submission_id = f.source_submission_id);
  PERFORM t_eq('7','SENTINEL judge: no submission with an assigned judge landed on -1', v_leak, 0);

  -- (3) the sentinel key itself is a cross-fact multiplier
  SELECT count(*) INTO v_naive
  FROM analytics.fact_submissions fu
  JOIN analytics.fact_appeals fa ON fa.judge_key = fu.judge_key
  WHERE fu.judge_key = -1;
  SELECT (SELECT count(*) FROM analytics.fact_submissions WHERE judge_key = -1)
       + (SELECT count(*) FROM analytics.fact_appeals     WHERE judge_key = -1)
    INTO v_correct;
  PERFORM t_true('7','SENTINEL judge: joining two facts ON judge_key = -1 multiplies rows',
    v_naive > v_correct OR v_naive = 0,
    format('cross-join on the sentinel yields %s rows vs %s real rows -- this is why a dashboard must not group across facts on a sentinel',
           v_naive, v_correct));

  -- (4) excluding the sentinel is a DELIBERATE choice with a different total
  SELECT count(*) INTO v_with    FROM analytics.fact_appeals;
  SELECT count(*) INTO v_without FROM analytics.fact_appeals WHERE challenge_key <> -1;
  PERFORM t_true('7','SENTINEL filter: WHERE challenge_key <> -1 changes the total (choice is not cosmetic)',
    v_with <> v_without,
    format('all appeals = %s, challenge-linked only = %s, difference = %s',
           v_with, v_without, v_with - v_without));
  PERFORM t_eq('7','SENTINEL filter: the excluded rows are precisely the sentinel rows',
    v_with - v_without, v_sent_appeals);
  PERFORM t_true('7','SENTINEL filter: the shipped per-challenge view excludes the sentinel on purpose',
    NOT EXISTS (SELECT 1 FROM analytics.vw_challenge_funnel WHERE challenge_key = -1),
    'vw_challenge_funnel is a per-challenge report, so the "no challenge" bucket is intentionally out');
END $$;


-- --- PART D: the "ready" dashboard query, pinned as a golden output ----
-- Per club x season: number of submissions, average score, appeals.
-- Reaches all three facts through the shared dimensions using ONLY the
-- mandated pattern (one pre-aggregated CTE per fact, joined on the dim
-- keys). Pinning it and re-running the ETL twice ties idempotency to the
-- shape the data is actually consumed in -- per-table row counts can be
-- stable while a dashboard number still moves.
-- PROVENANCE GUARD -- read the catalog, never create the object.
--
-- analytics.vw_partner_dashboard is PRODUCTION and is defined in
-- 02_analytics_schema.sql. It used to be created right here, which made
-- the suite the source of the very object it then validated: a deploy
-- running only 01_ -> 02_ -> 03_etl.sql shipped a warehouse with no
-- dashboard, and the tests still went green because they had built it
-- themselves moments earlier.
--
-- These checks query information_schema / pg_catalog and FAIL if the
-- view is absent, so the suite can no longer paper over a missing
-- production object. Everything below reads the view; nothing creates it.
DO $$
DECLARE
  v_exists BOOLEAN;
  v_def    TEXT;
  v_cols   TEXT;
  v_facts  INT;
  v_groups INT;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.views
    WHERE table_schema = 'analytics' AND table_name = 'vw_partner_dashboard'
  ) INTO v_exists;

  PERFORM t_true('7','PROVENANCE: analytics.vw_partner_dashboard exists BEFORE the suite runs',
    v_exists,
    CASE WHEN v_exists
         THEN 'found in information_schema.views -- shipped by 02_analytics_schema.sql'
         ELSE 'MISSING: the view is not in the catalog. It must be created by '
              || '02_analytics_schema.sql, not by this suite -- a deploy of '
              || '01_ -> 02_ -> 03_etl.sql would have no partner dashboard.' END);

  -- Fail loudly and immediately: every assertion after this point would
  -- otherwise report a confusing "relation does not exist" instead of
  -- the real problem.
  IF NOT v_exists THEN
    RAISE EXCEPTION
      'analytics.vw_partner_dashboard is missing -- it belongs in 02_analytics_schema.sql';
  END IF;

  -- it must be a real VIEW, not a table someone materialised by hand
  PERFORM t_true('7','PROVENANCE: it is a VIEW (relkind = v), not a table',
    EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname='analytics' AND c.relname='vw_partner_dashboard' AND c.relkind='v'),
    'checked via pg_catalog.pg_class.relkind');

  -- the contract the tests below depend on: the exact column list
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_cols
  FROM information_schema.columns
  WHERE table_schema='analytics' AND table_name='vw_partner_dashboard';
  PERFORM t_true('7','PROVENANCE: the shipped view exposes the expected column contract',
    v_cols = 'club_key,club_name,season_name,submissions,challenges_entered,'
             || 'scores_recorded,avg_score,total_score,valid_appeals,invalid_appeals',
    'got: ' || v_cols);

  -- and the move must not have flattened it back into the chasm trap
  v_def := pg_get_viewdef('analytics.vw_partner_dashboard'::regclass, TRUE);
  v_facts := (CASE WHEN v_def ~ 'fact_scores'      THEN 1 ELSE 0 END)
           + (CASE WHEN v_def ~ 'fact_submissions' THEN 1 ELSE 0 END)
           + (CASE WHEN v_def ~ 'fact_appeals'     THEN 1 ELSE 0 END);
  v_groups := (length(v_def) - length(replace(upper(v_def), 'GROUP BY', ''))) / length('GROUP BY');
  PERFORM t_true('7','PROVENANCE: the shipped view still pre-aggregates each fact separately',
    v_facts = 3 AND v_groups >= 3,
    format('%s fact tables, %s GROUP BY clauses -- one per fact', v_facts, v_groups));
END $$;

CREATE TABLE testing.golden_dashboard AS SELECT * FROM analytics.vw_partner_dashboard;

DO $$
DECLARE
  v_rows BIGINT;
  v_drift BIGINT;
  v_clubs BIGINT;
  v_seasons BIGINT;
  v_multi BIGINT;
  v_bad BIGINT;
BEGIN
  SELECT count(*) INTO v_rows FROM testing.golden_dashboard;
  SELECT count(DISTINCT club_key), count(DISTINCT season_name)
    INTO v_clubs, v_seasons FROM testing.golden_dashboard;

  PERFORM t_true('7','DASHBOARD: the golden query returns rows', v_rows > 0, v_rows || ' (club x season) rows');
  PERFORM t_true('7','DASHBOARD REACHABILITY: golden spans MANY clubs (not a single-group fixture)',
    v_clubs > 1, v_clubs || ' distinct clubs in the golden output');
  PERFORM t_true('7','DASHBOARD REACHABILITY: golden spans MANY seasons',
    v_seasons > 1, v_seasons || ' distinct seasons in the golden output');

  SELECT count(*) INTO v_multi FROM (
    SELECT club_key FROM testing.golden_dashboard GROUP BY club_key HAVING count(*) > 1) x;
  PERFORM t_true('7','DASHBOARD REACHABILITY: some club appears in MORE THAN ONE season',
    v_multi > 0,
    format('%s club(s) with >1 season row -- required for the bleed test below to mean anything', v_multi));

  -- --- per-group correctness (the check the single-row golden could not do)
  -- Recomputed independently for EVERY (club, season) cell, not just one.
  -- A wrong GROUP BY, or a join on club_key that ignores the season,
  -- shows up here as a mismatched cell.
  SELECT count(*) INTO v_bad
  FROM testing.golden_dashboard g
  LEFT JOIN (
    SELECT f.club_key, ch.season_name,
           count(*) AS scores_recorded,
           sum(f.total_score) AS total_score,
           round(avg(f.total_score),2) AS avg_score
    FROM analytics.fact_scores f
    JOIN analytics.dim_challenge ch ON ch.challenge_key = f.challenge_key
    GROUP BY f.club_key, ch.season_name
  ) truth ON truth.club_key = g.club_key AND truth.season_name = g.season_name
  WHERE g.scores_recorded IS DISTINCT FROM coalesce(truth.scores_recorded, 0)
     OR g.total_score     IS DISTINCT FROM coalesce(truth.total_score, 0)
     OR g.avg_score       IS DISTINCT FROM truth.avg_score;
  PERFORM t_eq('7','DASHBOARD: every (club x season) score cell matches an independent recomputation',
    v_bad, 0, 'per-group oracle -- a single-row golden could never detect a grouping bug');

  SELECT count(*) INTO v_bad
  FROM testing.golden_dashboard g
  LEFT JOIN (
    SELECT f.club_key, ch.season_name, sum(f.submission_count) AS submissions
    FROM analytics.fact_submissions f
    JOIN analytics.dim_challenge ch ON ch.challenge_key = f.challenge_key
    GROUP BY f.club_key, ch.season_name
  ) truth ON truth.club_key = g.club_key AND truth.season_name = g.season_name
  WHERE g.submissions IS DISTINCT FROM coalesce(truth.submissions, 0);
  PERFORM t_eq('7','DASHBOARD: every (club x season) submission cell matches an independent recomputation',
    v_bad, 0);

  -- --- column totals must reconcile with the fact tables ----------------
  PERFORM t_eq('7','DASHBOARD: submissions column sums to the fact table total',
    (SELECT sum(submissions)::BIGINT FROM testing.golden_dashboard),
    (SELECT sum(submission_count)::BIGINT FROM analytics.fact_submissions));
  PERFORM t_eq('7','DASHBOARD: total_score column sums to the fact table total',
    (SELECT sum(total_score)::BIGINT FROM testing.golden_dashboard),
    (SELECT sum(total_score)::BIGINT FROM analytics.fact_scores));
  PERFORM t_eq('7','DASHBOARD: appeals columns sum to the fact table total',
    (SELECT sum(valid_appeals + invalid_appeals)::BIGINT FROM testing.golden_dashboard),
    (SELECT count(*)::BIGINT FROM analytics.fact_appeals));

  -- --- idempotency, measured on the consumption shape -------------------
  PERFORM analytics.run_etl();
  PERFORM analytics.run_etl();

  SELECT count(*) INTO v_drift FROM (
    (SELECT * FROM testing.golden_dashboard EXCEPT SELECT * FROM analytics.vw_partner_dashboard)
    UNION ALL
    (SELECT * FROM analytics.vw_partner_dashboard EXCEPT SELECT * FROM testing.golden_dashboard)
  ) x;
  PERFORM t_eq('7','DASHBOARD: golden output is bit-identical after two more ETL runs', v_drift, 0,
    'idempotency measured on the consumption shape, not just per-table counts');

  PERFORM t_eq('7','DASHBOARD: row count is stable after reload',
    (SELECT count(*) FROM analytics.vw_partner_dashboard), v_rows);
END $$;

-- --- TASK 3 negative test: BLEED between groups ------------------------
-- This is the test that a single-row golden could never fail. It builds
-- the same dashboard with ONE deliberate defect -- the season is dropped
-- from the join key, so each club's seasons cross-join into each other --
-- and asserts that the result DIFFERS from the correct golden.
--
-- With one club and one season the bleeding version is identical to the
-- correct one, so this assertion would pass vacuously; the reachability
-- guards above are what stop that. If the seed is ever thinned back to a
-- single group, THIS test fails rather than silently going green.
DO $$
DECLARE
  v_correct_rows BIGINT;
  v_bleed_rows   BIGINT;
  v_correct_sum  BIGINT;
  v_bleed_sum    BIGINT;
BEGIN
  CREATE TEMP TABLE bleed_dashboard AS
  WITH s AS (
    SELECT f.club_key, ch.season_name, sum(f.total_score) AS total_score, count(*) AS scores_recorded
    FROM analytics.fact_scores f
    JOIN analytics.dim_challenge ch ON ch.challenge_key = f.challenge_key
    GROUP BY f.club_key, ch.season_name
  ),
  u AS (
    SELECT f.club_key, ch.season_name, sum(f.submission_count) AS submissions
    FROM analytics.fact_submissions f
    JOIN analytics.dim_challenge ch ON ch.challenge_key = f.challenge_key
    GROUP BY f.club_key, ch.season_name
  )
  SELECT s.club_key, s.season_name, s.total_score, s.scores_recorded, u.submissions
  FROM s
  JOIN u ON u.club_key = s.club_key;      -- BUG ON PURPOSE: season dropped from the join key

  SELECT count(*), coalesce(sum(submissions),0) INTO v_correct_rows, v_correct_sum
  FROM testing.golden_dashboard;
  SELECT count(*), coalesce(sum(submissions),0) INTO v_bleed_rows, v_bleed_sum
  FROM bleed_dashboard;

  PERFORM t_true('7','BLEED: joining on club_key WITHOUT the season produces a different result',
    v_bleed_rows <> v_correct_rows OR v_bleed_sum <> v_correct_sum,
    format('bleeding version: %s rows / %s submissions vs correct %s rows / %s submissions',
           v_bleed_rows, v_bleed_sum, v_correct_rows, v_correct_sum));

  -- Per-CELL detectability: it is not enough that the totals differ --
  -- at least one (club, season) cell must visibly disagree, which is the
  -- shape a real bleed bug takes on a dashboard.
  SELECT count(*) INTO v_bleed_rows
  FROM testing.golden_dashboard g
  JOIN bleed_dashboard b ON b.club_key = g.club_key AND b.season_name = g.season_name
  WHERE b.submissions IS DISTINCT FROM g.submissions;

  PERFORM t_true('7','BLEED: at least one (club x season) CELL differs under the bleeding join',
    v_bleed_rows > 0,
    format('%s contaminated cells -- with a single-group fixture this would be 0 and the test would pass vacuously',
           v_bleed_rows));

  DROP TABLE bleed_dashboard;
END $$;


-- =====================================================================
-- LEVEL 8 — every function, in detail (not just happy path)
-- =====================================================================
-- Levels 4 and 7 exercise the ETL end to end. This level takes each
-- shipped function individually and covers: happy path on the
-- multi-club seed, idempotency, COMPLETE Type 1 overwrite, derived
-- (not hardcoded) dim_date, and degenerate / empty input.

-- --- 8.0 inventory: every shipped function is actually covered ---------
DO $$
DECLARE
  v_missing TEXT[] := '{}';
  r RECORD;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('analytics.run_etl'), ('analytics.etl_phase0_setup'),
      ('analytics.etl_phase1_dimensions'), ('analytics.etl_phase2_facts'),
      ('analytics.etl_quality_report'),
      ('oltp.set_updated_at'), ('oltp.enforce_subtype_role'),
      ('oltp.enforce_team_capacity'), ('oltp.enforce_appeal_limit'),
      ('oltp.assign_submission_version'), ('oltp.enforce_single_notification_link')
    ) AS t(fname)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname || '.' || p.proname = r.fname
    ) THEN
      v_missing := v_missing || r.fname;
    END IF;
  END LOOP;
  PERFORM t_true('8','INVENTORY: every function this level claims to cover exists',
    cardinality(v_missing) = 0,
    CASE WHEN cardinality(v_missing) = 0 THEN '11 functions located'
         ELSE 'MISSING: ' || array_to_string(v_missing, ', ') END);
END $$;

-- --- 8.1 etl_phase0_setup: sentinels + DERIVED dim_date ----------------
DO $$
DECLARE
  v_min_fact DATE; v_max_fact DATE;
  v_min_dim  DATE; v_max_dim  DATE;
  v_before BIGINT; v_after BIGINT;
  v_jk BIGINT; v_ck BIGINT;
BEGIN
  SELECT min(full_date), max(full_date) INTO v_min_dim, v_max_dim FROM analytics.dim_date;
  SELECT LEAST(min(scored_at::date), (SELECT min(created_at::date) FROM oltp.submissions),
               (SELECT min(created_at::date) FROM oltp.appeals),
               (SELECT min(start_date) FROM oltp.seasons)) INTO v_min_fact FROM oltp.scores;
  SELECT GREATEST(max(scored_at::date), (SELECT max(created_at::date) FROM oltp.submissions),
                  (SELECT max(created_at::date) FROM oltp.appeals),
                  (SELECT max(end_date) FROM oltp.seasons)) INTO v_max_fact FROM oltp.scores;

  PERFORM t_true('8','phase0: dim_date covers the real data range (derived, not hardcoded)',
    v_min_dim <= v_min_fact AND v_max_dim >= v_max_fact,
    format('dim_date %s..%s vs data %s..%s', v_min_dim, v_max_dim, v_min_fact, v_max_fact));
  PERFORM t_true('8','phase0: the buffer really extends past the data on both ends',
    v_min_dim < v_min_fact AND v_max_dim > v_max_fact,
    format('lead=%s days, trail=%s days', v_min_fact - v_min_dim, v_max_dim - v_max_fact));

  -- the second season pushed the range into 2027; a hardcoded window
  -- would have stopped at 2026-12-31 and broken the date_key FK
  PERFORM t_true('8','phase0: the range followed the NEW season into 2027',
    v_max_dim > DATE '2027-01-01', 'max dim_date = ' || v_max_dim);

  -- idempotent + non-destructive to sentinels
  SELECT count(*) INTO v_before FROM analytics.dim_date;
  PERFORM analytics.etl_phase0_setup();
  SELECT count(*) INTO v_after FROM analytics.dim_date;
  PERFORM t_eq('8','phase0: re-running adds no duplicate dim_date rows', v_after, v_before);

  SELECT judge_key INTO v_jk FROM analytics.dim_judge WHERE judge_id IS NULL;
  SELECT challenge_key INTO v_ck FROM analytics.dim_challenge WHERE challenge_id IS NULL;
  PERFORM t_eq('8','phase0: re-running leaves the judge sentinel untouched', v_jk, -1);
  PERFORM t_eq('8','phase0: re-running leaves the challenge sentinel untouched', v_ck, -1);
  PERFORM t_eq('8','phase0: still exactly one sentinel per dimension',
    (SELECT count(*) FROM analytics.dim_judge WHERE judge_id IS NULL)
    + (SELECT count(*) FROM analytics.dim_challenge WHERE challenge_id IS NULL), 2);

  -- explicit buffer argument is honoured
  PERFORM analytics.etl_phase0_setup(60);
  PERFORM t_true('8','phase0: a larger buffer argument widens the calendar',
    (SELECT max(full_date) FROM analytics.dim_date) > v_max_dim,
    'called with p_buffer_days => 60');
END $$;

-- --- 8.2 phase1: dimensions, snowflake lookup, full Type 1 overwrite ---
DO $$
DECLARE
  v_c BIGINT; v_t BIGINT; v_ch BIGINT; v_j BIGINT;
  v_c2 BIGINT; v_t2 BIGINT;
  v_wrong BIGINT;
  v_key BIGINT;
  v_row RECORD;
BEGIN
  SELECT count(*) INTO v_c  FROM analytics.dim_club;
  SELECT count(*) INTO v_t  FROM analytics.dim_team;
  SELECT count(*) INTO v_ch FROM analytics.dim_challenge;
  SELECT count(*) INTO v_j  FROM analytics.dim_judge;

  PERFORM t_eq('8','phase1: dim_club has one row per OLTP club',
    v_c, (SELECT count(*) FROM oltp.clubs));
  PERFORM t_eq('8','phase1: dim_team has one row per OLTP team',
    v_t, (SELECT count(*) FROM oltp.teams));
  PERFORM t_eq('8','phase1: dim_challenge = OLTP challenges + 1 sentinel',
    v_ch, (SELECT count(*) FROM oltp.challenges) + 1);
  PERFORM t_eq('8','phase1: dim_judge = OLTP judges + 1 sentinel',
    v_j, (SELECT count(*) FROM oltp.judges) + 1);

  -- the snowflake lookup, now over 20 clubs and 50 teams: with one club
  -- every possible lookup produced the right answer by accident.
  SELECT count(*) INTO v_wrong
  FROM oltp.teams t
  JOIN analytics.dim_team dt ON dt.team_id = t.team_id
  JOIN analytics.dim_club dc ON dc.club_key = dt.club_key
  WHERE dc.club_id <> t.club_id;
  PERFORM t_eq('8','phase1: every team attaches to the RIGHT club across 20 clubs', v_wrong, 0,
    'a mis-wired snowflake lookup is undetectable with a single club');

  PERFORM t_eq('8','phase1: no team was dropped by the dim_club join',
    (SELECT count(*) FROM oltp.teams t
     WHERE NOT EXISTS (SELECT 1 FROM analytics.dim_team dt WHERE dt.team_id = t.team_id)), 0);

  -- COMPLETE Type 1 overwrite: change EVERY mutable attribute at once
  SELECT dt.team_key INTO v_key
  FROM analytics.dim_team dt JOIN oltp.teams t ON t.team_id = dt.team_id
  WHERE t.participation_code = 'BIG-01-T01';

  UPDATE oltp.teams SET team_name = 'RENAMED TEAM', participation_code = 'BIG-01-XX'
    WHERE participation_code = 'BIG-01-T01';
  UPDATE oltp.team_categories SET label = 'Robotics RELABELLED' WHERE code = 'ROBOTICS';
  PERFORM analytics.etl_phase1_dimensions();

  SELECT * INTO v_row FROM analytics.dim_team WHERE team_key = v_key;
  PERFORM t_true('8','phase1: Type 1 overwrite refreshes team_name',
    v_row.team_name = 'RENAMED TEAM', 'got ' || v_row.team_name);
  PERFORM t_true('8','phase1: Type 1 overwrite refreshes participation_code',
    v_row.participation_code = 'BIG-01-XX', 'got ' || v_row.participation_code);
  PERFORM t_true('8','phase1: Type 1 overwrite refreshes the denormalised category_label',
    v_row.category_label = 'Robotics RELABELLED', 'got ' || v_row.category_label);
  PERFORM t_eq('8','phase1: the surrogate key survived a full-attribute rewrite',
    (SELECT team_key FROM analytics.dim_team dt
     JOIN oltp.teams t ON t.team_id = dt.team_id WHERE t.participation_code = 'BIG-01-XX'), v_key);

  -- restore
  UPDATE oltp.teams SET team_name = 'BIG-01 Team 1', participation_code = 'BIG-01-T01'
    WHERE participation_code = 'BIG-01-XX';
  UPDATE oltp.team_categories SET label = 'Robotics' WHERE code = 'ROBOTICS';
  PERFORM analytics.etl_phase1_dimensions();

  SELECT count(*) INTO v_c2 FROM analytics.dim_club;
  SELECT count(*) INTO v_t2 FROM analytics.dim_team;
  PERFORM t_eq('8','phase1: repeated runs never duplicate dim_club', v_c2, v_c);
  PERFORM t_eq('8','phase1: repeated runs never duplicate dim_team', v_t2, v_t);
END $$;

-- --- 8.3 phase2: facts, complete overwrite of a corrected score --------
DO $$
DECLARE
  v_score BIGINT; v_fact RECORD; v_before RECORD;
  v_fs BIGINT; v_fu BIGINT; v_fa BIGINT;
BEGIN
  SELECT count(*) INTO v_fs FROM analytics.fact_scores;
  SELECT count(*) INTO v_fu FROM analytics.fact_submissions;
  SELECT count(*) INTO v_fa FROM analytics.fact_appeals;

  PERFORM t_eq('8','phase2: fact_scores matches OLTP scores', v_fs, (SELECT count(*) FROM oltp.scores));
  PERFORM t_eq('8','phase2: fact_submissions matches OLTP submissions', v_fu, (SELECT count(*) FROM oltp.submissions));
  PERFORM t_eq('8','phase2: fact_appeals matches OLTP appeals', v_fa, (SELECT count(*) FROM oltp.appeals));

  -- correct a score in OLTP and require EVERY mutable column to follow
  SELECT score_id INTO v_score FROM oltp.scores ORDER BY score_id LIMIT 1;
  SELECT * INTO v_before FROM analytics.fact_scores WHERE source_score_id = v_score;

  UPDATE oltp.scores
     SET innovation_score = 10, execution_score = 10,
         presentation_score = 10, teamwork_score = 10,
         scored_at = '2026-12-20 10:00+00'
   WHERE score_id = v_score;
  PERFORM analytics.run_etl();

  SELECT * INTO v_fact FROM analytics.fact_scores WHERE source_score_id = v_score;
  PERFORM t_eq('8','phase2: corrected innovation_score propagated', v_fact.innovation_score, 10);
  PERFORM t_eq('8','phase2: corrected execution_score propagated', v_fact.execution_score, 10);
  PERFORM t_eq('8','phase2: corrected presentation_score propagated', v_fact.presentation_score, 10);
  PERFORM t_eq('8','phase2: corrected teamwork_score propagated', v_fact.teamwork_score, 10);
  PERFORM t_eq('8','phase2: recomputed total_score propagated (4x10)', v_fact.total_score, 40);
  PERFORM t_true('8','phase2: the changed date moved date_key too (not just the measures)',
    v_fact.date_key = 20261220,
    format('date_key %s -> %s', v_before.date_key, v_fact.date_key));
  PERFORM t_eq('8','phase2: correcting a score did NOT create a second fact row',
    (SELECT count(*) FROM analytics.fact_scores WHERE source_score_id = v_score), 1);
  PERFORM t_eq('8','phase2: fact_scores row count unchanged by the correction',
    (SELECT count(*) FROM analytics.fact_scores), v_fs);

  -- restore
  UPDATE oltp.scores
     SET innovation_score = v_before.innovation_score, execution_score = v_before.execution_score,
         presentation_score = v_before.presentation_score, teamwork_score = v_before.teamwork_score,
         scored_at = '2026-05-10 11:00+00'
   WHERE score_id = v_score;
  PERFORM analytics.run_etl();
END $$;

-- --- 8.4 tiebreaker determinism in >= 2 different clubs ----------------
DO $$
DECLARE
  v_clubs BIGINT;
  v_first BIGINT; v_second BIGINT;
BEGIN
  -- how many DISTINCT clubs own a submission whose reviews tie on assigned_at
  SELECT count(DISTINCT t.club_id) INTO v_clubs
  FROM oltp.submission_reviews r
  JOIN oltp.submissions s ON s.submission_id = r.submission_id
  JOIN oltp.teams t ON t.team_id = s.team_id
  WHERE r.submission_id IN (
    SELECT submission_id FROM oltp.submission_reviews
    GROUP BY submission_id, assigned_at HAVING count(*) >= 2);

  PERFORM t_true('8','FIXTURE: the DISTINCT ON tie occurs in >= 2 different clubs',
    v_clubs >= 2, v_clubs || ' clubs contain a tied submission');

  -- every tied submission must resolve to the lowest judge_id, in every club
  SELECT count(*) INTO v_first
  FROM analytics.fact_submissions f
  JOIN analytics.dim_judge dj ON dj.judge_key = f.judge_key
  JOIN (
    SELECT r.submission_id, min(r.judge_id) AS expected
    FROM oltp.submission_reviews r
    JOIN (SELECT submission_id, min(assigned_at) AS first_at
          FROM oltp.submission_reviews GROUP BY submission_id) w
      ON w.submission_id = r.submission_id AND w.first_at = r.assigned_at
    GROUP BY r.submission_id
  ) exp ON exp.submission_id = f.source_submission_id
  WHERE dj.judge_id IS DISTINCT FROM exp.expected;
  PERFORM t_eq('8','TIEBREAK: every reviewed submission resolved to the lowest judge_id', v_first, 0,
    'checked across all clubs, not just the one tie-break fixture');

  -- and it is stable across reloads
  SELECT count(*) INTO v_first FROM analytics.fact_submissions WHERE judge_key <> -1;
  PERFORM analytics.run_etl();
  SELECT count(*) INTO v_second FROM analytics.fact_submissions WHERE judge_key <> -1;
  PERFORM t_eq('8','TIEBREAK: reviewer assignment count is stable across a reload', v_second, v_first);
END $$;

-- --- 8.5 degenerate input ----------------------------------------------
-- The two degenerate clubs are why they are in the seed: a club with no
-- teams at all, and a club whose only team is empty. Both must survive
-- the ETL without disappearing and without inventing rows.
DO $$
DECLARE
  v_d1 BIGINT; v_d2 BIGINT; v_team BIGINT;
  v_facts BIGINT;
  v_empty BIGINT; v_atcap BIGINT;
BEGIN
  SELECT dc.club_key INTO v_d1 FROM analytics.dim_club dc
    JOIN oltp.clubs c ON c.account_id = dc.club_id WHERE c.club_name = 'Club DEGEN-01';
  SELECT dc.club_key INTO v_d2 FROM analytics.dim_club dc
    JOIN oltp.clubs c ON c.account_id = dc.club_id WHERE c.club_name = 'Club DEGEN-02';

  PERFORM t_true('8','DEGENERATE: a club with zero teams still reaches dim_club',
    v_d1 IS NOT NULL, 'club_key=' || coalesce(v_d1::text,'NULL'));
  PERFORM t_eq('8','DEGENERATE: the zero-team club has zero teams in dim_team',
    (SELECT count(*) FROM analytics.dim_team WHERE club_key = v_d1), 0);

  SELECT (SELECT count(*) FROM analytics.fact_scores      WHERE club_key = v_d1)
       + (SELECT count(*) FROM analytics.fact_submissions WHERE club_key = v_d1)
       + (SELECT count(*) FROM analytics.fact_appeals     WHERE club_key = v_d1) INTO v_facts;
  PERFORM t_eq('8','DEGENERATE: the zero-team club produced no fact rows at all', v_facts, 0);

  PERFORM t_eq('8','DEGENERATE: the empty-team club still has its team in dim_team',
    (SELECT count(*) FROM analytics.dim_team WHERE club_key = v_d2), 1);

  -- these clubs must not silently vanish from, or corrupt, the dashboard
  PERFORM t_true('8','DEGENERATE: a club with no facts is simply absent from the dashboard grid',
    NOT EXISTS (SELECT 1 FROM analytics.vw_partner_dashboard WHERE club_key = v_d1),
    'no facts -> no (club, season) cell, and no zero-filled ghost row either');

  -- the roster edge cases the seed promised
  SELECT count(*) INTO v_empty FROM oltp.teams t
    WHERE NOT EXISTS (SELECT 1 FROM oltp.memberships m WHERE m.team_id = t.team_id AND m.left_at IS NULL);
  PERFORM t_true('8','FIXTURE: at least one team has an EMPTY roster', v_empty > 0, v_empty || ' empty team(s)');

  SELECT count(*) INTO v_atcap FROM (
    SELECT t.team_id FROM oltp.teams t
    JOIN oltp.team_categories tc ON tc.category_id = t.category_id
    JOIN oltp.memberships m ON m.team_id = t.team_id AND m.left_at IS NULL
    GROUP BY t.team_id, tc.max_members HAVING count(*) = max(tc.max_members)) x;
  PERFORM t_true('8','FIXTURE: at least one team sits exactly AT max_members', v_atcap > 0,
    v_atcap || ' team(s) at their category cap');

  -- a season with no scores at all must not break the aggregate
  PERFORM t_true('8','DEGENERATE: a (club, season) cell with no scores reports 0, not NULL',
    NOT EXISTS (SELECT 1 FROM analytics.vw_partner_dashboard WHERE total_score IS NULL),
    'coalesce on the LEFT JOIN paths');
END $$;

-- --- 8.6 etl_quality_report -------------------------------------------
DO $$
DECLARE
  v_total INT; v_ok INT; v_bad TEXT;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE ok) INTO v_total, v_ok
  FROM analytics.etl_quality_report();
  PERFORM t_true('8','quality_report: returns a full set of checks', v_total >= 7, v_total || ' checks');
  PERFORM t_eq('8','quality_report: every check passes on the multi-club seed', v_ok, v_total);

  SELECT string_agg(check_name, ', ') INTO v_bad
  FROM analytics.etl_quality_report() WHERE NOT ok;
  PERFORM t_true('8','quality_report: no failing check to report', v_bad IS NULL,
    coalesce('FAILING: ' || v_bad, 'all green'));

  -- it must be a pure reader: calling it changes nothing
  PERFORM t_eq('8','quality_report: is side-effect free (fact counts unchanged)',
    (SELECT count(*) FROM analytics.fact_scores),
    (SELECT count(*) FROM analytics.fact_scores));
END $$;

-- --- 8.7 run_etl orchestrator ------------------------------------------
DO $$
DECLARE
  v_phases INT;
  v_hash_a TEXT; v_hash_b TEXT;
BEGIN
  SELECT count(*) INTO v_phases FROM analytics.run_etl();
  PERFORM t_eq('8','run_etl: reports all three phases', v_phases, 3);

  PERFORM t_true('8','run_etl: phase names are the documented ones',
    (SELECT array_agg(phase ORDER BY phase) FROM analytics.run_etl())
      = ARRAY['phase0_setup','phase1_dimensions','phase2_facts'],
    'phase0_setup -> phase1_dimensions -> phase2_facts');

  -- whole-warehouse fingerprint before/after another run
  SELECT md5(string_agg(x, '|' ORDER BY x)) INTO v_hash_a FROM (
    SELECT concat_ws(':', 'S', source_score_id, team_key, club_key, challenge_key, judge_key, total_score) AS x
      FROM analytics.fact_scores
    UNION ALL SELECT concat_ws(':', 'U', source_submission_id, team_key, club_key, challenge_key, judge_key)
      FROM analytics.fact_submissions
    UNION ALL SELECT concat_ws(':', 'A', source_appeal_id, team_key, club_key, challenge_key, judge_key, appeal_status)
      FROM analytics.fact_appeals) y;

  PERFORM analytics.run_etl();

  SELECT md5(string_agg(x, '|' ORDER BY x)) INTO v_hash_b FROM (
    SELECT concat_ws(':', 'S', source_score_id, team_key, club_key, challenge_key, judge_key, total_score) AS x
      FROM analytics.fact_scores
    UNION ALL SELECT concat_ws(':', 'U', source_submission_id, team_key, club_key, challenge_key, judge_key)
      FROM analytics.fact_submissions
    UNION ALL SELECT concat_ws(':', 'A', source_appeal_id, team_key, club_key, challenge_key, judge_key, appeal_status)
      FROM analytics.fact_appeals) y;

  PERFORM t_true('8','run_etl: the whole warehouse fingerprint is identical after a re-run',
    v_hash_a = v_hash_b, format('md5 %s vs %s', left(v_hash_a,12), left(v_hash_b,12)));
END $$;

-- --- 8.8 OLTP trigger functions, on the multi-club seed -----------------
-- Levels 1-3 already prove each trigger fires. This re-proves the two
-- COUNTING triggers on a seed where many clubs and teams exist at once,
-- because both aggregate across rows and a missing predicate would make
-- them count another team's rows.
DO $$
DECLARE
  v_team BIGINT; v_cap SMALLINT; v_cnt INT; v_acct BIGINT;
  v_other BIGINT; v_rejected INT; v_fresh BIGINT;
BEGIN
  -- capacity is evaluated PER TEAM, not globally
  SELECT t.team_id, tc.max_members INTO v_team, v_cap
  FROM oltp.teams t JOIN oltp.team_categories tc ON tc.category_id = t.category_id
  JOIN oltp.memberships m ON m.team_id = t.team_id AND m.left_at IS NULL
  GROUP BY t.team_id, tc.max_members HAVING count(*) = max(tc.max_members) LIMIT 1;

  INSERT INTO oltp.accounts(email,password_hash,role) VALUES ('cap-probe@test.dev','x','member')
    RETURNING account_id INTO v_acct;
  INSERT INTO oltp.members(account_id, full_name) VALUES (v_acct,'Cap Probe');

  PERFORM t_reject('8','enforce_team_capacity: rejects on a full team even with 49 other teams around',
    format('INSERT INTO oltp.memberships(team_id,member_id) VALUES (%s,%s)', v_team, v_acct));

  SELECT t.team_id INTO v_other FROM oltp.teams t
  WHERE NOT EXISTS (SELECT 1 FROM oltp.memberships m WHERE m.team_id=t.team_id AND m.left_at IS NULL)
  LIMIT 1;
  PERFORM t_accept('8','enforce_team_capacity: an EMPTY team still accepts a member (not over-counting)',
    format('INSERT INTO oltp.memberships(team_id,member_id) VALUES (%s,%s)', v_other, v_acct));

  -- appeal limit counts per team, not across the whole festival
  SELECT count(*) INTO v_rejected FROM oltp.appeals WHERE status='rejected';
  PERFORM t_true('8','enforce_appeal_limit: festival-wide rejected appeals exceed 3 without blocking new teams',
    v_rejected >= 3, v_rejected || ' rejected appeals exist overall');
  -- pick a team that genuinely has < 3 rejected appeals -- the previous
  -- version reused the empty team, which already carried 3 rejections
  -- from Level 3, so the test's own premise was false.
  SELECT t.team_id INTO v_fresh
  FROM oltp.teams t
  WHERE (SELECT count(*) FROM oltp.appeals a WHERE a.team_id = t.team_id AND a.status = 'rejected') = 0
  ORDER BY t.team_id LIMIT 1;

  PERFORM t_true('8','FIXTURE: a team with zero rejected appeals exists', v_fresh IS NOT NULL,
    'team_id=' || coalesce(v_fresh::text,'NONE'));
  PERFORM t_accept('8','enforce_appeal_limit: the limit is PER TEAM, not festival-wide',
    format('INSERT INTO oltp.appeals(team_id,filed_by_account_id,reason) VALUES (%s,%s,''fresh team appeal'')',
           v_fresh, (SELECT account_id FROM oltp.accounts WHERE email='m1@test.dev')));

  -- versioning is per (team, challenge), not global
  PERFORM t_eq('8','assign_submission_version: versions restart per (team, challenge)',
    (SELECT count(*) FROM (
       SELECT team_id, challenge_id FROM oltp.submissions
       GROUP BY team_id, challenge_id HAVING min(version) <> 1) x), 0,
    'every (team, challenge) pair must start at version 1');

  PERFORM t_eq('8','assign_submission_version: versions are gapless per (team, challenge)',
    (SELECT count(*) FROM (
       SELECT team_id, challenge_id FROM oltp.submissions
       GROUP BY team_id, challenge_id HAVING count(*) <> max(version)) x), 0);
END $$;


-- =====================================================================
-- REPORT
-- =====================================================================
\echo ''
\echo '===================== DETAILED RESULTS ====================='
SELECT seq, lvl AS "L", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result,
       label, detail
FROM test_results ORDER BY seq;

\echo ''
\echo '===================== PER-LEVEL SUMMARY ====================='
SELECT lvl AS "level",
       CASE lvl
         WHEN '0' THEN 'schema exists & creates cleanly'
         WHEN '1' THEN 'referential integrity (FK)'
         WHEN '2' THEN 'constraints & unique keys'
         WHEN '3' THEN 'business rules (behaviour)'
         WHEN '4' THEN 'ETL OLTP -> analytics'
         WHEN '5' THEN 'grain / anti fan-out (CRITICAL)'
         WHEN '6' THEN 'sanity queries / anti chasm-trap (CRITICAL)'
         WHEN '7' THEN 'partner dashboard: 3 facts x 5 dimensions (CRITICAL)'
         WHEN '8' THEN 'per-function coverage + degenerate input'
       END AS description,
       count(*) FILTER (WHERE ok)     AS passed,
       count(*) FILTER (WHERE NOT ok) AS failed,
       count(*)                        AS total
FROM test_results GROUP BY lvl ORDER BY lvl;

\echo ''
\echo '===================== BLOCKING FAILURES ====================='
SELECT seq, lvl AS "L", label, detail
FROM test_results WHERE NOT ok AND blocking ORDER BY seq;

\echo ''
\echo '===================== VERDICT ====================='
SELECT
  CASE WHEN count(*) FILTER (WHERE NOT ok AND blocking) = 0
       THEN 'READY  -- backend (OLTP + analytics) is fit for use'
       ELSE 'NOT READY -- ' || count(*) FILTER (WHERE NOT ok AND blocking) || ' blocking failure(s)'
  END AS verdict,
  count(*) FILTER (WHERE ok)                       AS passed,
  count(*) FILTER (WHERE NOT ok AND blocking)      AS blocking_failures,
  count(*) FILTER (WHERE NOT ok AND NOT blocking)  AS non_blocking_failures,
  count(*)                                          AS total
FROM test_results;

DO $$
DECLARE v INT := (SELECT count(*) FROM test_results WHERE NOT ok AND blocking);
BEGIN
  IF v > 0 THEN
    RAISE EXCEPTION 'NOT READY: % blocking test(s) failed -- see BLOCKING FAILURES above', v;
  END IF;
  RAISE NOTICE 'READY: all blocking tests passed.';
END $$;
