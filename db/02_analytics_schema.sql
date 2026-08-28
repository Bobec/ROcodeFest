-- =====================================================================
-- ROcodeFest — Analytics Schema (PostgreSQL, Star Schema)
-- Powers the partner dashboard + public leaderboard.
-- =====================================================================
-- This lives in its own `analytics` schema, deliberately separate from
-- the OLTP tables in 01_oltp_schema.sql:
--   * OLTP tables are normalized (3NF) and optimized for many small,
--     concurrent read/write transactions from the API.
--   * `analytics` tables are denormalized and optimized for few, large,
--     read-only aggregate queries from dashboards.
-- It is populated by an ETL/ELT job (out of scope here -- a scheduled
-- Node.js job or a tool like dbt) that reads the OLTP schema and
-- reshapes it into these dimension/fact tables. The application never
-- writes to `analytics` directly; only the ETL job does.
--
-- Star-schema conventions used throughout:
--   * Every dimension has its own surrogate key (dim_*_key). Fact
--     tables join on these surrogate keys, never on OLTP primary keys
--     directly -- this insulates the warehouse from OLTP key changes
--     and leaves room to add slowly-changing history later without
--     touching any fact table.
--   * Dimensions are flat/denormalized on purpose (no snowflaking)
--     except dim_team -> dim_club, which is kept as a genuine shared
--     dimension because both fact_scores and fact_submissions need
--     club-level rollups independently of team-level detail (see note
--     at dim_team).
--   * Fact tables are one-row-per-event, additive-measure tables, and
--     each keeps a `source_*_id` pointing back to the OLTP row it came
--     from, for drill-through / debugging.
--
-- ETL load order (dependencies flow strictly downward):
--   Phase 0 (once): create schema/tables/indexes, populate dim_date for
--     the festival window + a 1-month buffer on each side, and manually
--     insert the two sentinel rows (dim_judge/dim_challenge key -1;
--     see "Sentinel dimension members" below).
--   Phase 1 (dims): dim_club, dim_challenge, dim_judge (no
--     dependencies) -- then dim_team, which must run AFTER dim_club
--     because it resolves club_key by lookup on teams.club_id.
--     Every dimension load is an UPSERT on its natural key
--     (ON CONFLICT (club_id) DO UPDATE ...), never TRUNCATE + reload --
--     a truncate would delete the sentinel rows (NULL natural key) and
--     hand the next IDENTITY-generated row surrogate key -1, silently
--     repointing every fact row that references the sentinel.
--   Phase 2 (facts): fact_scores, fact_submissions, fact_appeals, in
--     any order relative to each other (no fact depends on another
--     fact) -- but only after Phase 1 is fully complete. Facts join
--     exclusively on analytics surrogate keys, never on OLTP primary
--     keys, and upsert on source_*_id keyed off updated_at/created_at
--     watermarks for idempotent incremental re-runs.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS analytics;

-- ---------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------

-- Standard date dimension. Why a dimension instead of a raw DATE column
-- on every fact table: it lets a BI tool / the partner dashboard group
-- and filter by month, quarter, weekday, etc. without repeating date
-- arithmetic in every query, and gives every fact table an identical
-- calendar vocabulary to join against.
CREATE TABLE analytics.dim_date (
  date_key     INT PRIMARY KEY,       -- YYYYMMDD, e.g. 20261114
  full_date    DATE NOT NULL,
  day          SMALLINT NOT NULL,
  month        SMALLINT NOT NULL,
  month_name   VARCHAR(20) NOT NULL,
  quarter      SMALLINT NOT NULL,
  year         SMALLINT NOT NULL,
  day_of_week  SMALLINT NOT NULL,     -- 1=Monday .. 7=Sunday (ISO)
  day_name     VARCHAR(20) NOT NULL,
  is_weekend   BOOLEAN NOT NULL,
  CONSTRAINT uq_dim_date_full_date UNIQUE (full_date)
);

