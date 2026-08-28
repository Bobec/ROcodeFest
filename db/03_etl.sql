-- =====================================================================
-- ROcodeFest — ETL: oltp  ->  analytics (star schema)
-- =====================================================================
-- Production loader. Run AFTER 01_oltp_schema.sql and
-- 02_analytics_schema.sql:
--
--   psql -d rocodefest -f db/03_etl.sql     -- installs the functions
--   psql -d rocodefest -c "SELECT analytics.run_etl();"   -- runs a load
--
-- Design rules, all of them load-bearing:
--
--   * IDEMPOTENT. Every statement is an UPSERT keyed on the NATURAL key
--     (club_id, team_id, challenge_id, judge_id) or, for facts, on the
--     source row id. Running this twice must leave the warehouse
--     bit-identical to running it once.
--
--   * NEVER TRUNCATE. The two sentinel rows (judge_key = -1,
--     challenge_key = -1) carry a NULL natural key, so no UPSERT can
--     ever match them -- but a TRUNCATE would delete them, and the
--     IDENTITY sequence would then hand surrogate key -1 to the next
--     real row, silently repointing every fact that referenced the
--     sentinel. This is why Type 1 overwrite is done with
--     ON CONFLICT DO UPDATE and not with a reload.
--
--   * SURROGATE KEYS ARE STABLE. Because dimensions upsert on the
--     natural key, a club that changes its name keeps its club_key, so
--     facts loaded in an earlier run stay correctly attached.
--
--   * PHASE ORDER IS A DEPENDENCY ORDER, not a preference:
--       Phase 0  sentinels + dim_date        (nothing depends on OLTP)
--       Phase 1  dim_club, dim_challenge, dim_judge  (independent)
--                then dim_team               (needs dim_club.club_key)
--       Phase 2  the three fact tables       (need every dimension)
--
-- =====================================================================

SET search_path = oltp, public;

-- ---------------------------------------------------------------------
-- Phase 0 — setup: sentinels, then the date dimension
-- ---------------------------------------------------------------------
-- Sentinels are created here (not only in 02_) so this loader is safe on
-- a warehouse built by any route. They are inserted with an explicit
-- surrogate key via OVERRIDING SYSTEM VALUE and guarded by NOT EXISTS
-- rather than ON CONFLICT, because their natural key is NULL and NULL
-- never conflicts.
--
-- dim_date is derived from the ACTUAL data range rather than hardcoded:
-- a hardcoded window silently starts violating the date_key FK the day
-- an event falls outside it.
CREATE OR REPLACE FUNCTION analytics.etl_phase0_setup(p_buffer_days INT DEFAULT 31)
RETURNS void AS $fn$
DECLARE
  v_min DATE;
  v_max DATE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM analytics.dim_judge WHERE judge_key = -1) THEN
    INSERT INTO analytics.dim_judge (judge_key, judge_id, judge_name, expertise)
      OVERRIDING SYSTEM VALUE VALUES (-1, NULL, 'Unassigned', NULL);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM analytics.dim_challenge WHERE challenge_key = -1) THEN
    INSERT INTO analytics.dim_challenge
      (challenge_key, challenge_id, challenge_name, stage, season_name, category_label)
      OVERRIDING SYSTEM VALUE
      VALUES (-1, NULL, 'Unknown / not challenge-linked', 'n/a', 'n/a', NULL);
  END IF;

  -- LEAST/GREATEST ignore NULLs, so empty source tables simply drop out.
  v_min := LEAST(
    (SELECT min(scored_at::date)  FROM oltp.scores),
    (SELECT min(created_at::date) FROM oltp.submissions),
    (SELECT min(created_at::date) FROM oltp.appeals),
    (SELECT min(start_date)       FROM oltp.seasons));
  v_max := GREATEST(
    (SELECT max(scored_at::date)  FROM oltp.scores),
    (SELECT max(created_at::date) FROM oltp.submissions),
    (SELECT max(created_at::date) FROM oltp.appeals),
    (SELECT max(end_date)         FROM oltp.seasons));

  -- Cold start (no data yet): cover the current year so a first load of
  -- freshly-created rows still resolves.
  v_min := COALESCE(v_min, date_trunc('year', now())::date);
  v_max := COALESCE(v_max, (date_trunc('year', now()) + interval '1 year - 1 day')::date);

  INSERT INTO analytics.dim_date
  SELECT to_char(d,'YYYYMMDD')::INT, d,
         extract(day     FROM d)::SMALLINT,
         extract(month   FROM d)::SMALLINT,
         to_char(d,'Month'),
         extract(quarter FROM d)::SMALLINT,
         extract(year    FROM d)::SMALLINT,
         extract(isodow  FROM d)::SMALLINT,
         to_char(d,'Day'),
         extract(isodow  FROM d) IN (6,7)
  FROM generate_series(v_min - p_buffer_days, v_max + p_buffer_days, interval '1 day') AS d
  ON CONFLICT (date_key) DO NOTHING;
