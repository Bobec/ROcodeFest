-- =====================================================================
-- ROcodeFest — OLTP Schema (PostgreSQL, 3NF)
-- =====================================================================
-- Operational schema backing the Node.js API: accounts/roles, clubs &
-- teams, join requests, forum, regulations, submissions (with
-- judge-assigned reviews and resubmission versioning), competition
-- (challenges/matches/scores), appeals, certificates, notifications.
--
-- Conventions used throughout:
--   * Surrogate keys use `GENERATED ALWAYS AS IDENTITY` (modern
--     Postgres, replaces legacy SERIAL) except where a natural key
--     already makes a good primary key (subtype tables keyed by
--     account_id).
--   * Every FK has an explicit index unless it's already covered by a
--     PRIMARY KEY or UNIQUE constraint (Postgres does NOT auto-index
--     FK columns, only PK/UNIQUE ones).
--   * Small closed vocabularies that don't need extra admin-editable
--     attributes are Postgres ENUM types; vocabularies that carry
--     extra attributes (e.g. a category's max member count) are
--     lookup TABLES instead, so they can be edited without a
--     migration. Both choices are noted inline where they happen.
--   * Business rules that require aggregating across rows (team
--     capacity by category, max 3 invalid appeals per team) can't be
--     expressed as a plain CHECK constraint in Postgres, so they're
--     enforced with small BEFORE INSERT triggers instead. This is
--     called out at each trigger.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS citext; -- case-insensitive email uniqueness

-- ---------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------
-- The OLTP tables live in their own `oltp` schema, mirroring the tree
-- export's root node ("OLTP SCHEMA") and staying symmetric with the
-- `analytics` schema in 02_analytics_schema.sql. Keeping them out of
-- `public` also means an extension installed into public (citext below,
-- and anything added later) can never collide with a table name here.
--
-- search_path is set for the LOADING SESSION only, so the unqualified
-- CREATE statements below land in `oltp` while CITEXT still resolves
-- from public. Any client that wants unqualified access afterwards
-- should do the same, e.g.:
--     SET search_path = oltp, public;            -- per session
--     ALTER DATABASE rocodefest SET search_path = oltp, public;  -- persistent
-- Otherwise reference tables as oltp.accounts, oltp.teams, ...
CREATE SCHEMA IF NOT EXISTS oltp;
SET search_path = oltp, public;

-- ---------------------------------------------------------------------
-- ENUM types
-- ---------------------------------------------------------------------

CREATE TYPE account_role AS ENUM ('member', 'club', 'judge', 'partner', 'organizer');
-- 'member'  = a Competitor -- the only role that can join a team.
-- 'organizer' = R9. The role that runs the festival: seasons,
--            challenges, matches, panels, the day's schedule, news.
--            Every one of those tables existed from the start and none
--            of them could be written by any account, which stayed
--            invisible while the pages kept their own data and became
--            plain the moment scoring went on the API -- a judge could
--            ask which matches they were officiating and the honest
--            answer was "none, and nothing can change that".
--            An organiser does NOT act as somebody else: they never
--            author a submission, an appeal or a post under another
--            account, because those columns are attribution and a row
--            written that way would say something untrue.
-- 'partner' covers BOTH the "Partner" and "Speaker" registration paths
--            (see partners.partner_type below). Both are external
--            collaborators with the same core shape (org/contact +
--            a message), so one subtype table with a type
--            discriminator avoids a near-duplicate `speakers` table.
--            If speaker-specific structured fields grow later (talk
--            topic, availability slots), split it out into its own
--            subtype table at that point.

CREATE TYPE partner_type AS ENUM ('sponsor', 'speaker', 'mentor', 'vendor', 'other');

-- Shared by join_requests AND appeals -- both are literally the same
-- pending/accepted/rejected decision workflow, so one ENUM is reused
-- instead of declaring two near-identical types.
CREATE TYPE request_status AS ENUM ('pending', 'accepted', 'rejected');

CREATE TYPE challenge_stage AS ENUM ('city_challenge', 'final');
CREATE TYPE match_status AS ENUM ('scheduled', 'in_progress', 'completed', 'cancelled');
CREATE TYPE certificate_type AS ENUM ('participation', 'winner', 'runner_up', 'special_award');
CREATE TYPE notification_type AS ENUM (
  'join_request_received', 'join_request_accepted', 'join_request_rejected',
  'appeal_accepted', 'appeal_rejected',
  'announcement_posted',
  'comment_posted', 'reply_posted',
  'submission_assigned', 'judge_feedback_given'
);
-- submission_assigned / judge_feedback_given are both lifecycle events on
-- one submission_reviews row (see Submissions section) -- that table is
-- both "which judge evaluates this submission" and "what feedback did
-- they leave", so both notification types point at the same source row.

-- =====================================================================
-- Accounts & roles
-- =====================================================================
-- Table-per-subtype (class-table inheritance): `accounts` holds
-- everything every login needs (credentials, role, audit columns);
-- one subtype table per role holds the fields specific to that role.
-- account_id is BOTH the subtype table's primary key AND its foreign
-- key back to accounts, so a `members` row IS a 1:1 extension of an
-- `accounts` row -- there is exactly one place email/password live
-- (3NF: every non-key column depends on the whole key and nothing but
-- the key).
--
-- A role is chosen once at registration and stored on accounts.role
-- (single column, not a many-to-many junction) because that matches
-- how registration actually works today: you sign up AS a club, OR a
-- competitor, OR a judge, OR a partner/speaker -- never several at
-- once. If multi-role accounts are ever needed, swap accounts.role for
-- an account_roles(account_id, role) junction without touching the
-- four subtype tables below.

CREATE TABLE accounts (
  account_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email          CITEXT NOT NULL,
  password_hash  TEXT NOT NULL,
  role           account_role NOT NULL,
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_accounts_email UNIQUE (email)
);

-- ---------------------------------------------------------------------
-- avatar_data_uri, on all four subtype tables
-- ---------------------------------------------------------------------
-- An image in a database column is rarely the right answer, and it is the
-- right answer here: this project has no object storage, and
-- forum_attachments.storage_key already points at one that does not
-- exist. A festival's avatars are small and few.
--
-- The two CHECKs are what keep that true. The size limit -- roughly 150 KB
-- once base64 is accounted for -- is a generous portrait and far too small
-- to be useful as file hosting. The shape check refuses anything that is
-- not an image data URI, so the column cannot quietly become a place to
-- put arbitrary text.
--
-- Per subtype rather than on accounts: a club's picture and a judge's are
-- the same idea about different things, and accounts holds only what every
-- role shares.
--
-- Before this, the picture lived in localStorage as
-- rocodefest_avatar_<name> -- so the same account had an avatar on one
-- computer and none on another, and nobody else ever saw it.
CREATE TABLE members (
  account_id  BIGINT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
  full_name   VARCHAR(150) NOT NULL,
  city        VARCHAR(120),
  bio         TEXT,
  avatar_data_uri TEXT,
  CONSTRAINT ck_members_avatar_size  CHECK (avatar_data_uri IS NULL OR length(avatar_data_uri) <= 200000),
  CONSTRAINT ck_members_avatar_shape CHECK (avatar_data_uri IS NULL OR avatar_data_uri ~ '^data:image/(png|jpeg|gif|webp);base64,'),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE clubs (
  account_id       BIGINT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
  club_name        VARCHAR(150) NOT NULL,
  city             VARCHAR(120),
  coach_name       VARCHAR(150),
  -- Own IDENTITY sequence (independent of account_id): a stable,
  -- always-unique "founding number" assigned in registration order.
  -- Doing this in the DB (not in application code) is what actually
  -- fixes the duplicate "#1" badge bug we hit in the frontend demo,
  -- where the number was recomputed client-side as `clubs.length + 1`
  -- and collided whenever local demo data was reset.
  founding_number  INT GENERATED ALWAYS AS IDENTITY,
  notes            TEXT,
  -- see the note above CREATE TABLE members for why this is a column
  avatar_data_uri  TEXT,
  CONSTRAINT ck_clubs_avatar_size  CHECK (avatar_data_uri IS NULL OR length(avatar_data_uri) <= 200000),
  CONSTRAINT ck_clubs_avatar_shape CHECK (avatar_data_uri IS NULL OR avatar_data_uri ~ '^data:image/(png|jpeg|gif|webp);base64,'),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_clubs_name UNIQUE (club_name),
  CONSTRAINT uq_clubs_founding_number UNIQUE (founding_number)
);

CREATE TABLE judges (
  account_id  BIGINT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
  full_name   VARCHAR(150) NOT NULL,
  expertise   VARCHAR(200),
  bio         TEXT,
  -- see the note above CREATE TABLE members for why this is a column
  avatar_data_uri TEXT,
  CONSTRAINT ck_judges_avatar_size  CHECK (avatar_data_uri IS NULL OR length(avatar_data_uri) <= 200000),
  CONSTRAINT ck_judges_avatar_shape CHECK (avatar_data_uri IS NULL OR avatar_data_uri ~ '^data:image/(png|jpeg|gif|webp);base64,'),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- R9. A fifth subtype rather than an accounts.is_admin flag: the other
-- four are tables because enforce_subtype_role and
-- enforce_role_change_has_no_subtype together make "an account is
-- exactly one kind of thing" something the database holds. A boolean
-- beside the enum would let an account be a club AND an organiser,
-- which is the shape those two triggers exist to refuse. It also gives
-- an organiser a name and a picture, which matters the moment an
-- announcement is attributed to one.
CREATE TABLE organizers (
  account_id  BIGINT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
  full_name   VARCHAR(150) NOT NULL,
  title       VARCHAR(120),
  bio         TEXT,
  -- see the note above CREATE TABLE members for why this is a column
  avatar_data_uri TEXT,
  CONSTRAINT ck_organizers_avatar_size  CHECK (avatar_data_uri IS NULL OR length(avatar_data_uri) <= 200000),
  CONSTRAINT ck_organizers_avatar_shape CHECK (avatar_data_uri IS NULL OR avatar_data_uri ~ '^data:image/(png|jpeg|gif|webp);base64,'),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE partners (
  account_id    BIGINT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
  org_name      VARCHAR(150),
  contact_name  VARCHAR(150) NOT NULL,
  partner_type  partner_type NOT NULL, -- distinguishes Partner vs Speaker (and future types)
  message       TEXT,
  -- see the note above CREATE TABLE members for why this is a column
  avatar_data_uri TEXT,
  CONSTRAINT ck_partners_avatar_size  CHECK (avatar_data_uri IS NULL OR length(avatar_data_uri) <= 200000),
  CONSTRAINT ck_partners_avatar_shape CHECK (avatar_data_uri IS NULL OR avatar_data_uri ~ '^data:image/(png|jpeg|gif|webp);base64,'),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- Clubs & teams
-- =====================================================================

-- Lookup table, not an ENUM: each category carries an extra business
-- attribute (max_members) that legitimately varies and may need
-- editing (e.g. bumping Programming's cap) without a schema migration.
CREATE TABLE team_categories (
  category_id  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         VARCHAR(20) NOT NULL,
  label        VARCHAR(60) NOT NULL,
  max_members  SMALLINT NOT NULL CHECK (max_members > 0),
  CONSTRAINT uq_team_categories_code UNIQUE (code)
);

-- Robotics/Programming caps per spec; Design/Other caps are a
-- reasonable default (assumption) -- change via UPDATE, no migration.
INSERT INTO team_categories (code, label, max_members) VALUES
  ('ROBOTICS',    'Robotics',    5),
  ('PROGRAMMING', 'Programming', 3),
  ('DESIGN',      'Design',      5),
  ('OTHER',       'Other',       5);

CREATE TABLE teams (
  team_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  club_id             BIGINT NOT NULL REFERENCES clubs(account_id) ON DELETE CASCADE,
  category_id         SMALLINT NOT NULL REFERENCES team_categories(category_id),
  team_name           VARCHAR(150) NOT NULL,
  participation_code  VARCHAR(20) NOT NULL, -- public-facing team code (e.g. shown on badges/certificates)
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_teams_participation_code UNIQUE (participation_code),
  CONSTRAINT uq_teams_club_name UNIQUE (club_id, team_name) -- a club can't register two teams with the same name
);
CREATE INDEX ix_teams_club_id ON teams(club_id);
CREATE INDEX ix_teams_category_id ON teams(category_id);

-- Join requests belong to this domain (a request is addressed to a
-- team), and they're declared BEFORE memberships because an approved
-- request is what produces a membership -- see
-- memberships.source_request_id below.
CREATE TABLE join_requests (
  request_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  member_id     BIGINT NOT NULL REFERENCES members(account_id) ON DELETE CASCADE,
  team_id       BIGINT NOT NULL REFERENCES teams(team_id) ON DELETE CASCADE,
  status        request_status NOT NULL DEFAULT 'pending',
  message       TEXT,
  requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at    TIMESTAMPTZ,
  decided_by    BIGINT REFERENCES accounts(account_id), -- the club account that accepted/rejected
  -- R7: a decision cannot predate the request it decides. NULL-tolerant,
  -- because an undecided request legitimately has no decided_at.
  CONSTRAINT ck_join_requests_decided_after_requested
    CHECK (decided_at IS NULL OR decided_at >= requested_at)
);
CREATE INDEX ix_join_requests_member_id ON join_requests(member_id);
CREATE INDEX ix_join_requests_team_id ON join_requests(team_id);
CREATE INDEX ix_join_requests_decided_by ON join_requests(decided_by);
-- Only one PENDING request per (member, team); a member CAN re-request
-- after a rejection, so this must be a partial unique index scoped to
-- status='pending', not a full unique constraint on (member_id, team_id).
CREATE UNIQUE INDEX uq_join_requests_pending
  ON join_requests(member_id, team_id) WHERE status = 'pending';
-- R8: request_id is already unique as the PK, so this adds no
-- restriction -- it exists so memberships can point a COMPOSITE FK at
-- the whole triple and prove a membership came from ITS OWN request.
CREATE UNIQUE INDEX uq_join_requests_identity
  ON join_requests (request_id, member_id, team_id);

-- Many-to-many members <-> teams. A surrogate PK (not a composite
-- (team_id, member_id) PK) is used because a membership carries its
-- own attributes (role_title, joined_at/left_at) and needs to support
-- history: a member can leave and later rejoin the same team, which
-- would violate a plain composite-PK/UNIQUE if we tried to reuse the
-- same row identity for both stints.
CREATE TABLE memberships (
  membership_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  team_id        BIGINT NOT NULL REFERENCES teams(team_id) ON DELETE CASCADE,
  member_id      BIGINT NOT NULL REFERENCES members(account_id) ON DELETE CASCADE,
  -- Provenance: which approved join_request created this membership.
  -- NULLABLE on purpose -- a club can also add a member to one of its
  -- own teams directly, with no request in between, and historical
  -- rows predating this column have no request to point at. It is NOT
  -- a duplicate of (team_id, member_id): a member who left and
  -- rejoined has two membership rows, each traceable to the specific
  -- request that produced it. ON DELETE SET NULL so purging old
  -- request history never deletes an active roster row.
  --
  -- R8: the link is a COMPOSITE FK, not a bare one. A single-column
  -- reference proved only that the request exists -- it could belong to
  -- another member, or be for another team, and the audit trail would
  -- then read "this person joined because of that request" when the
  -- request was for someone else entirely. Same shape scores uses into
  -- match_teams, and both forum edges R6 added.
  source_request_id  BIGINT,
  role_title     VARCHAR(60), -- e.g. 'Captain'; free text, optional
  joined_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  left_at        TIMESTAMPTZ, -- NULL while the membership is active
  -- R7: a membership cannot end before it begins. Worth stating even
  -- though enforce_team_capacity keys on left_at IS NULL rather than on
  -- the dates -- which is precisely why a reversed interval used to be
  -- invisible from the one place that reads the column.
  CONSTRAINT ck_memberships_left_after_joined
    CHECK (left_at IS NULL OR left_at >= joined_at),
  -- ON DELETE SET NULL names its COLUMN. Without the column list Postgres
  -- nulls every referencing column, which here means member_id and
  -- team_id too -- both NOT NULL, so deleting a join request would fail
  -- outright instead of just clearing the provenance. The single-column
  -- FK this replaced had no such trap, and the QA suite caught it.
  CONSTRAINT fk_memberships_source_request_matches
    FOREIGN KEY (source_request_id, member_id, team_id)
    REFERENCES join_requests (request_id, member_id, team_id)
    ON DELETE SET NULL (source_request_id)
);
CREATE INDEX ix_memberships_team_id ON memberships(team_id);
CREATE INDEX ix_memberships_member_id ON memberships(member_id);
CREATE INDEX ix_memberships_source_request_id ON memberships(source_request_id);
-- Only one ACTIVE membership per (team, member) at a time; a partial
-- unique index (not a table constraint) so leaving and rejoining is
-- allowed -- a full UNIQUE(team_id, member_id) would permanently block
-- rejoining after a single departure.
CREATE UNIQUE INDEX uq_memberships_active_team_member
  ON memberships(team_id, member_id) WHERE left_at IS NULL;
-- One request can only ever produce ONE membership -- a partial unique
-- index (skipping the NULLs, which a plain UNIQUE would treat as all
-- distinct anyway) so an approved request can't be replayed into
-- several roster rows.
CREATE UNIQUE INDEX uq_memberships_source_request
  ON memberships(source_request_id) WHERE source_request_id IS NOT NULL;

-- =====================================================================
-- Forum
-- =====================================================================

-- Lookup table, not an ENUM: forum categories are the kind of thing an
-- organizer wants to add/rename/reorder from an admin screen without a
-- deploy.
CREATE TABLE forum_categories (
  category_id  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         VARCHAR(30) NOT NULL,
  label        VARCHAR(60) NOT NULL,
  sort_order   SMALLINT NOT NULL DEFAULT 0,
  CONSTRAINT uq_forum_categories_code UNIQUE (code)
);

-- Seeded, like team_categories and forum_allowed_mime_types: a lookup
-- table with no rows is a foreign key nothing can satisfy, and
-- forum_posts.category_id is NOT NULL. The forum page named these four
-- in its own markup and this table was empty, so no post it composed
-- could ever have become a row.
--
-- 'announcements' is the fifth because the page has a separate
-- announcements strip. It is a category like the others -- what makes
-- it different is who may post to it, which is a question for the API,
-- not for this table.
INSERT INTO forum_categories (code, label, sort_order) VALUES
  ('announcements', 'Announcements', 0),
  ('general',       'All general',   1),
  ('robotics',      'Robotics',      2),
  ('programming',   'Programming',   3),
  ('design',        'Design',        4);

CREATE TABLE forum_posts (
  post_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  category_id        SMALLINT NOT NULL REFERENCES forum_categories(category_id),
  author_account_id  BIGINT NOT NULL REFERENCES accounts(account_id),
  title              VARCHAR(200) NOT NULL,
  body               TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at          TIMESTAMPTZ,
  is_deleted         BOOLEAN NOT NULL DEFAULT FALSE, -- soft delete: preserves thread/reply integrity for moderation
  CONSTRAINT ck_forum_posts_edited_after_created
    CHECK (edited_at IS NULL OR edited_at >= created_at),
  -- Target of the composite FK from forum_post_tags: it is what makes a
  -- post's category and its tags' category unable to disagree.
  CONSTRAINT uq_forum_posts_category_post UNIQUE (category_id, post_id)
);
CREATE INDEX ix_forum_posts_category_id ON forum_posts(category_id);
CREATE INDEX ix_forum_posts_author_id ON forum_posts(author_account_id);
-- NOTE: post "type" (member vs club) is intentionally NOT a stored
-- column here. It's derived by joining author_account_id -> accounts.
-- role, so it can never drift out of sync with the account's actual
-- role -- storing a copy would be redundant, derivable data (violates
-- 3NF: it wouldn't depend on this table's own key).

CREATE TABLE forum_comments (
  comment_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  post_id            BIGINT NOT NULL REFERENCES forum_posts(post_id) ON DELETE CASCADE,
  parent_comment_id  BIGINT,   -- optional nested reply; see the composite FK below
  author_account_id  BIGINT NOT NULL REFERENCES accounts(account_id),
  body               TEXT NOT NULL,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at          TIMESTAMPTZ,
  is_deleted         BOOLEAN NOT NULL DEFAULT FALSE,
  -- Referencing comment_id alone let a reply hang under a comment
  -- belonging to a DIFFERENT post, silently breaking the thread. The
  -- composite FK below ties parent and child to the same post -- the
  -- same technique scores uses with (match_id, team_id) into
  -- match_teams, and for the same reason.
  CONSTRAINT uq_forum_comments_post_comment UNIQUE (post_id, comment_id),
  CONSTRAINT fk_forum_comments_parent_same_post
    FOREIGN KEY (post_id, parent_comment_id)
    REFERENCES forum_comments(post_id, comment_id) ON DELETE CASCADE,
  -- The trivial cycle is a one-row comparison, so a CHECK reaches it.
  -- Longer cycles (A -> B -> A) need the ancestry walk in
  -- enforce_comment_acyclic(), because every individual reference in a
  -- cycle is perfectly valid.
  CONSTRAINT ck_forum_comments_not_self_parent
    CHECK (parent_comment_id IS DISTINCT FROM comment_id),
  CONSTRAINT ck_forum_comments_edited_after_created
    CHECK (edited_at IS NULL OR edited_at >= created_at)
);
CREATE INDEX ix_forum_comments_post_id ON forum_comments(post_id);
CREATE INDEX ix_forum_comments_parent_id ON forum_comments(parent_comment_id);
CREATE INDEX ix_forum_comments_author_id ON forum_comments(author_account_id);

-- Metadata only, per spec -- actual file bytes live in object storage
-- (S3-compatible bucket etc.), referenced elsewhere by the app; this
-- table never stores file content. Can attach to a post OR a comment,
-- never neither/both: modelled as two nullable FKs plus a CHECK using
-- num_nonnulls() rather than a polymorphic type+id pair, so both
-- relationships stay real, indexable foreign keys.
CREATE TABLE forum_attachments (
  attachment_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  post_id        BIGINT REFERENCES forum_posts(post_id) ON DELETE CASCADE,
  comment_id     BIGINT REFERENCES forum_comments(comment_id) ON DELETE CASCADE,
  file_name      VARCHAR(255) NOT NULL,
  mime_type      VARCHAR(100) NOT NULL,
  size_bytes     INTEGER NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 1048576), -- <= 1 MB, enforced in-DB
  -- Where the bytes actually live. Without it the row records THAT a
  -- file exists but not WHICH one: it cannot be fetched, its declared
  -- type cannot be checked against reality, and once the row is gone
  -- nothing can find the object to clean it up. certificates.file_url
  -- already sets the precedent for storing a location.
  storage_key    TEXT NOT NULL,
  checksum_sha256 CHAR(64),
  -- Who attached it. The parent post has an author, but a moderator or
  -- a second member adding a file to an existing thread is a different
  -- actor -- and every other actor-bearing table here records one.
  uploaded_by_account_id BIGINT NOT NULL REFERENCES accounts(account_id),
  uploaded_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_forum_attachments_one_parent CHECK (num_nonnulls(post_id, comment_id) = 1),
  -- The declared type must at least BE a type. Which types are allowed
  -- is policy and lives in forum_allowed_mime_types below.
  CONSTRAINT ck_forum_attachments_mime_shape
    CHECK (mime_type ~ '^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$')
);
CREATE INDEX ix_forum_attachments_post_id ON forum_attachments(post_id);
CREATE INDEX ix_forum_attachments_comment_id ON forum_attachments(comment_id);

CREATE INDEX ix_forum_attachments_uploaded_by ON forum_attachments(uploaded_by_account_id);
CREATE INDEX ix_forum_attachments_storage_key ON forum_attachments(storage_key);

-- Lookup table, not a CHECK: which file types a forum accepts is a
-- product decision an organiser changes without a migration. extensions
-- lets the trigger verify the name agrees with the declared type --
-- since the bytes are not in the database, the declared type is the only
-- signal there is, so it must at least be self-consistent.
CREATE TABLE forum_allowed_mime_types (
  mime_type   VARCHAR(100) PRIMARY KEY,
  extensions  TEXT[] NOT NULL,        -- lower-case, no dot
  label       VARCHAR(60) NOT NULL
);
INSERT INTO forum_allowed_mime_types(mime_type, extensions, label) VALUES
  ('image/png',       ARRAY['png'],             'PNG image'),
  ('image/jpeg',      ARRAY['jpg','jpeg'],      'JPEG image'),
  ('image/gif',       ARRAY['gif'],             'GIF image'),
  ('application/pdf', ARRAY['pdf'],             'PDF document'),
  ('text/plain',      ARRAY['txt','log','csv'], 'Plain text'),
  ('application/zip', ARRAY['zip'],             'ZIP archive'),
  ('video/mp4',       ARRAY['mp4'],             'MP4 video');

-- Outbox for the storage sweeper. Deleting a post CASCADEs its
-- attachment rows away, and those rows were the only reference to the
-- stored objects -- so without a tombstone the bytes become unreachable
-- and unfindable. A row here survives the cascade; purged_at is stamped
-- once the object is actually gone from the bucket.
CREATE TABLE forum_attachment_deletions (
  deletion_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  storage_key  TEXT NOT NULL,
  file_name    VARCHAR(255) NOT NULL,
  size_bytes   INTEGER NOT NULL,
  deleted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  purged_at    TIMESTAMPTZ
);
CREATE INDEX ix_forum_attachment_deletions_pending
  ON forum_attachment_deletions(deleted_at) WHERE purged_at IS NULL;

-- Lookup table, scoped to a category (not global) -- a "Robotics" tag
-- and a "Forum" tag can both read as e.g. "Help Wanted" without
-- colliding, and an admin can rename/retire tags per category without
-- touching unrelated ones.
CREATE TABLE forum_tags (
  tag_id       SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  category_id  SMALLINT NOT NULL REFERENCES forum_categories(category_id),
  label        VARCHAR(40) NOT NULL,
  CONSTRAINT uq_forum_tags_category_label UNIQUE (category_id, label),
  -- Target of the composite FK from forum_post_tags.
  CONSTRAINT uq_forum_tags_category_tag UNIQUE (category_id, tag_id)
);
CREATE INDEX ix_forum_tags_category_id ON forum_tags(category_id);

-- Many-to-many post <-> tag.
--
-- An earlier version of this comment argued that category_id must NOT be
-- repeated here, because a copy could drift from its two parents. That
-- was right about a BARE copy and wrong about the remedy: a copy pinned
-- by two composite FKs cannot drift, because both parents have to agree
-- with it. Disagreement becomes unrepresentable rather than merely
-- discouraged -- and "a post may only wear tags from its own category"
-- stops being an application-layer hope.
CREATE TABLE forum_post_tags (
  post_id      BIGINT NOT NULL,
  tag_id       SMALLINT NOT NULL,
  category_id  SMALLINT NOT NULL,
  PRIMARY KEY (post_id, tag_id),
  CONSTRAINT fk_forum_post_tags_post FOREIGN KEY (category_id, post_id)
    REFERENCES forum_posts(category_id, post_id) ON DELETE CASCADE,
  CONSTRAINT fk_forum_post_tags_tag FOREIGN KEY (category_id, tag_id)
    REFERENCES forum_tags(category_id, tag_id) ON DELETE CASCADE
);
CREATE INDEX ix_forum_post_tags_tag_id ON forum_post_tags(tag_id);

-- =====================================================================
-- Regulations & rules
-- =====================================================================

CREATE TABLE rule_sections (
  section_id  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        VARCHAR(5) NOT NULL, -- e.g. 'G' (General), 'S' (Season/Scoring), 'A' (Appeals), 'E' (Eligibility)
  title       VARCHAR(100) NOT NULL,
  sort_order  SMALLINT NOT NULL DEFAULT 0,
  CONSTRAINT uq_rule_sections_code UNIQUE (code)
);

CREATE TABLE rules (
  rule_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  section_id     SMALLINT NOT NULL REFERENCES rule_sections(section_id),
  code           VARCHAR(10) NOT NULL, -- e.g. 'G4', 'A21', 'E2' -- the citable business key everyone actually uses
  title          VARCHAR(200) NOT NULL,
  body           TEXT NOT NULL,
  version_label  VARCHAR(30),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Withdrawal without destruction. A retired rule stops being citable
  -- but every existing citation still resolves -- deleting it would
  -- leave posts and appeals arguing from a rule nobody can look up.
  retired_at     TIMESTAMPTZ,
  CONSTRAINT uq_rules_code UNIQUE (code)
);
CREATE INDEX ix_rules_section_id ON rules(section_id);

-- Append-only history of every wording a rule has ever had.
--
-- Without it, editing G4 rewrote history: every appeal and every forum
-- post that had ever cited it silently started pointing at the new text.
-- For a competition rulebook that is the sharpest failure available --
-- a dispute decided against wording the filer never saw.
--
-- `rules` stays the IDENTITY of a rule (its code, its section, its
-- current state); this is what a citation actually pins itself to.
CREATE TABLE rule_revisions (
  revision_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_id        BIGINT NOT NULL REFERENCES rules(rule_id) ON DELETE CASCADE,
  title          VARCHAR(200) NOT NULL,
  body           TEXT NOT NULL,
  version_label  VARCHAR(30),
  recorded_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_rule_revisions_rule_id ON rule_revisions(rule_id, revision_id DESC);
-- `code` duplicates the section's prefix (G4 starts with the 'G'
-- section code) -- a small, deliberate denormalization. Composing it
-- from section_id + a sequence number on every read would be more
-- "pure" 3NF, but codes are how staff and users actually reference
-- rules (forum posts, appeals), so storing the authoritative display
-- code directly avoids fragile string-building logic scattered across
-- the app.

-- Many-to-many: a forum post can cite several rules, and a rule can be
-- cited by many posts. Composite PK (no surrogate key needed) because
-- the pair itself is the whole fact being recorded.
-- rule_id deliberately has NO ON DELETE CASCADE. It used to, which meant
-- deleting a rule silently erased every forum citation of it while the
-- identical DELETE against an appeal-cited rule was refused -- one act,
-- two behaviours, neither of them a decision. Both paths now refuse;
-- withdrawal goes through rules.retired_at instead.
CREATE TABLE post_rule_references (
  post_id            BIGINT NOT NULL REFERENCES forum_posts(post_id) ON DELETE CASCADE,
  rule_id            BIGINT NOT NULL REFERENCES rules(rule_id),
  -- WHICH wording was invoked. Filled by trigger, not by the caller:
  -- work left to an application layer is work nothing does.
  cited_revision_id  BIGINT REFERENCES rule_revisions(revision_id),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, rule_id)
);
CREATE INDEX ix_post_rule_references_cited_revision ON post_rule_references(cited_revision_id);
CREATE INDEX ix_post_rule_references_rule_id ON post_rule_references(rule_id);

-- =====================================================================
-- Competition: seasons, challenges, matches, scores
-- =====================================================================

CREATE TABLE seasons (
  season_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name        VARCHAR(60) NOT NULL,
  start_date  DATE NOT NULL,
  end_date    DATE,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT uq_seasons_name UNIQUE (name),
  -- R7: a season cannot end before it starts. A reversed range yields an
  -- EMPTY reporting window rather than an error, so every report built on
  -- it returns nothing and merely looks quiet.
  CONSTRAINT ck_seasons_end_after_start
    CHECK (end_date IS NULL OR end_date >= start_date)
);
-- R7: at most one active season. "One active season per year" was the
-- rule given; this is the stricter reading and satisfies it for any
-- cadence of one season a year, whereas scoping to the calendar year
-- would permit two active seasons whose start dates straddle a new year
-- -- exactly the situation the flag exists to prevent.
--
-- A partial unique index on a constant is how "at most one row satisfies
-- this predicate" is said in SQL, and the schema already uses the shape
-- twice above (uq_memberships_active_team_member, uq_join_requests_pending).
CREATE UNIQUE INDEX uq_seasons_single_active
  ON seasons ((TRUE)) WHERE is_active;

CREATE TABLE challenges (
  challenge_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  season_id            SMALLINT NOT NULL REFERENCES seasons(season_id),
  category_id          SMALLINT REFERENCES team_categories(category_id), -- NULL = applies to every category
  name                 VARCHAR(150) NOT NULL,
  description          TEXT,
  stage                challenge_stage NOT NULL,
  submission_deadline  TIMESTAMPTZ
);
CREATE INDEX ix_challenges_season_id ON challenges(season_id);
CREATE INDEX ix_challenges_category_id ON challenges(category_id);

CREATE TABLE matches (
  match_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  challenge_id  BIGINT NOT NULL REFERENCES challenges(challenge_id) ON DELETE CASCADE,
  round_name    VARCHAR(100),
  scheduled_at  TIMESTAMPTZ,
  location      VARCHAR(150),
  status        match_status NOT NULL DEFAULT 'scheduled'
);
CREATE INDEX ix_matches_challenge_id ON matches(challenge_id);

-- Many-to-many matches <-> teams (a match can involve several teams:
-- head-to-head heats, multi-team rounds, etc.).
CREATE TABLE match_teams (
  match_id  BIGINT NOT NULL REFERENCES matches(match_id) ON DELETE CASCADE,
  team_id   BIGINT NOT NULL REFERENCES teams(team_id) ON DELETE CASCADE,
  PRIMARY KEY (match_id, team_id)
);
CREATE INDEX ix_match_teams_team_id ON match_teams(team_id);

-- Which judges sit on a match's panel. A judge is assigned to a BLOCK of
-- matches: one judge -> N matches, one match -> N judges, so the pair
-- itself is the whole fact and needs no surrogate key -- the same shape
-- as match_teams above.
--
-- Without it, scores.judge_id proved the account was A judge but never
-- THE judge for that match, so anyone with the role could score anything.
CREATE TABLE match_judges (
  match_id     BIGINT NOT NULL REFERENCES matches(match_id) ON DELETE CASCADE,
  judge_id     BIGINT NOT NULL REFERENCES judges(account_id) ON DELETE CASCADE,
  assigned_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (match_id, judge_id)
);
-- match_id already leads the PK; judge_id does not, and this is the index
-- that answers "which matches is this judge on?" -- i.e. reads a block.
CREATE INDEX ix_match_judges_judge_id ON match_judges(judge_id);

CREATE TABLE scores (
  score_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  match_id            BIGINT NOT NULL,
  team_id             BIGINT NOT NULL,
  judge_id            BIGINT NOT NULL REFERENCES judges(account_id),
  innovation_score    SMALLINT NOT NULL CHECK (innovation_score BETWEEN 1 AND 10),
  execution_score     SMALLINT NOT NULL CHECK (execution_score BETWEEN 1 AND 10),
  presentation_score  SMALLINT NOT NULL CHECK (presentation_score BETWEEN 1 AND 10),
  teamwork_score      SMALLINT NOT NULL CHECK (teamwork_score BETWEEN 1 AND 10),
  -- Generated column: total is always innovation+execution+presentation
  -- +teamwork, so it's computed and stored by Postgres itself rather
  -- than trusted to app code -- it can never drift from its inputs.
  total_score         SMALLINT GENERATED ALWAYS AS
                         (innovation_score + execution_score + presentation_score + teamwork_score) STORED,
  comment             TEXT,
  scored_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Composite FK: a score can only be recorded for a (match, team) pair
  -- that is actually registered in match_teams -- prevents scoring a
  -- team that isn't in that match.
  CONSTRAINT fk_scores_match_team FOREIGN KEY (match_id, team_id)
    REFERENCES match_teams(match_id, team_id) ON DELETE CASCADE,
  -- The judge side of the same idea. Declarative rather than a trigger:
  -- it is enforced on UPDATE as well as INSERT, and it mirrors the team
  -- guard above. A score now depends on TWO composite parents, because
  -- the two facts are independent and both must hold.
  CONSTRAINT fk_scores_match_judge FOREIGN KEY (match_id, judge_id)
    REFERENCES match_judges(match_id, judge_id) ON DELETE CASCADE,
  -- One score row per judge per team per match; a judge revising their
  -- score should UPDATE this row, not insert a second one.
  CONSTRAINT uq_scores_match_team_judge UNIQUE (match_id, team_id, judge_id)
);
CREATE INDEX ix_scores_judge_id ON scores(judge_id);
CREATE INDEX ix_scores_team_id ON scores(team_id);
CREATE INDEX ix_scores_match_id ON scores(match_id);

-- =====================================================================
-- Appeals
-- =====================================================================

CREATE TABLE appeals (
  appeal_id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  team_id                BIGINT NOT NULL REFERENCES teams(team_id) ON DELETE CASCADE,
  match_id                BIGINT REFERENCES matches(match_id),
  score_id                BIGINT REFERENCES scores(score_id), -- the specific score being appealed, if any
  -- DEPRECATED: superseded by appeal_rule_references below, which allows
  -- several rules per appeal. Kept because existing readers write it;
  -- drop it once none remain.
  rule_id                 BIGINT REFERENCES rules(rule_id),   -- optional cited rule (e.g. G4, A21)
  cited_revision_id       BIGINT REFERENCES rule_revisions(revision_id),
  filed_by_account_id     BIGINT NOT NULL REFERENCES accounts(account_id),
  livestream_timestamp    INTERVAL, -- elapsed time into the stream, e.g. '01:42:30'
  reason                  TEXT NOT NULL,
  status                  request_status NOT NULL DEFAULT 'pending',
  decided_at               TIMESTAMPTZ,
  -- R7: the decider must be a JUDGE, not merely an account. Two FKs on
  -- one column: judges.account_id is itself an FK to accounts, so both
  -- hold at once and the original keeps documenting that this IS an
  -- account. Without the second one a club or a member could be recorded
  -- as having ruled on a protest against their own team.
  decided_by_account_id    BIGINT REFERENCES accounts(account_id)
                                  REFERENCES judges(account_id),
  -- R7: the rule the VERDICT rests on, distinct from rule_id above,
  -- which is the rule the FILER invoked. A judge may decide on different
  -- grounds, and "you cited G4, but the decision is made under A21" is a
  -- real outcome that one shared column cannot express -- reusing rule_id
  -- would also silently rewrite the filer's citation, destroying the
  -- record R5 exists to protect.
  decided_under_rule_id    BIGINT REFERENCES rules(rule_id),
  decided_revision_id      BIGINT REFERENCES rule_revisions(revision_id),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- R7: "an appeal is closed when the judge gives a final answer,
  -- supported by a rule" -- so closing requires all three: who, when, and
  -- under which rule. Expressible as a CHECK because every column
  -- involved lives on this row.
  CONSTRAINT ck_appeals_closure_is_accountable
    CHECK (status = 'pending'
           OR (decided_at IS NOT NULL
               AND decided_by_account_id IS NOT NULL
               AND decided_under_rule_id IS NOT NULL)),
  -- R7: a decision cannot be dated before the appeal was filed.
  CONSTRAINT ck_appeals_decided_after_created
    CHECK (decided_at IS NULL OR decided_at >= created_at)
);
CREATE INDEX ix_appeals_team_id ON appeals(team_id);
CREATE INDEX ix_appeals_match_id ON appeals(match_id);
CREATE INDEX ix_appeals_score_id ON appeals(score_id);
CREATE INDEX ix_appeals_rule_id ON appeals(rule_id);
CREATE INDEX ix_appeals_filed_by ON appeals(filed_by_account_id);
CREATE INDEX ix_appeals_decided_by ON appeals(decided_by_account_id);
CREATE INDEX ix_appeals_cited_revision ON appeals(cited_revision_id);
CREATE INDEX ix_appeals_decided_under_rule ON appeals(decided_under_rule_id);

COMMENT ON COLUMN appeals.decided_under_rule_id IS
  'The rule the VERDICT rests on. Distinct from rule_id, which is the rule '
  'the filer invoked -- a judge may decide on different grounds, and both '
  'claims are part of the record.';
COMMENT ON COLUMN appeals.decided_revision_id IS
  'The revision of decided_under_rule_id as it read when the decision was '
  'taken, pinned the same way cited_revision_id is pinned at filing.';

-- A forum post could cite any number of rules through a junction, but an
-- appeal was capped at one by a single nullable FK -- so "this breaches
-- G4 and A21" was not expressible and the rest went into free-text
-- `reason`, where nothing can query it. A real dispute breaches several
-- rules at once. Same shape as post_rule_references, deliberately: the
-- two citation paths should not be modelled differently.
CREATE TABLE appeal_rule_references (
  appeal_id          BIGINT NOT NULL REFERENCES appeals(appeal_id) ON DELETE CASCADE,
  rule_id            BIGINT NOT NULL REFERENCES rules(rule_id),
  cited_revision_id  BIGINT REFERENCES rule_revisions(revision_id),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (appeal_id, rule_id)
);
CREATE INDEX ix_appeal_rule_references_rule_id ON appeal_rule_references(rule_id);

-- =====================================================================
-- Submissions  (part of the Competition domain: a submission is always
--               "for" a challenge -- kept as its own section here only
--               because it must be declared after appeals/scores)
-- =====================================================================

-- Versioned, not edit-in-place: a judge can send a submission back for
-- rework (see submission_reviews.requires_resubmission below), and the
-- team's next attempt for the same challenge needs its own row so the
-- review history isn't overwritten. `version` is assigned by
-- trg_submissions_version (see Triggers) rather than trusted to the
-- client, so a caller cannot skip or forge one.
--
-- Duplicates under concurrency are stopped by
-- uq_submissions_team_challenge_version below, NOT by that trigger --
-- see the note at assign_submission_version() for the measurement.
CREATE TABLE submissions (
  submission_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  team_id                  BIGINT NOT NULL REFERENCES teams(team_id) ON DELETE CASCADE,
  challenge_id             BIGINT NOT NULL REFERENCES challenges(challenge_id) ON DELETE CASCADE,
  version                  SMALLINT NOT NULL DEFAULT 1,
  title                    VARCHAR(200) NOT NULL,
  description              TEXT,
  link_url                 TEXT,
  submitted_by_account_id  BIGINT NOT NULL REFERENCES accounts(account_id),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_submissions_team_challenge_version UNIQUE (team_id, challenge_id, version)
);
CREATE INDEX ix_submissions_challenge_id ON submissions(challenge_id);
CREATE INDEX ix_submissions_submitted_by ON submissions(submitted_by_account_id);
-- (team_id already indexed via the UNIQUE constraint above.)

-- Connects a judge to a specific submission: the row's existence is the
-- assignment ("this judge evaluates this submission"), and `feedback`
-- filled in later is the review. One judge can review the same team's
-- submission again for a resubmission -- that's just a new submissions
-- row (new version) getting its own submission_reviews row, so a
-- judge's full history for a team/challenge is every review row across
-- every version, joinable straight back through submission_id.
CREATE TABLE submission_reviews (
  review_id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  submission_id          BIGINT NOT NULL REFERENCES submissions(submission_id) ON DELETE CASCADE,
  judge_id               BIGINT NOT NULL REFERENCES judges(account_id) ON DELETE CASCADE,
  feedback                TEXT, -- NULL = assigned, not yet reviewed
  requires_resubmission   BOOLEAN NOT NULL DEFAULT FALSE,
  reviewed_at             TIMESTAMPTZ, -- NULL until feedback is actually given
  assigned_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_submission_reviews_submission_judge UNIQUE (submission_id, judge_id),
  -- R8: reviewed_at and feedback are two independent answers to "was
  -- this reviewed?", and they must not disagree. A timestamp with no
  -- text says a judge reviewed the submission and said nothing, which
  -- reads as an empty verdict rather than as a missing one. An
  -- ASSIGNED-but-not-yet-reviewed row is untouched: that is the ordinary
  -- starting state, and both columns are NULL there.
  CONSTRAINT ck_submission_reviews_verdict_has_text
    CHECK (reviewed_at IS NULL OR feedback IS NOT NULL)
);
CREATE INDEX ix_submission_reviews_submission_id ON submission_reviews(submission_id);
CREATE INDEX ix_submission_reviews_judge_id ON submission_reviews(judge_id);

-- =====================================================================
-- Certificates
-- =====================================================================

-- --- the day's agenda (R9) --------------------------------------------
-- matches already carry scheduled_at and location, so the times of the
-- competition itself need no new table. What has no home is everything
-- between the matches: the opening, the lunch break, the awards. Those
-- are what turn a list of match times into a run of show.
--
-- Matches are NOT copied in here. A schedule row may POINT at one, and
-- the contest-day page merges the two streams by time. Copying would
-- create a second scheduled_at, and two copies of a time are two times
-- that disagree the first time one of them moves.
CREATE TYPE schedule_kind AS ENUM
  ('opening', 'match', 'break', 'talk', 'awards', 'other');

CREATE TABLE schedule_items (
  item_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  season_id   SMALLINT NOT NULL REFERENCES seasons(season_id) ON DELETE CASCADE,
  match_id    BIGINT REFERENCES matches(match_id) ON DELETE CASCADE,
  kind        schedule_kind NOT NULL,
  title       VARCHAR(150) NOT NULL,
  detail      TEXT,
  location    VARCHAR(150),
  starts_at   TIMESTAMPTZ NOT NULL,
  ends_at     TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_schedule_items_ends_after_starts
    CHECK (ends_at IS NULL OR ends_at >= starts_at),
  -- A row pointing at a match must say it is one; otherwise 'break'
  -- could carry a match_id and the page would draw a lunch break where
  -- a match belongs.
  CONSTRAINT ck_schedule_items_match_kind
    CHECK (match_id IS NULL OR kind = 'match'),
  -- A match listed twice is a match the audience is told to watch in
  -- two places at once.
  CONSTRAINT uq_schedule_items_match UNIQUE (match_id)
);
CREATE INDEX ix_schedule_items_season ON schedule_items(season_id);
CREATE INDEX ix_schedule_items_starts ON schedule_items(starts_at);

-- --- news (R9) --------------------------------------------------------
-- Separate from the forum's announcements category on purpose: an
-- announcement is a thread people reply to, an article is not.
--
-- published_at is nullable so a draft is a row without a publication
-- date, rather than a status column that would then need rules of its
-- own about which transitions are legal.
CREATE TABLE news_posts (
  news_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  author_account_id BIGINT NOT NULL REFERENCES accounts(account_id),
  title             VARCHAR(200) NOT NULL,
  summary           VARCHAR(400),
  body              TEXT NOT NULL,
  published_at      TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_news_posts_published ON news_posts(published_at DESC NULLS LAST);

CREATE TABLE certificates (
  certificate_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  team_id           BIGINT NOT NULL REFERENCES teams(team_id) ON DELETE CASCADE,
  member_id         BIGINT REFERENCES members(account_id) ON DELETE CASCADE, -- NULL = team-level certificate
  season_id         SMALLINT NOT NULL REFERENCES seasons(season_id),
  certificate_type  certificate_type NOT NULL DEFAULT 'participation',
  serial_code       VARCHAR(40) NOT NULL, -- verifiable public ID, e.g. 'RCFEST-2026-000123'
  file_url          TEXT,                 -- generated PDF/PNG in object storage
  issued_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_certificates_serial UNIQUE (serial_code)
);
CREATE INDEX ix_certificates_team_id ON certificates(team_id);
CREATE INDEX ix_certificates_member_id ON certificates(member_id);
CREATE INDEX ix_certificates_season_id ON certificates(season_id);
-- "Issued per team OR per participant" is modelled with one table and
-- a nullable member_id rather than two near-identical tables. Because
-- a plain UNIQUE constraint treats every NULL as distinct (so it would
-- NOT stop two team-level certs of the same type existing), uniqueness
-- is split into two partial indexes instead:
CREATE UNIQUE INDEX uq_certificates_team_level
  ON certificates(team_id, season_id, certificate_type) WHERE member_id IS NULL;
CREATE UNIQUE INDEX uq_certificates_participant_level
  ON certificates(team_id, member_id, season_id, certificate_type) WHERE member_id IS NOT NULL;

-- =====================================================================
-- Notifications
-- =====================================================================
-- Placed last on purpose: the event-link tables below cite almost every
-- other domain (join requests, appeals, the forum, submission reviews),
-- so they have to come after all of them exist. `notifications` itself
-- has no such dependency and could live anywhere, but stays next to its
-- links for readability.
--
-- `notifications` is the generic destination, mirroring the
-- accounts/subtype-table pattern used at the top of this file: an
-- inbox row for one account -- who it's for, its text, its read state,
-- when it's allowed to be delivered -- with no notion of *why* it
-- exists or what it's about.
CREATE TABLE notifications (
  notification_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  recipient_account_id  BIGINT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  title                 VARCHAR(150) NOT NULL,
  body                  TEXT,
  -- Delivery buffer: NULL/now() = deliver immediately; set in the
  -- future to hold delivery until then. Used for comment/reply
  -- notifications specifically -- the app inserts with
  -- `notify_after = now() + interval '30 minutes'` so a flurry of
  -- edits or follow-up replies in that window collapses into one
  -- delivered notification instead of spamming the recipient. A
  -- dispatch worker only sends rows where notify_after <= now().
  notify_after           TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_read                BOOLEAN NOT NULL DEFAULT FALSE,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_notifications_recipient ON notifications(recipient_account_id, is_read);
CREATE INDEX ix_notifications_notify_after ON notifications(notify_after) WHERE is_read = FALSE;

-- What each notification is *about* lives in one of four separate,
-- domain-scoped link tables rather than one shared table with a
-- nullable FK per source. Forum activity and appeals (for example)
-- have nothing to do with each other, so they don't share a table --
-- each link table only knows about its own domain's source rows. Every
-- link table is a 1:1 extension of `notifications` (same shape as
-- members/clubs/judges/partners extending accounts): notification_id
-- is both its PK and its FK back to notifications. A shared trigger
-- (enforce_single_notification_link, see Triggers) checks across all
-- four tables that a given notification_id has exactly one link total,
-- since Postgres can't express a cross-table uniqueness constraint
-- declaratively.
CREATE TABLE notification_join_request_links (
  notification_id  BIGINT PRIMARY KEY REFERENCES notifications(notification_id) ON DELETE CASCADE,
  event_type       notification_type NOT NULL, -- join_request_received/accepted/rejected
  join_request_id  BIGINT NOT NULL REFERENCES join_requests(request_id) ON DELETE CASCADE
);
CREATE INDEX ix_notification_join_request_links_request ON notification_join_request_links(join_request_id);

CREATE TABLE notification_appeal_links (
  notification_id  BIGINT PRIMARY KEY REFERENCES notifications(notification_id) ON DELETE CASCADE,
  event_type       notification_type NOT NULL, -- appeal_accepted/rejected
  appeal_id        BIGINT NOT NULL REFERENCES appeals(appeal_id) ON DELETE CASCADE
);
CREATE INDEX ix_notification_appeal_links_appeal ON notification_appeal_links(appeal_id);

CREATE TABLE notification_forum_links (
  notification_id   BIGINT PRIMARY KEY REFERENCES notifications(notification_id) ON DELETE CASCADE,
  event_type        notification_type NOT NULL, -- announcement_posted / comment_posted / reply_posted
  forum_post_id     BIGINT REFERENCES forum_posts(post_id) ON DELETE CASCADE,
  forum_comment_id  BIGINT REFERENCES forum_comments(comment_id) ON DELETE CASCADE,
  CONSTRAINT ck_notification_forum_links_one_source CHECK (num_nonnulls(forum_post_id, forum_comment_id) = 1)
);
CREATE INDEX ix_notification_forum_links_post ON notification_forum_links(forum_post_id);
CREATE INDEX ix_notification_forum_links_comment ON notification_forum_links(forum_comment_id);

CREATE TABLE notification_submission_review_links (
  notification_id      BIGINT PRIMARY KEY REFERENCES notifications(notification_id) ON DELETE CASCADE,
  event_type            notification_type NOT NULL, -- submission_assigned/judge_feedback_given
  submission_review_id  BIGINT NOT NULL REFERENCES submission_reviews(review_id) ON DELETE CASCADE
);
CREATE INDEX ix_notification_submission_review_links_review ON notification_submission_review_links(submission_review_id);
-- NOTE: "notify the whole event" (e.g. an announcement) is a fan-out at
-- insert time -- one notifications row per recipient, each with its
-- own notification_forum_links row pointing at the same forum_post_id
-- -- not a schema concern; nothing here assumes a single recipient.

-- =====================================================================
-- Triggers
-- =====================================================================

-- --- keep updated_at columns honest -------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql
-- R4: pinned on the function, because plpgsql resolves names at
-- EXECUTION time against the CALLER's search_path. Without this, an
-- ordinary client connection (search_path = public) fails on every
-- write path with "relation ... does not exist".
SET search_path = oltp, public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_accounts_updated_at BEFORE UPDATE ON accounts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_submissions_updated_at BEFORE UPDATE ON submissions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_news_posts_updated_at BEFORE UPDATE ON news_posts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- --- subtype/role consistency -------------------------------------------
-- Postgres CHECK constraints can't reference another table, so "a
-- `members` row must belong to an account with role='member'" (and
-- likewise for clubs/judges/partners) is enforced here instead of
-- declaratively. One parameterized function, reused by all four
-- subtype tables via TG_ARGV, rather than four near-duplicate
-- functions.
CREATE OR REPLACE FUNCTION enforce_subtype_role() RETURNS trigger
LANGUAGE plpgsql
-- R4: pinned on the function, because plpgsql resolves names at
-- EXECUTION time against the CALLER's search_path. Without this, an
-- ordinary client connection (search_path = public) fails on every
-- write path with "relation ... does not exist".
SET search_path = oltp, public
AS $$
DECLARE
  expected_role account_role := TG_ARGV[0]::account_role;
  actual_role account_role;
BEGIN
  SELECT role INTO actual_role FROM accounts WHERE account_id = NEW.account_id;
  IF actual_role IS DISTINCT FROM expected_role THEN
    RAISE EXCEPTION 'account % has role %, expected % for table %',
      NEW.account_id, actual_role, expected_role, TG_TABLE_NAME;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_members_role_check BEFORE INSERT OR UPDATE ON members
  FOR EACH ROW EXECUTE FUNCTION enforce_subtype_role('member');
CREATE TRIGGER trg_clubs_role_check BEFORE INSERT OR UPDATE ON clubs
  FOR EACH ROW EXECUTE FUNCTION enforce_subtype_role('club');
CREATE TRIGGER trg_judges_role_check BEFORE INSERT OR UPDATE ON judges
  FOR EACH ROW EXECUTE FUNCTION enforce_subtype_role('judge');
CREATE TRIGGER trg_partners_role_check BEFORE INSERT OR UPDATE ON partners
  FOR EACH ROW EXECUTE FUNCTION enforce_subtype_role('partner');
CREATE TRIGGER trg_organizers_role BEFORE INSERT OR UPDATE ON organizers
  FOR EACH ROW EXECUTE FUNCTION enforce_subtype_role('organizer');

-- R8: the same invariant, enforced from the OTHER side.
--
-- enforce_subtype_role guards writes to the four subtype tables, on
-- INSERT and on UPDATE, and guards them well. Nothing guarded
-- accounts.role -- so changing the role left the subtype row attached,
-- and the database ended up holding precisely the shape these triggers
-- exist to reject, silently, because nothing re-checked the pair
-- afterwards. It was demonstrated on all four tables, not just the one
-- where it was noticed.
--
-- The account may still change role once the old subtype row is gone,
-- which is what makes this a guard rather than a freeze.
CREATE OR REPLACE FUNCTION enforce_role_change_has_no_subtype() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
DECLARE v_tbl TEXT; v_found BOOLEAN;
BEGIN
  IF NEW.role IS NOT DISTINCT FROM OLD.role THEN RETURN NEW; END IF;

  -- the table matching the role being LEFT is the one that would be
  -- orphaned; the others were never valid for this account anyway
  v_tbl := CASE OLD.role
             WHEN 'member'  THEN 'members'
             WHEN 'club'    THEN 'clubs'
             WHEN 'judge'   THEN 'judges'
             WHEN 'partner' THEN 'partners'
             -- R9. A fifth role with no entry here would fall through
             -- to NULL and the guard would return early -- which is
             -- exactly the silent hole R8 was written to close,
             -- reopened by adding a role. Adding one to the enum means
             -- adding one here, and qa_lifecycle proves it on all five.
             WHEN 'organizer' THEN 'organizers'
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
$$;

CREATE TRIGGER trg_accounts_role_change_has_no_subtype
  BEFORE UPDATE ON accounts
  FOR EACH ROW EXECUTE FUNCTION enforce_role_change_has_no_subtype();

-- --- team capacity by category -------------------------------------------
-- "Robotics = max 5, Programming = max 3" is a count-across-rows rule,
-- so it's enforced on INSERT into memberships rather than as a CHECK.
CREATE OR REPLACE FUNCTION enforce_team_capacity() RETURNS trigger
LANGUAGE plpgsql
-- R4: pinned on the function, because plpgsql resolves names at
-- EXECUTION time against the CALLER's search_path. Without this, an
-- ordinary client connection (search_path = public) fails on every
-- write path with "relation ... does not exist".
SET search_path = oltp, public
AS $$
DECLARE
  v_max SMALLINT;
  v_current INT;
BEGIN
  SELECT tc.max_members INTO v_max
  FROM teams t JOIN team_categories tc ON tc.category_id = t.category_id
  WHERE t.team_id = NEW.team_id;

  SELECT count(*) INTO v_current
  FROM memberships
  WHERE team_id = NEW.team_id AND left_at IS NULL;

  IF v_current >= v_max THEN
    RAISE EXCEPTION 'team % is at capacity (% members, category max %)', NEW.team_id, v_current, v_max;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_memberships_capacity BEFORE INSERT ON memberships
  FOR EACH ROW EXECUTE FUNCTION enforce_team_capacity();

-- --- max 3 invalid (rejected) appeals per team ---------------------------
CREATE OR REPLACE FUNCTION enforce_appeal_limit() RETURNS trigger
LANGUAGE plpgsql
-- R4: pinned on the function, because plpgsql resolves names at
-- EXECUTION time against the CALLER's search_path. Without this, an
-- ordinary client connection (search_path = public) fails on every
-- write path with "relation ... does not exist".
SET search_path = oltp, public
AS $$
DECLARE
  v_rejected_count INT;
BEGIN
  SELECT count(*) INTO v_rejected_count
  FROM appeals
  WHERE team_id = NEW.team_id AND status = 'rejected';

  IF v_rejected_count >= 3 THEN
    RAISE EXCEPTION 'team % has reached the limit of 3 invalid (rejected) appeals', NEW.team_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appeals_limit BEFORE INSERT ON appeals
  FOR EACH ROW EXECUTE FUNCTION enforce_appeal_limit();

-- --- submission resubmission versioning ----------------------------------
-- Assigns version server-side instead of trusting the client with it, so
-- a caller cannot forge or skip a version number.
--
-- WHAT THIS DOES *NOT* DO -- corrected after measurement, see
-- db/qa_concurrency.sql C1:
-- an earlier version of this comment claimed two racing "resubmit"
-- requests could not both compute the same next version. That is FALSE.
-- Under READ COMMITTED (the default) neither transaction sees the
-- other's uncommitted row, so MAX(version)+1 returns the SAME value in
-- both. Observed directly: two concurrent sessions both computed
-- version 2, and the second was stopped by
-- uq_submissions_team_challenge_version, not by this trigger.
--
-- So the invariant "one row per (team, challenge, version)" is held by
-- THE UNIQUE CONSTRAINT ALONE. This trigger only decides what the number
-- should be. Removing that constraint on the belief that this function
-- serialises resubmissions would silently allow duplicate versions --
-- which is exactly why the mistaken comment was worth correcting rather
-- than deleting.
--
-- Consequence for callers: under contention a legitimate resubmission
-- can surface a raw 23505. Retrying is the API's job; the database is
-- right to refuse.
CREATE OR REPLACE FUNCTION assign_submission_version() RETURNS trigger
LANGUAGE plpgsql
-- R4: pinned on the function, because plpgsql resolves names at
-- EXECUTION time against the CALLER's search_path. Without this, an
-- ordinary client connection (search_path = public) fails on every
-- write path with "relation ... does not exist".
SET search_path = oltp, public
AS $$
BEGIN
  SELECT COALESCE(MAX(version), 0) + 1 INTO NEW.version
  FROM submissions
  WHERE team_id = NEW.team_id AND challenge_id = NEW.challenge_id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_submissions_version BEFORE INSERT ON submissions
  FOR EACH ROW EXECUTE FUNCTION assign_submission_version();

-- --- the resubmission gate -----------------------------------------------
-- Version N+1 may exist only if version N carries at least one review
-- with requires_resubmission = TRUE. Aggregation is ANY / bool_or, not
-- ALL and not latest-wins.
--
-- The rule is INDUCTIVE, which is why one trigger closes four separate
-- holes: a unanimous FALSE round is a dead end, an unreviewed parent
-- blocks its child, v3 needs v2 (not v1) to have asked, and a burst is
-- impossible because the first new version has no reviews yet.
--
-- coalesce(..., FALSE) is a DECLARED policy, not an accident of
-- three-valued logic: with no reviews the answer is "no resubmission was
-- requested". Without it, NULL is not TRUE, `IF NOT v` never fires and
-- every unreviewed submission passes through a branch nobody chose.
CREATE OR REPLACE FUNCTION enforce_resubmission_gate() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
DECLARE
  v_prev_id BIGINT; v_prev_version SMALLINT; v_allowed BOOLEAN; v_reviews INT;
BEGIN
  IF NEW.version IS NULL OR NEW.version <= 1 THEN RETURN NEW; END IF;

  SELECT submission_id, version INTO v_prev_id, v_prev_version
  FROM submissions
  WHERE team_id = NEW.team_id AND challenge_id = NEW.challenge_id
  ORDER BY version DESC LIMIT 1;

  IF v_prev_id IS NULL THEN
    RAISE EXCEPTION 'submission version % has no predecessor in the (team %, challenge %) chain',
      NEW.version, NEW.team_id, NEW.challenge_id;
  END IF;

  SELECT coalesce(bool_or(requires_resubmission), FALSE), count(*)
    INTO v_allowed, v_reviews
  FROM submission_reviews WHERE submission_id = v_prev_id;

  IF NOT v_allowed THEN
    RAISE EXCEPTION
      'version % refused: version % (submission %) has % review(s) and none requested a resubmission',
      NEW.version, v_prev_version, v_prev_id, v_reviews
      USING HINT = 'a new version requires at least one review with requires_resubmission = true '
                   'on the immediately preceding version (ANY / bool_or)';
  END IF;
  RETURN NEW;
END;
$$;

-- MUST fire AFTER trg_submissions_version, which is what assigns
-- NEW.version. Postgres runs same-timing triggers in NAME order and
-- 'trg_submissions_version' < 'trg_submissions_zz_resubmission_gate',
-- so the zz prefix is load-bearing, not decoration: reading NEW.version
-- before assignment would compare against NULL and let everything past.
CREATE TRIGGER trg_submissions_zz_resubmission_gate
  BEFORE INSERT ON submissions
  FOR EACH ROW EXECUTE FUNCTION enforce_resubmission_gate();

-- trg_submissions_version is BEFORE INSERT only, so `version` was freely
-- mutable afterwards: the unique constraint caught a collision but not a
-- SKIP, and a row could be moved to another chain entirely.
CREATE OR REPLACE FUNCTION enforce_submission_lineage_immutable() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
BEGIN
  IF NEW.version IS DISTINCT FROM OLD.version THEN
    RAISE EXCEPTION 'submission % version is immutable (% -> %)',
      OLD.submission_id, OLD.version, NEW.version;
  END IF;
  IF NEW.team_id IS DISTINCT FROM OLD.team_id
     OR NEW.challenge_id IS DISTINCT FROM OLD.challenge_id THEN
    RAISE EXCEPTION 'submission % cannot move between chains after insert', OLD.submission_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_submissions_lineage_immutable
  BEFORE UPDATE ON submissions
  FOR EACH ROW EXECUTE FUNCTION enforce_submission_lineage_immutable();
-- --- the rulebook: history, pinned citations, retirement ------------------
-- Records a revision only when the CITABLE CONTENT changes. A touch of
-- an unrelated column must not manufacture a revision no reader would
-- recognise as different.
CREATE OR REPLACE FUNCTION record_rule_revision() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
BEGIN
  IF TG_OP = 'INSERT'
     OR NEW.title IS DISTINCT FROM OLD.title
     OR NEW.body  IS DISTINCT FROM OLD.body
     OR NEW.version_label IS DISTINCT FROM OLD.version_label THEN
    INSERT INTO rule_revisions(rule_id, title, body, version_label)
      VALUES (NEW.rule_id, NEW.title, NEW.body, NEW.version_label);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_rules_revision
  AFTER INSERT OR UPDATE ON rules
  FOR EACH ROW EXECUTE FUNCTION record_rule_revision();

-- Pins the citation to the wording current at the moment it is made.
-- By trigger rather than by caller: a default only the application can
-- set is a default nobody sets.
CREATE OR REPLACE FUNCTION pin_cited_revision() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
BEGIN
  IF NEW.rule_id IS NULL OR NEW.cited_revision_id IS NOT NULL THEN RETURN NEW; END IF;
  SELECT revision_id INTO NEW.cited_revision_id
  FROM rule_revisions WHERE rule_id = NEW.rule_id
  ORDER BY revision_id DESC LIMIT 1;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appeals_pin_revision
  BEFORE INSERT ON appeals FOR EACH ROW EXECUTE FUNCTION pin_cited_revision();
CREATE TRIGGER trg_post_rule_references_pin_revision
  BEFORE INSERT ON post_rule_references FOR EACH ROW EXECUTE FUNCTION pin_cited_revision();
CREATE TRIGGER trg_appeal_rule_references_pin_revision
  BEFORE INSERT ON appeal_rule_references FOR EACH ROW EXECUTE FUNCTION pin_cited_revision();

-- A retired rule keeps resolving for existing citations but accepts no
-- new ones.
CREATE OR REPLACE FUNCTION refuse_retired_rule_citation() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
DECLARE v_retired TIMESTAMPTZ;
BEGIN
  IF NEW.rule_id IS NULL THEN RETURN NEW; END IF;
  SELECT retired_at INTO v_retired FROM rules WHERE rule_id = NEW.rule_id;
  IF v_retired IS NOT NULL THEN
    RAISE EXCEPTION 'rule % was retired on % and can no longer be cited', NEW.rule_id, v_retired
      USING HINT = 'existing citations still resolve; cite a current rule instead';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appeals_no_retired_rule
  BEFORE INSERT ON appeals FOR EACH ROW EXECUTE FUNCTION refuse_retired_rule_citation();
CREATE TRIGGER trg_post_rule_references_no_retired_rule
  BEFORE INSERT ON post_rule_references FOR EACH ROW EXECUTE FUNCTION refuse_retired_rule_citation();
CREATE TRIGGER trg_appeal_rule_references_no_retired_rule
  BEFORE INSERT ON appeal_rule_references FOR EACH ROW EXECUTE FUNCTION refuse_retired_rule_citation();

-- ---------------------------------------------------------------------
-- R7 — closing an appeal
-- ---------------------------------------------------------------------
-- Pin the DECIDING rule's wording, mirroring pin_cited_revision above.
-- Without it a verdict would drift with the rulebook exactly as a
-- citation does, and a decision could later appear to rest on text
-- written after it was taken.
CREATE OR REPLACE FUNCTION pin_decided_revision() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
BEGIN
  IF NEW.decided_under_rule_id IS NULL OR NEW.decided_revision_id IS NOT NULL THEN
    RETURN NEW;
  END IF;
  SELECT revision_id INTO NEW.decided_revision_id
  FROM rule_revisions WHERE rule_id = NEW.decided_under_rule_id
  ORDER BY revision_id DESC LIMIT 1;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appeals_pin_decided_revision
  BEFORE INSERT OR UPDATE ON appeals
  FOR EACH ROW EXECUTE FUNCTION pin_decided_revision();

-- A retired rule cannot be the basis of a NEW decision, for the same
-- reason it cannot be freshly cited. refuse_retired_rule_citation reads
-- NEW.rule_id, so it cannot be reused for this column as-is.
CREATE OR REPLACE FUNCTION refuse_retired_deciding_rule() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
DECLARE v_retired TIMESTAMPTZ;
BEGIN
  IF NEW.decided_under_rule_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE'
     AND NEW.decided_under_rule_id IS NOT DISTINCT FROM OLD.decided_under_rule_id THEN
    RETURN NEW;   -- unchanged: a decision already taken keeps standing
  END IF;
  SELECT retired_at INTO v_retired FROM rules WHERE rule_id = NEW.decided_under_rule_id;
  IF v_retired IS NOT NULL THEN
    RAISE EXCEPTION 'rule % was retired on % and cannot be the basis of a decision',
      NEW.decided_under_rule_id, v_retired
      USING HINT = 'decisions already taken under it stand; decide under a current rule';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appeals_no_retired_deciding_rule
  BEFORE INSERT OR UPDATE ON appeals
  FOR EACH ROW EXECUTE FUNCTION refuse_retired_deciding_rule();

-- FINAL means final. A closed appeal does not return to pending, and
-- does not flip from accepted to rejected either.
--
-- This is deliberately the ONLY transition rule in the schema: it
-- constrains appeals because appeals were specified. join_requests.status
-- and matches.status carry the same omission and are left open, because
-- assuming the rule elsewhere would be inventing policy.
CREATE OR REPLACE FUNCTION enforce_appeal_finality() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
BEGIN
  IF OLD.status <> 'pending' AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'appeal % was closed as % and cannot be reopened or changed to %',
      OLD.appeal_id, OLD.status, NEW.status
      USING HINT = 'the judge''s answer is final; file a new appeal if there are new grounds';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appeals_finality
  BEFORE UPDATE ON appeals
  FOR EACH ROW EXECUTE FUNCTION enforce_appeal_finality();


-- ---------------------------------------------------------------------
-- R7 — only a match that was played carries results
-- ---------------------------------------------------------------------
-- "A cancelled match receives no results, it is marked void", extended
-- to scheduled matches: a result presumes the event happened. The
-- officiating panel and the roster were already checked when a score is
-- written; the EVENT was not. A trigger rather than a CHECK, because
-- matches.status lives on another table.
CREATE OR REPLACE FUNCTION enforce_match_is_playable() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
DECLARE v_status match_status;
BEGIN
  SELECT status INTO v_status FROM matches WHERE match_id = NEW.match_id;
  IF v_status NOT IN ('in_progress','completed') THEN
    RAISE EXCEPTION 'match % is % and cannot be scored', NEW.match_id, v_status
      USING HINT = 'only a match that has been played may carry results';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_scores_match_playable
  BEFORE INSERT OR UPDATE ON scores
  FOR EACH ROW EXECUTE FUNCTION enforce_match_is_playable();

-- The other direction: a match already carrying results cannot be
-- quietly cancelled, which would leave exactly the state above exists to
-- prevent -- a void match holding scores that flow into fact_scores and
-- the leaderboard.
--
-- This REFUSES rather than deleting: refusing preserves the record and
-- makes voiding a deliberate, visible act, where deleting would silently
-- destroy officials' work on a partially played match with no way back.
CREATE OR REPLACE FUNCTION enforce_cancel_has_no_scores() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
DECLARE v_n INT;
BEGIN
  IF NEW.status <> 'cancelled' OR OLD.status = 'cancelled' THEN RETURN NEW; END IF;
  SELECT count(*) INTO v_n FROM scores WHERE match_id = NEW.match_id;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'match % carries % score(s) and cannot be cancelled', NEW.match_id, v_n
      USING HINT = 'remove the results first, so voiding the match is an explicit act';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_matches_cancel_has_no_scores
  BEFORE UPDATE ON matches
  FOR EACH ROW EXECUTE FUNCTION enforce_cancel_has_no_scores();

-- `rules.code` is a denormalised copy of the section prefix, kept because
-- codes are how people actually cite rules. Nothing kept the copy honest,
-- so 'A99' could sit under section 'G' and a citation would resolve to a
-- rule whose code implies a different chapter. A CHECK cannot reach the
-- section's code -- it lives in another table.
CREATE OR REPLACE FUNCTION enforce_rule_code_section() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
DECLARE v_section_code TEXT;
BEGIN
  SELECT code INTO v_section_code FROM rule_sections WHERE section_id = NEW.section_id;
  IF upper(NEW.code) NOT LIKE upper(v_section_code) || '%' THEN
    RAISE EXCEPTION 'rule code % does not belong to section %', NEW.code, v_section_code;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_rules_code_section
  BEFORE INSERT OR UPDATE ON rules
  FOR EACH ROW EXECUTE FUNCTION enforce_rule_code_section();
-- --- forum attachments: type, quota, and the deletion outbox -------------
-- The declared mime type must be permitted AND must agree with the file
-- name. Neither is expressible as a CHECK: the allowlist lives in
-- another table, and the extension is a substring compared against an
-- array. Because the bytes are not in the database, this declaration is
-- the only signal available -- so it has to be self-consistent.
CREATE OR REPLACE FUNCTION enforce_attachment_type() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
DECLARE v_ext TEXT; v_allowed TEXT[];
BEGIN
  SELECT extensions INTO v_allowed FROM forum_allowed_mime_types WHERE mime_type = NEW.mime_type;
  IF v_allowed IS NULL THEN
    RAISE EXCEPTION 'mime type % is not permitted for forum attachments', NEW.mime_type
      USING HINT = 'see oltp.forum_allowed_mime_types';
  END IF;
  v_ext := lower(substring(NEW.file_name from '\.([^.]+)$'));
  IF v_ext IS NULL OR NOT (v_ext = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'file name % does not match declared type % (expected one of %)',
      NEW.file_name, NEW.mime_type, v_allowed;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_forum_attachments_type
  BEFORE INSERT OR UPDATE ON forum_attachments
  FOR EACH ROW EXECUTE FUNCTION enforce_attachment_type();

-- The 1 MB CHECK caps one file and nothing capped the set, so a post
-- could carry unlimited megabytes one megabyte at a time. Neither a
-- count nor a running sum is expressible as a row-level CHECK.
--
-- THE NUMBERS ARE A POLICY, NOT A MEASUREMENT: 10 files and 8 MB per
-- thread item. Named constants so changing them is an obvious edit.
-- Both ceilings are INCLUSIVE, matching size_bytes <= 1048576.
CREATE OR REPLACE FUNCTION enforce_attachment_quota() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
DECLARE
  c_max_files INT := 10;
  c_max_bytes BIGINT := 8 * 1048576;
  v_count INT; v_bytes BIGINT; v_scope TEXT;
BEGIN
  IF NEW.post_id IS NOT NULL THEN
    SELECT count(*), coalesce(sum(size_bytes),0) INTO v_count, v_bytes
      FROM forum_attachments WHERE post_id = NEW.post_id;
    v_scope := 'post ' || NEW.post_id;
  ELSE
    SELECT count(*), coalesce(sum(size_bytes),0) INTO v_count, v_bytes
      FROM forum_attachments WHERE comment_id = NEW.comment_id;
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
$$;

CREATE TRIGGER trg_forum_attachments_quota
  BEFORE INSERT ON forum_attachments
  FOR EACH ROW EXECUTE FUNCTION enforce_attachment_quota();

-- A deleted attachment row was the only reference to its stored object.
-- The tombstone outlives the cascade so a sweeper has something to act
-- on; without it the bytes are unreachable and unfindable.
CREATE OR REPLACE FUNCTION record_attachment_deletion() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
BEGIN
  INSERT INTO forum_attachment_deletions(storage_key, file_name, size_bytes)
    VALUES (OLD.storage_key, OLD.file_name, OLD.size_bytes);
  RETURN OLD;
END;
$$;

CREATE TRIGGER trg_forum_attachments_deletion
  AFTER DELETE ON forum_attachments
  FOR EACH ROW EXECUTE FUNCTION record_attachment_deletion();

-- --- forum threads: no cycles --------------------------------------------
-- The composite FK ties a reply to its parent's post and the CHECK stops
-- self-parenting, but a longer cycle (A -> B -> A) is invisible to any
-- constraint: every individual reference in it is valid. Walking the
-- ancestry is the only way to see one.
CREATE OR REPLACE FUNCTION enforce_comment_acyclic() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oltp, public
AS $$
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
    SELECT parent_comment_id INTO v_cursor FROM forum_comments WHERE comment_id = v_cursor;
  END LOOP;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_forum_comments_acyclic
  BEFORE INSERT OR UPDATE ON forum_comments
  FOR EACH ROW EXECUTE FUNCTION enforce_comment_acyclic();
-- --- exactly one link per notification -----------------------------------
-- The four notification_*_links tables are all 1:1 extensions of
-- notifications (same PK/FK shape as members/clubs/judges/partners
-- extending accounts), but nothing about that shape stops the same
-- notification_id from also getting a row in a second links table by
-- mistake. This checks across all four before allowing an insert into
-- any one of them.
CREATE OR REPLACE FUNCTION enforce_single_notification_link() RETURNS trigger
LANGUAGE plpgsql
-- R4: pinned on the function, because plpgsql resolves names at
-- EXECUTION time against the CALLER's search_path. Without this, an
-- ordinary client connection (search_path = public) fails on every
-- write path with "relation ... does not exist".
SET search_path = oltp, public
AS $$
DECLARE
  existing_count INT;
BEGIN
  SELECT
    (SELECT count(*) FROM notification_join_request_links WHERE notification_id = NEW.notification_id) +
    (SELECT count(*) FROM notification_appeal_links WHERE notification_id = NEW.notification_id) +
    (SELECT count(*) FROM notification_forum_links WHERE notification_id = NEW.notification_id) +
    (SELECT count(*) FROM notification_submission_review_links WHERE notification_id = NEW.notification_id)
  INTO existing_count;

  IF existing_count > 0 THEN
    RAISE EXCEPTION 'notification % already has a link', NEW.notification_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_notification_join_request_links_single BEFORE INSERT ON notification_join_request_links
  FOR EACH ROW EXECUTE FUNCTION enforce_single_notification_link();
CREATE TRIGGER trg_notification_appeal_links_single BEFORE INSERT ON notification_appeal_links
  FOR EACH ROW EXECUTE FUNCTION enforce_single_notification_link();
CREATE TRIGGER trg_notification_forum_links_single BEFORE INSERT ON notification_forum_links
  FOR EACH ROW EXECUTE FUNCTION enforce_single_notification_link();
CREATE TRIGGER trg_notification_submission_review_links_single BEFORE INSERT ON notification_submission_review_links
  FOR EACH ROW EXECUTE FUNCTION enforce_single_notification_link();

-- =====================================================================
-- Moderation views
-- =====================================================================
-- is_deleted was a flag with no reader: no view, no policy, no default
-- filter, so every caller had to remember `WHERE NOT is_deleted` and the
-- one that forgot showed moderated content. These make the safe read the
-- obvious one.
--
-- HONEST LIMIT: a view does not PREVENT anyone selecting the base table.
-- It removes the excuse and gives new code an obvious target. Making it
-- mandatory needs RLS, which is the still-open authorisation decision
-- sketched at the bottom of this file.
CREATE VIEW vw_forum_posts_visible AS
  SELECT * FROM forum_posts WHERE NOT is_deleted;

-- Comments that are themselves undeleted AND whose post is undeleted.
-- The flag did not propagate down the thread, so a moderated post kept
-- showing its replies.
CREATE VIEW vw_forum_comments_visible AS
  SELECT c.* FROM forum_comments c
  JOIN forum_posts p ON p.post_id = c.post_id
  WHERE NOT c.is_deleted AND NOT p.is_deleted;
-- =====================================================================
-- Optional: Row Level Security example (submissions edit permissions)
-- =====================================================================
-- "A member can edit only their own team's submission; a club can edit
-- any of its teams' submissions" is an authorization rule, not a data
-- integrity rule -- normally enforced in the Node.js service layer.
-- Shown here as an OPTIONAL illustration of expressing it at the DB
-- layer too (defense in depth), using session variables the app sets
-- per request after authenticating (`SET LOCAL app.current_account_id`,
-- `SET LOCAL app.current_role`). Not required for the schema to work;
-- comment out or delete if the API will own this check exclusively.

-- ALTER TABLE submissions ENABLE ROW LEVEL SECURITY;
--
-- CREATE POLICY submissions_team_member_edit ON submissions
--   FOR UPDATE
--   USING (
--     current_setting('app.current_role', true) = 'member'
--     AND team_id IN (
--       SELECT m.team_id FROM memberships m
--       WHERE m.member_id = current_setting('app.current_account_id', true)::BIGINT
--         AND m.left_at IS NULL
--     )
--   );
--
-- CREATE POLICY submissions_club_edit ON submissions
--   FOR UPDATE
--   USING (
--     current_setting('app.current_role', true) = 'club'
--     AND team_id IN (
--       SELECT t.team_id FROM teams t
--       WHERE t.club_id = current_setting('app.current_account_id', true)::BIGINT
--     )
--   );