-- Convenience: populate dim_date for the festival's operating window.
-- INSERT INTO analytics.dim_date
-- SELECT
--   to_char(d, 'YYYYMMDD')::INT,
--   d,
--   extract(day FROM d)::SMALLINT,
--   extract(month FROM d)::SMALLINT,
--   to_char(d, 'Month'),
--   extract(quarter FROM d)::SMALLINT,
--   extract(year FROM d)::SMALLINT,
--   extract(isodow FROM d)::SMALLINT,
--   to_char(d, 'Day'),
--   extract(isodow FROM d) IN (6, 7)
-- FROM generate_series('2026-01-01'::date, '2026-12-31'::date, interval '1 day') AS d;

CREATE TABLE analytics.dim_club (
  club_key         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  club_id          BIGINT NOT NULL,   -- OLTP clubs.account_id (natural/business key)
  club_name        VARCHAR(150) NOT NULL,
  city             VARCHAR(120),
  founding_number  INT,
  CONSTRAINT uq_dim_club_club_id UNIQUE (club_id)
);

-- dim_team keeps a FK to dim_club (a light, deliberate exception to
-- "no snowflaking") because the partner dashboard needs BOTH
-- team-level detail and club-level rollups constantly, and re-deriving
-- "which club is this team's" by re-joining OLTP tables on every ETL
-- run (rather than once here) would be wasteful. To keep club-level
-- queries on the fact tables cheap (no forced join through dim_team),
-- every fact table below ALSO carries club_key directly.
CREATE TABLE analytics.dim_team (
  team_key            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  team_id             BIGINT NOT NULL, -- OLTP teams.team_id (natural key)
  club_key            BIGINT NOT NULL REFERENCES analytics.dim_club(club_key),
  team_name           VARCHAR(150) NOT NULL,
  participation_code  VARCHAR(20) NOT NULL,
  category_code       VARCHAR(20) NOT NULL, -- denormalized from OLTP team_categories, flat on purpose
  category_label      VARCHAR(60) NOT NULL,
  CONSTRAINT uq_dim_team_team_id UNIQUE (team_id)
);
CREATE INDEX ix_dim_team_club_key ON analytics.dim_team(club_key);

-- challenge_id is nullable to allow exactly one sentinel row (see
-- "Sentinel dimension members" below) -- every real ETL-loaded row still
-- has a non-null challenge_id, enforced by the ETL query, not by a
-- NOT NULL here.
CREATE TABLE analytics.dim_challenge (
  challenge_key   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  challenge_id    BIGINT,                   -- OLTP challenges.challenge_id; NULL only for the sentinel row
  challenge_name  VARCHAR(150) NOT NULL,
  stage           VARCHAR(30) NOT NULL,     -- 'city_challenge' | 'final'
  season_name     VARCHAR(60) NOT NULL,
  category_label  VARCHAR(60),              -- NULL = applies to every category
  CONSTRAINT uq_dim_challenge_challenge_id UNIQUE (challenge_id)
);

-- judge_id is nullable for the same reason as dim_challenge.challenge_id
-- above -- exactly one sentinel row, everything else NOT NULL by
-- ETL-query convention.
CREATE TABLE analytics.dim_judge (
  judge_key   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  judge_id    BIGINT,            -- OLTP judges.account_id; NULL only for the sentinel row
  judge_name  VARCHAR(150) NOT NULL,
  expertise   VARCHAR(200),
  CONSTRAINT uq_dim_judge_judge_id UNIQUE (judge_id)
);

-- ---------------------------------------------------------------------
-- Sentinel dimension members
-- ---------------------------------------------------------------------
-- fact_submissions.judge_key, fact_appeals.judge_key and
-- fact_appeals.challenge_key must stay NOT NULL (every fact references
-- all 5 conformed dimensions), but the OLTP source doesn't always have
-- a resolvable judge/challenge for those rows:
--   * a submission may not have a judge assigned yet
--     (no submission_reviews row)
--   * an appeal may not cite a specific score (appeals.score_id NULL)
--     -> no judge derivable
--   * an appeal may not cite a specific match (appeals.match_id NULL)
--     -> no challenge derivable
-- Standard star-schema fix: one "Unknown" member per dimension, with a
-- fixed, out-of-band surrogate key (-1) and a NULL natural key.
-- Inserted ONCE, manually, in Phase 0 -- NOT part of the recurring
-- incremental ETL. This is also why the ETL's dimension UPSERT must key
-- on the natural key (judge_id / challenge_id), never TRUNCATE+reload:
-- the source data never produces a NULL natural key, so an
-- ON CONFLICT (judge_id) DO UPDATE / ON CONFLICT (challenge_id) DO
-- UPDATE upsert can never match, touch, or regenerate these two rows --
-- but a TRUNCATE would delete them and IDENTITY would hand the
-- next-loaded real row surrogate key -1, silently corrupting every fact
-- row already pointing at the sentinel.
INSERT INTO analytics.dim_judge (judge_key, judge_id, judge_name, expertise)
  OVERRIDING SYSTEM VALUE
  VALUES (-1, NULL, 'Unassigned', NULL);

