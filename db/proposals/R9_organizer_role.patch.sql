-- =====================================================================
-- PROPOSAL R9 — the role that runs the festival
-- =====================================================================
-- STATUS: ADOPTED on 2026-08-29. This file is now a RECORD, not a
-- migration: its contents were folded into 01_oltp_schema.sql and the
-- pipeline builds them from there. Do NOT run it against a current
-- database -- it would fail on objects that already exist. It is kept
-- because the reasoning here is the reasoning behind the schema, and
-- the pipeline carries only the short form of it.
--
-- Verified by: db/proposals/R9_organizer_role.verify.sql
--
-- WHAT THIS FIXES
-- ---------------
-- The schema has always described a festival that somebody runs. It has
-- seasons, challenges, matches, panels of judges, certificates -- and
-- not one of them can be created by anyone, because there is no role
-- whose job that is. Every one of those tables is populated in the
-- test suites by INSERT and nowhere else.
--
-- That went unnoticed for as long as the site was a set of pages
-- keeping their own data. It became visible the moment scoring was put
-- on the API: a judge signs in, asks which matches they are officiating,
-- and the honest answer is "none, and there is no way for that to
-- change". The same is true of submissions -- challenge_id is NOT NULL
-- and no account can create a challenge.
--
-- So this adds the missing role rather than a new feature. Nothing here
-- is a capability the festival did not already need; it is the account
-- that was assumed everywhere and declared nowhere.
--
-- WHY A FIFTH SUBTYPE RATHER THAN A FLAG
-- --------------------------------------
-- The obvious alternative is accounts.is_admin, and it is worse for the
-- reason the other four roles are tables: enforce_subtype_role and
-- enforce_role_change_has_no_subtype together make "an account is
-- exactly one kind of thing" a property the database holds, not a
-- convention the application remembers. A boolean beside the enum would
-- let an account be a club AND an organiser, which is precisely the
-- shape those two triggers exist to refuse.
--
-- It also means an organiser has a name and a picture like everyone
-- else, which matters as soon as an announcement or a decision is
-- attributed to one.
--
-- WHAT AN ORGANISER MAY DO, AND THE ONE THING THEY MAY NOT
-- --------------------------------------------------------
-- Full authority over the festival's own structure: seasons,
-- challenges, matches, which teams are in a match, which judges are on
-- its panel, the day's schedule, news.
--
-- They may NOT act as somebody else -- submit work for a team, file an
-- appeal, post as a club. That is not a permission being withheld; it
-- is that submitted_by_account_id, filed_by_account_id and
-- author_account_id are attribution, and an organiser writing a row
-- under another account's name would make the record say something
-- untrue. An organiser who needs a submission removed deletes it; they
-- do not author one.
--
-- The deciding of appeals is already narrower than "organiser": R7 gave
-- appeals.decided_by_account_id a second foreign key to judges, so only
-- a judge closes an appeal. That stands. Running the festival and
-- ruling on it are different jobs.
-- =====================================================================

ALTER TYPE account_role ADD VALUE 'organizer';

CREATE TABLE organizers (
  account_id  BIGINT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
  full_name   VARCHAR(150) NOT NULL,
  title       VARCHAR(120),
  bio         TEXT,
  avatar_data_uri TEXT,
  CONSTRAINT ck_organizers_avatar_size  CHECK (avatar_data_uri IS NULL OR length(avatar_data_uri) <= 200000),
  CONSTRAINT ck_organizers_avatar_shape CHECK (avatar_data_uri IS NULL OR avatar_data_uri ~ '^data:image/(png|jpeg|gif|webp);base64,'),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_organizers_role BEFORE INSERT OR UPDATE ON organizers
  FOR EACH ROW EXECUTE FUNCTION enforce_subtype_role('organizer');

-- enforce_role_change_has_no_subtype maps a role to the table that would
-- be orphaned by changing it. A fifth role with no entry in that CASE
-- falls through to NULL and the guard returns early -- which is exactly
-- the silent hole R8 was written to close, reopened by adding a role.
-- The mapping is extended in 01_ along with this table.

-- --- the day's agenda -------------------------------------------------
-- matches already carry scheduled_at and location, so the times of the
-- competition itself need no new table. What has no home is everything
-- between the matches: the opening, the lunch break, the awards. Those
-- are what turns a list of match times into a run of show.
--
-- One table, not two, and matches are NOT copied into it: a schedule
-- item may POINT at a match, and the contest-day page merges the two
-- streams by time. Copying would create a second scheduled_at, and two
-- copies of a time are two times that disagree the first time one moves.
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
  -- A row that points at a match must say it is one. Without this,
  -- 'break' could carry a match_id and the page would draw a lunch
  -- break where a match belongs.
  CONSTRAINT ck_schedule_items_match_kind
    CHECK (match_id IS NULL OR kind = 'match'),
  -- One schedule row per match. A match listed twice is a match the
  -- audience is told to watch in two places.
  CONSTRAINT uq_schedule_items_match UNIQUE (match_id)
);

CREATE INDEX ix_schedule_items_season ON schedule_items(season_id);
CREATE INDEX ix_schedule_items_starts ON schedule_items(starts_at);

-- --- news -------------------------------------------------------------
-- The news page is an empty state today, with nothing behind it. It is
-- the one piece of purely editorial content the festival publishes, and
-- it is separate from the forum's announcements category on purpose:
-- an announcement is a thread people reply to, an article is not.
--
-- published_at is nullable so a draft is a row with no publication
-- date, rather than a second table or a status column that would then
-- need its own rules.
CREATE TABLE news_posts (
  news_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  author_account_id BIGINT NOT NULL REFERENCES accounts(account_id),
  title        VARCHAR(200) NOT NULL,
  summary      VARCHAR(400),
  body         TEXT NOT NULL,
  published_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ix_news_posts_published ON news_posts(published_at DESC NULLS LAST);

CREATE TRIGGER trg_news_posts_updated_at BEFORE UPDATE ON news_posts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