END;
$fn$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------
-- Phase 1 — dimensions (Type 1 overwrite, upsert on natural key)
-- ---------------------------------------------------------------------
-- Order inside this function matters exactly once: dim_team resolves
-- club_key by looking up dim_club, so dim_club must already be current.
-- The club is deliberately reached through the team (snowflake), while
-- every fact ALSO carries club_key directly so club rollups never have
-- to route through dim_team.
CREATE OR REPLACE FUNCTION analytics.etl_phase1_dimensions() RETURNS void AS $fn$
BEGIN
  INSERT INTO analytics.dim_club (club_id, club_name, city, founding_number)
  SELECT account_id, club_name, city, founding_number FROM oltp.clubs
  ON CONFLICT (club_id) DO UPDATE SET
    club_name       = EXCLUDED.club_name,
    city            = EXCLUDED.city,
    founding_number = EXCLUDED.founding_number;

  INSERT INTO analytics.dim_challenge (challenge_id, challenge_name, stage, season_name, category_label)
  SELECT c.challenge_id, c.name, c.stage::text, s.name, tc.label
  FROM oltp.challenges c
  JOIN oltp.seasons s ON s.season_id = c.season_id
  LEFT JOIN oltp.team_categories tc ON tc.category_id = c.category_id
  ON CONFLICT (challenge_id) DO UPDATE SET
    challenge_name = EXCLUDED.challenge_name,
    stage          = EXCLUDED.stage,
    season_name    = EXCLUDED.season_name,
    category_label = EXCLUDED.category_label;

  INSERT INTO analytics.dim_judge (judge_id, judge_name, expertise)
  SELECT account_id, full_name, expertise FROM oltp.judges
  ON CONFLICT (judge_id) DO UPDATE SET
    judge_name = EXCLUDED.judge_name,
    expertise  = EXCLUDED.expertise;

  -- depends on dim_club above
  INSERT INTO analytics.dim_team (team_id, club_key, team_name, participation_code, category_code, category_label)
  SELECT t.team_id, dc.club_key, t.team_name, t.participation_code, tc.code, tc.label
  FROM oltp.teams t
  JOIN oltp.team_categories tc ON tc.category_id = t.category_id
  JOIN analytics.dim_club dc   ON dc.club_id     = t.club_id
  ON CONFLICT (team_id) DO UPDATE SET
    club_key           = EXCLUDED.club_key,
    team_name          = EXCLUDED.team_name,
    participation_code = EXCLUDED.participation_code,
    category_code      = EXCLUDED.category_code,
    category_label     = EXCLUDED.category_label;