INSERT INTO analytics.dim_challenge (challenge_key, challenge_id, challenge_name, stage, season_name, category_label)
  OVERRIDING SYSTEM VALUE
  VALUES (-1, NULL, 'Unknown / not challenge-linked', 'n/a', 'n/a', NULL);

-- ---------------------------------------------------------------------
-- Fact tables
-- ---------------------------------------------------------------------

-- Grain: one row per (team, match, judge) score -- i.e. one row per
-- OLTP `scores` row. This is the finest useful grain: it supports
-- "average score per judge" as well as "average score per team",
-- which a pre-aggregated grain (e.g. one row per team/match) would
-- lose. Grain uniqueness is guaranteed transitively: OLTP
-- uq_scores_match_team_judge UNIQUE(match_id, team_id, judge_id) means
-- one scores row per (match, team, judge), and
-- uq_fact_scores_source UNIQUE(source_score_id) below means exactly
-- one fact_scores row per scores row -- so fact_score_id is unique at
-- this grain by construction, no separate check needed.
CREATE TABLE analytics.fact_scores (
  fact_score_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  date_key            INT NOT NULL REFERENCES analytics.dim_date(date_key),
  team_key            BIGINT NOT NULL REFERENCES analytics.dim_team(team_key),
  club_key            BIGINT NOT NULL REFERENCES analytics.dim_club(club_key),
  challenge_key       BIGINT NOT NULL REFERENCES analytics.dim_challenge(challenge_key),
  judge_key           BIGINT NOT NULL REFERENCES analytics.dim_judge(judge_key),
  innovation_score    SMALLINT NOT NULL,
  execution_score     SMALLINT NOT NULL,
  presentation_score  SMALLINT NOT NULL,
  teamwork_score      SMALLINT NOT NULL,
  total_score         SMALLINT NOT NULL,  -- additive measure: SUM/AVG per team_key = the leaderboard
  source_score_id     BIGINT NOT NULL,    -- OLTP scores.score_id, for drill-through
  CONSTRAINT uq_fact_scores_source UNIQUE (source_score_id)
);
CREATE INDEX ix_fact_scores_date_key ON analytics.fact_scores(date_key);
CREATE INDEX ix_fact_scores_team_key ON analytics.fact_scores(team_key);
CREATE INDEX ix_fact_scores_club_key ON analytics.fact_scores(club_key);
CREATE INDEX ix_fact_scores_challenge_key ON analytics.fact_scores(challenge_key);
CREATE INDEX ix_fact_scores_judge_key ON analytics.fact_scores(judge_key);

-- Grain: one row per submission (source PK = submissions.submission_id).
-- NOT the (submission, judge) pair -- a submission can have more than
-- one submission_reviews row (uq_submission_reviews_submission_judge
-- allows several judges per submission), so joining fact_submissions
-- straight onto submission_reviews would fan out and inflate
-- SUM(submission_count) for any submission with >1 judge assigned.
-- judge_key is therefore always derived from a PRE-AGGREGATED
-- (one-row-per-submission_id) subquery, never an inline JOIN. ETL
-- extraction shape:
--   WITH primary_review AS (
--     SELECT DISTINCT ON (submission_id) submission_id, judge_id
--     FROM submission_reviews
--     ORDER BY submission_id, assigned_at ASC  -- earliest-assigned judge wins
--   )
--   SELECT ..., COALESCE(dj.judge_key, -1) AS judge_key, ...
--   FROM submissions s
--   LEFT JOIN primary_review pr ON pr.submission_id = s.submission_id
--   LEFT JOIN analytics.dim_judge dj ON dj.judge_id = pr.judge_id
-- primary_review has at most one row per submission_id by construction
-- (DISTINCT ON), so this LEFT JOIN stays 1:1 -- no fan-out, and
-- submissions with zero assigned judges correctly land on the -1
-- "Unassigned" sentinel instead of being dropped or duplicated.
CREATE TABLE analytics.fact_submissions (
  fact_submission_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  date_key                INT NOT NULL REFERENCES analytics.dim_date(date_key),
  team_key                 BIGINT NOT NULL REFERENCES analytics.dim_team(team_key),
  club_key                  BIGINT NOT NULL REFERENCES analytics.dim_club(club_key),
  challenge_key              BIGINT NOT NULL REFERENCES analytics.dim_challenge(challenge_key),
  judge_key                   BIGINT NOT NULL REFERENCES analytics.dim_judge(judge_key), -- -1 = no judge assigned yet
  submission_count           SMALLINT NOT NULL DEFAULT 1, -- "factless fact" measure, see note above
  source_submission_id       BIGINT NOT NULL,
  CONSTRAINT uq_fact_submissions_source UNIQUE (source_submission_id)
);
-- submission_count is literally always 1: it lets any BI tool compute
-- "number of submissions" with a plain SUM(), the same way it sums
-- total_score in fact_scores, instead of needing a separate COUNT(*)
-- code path just for this one fact table.
CREATE INDEX ix_fact_submissions_date_key ON analytics.fact_submissions(date_key);
CREATE INDEX ix_fact_submissions_team_key ON analytics.fact_submissions(team_key);
CREATE INDEX ix_fact_submissions_club_key ON analytics.fact_submissions(club_key);
CREATE INDEX ix_fact_submissions_challenge_key ON analytics.fact_submissions(challenge_key);
CREATE INDEX ix_fact_submissions_judge_key ON analytics.fact_submissions(judge_key);

-- Grain: one row per appeal. challenge_key and judge_key are both
-- NOT NULL and both resolve through the -1 sentinel when the source
-- appeal doesn't carry enough to derive them:
--   challenge_key <- matches.challenge_id via appeals.match_id
--                     (appeals.match_id IS NULL -> -1)
--   judge_key     <- scores.judge_id via appeals.score_id
--                     (appeals.score_id IS NULL -> -1)
-- Both lookups are single-row (appeals.match_id -> exactly one match,
-- appeals.score_id -> exactly one score), so this join shape is
-- naturally 1:1 -- no pre-aggregation needed here, unlike
-- fact_submissions above.
CREATE TABLE analytics.fact_appeals (
  fact_appeal_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  date_key               INT NOT NULL REFERENCES analytics.dim_date(date_key),
  team_key                BIGINT NOT NULL REFERENCES analytics.dim_team(team_key),
  club_key                 BIGINT NOT NULL REFERENCES analytics.dim_club(club_key),
  challenge_key             BIGINT NOT NULL REFERENCES analytics.dim_challenge(challenge_key), -- -1 = appeal not tied to a match
  judge_key                  BIGINT NOT NULL REFERENCES analytics.dim_judge(judge_key),         -- -1 = appeal not tied to a scored score
  appeal_status             VARCHAR(20) NOT NULL,        -- 'pending' | 'accepted' | 'rejected', snapshot at ETL time
  valid_appeal_count        SMALLINT NOT NULL DEFAULT 0,  -- 1 if status IN ('pending','accepted')
  invalid_appeal_count      SMALLINT NOT NULL DEFAULT 0,  -- 1 if status = 'rejected'
  source_appeal_id          BIGINT NOT NULL,
  CONSTRAINT uq_fact_appeals_source UNIQUE (source_appeal_id),
  CONSTRAINT ck_fact_appeals_flags CHECK (valid_appeal_count + invalid_appeal_count = 1)
);
-- valid_appeal_count / invalid_appeal_count use the same "factless
-- fact" trick as submission_count above, split into two flags so
-- "number of valid/invalid appeals" (an explicitly requested measure)
-- is a plain SUM() per column rather than a CASE-laden query -- exactly
-- one of the two is 1 for any given row ('pending' counts as valid /
-- still in progress, only 'rejected' is "invalid").
CREATE INDEX ix_fact_appeals_date_key ON analytics.fact_appeals(date_key);
CREATE INDEX ix_fact_appeals_team_key ON analytics.fact_appeals(team_key);
CREATE INDEX ix_fact_appeals_club_key ON analytics.fact_appeals(club_key);
CREATE INDEX ix_fact_appeals_challenge_key ON analytics.fact_appeals(challenge_key);
CREATE INDEX ix_fact_appeals_judge_key ON analytics.fact_appeals(judge_key);