END;
$fn$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------
-- Phase 2 — facts
-- ---------------------------------------------------------------------
-- Every ON CONFLICT refreshes EVERY mutable column, not just one: a
-- partial update would let a corrected OLTP value (a re-scored match, a
-- reassigned judge, a resolved appeal) sit stale in the warehouse
-- forever while the load kept reporting success.
CREATE OR REPLACE FUNCTION analytics.etl_phase2_facts() RETURNS void AS $fn$
BEGIN
  -- Grain: one row per oltp.scores row (one judge, one team, one match).
  INSERT INTO analytics.fact_scores
    (date_key, team_key, club_key, challenge_key, judge_key,
     innovation_score, execution_score, presentation_score, teamwork_score,
     total_score, source_score_id)
  SELECT to_char(sc.scored_at,'YYYYMMDD')::INT,
         dt.team_key, dt.club_key, dch.challenge_key, dj.judge_key,
         sc.innovation_score, sc.execution_score, sc.presentation_score,
         sc.teamwork_score, sc.total_score, sc.score_id
  FROM oltp.scores sc
  JOIN oltp.matches m               ON m.match_id      = sc.match_id
  JOIN analytics.dim_team dt        ON dt.team_id      = sc.team_id
  JOIN analytics.dim_challenge dch  ON dch.challenge_id = m.challenge_id
  JOIN analytics.dim_judge dj       ON dj.judge_id     = sc.judge_id
  ON CONFLICT (source_score_id) DO UPDATE SET
    date_key           = EXCLUDED.date_key,
    team_key           = EXCLUDED.team_key,
    club_key           = EXCLUDED.club_key,
    challenge_key      = EXCLUDED.challenge_key,
    judge_key          = EXCLUDED.judge_key,
    innovation_score   = EXCLUDED.innovation_score,
    execution_score    = EXCLUDED.execution_score,
    presentation_score = EXCLUDED.presentation_score,
    teamwork_score     = EXCLUDED.teamwork_score,
    total_score        = EXCLUDED.total_score;

  -- Grain: ONE ROW PER SUBMISSION. A submission may have several
  -- assigned judges (uq_submission_reviews_submission_judge only stops
  -- the SAME judge twice), so joining oltp.submission_reviews inline
  -- would fan out and multiply the submission count. The reviews are
  -- therefore collapsed to at most one row per submission FIRST.
  --
  -- The ORDER BY carries an explicit judge_id tiebreaker: with
  -- `ORDER BY submission_id, assigned_at` alone, two reviews assigned in
  -- the same transaction share assigned_at and DISTINCT ON would pick
  -- an ARBITRARY one -- which can differ between two runs of this
  -- loader and silently break idempotency. judge_id makes the choice
  -- total and deterministic.
  INSERT INTO analytics.fact_submissions
    (date_key, team_key, club_key, challenge_key, judge_key,
     submission_count, source_submission_id)
  SELECT to_char(s.created_at,'YYYYMMDD')::INT,
         dt.team_key, dt.club_key, dch.challenge_key,
         COALESCE(dj.judge_key, -1), 1, s.submission_id
  FROM oltp.submissions s
  JOIN analytics.dim_team dt       ON dt.team_id       = s.team_id
  JOIN analytics.dim_challenge dch ON dch.challenge_id = s.challenge_id
  LEFT JOIN (
    SELECT DISTINCT ON (submission_id) submission_id, judge_id
    FROM oltp.submission_reviews
    ORDER BY submission_id, assigned_at ASC, judge_id ASC
  ) pr ON pr.submission_id = s.submission_id
  LEFT JOIN analytics.dim_judge dj ON dj.judge_id = pr.judge_id
  ON CONFLICT (source_submission_id) DO UPDATE SET
    date_key         = EXCLUDED.date_key,
    team_key         = EXCLUDED.team_key,
    club_key         = EXCLUDED.club_key,
    challenge_key    = EXCLUDED.challenge_key,
    judge_key        = EXCLUDED.judge_key,
    submission_count = EXCLUDED.submission_count;

  -- Grain: one row per appeal. Both optional lookups fall back to the
  -- -1 sentinel so the fact keeps NOT NULL keys into all 5 dimensions.
  --
  -- An appeal names its target EITHER as a match OR as a single score,
  -- and disputing one judge's score is the ordinary way to file one. The
  -- challenge therefore has to be resolved down both paths: this used to
  -- read only a.match_id, so every score-filed appeal landed on the
  -- challenge sentinel and vanished from vw_challenge_funnel, which
  -- excludes -1. The judge was resolved correctly the whole time --
  -- through oltp.scores, the very join that also carries match_id.
  --
  -- Guarded by qa_analytics.sql group F, which files the same appeal
  -- both ways and asserts the two agree.
  INSERT INTO analytics.fact_appeals
    (date_key, team_key, club_key, challenge_key, judge_key, appeal_status,
     valid_appeal_count, invalid_appeal_count, source_appeal_id)
  SELECT to_char(a.created_at,'YYYYMMDD')::INT,
         dt.team_key, dt.club_key,
         COALESCE(dch.challenge_key, dch_sc.challenge_key, -1),
         COALESCE(dj.judge_key, -1),
         a.status::text,
         CASE WHEN a.status = 'rejected' THEN 0 ELSE 1 END,
         CASE WHEN a.status = 'rejected' THEN 1 ELSE 0 END,
         a.appeal_id
  FROM oltp.appeals a
  JOIN analytics.dim_team dt ON dt.team_id = a.team_id
  LEFT JOIN oltp.matches m           ON m.match_id       = a.match_id
  LEFT JOIN analytics.dim_challenge dch ON dch.challenge_id = m.challenge_id
  LEFT JOIN oltp.scores sc           ON sc.score_id      = a.score_id
  LEFT JOIN analytics.dim_judge dj   ON dj.judge_id      = sc.judge_id
  -- the second path: score -> match -> challenge. Kept as its own pair of
  -- joins rather than folded into the first, so a.match_id keeps priority
  -- when an appeal happens to carry both.
  LEFT JOIN oltp.matches ms          ON ms.match_id      = sc.match_id
  LEFT JOIN analytics.dim_challenge dch_sc ON dch_sc.challenge_id = ms.challenge_id
  ON CONFLICT (source_appeal_id) DO UPDATE SET
    date_key             = EXCLUDED.date_key,
    team_key             = EXCLUDED.team_key,
    club_key             = EXCLUDED.club_key,
    challenge_key        = EXCLUDED.challenge_key,
    judge_key            = EXCLUDED.judge_key,
    appeal_status        = EXCLUDED.appeal_status,
    valid_appeal_count   = EXCLUDED.valid_appeal_count,
    invalid_appeal_count = EXCLUDED.invalid_appeal_count;