-- ---------------------------------------------------------------------
-- Example analytical views (leaderboard + season progress)
-- ---------------------------------------------------------------------
-- These aren't strictly "schema", but they show the requested measures
-- actually working end-to-end against the tables above.

-- Total/average score per team -> the public leaderboard.
CREATE VIEW analytics.vw_leaderboard AS
SELECT
  t.team_key,
  t.team_id,
  t.team_name,
  t.category_label,
  c.club_key,
  c.club_name,
  count(*)                       AS scored_matches,
  sum(fs.total_score)            AS total_score,
  round(avg(fs.total_score), 1)  AS avg_score
FROM analytics.fact_scores fs
JOIN analytics.dim_team t ON t.team_key = fs.team_key
JOIN analytics.dim_club c ON c.club_key = fs.club_key
GROUP BY t.team_key, t.team_id, t.team_name, t.category_label, c.club_key, c.club_name
ORDER BY avg_score DESC;

-- Season progress per team: % of the ELIGIBLE challenges the team has
-- at least one submission for.
--
-- R8 rewrote this view for two reasons, both about rows it used to get
-- wrong rather than numbers it computed wrong:
--
--   * it was DRIVEN from fact_submissions, so a team that had submitted
--     nothing produced no row and was reported as absent rather than as
--     0%. The teams furthest behind are exactly the ones a progress
--     report exists for, and an empty entry reads as "no data" rather
--     than "no work". It is now driven from dim_team.
--
--   * the denominator counted EVERY challenge in the season regardless
--     of category, while challenges.category_id exists precisely to
--     scope them -- so a team was measured against work it is not
--     allowed to do, and its progress fell whenever an unrelated
--     category added a challenge. A number that gets worse on its own.
--
-- Both fixes are view-only: dim_team.category_label and
-- dim_challenge.category_label were already being loaded.
CREATE VIEW analytics.vw_team_season_progress AS
WITH eligible AS (
  -- a challenge counts towards a team's denominator when it is open to
  -- every category (category_label IS NULL) or to that team's own
  SELECT t.team_key, t.team_name, ch.season_name,
         count(*) AS total_challenges
  FROM analytics.dim_team t
  JOIN analytics.dim_challenge ch
    ON ch.challenge_key <> -1
   AND (ch.category_label IS NULL OR ch.category_label = t.category_label)
  GROUP BY t.team_key, t.team_name, ch.season_name
),
submitted AS (
  SELECT t.team_key, ch.season_name,
         count(DISTINCT fsub.challenge_key) AS submitted_challenges
  FROM analytics.dim_team t
  JOIN analytics.fact_submissions fsub ON fsub.team_key = t.team_key
  JOIN analytics.dim_challenge ch      ON ch.challenge_key = fsub.challenge_key
  GROUP BY t.team_key, ch.season_name
)
SELECT
  e.team_key,
  e.team_name,
  e.season_name,
  COALESCE(s.submitted_challenges, 0) AS submitted_challenges,
  e.total_challenges,
  round(100.0 * COALESCE(s.submitted_challenges, 0)::numeric
        / NULLIF(e.total_challenges, 0)::numeric, 1) AS progress_pct
FROM eligible e
LEFT JOIN submitted s
  ON s.team_key = e.team_key AND s.season_name::text = e.season_name::text;

-- Number of valid/invalid appeals per team is just:
--   SELECT team_key, sum(valid_appeal_count), sum(invalid_appeal_count)
--   FROM analytics.fact_appeals GROUP BY team_key;
-- -- no dedicated view needed; the fact table's flag columns already
-- make it a one-liner.

-- ---------------------------------------------------------------------
-- Multi-fact partner-dashboard views (chasm-trap-safe pattern)
-- ---------------------------------------------------------------------
-- These three views each touch all 3 fact tables through a shared
-- dimension. NEVER LEFT JOIN fact_scores + fact_submissions +
-- fact_appeals directly against each other in one query: joining three
-- one-to-many relationships off the same dimension row produces a
-- cross (chasm-trap) product -- e.g. a club with 10 scores, 5
-- submissions and 3 appeals would yield 10*5*3 = 150 combined rows,
-- and SUM(total_score) over those 150 rows comes out 15x too high
-- (COUNT(DISTINCT ...) happens to survive this because duplicates of
-- the same key collapse back down, but SUM/AVG do not). The fix used
-- in all three views below: aggregate each fact to one row per
-- dimension key in its own CTE first, then LEFT JOIN the three
-- pre-aggregated CTEs onto the dimension -- every join from that point
-- on is at most 1:1, so no fan-out is possible.

CREATE VIEW analytics.vw_partner_club_summary AS
WITH s AS (
  SELECT club_key, sum(total_score) AS total_score, count(*) AS scored_rows
  FROM analytics.fact_scores GROUP BY club_key
),
sub AS (
  SELECT club_key, sum(submission_count) AS submissions
  FROM analytics.fact_submissions GROUP BY club_key
),
a AS (
  SELECT club_key,
         sum(valid_appeal_count) AS valid_appeals,
         sum(invalid_appeal_count) AS invalid_appeals
  FROM analytics.fact_appeals GROUP BY club_key
)
SELECT
  c.club_key,
  c.club_name,
  coalesce(s.total_score, 0)    AS total_score,
  coalesce(sub.submissions, 0)  AS submissions,
  coalesce(a.valid_appeals, 0)   AS valid_appeals,
  coalesce(a.invalid_appeals, 0) AS invalid_appeals
FROM analytics.dim_club c
LEFT JOIN s   ON s.club_key = c.club_key
LEFT JOIN sub ON sub.club_key = c.club_key
LEFT JOIN a   ON a.club_key = c.club_key
ORDER BY total_score DESC;

CREATE VIEW analytics.vw_judge_workload AS
WITH s AS (
  SELECT judge_key, count(*) AS scores_given, avg(total_score) AS avg_score_given
  FROM analytics.fact_scores GROUP BY judge_key
),
sub AS (
  SELECT judge_key, sum(submission_count) AS submissions_reviewed
  FROM analytics.fact_submissions GROUP BY judge_key
),
a AS (
  SELECT judge_key, count(*) AS appeals_against_their_scores
  FROM analytics.fact_appeals GROUP BY judge_key
)
SELECT
  j.judge_key,
  j.judge_name,
  coalesce(s.scores_given, 0)               AS scores_given,
  round(s.avg_score_given, 1)                AS avg_score_given,
  coalesce(sub.submissions_reviewed, 0)      AS submissions_reviewed,
  coalesce(a.appeals_against_their_scores, 0) AS appeals_against_their_scores
FROM analytics.dim_judge j
LEFT JOIN s   ON s.judge_key = j.judge_key
LEFT JOIN sub ON sub.judge_key = j.judge_key
LEFT JOIN a   ON a.judge_key = j.judge_key
WHERE j.judge_key <> -1  -- exclude the "Unassigned" sentinel from a workload report
ORDER BY scores_given DESC;