END;
$fn$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------
-- Orchestrator
-- ---------------------------------------------------------------------
-- One transaction: a failure in Phase 2 must not leave dimensions
-- advanced past the facts that reference them.
CREATE OR REPLACE FUNCTION analytics.run_etl(p_buffer_days INT DEFAULT 31)
RETURNS TABLE(phase TEXT, detail TEXT) AS $fn$
BEGIN
  PERFORM analytics.etl_phase0_setup(p_buffer_days);
  phase := 'phase0_setup';
  detail := format('sentinels ensured; dim_date has %s rows',
                   (SELECT count(*) FROM analytics.dim_date));
  RETURN NEXT;

  PERFORM analytics.etl_phase1_dimensions();
  phase := 'phase1_dimensions';
  detail := format('dim_club=%s dim_team=%s dim_challenge=%s dim_judge=%s',
                   (SELECT count(*) FROM analytics.dim_club),
                   (SELECT count(*) FROM analytics.dim_team),
                   (SELECT count(*) FROM analytics.dim_challenge),
                   (SELECT count(*) FROM analytics.dim_judge));
  RETURN NEXT;

  PERFORM analytics.etl_phase2_facts();
  phase := 'phase2_facts';
  detail := format('fact_scores=%s fact_submissions=%s fact_appeals=%s',
                   (SELECT count(*) FROM analytics.fact_scores),
                   (SELECT count(*) FROM analytics.fact_submissions),
                   (SELECT count(*) FROM analytics.fact_appeals));
  RETURN NEXT;