CREATE VIEW analytics.vw_challenge_funnel AS
WITH sub AS (
  SELECT challenge_key, sum(submission_count) AS submissions
  FROM analytics.fact_submissions GROUP BY challenge_key
),
s AS (
  SELECT challenge_key, count(*) AS scores_recorded
  FROM analytics.fact_scores GROUP BY challenge_key
),
a AS (
  SELECT challenge_key, count(*) AS appeals_filed
  FROM analytics.fact_appeals GROUP BY challenge_key
)
SELECT
  ch.challenge_key,
  ch.challenge_name,
  ch.season_name,
  coalesce(sub.submissions, 0)     AS submissions,
  coalesce(s.scores_recorded, 0)   AS scores_recorded,
  coalesce(a.appeals_filed, 0)     AS appeals_filed
FROM analytics.dim_challenge ch
LEFT JOIN sub ON sub.challenge_key = ch.challenge_key
LEFT JOIN s   ON s.challenge_key = ch.challenge_key
LEFT JOIN a   ON a.challenge_key = ch.challenge_key
WHERE ch.challenge_key <> -1  -- exclude the "not challenge-linked" sentinel from a per-challenge funnel
ORDER BY ch.season_name, ch.challenge_name;

-- ---------------------------------------------------------------------
-- The partner dashboard
-- ---------------------------------------------------------------------
-- Per club x season: submissions, scoring, appeals -- the shape a
-- partner actually asks for, reaching all three fact tables through the
-- shared dimensions.
--
-- This is a PRODUCTION object and lives here, with the rest of the
-- analytics schema. It was previously created from 99_tests.sql, which
-- meant a deploy running only 01_ -> 02_ -> 03_etl.sql produced a
-- warehouse with no dashboard at all while the test suite still reported
-- green -- the suite was creating the very object it then validated.
--
-- Definition unchanged in the move: same column list, same joins on
-- surrogate keys, same one-pre-aggregated-CTE-per-fact shape. That shape
-- is not stylistic -- joining the three facts directly would reintroduce
-- the chasm trap and inflate every SUM.
--
-- Depends only on tables declared above; it is created against empty
-- tables here and populated later by 03_etl.sql.
CREATE OR REPLACE VIEW analytics.vw_partner_dashboard AS
WITH s AS (
  SELECT f.club_key, ch.season_name,
         sum(f.total_score) AS total_score,
         round(avg(f.total_score), 2) AS avg_score,
         count(*) AS scores_recorded
  FROM analytics.fact_scores f
  JOIN analytics.dim_challenge ch ON ch.challenge_key = f.challenge_key
  GROUP BY f.club_key, ch.season_name
),
u AS (
  SELECT f.club_key, ch.season_name,
         sum(f.submission_count) AS submissions,
         count(DISTINCT f.challenge_key) AS challenges_entered
  FROM analytics.fact_submissions f
  JOIN analytics.dim_challenge ch ON ch.challenge_key = f.challenge_key
  GROUP BY f.club_key, ch.season_name
),
a AS (
  SELECT f.club_key, ch.season_name,
         sum(f.valid_appeal_count)   AS valid_appeals,
         sum(f.invalid_appeal_count) AS invalid_appeals
  FROM analytics.fact_appeals f
  JOIN analytics.dim_challenge ch ON ch.challenge_key = f.challenge_key
  GROUP BY f.club_key, ch.season_name
),
grid AS (   -- every (club, season) that any fact touches
  SELECT club_key, season_name FROM s
  UNION SELECT club_key, season_name FROM u
  UNION SELECT club_key, season_name FROM a
)
SELECT
  c.club_key, c.club_name, g.season_name,
  coalesce(u.submissions, 0)        AS submissions,
  coalesce(u.challenges_entered, 0) AS challenges_entered,
  coalesce(s.scores_recorded, 0)    AS scores_recorded,
  s.avg_score,
  coalesce(s.total_score, 0)        AS total_score,
  coalesce(a.valid_appeals, 0)      AS valid_appeals,
  coalesce(a.invalid_appeals, 0)    AS invalid_appeals
FROM grid g
JOIN analytics.dim_club c ON c.club_key = g.club_key
LEFT JOIN s ON s.club_key = g.club_key AND s.season_name = g.season_name
LEFT JOIN u ON u.club_key = g.club_key AND u.season_name = g.season_name
LEFT JOIN a ON a.club_key = g.club_key AND a.season_name = g.season_name
ORDER BY c.club_key, g.season_name;