END;
$fn$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------
-- Post-load quality gate
-- ---------------------------------------------------------------------
-- Cheap assertions meant to run right after every scheduled load. Each
-- returns one row; `ok = false` on any row should fail the job.
CREATE OR REPLACE FUNCTION analytics.etl_quality_report()
RETURNS TABLE(check_name TEXT, ok BOOLEAN, detail TEXT) AS $fn$
BEGIN
  RETURN QUERY SELECT 'grain_fact_submissions'::TEXT,
    (SELECT count(*) FROM analytics.fact_submissions)
      = (SELECT count(DISTINCT source_submission_id) FROM analytics.fact_submissions)
    AND (SELECT count(*) FROM analytics.fact_submissions)
      = (SELECT count(*) FROM oltp.submissions),
    format('%s fact rows vs %s OLTP submissions',
           (SELECT count(*) FROM analytics.fact_submissions),
           (SELECT count(*) FROM oltp.submissions));

  RETURN QUERY SELECT 'grain_fact_scores'::TEXT,
    (SELECT count(*) FROM analytics.fact_scores) = (SELECT count(*) FROM oltp.scores),
    format('%s fact rows vs %s OLTP scores',
           (SELECT count(*) FROM analytics.fact_scores),
           (SELECT count(*) FROM oltp.scores));

  RETURN QUERY SELECT 'grain_fact_appeals'::TEXT,
    (SELECT count(*) FROM analytics.fact_appeals) = (SELECT count(*) FROM oltp.appeals),
    format('%s fact rows vs %s OLTP appeals',
           (SELECT count(*) FROM analytics.fact_appeals),
           (SELECT count(*) FROM oltp.appeals));

  RETURN QUERY SELECT 'sentinels_intact'::TEXT,
    (SELECT count(*) FROM analytics.dim_judge     WHERE judge_id IS NULL)     = 1
    AND (SELECT count(*) FROM analytics.dim_challenge WHERE challenge_id IS NULL) = 1
    AND NOT EXISTS (SELECT 1 FROM analytics.dim_judge     WHERE judge_key = -1     AND judge_id     IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM analytics.dim_challenge WHERE challenge_key = -1 AND challenge_id IS NOT NULL),
    'exactly one NULL-natural-key row per sentinel dimension, key -1 not reused';

  RETURN QUERY SELECT 'date_range_covered'::TEXT,
    NOT EXISTS (
      SELECT 1 FROM (
        SELECT date_key FROM analytics.fact_scores
        UNION ALL SELECT date_key FROM analytics.fact_submissions
        UNION ALL SELECT date_key FROM analytics.fact_appeals) x
      WHERE NOT EXISTS (SELECT 1 FROM analytics.dim_date d WHERE d.date_key = x.date_key)),
    'every fact date_key resolves in dim_date';

  RETURN QUERY SELECT 'sentinel_rate_submissions'::TEXT,
    COALESCE((SELECT 100.0 * count(*) FILTER (WHERE judge_key = -1) / NULLIF(count(*),0)
              FROM analytics.fact_submissions), 0) < 75,
    format('%s%% of submissions have no assigned judge',
           COALESCE(round((SELECT 100.0 * count(*) FILTER (WHERE judge_key = -1) / NULLIF(count(*),0)
                           FROM analytics.fact_submissions), 1), 0));

  RETURN QUERY SELECT 'sentinel_rate_appeals'::TEXT,
    COALESCE((SELECT 100.0 * count(*) FILTER (WHERE challenge_key = -1) / NULLIF(count(*),0)
              FROM analytics.fact_appeals), 0) < 50,
    format('%s%% of appeals are not challenge-linked',
           COALESCE(round((SELECT 100.0 * count(*) FILTER (WHERE challenge_key = -1) / NULLIF(count(*),0)
                           FROM analytics.fact_appeals), 1), 0));
END;
$fn$ LANGUAGE plpgsql;
