'use strict';
const express = require('express');
const db = require('../db');

const router = express.Router();

// =====================================================================
// The leaderboard
// =====================================================================
// Computed live from oltp.scores, not read from analytics.vw_leaderboard.
//
// The requirement was "updated automatically when a match ends", and a
// live query is current BY CONSTRUCTION: there is no ETL run to schedule,
// no cache to invalidate, and therefore no window in which it is wrong.
// The analytics star schema is the better answer for historical
// reporting, where a few minutes of lag costs nothing -- but it is fed
// by run_etl(), so on the day of the contest it would show whatever the
// last run captured, and the gap between the announcement and the screen
// is exactly where an argument starts.
//
// Cost: one aggregate over scores per request. At festival scale that is
// a few thousand rows.
//
// WHAT COUNTS
// -----------
// Only scores from COMPLETED matches. That is what "a match has ended"
// means, and it also stops a half-judged match in progress from moving
// a team up the table and then back down as the rest of the panel
// submits.
//
// A team's score for a match is the AVERAGE across the judges who scored
// it, not the sum. A panel of three would otherwise beat a panel of two
// on arithmetic alone, and which panel a team drew is not something the
// team did.
const LEADERBOARD = `
  WITH per_match AS (
    SELECT s.team_id,
           s.match_id,
           avg(s.total_score)::numeric(6,2) AS match_score,
           count(*)::int                    AS judge_count
      FROM scores s
      JOIN matches m ON m.match_id = s.match_id
     -- Always season-scoped. This used to read
     --   ($1 IS NULL OR m.challenge_id IN (...))
     -- so a NULL season fell through to every season ever played --
     -- which is exactly what the comment above says a leaderboard must
     -- not be. The route never calls this without a season now, and the
     -- query no longer offers the option.
     WHERE m.status = 'completed'
       AND m.challenge_id IN (
             SELECT challenge_id FROM challenges WHERE season_id = $1)
     GROUP BY s.team_id, s.match_id
  )
  SELECT t.team_id  AS id,
         t.team_name AS "teamName",
         c.account_id AS "clubId",
         c.club_name  AS "clubName",
         c.city       AS "clubCity",
         tc.code  AS category,
         tc.label AS "categoryLabel",
         count(pm.match_id)::int                      AS "matchesPlayed",
         sum(pm.judge_count)::int                     AS "scoreCount",
         round(sum(pm.match_score), 2)::float8        AS "totalScore",
         round(avg(pm.match_score), 2)::float8        AS "averageScore"
    FROM per_match pm
    JOIN teams t            ON t.team_id      = pm.team_id
    JOIN clubs c            ON c.account_id   = t.club_id
    JOIN team_categories tc ON tc.category_id = t.category_id
   GROUP BY t.team_id, t.team_name, c.account_id, c.club_name, c.city, tc.code, tc.label
   ORDER BY sum(pm.match_score) DESC, t.team_name`;

// ---------------------------------------------------------------------
// GET /api/leaderboard[?seasonId=]
// ---------------------------------------------------------------------
// Open: the leaderboard is a public page, and it is the whole point of
// the festival being watched.
//
// Defaults to the active season rather than to all time. A table mixing
// this year with last year is not a ranking of anything.
router.get('/', async (req, res, next) => {
  try {
    let seasonId = req.query.seasonId || null;
    let seasonName = null;

    if (!seasonId) {
      const s = await db.query('SELECT season_id, name FROM seasons WHERE is_active');
      if (s.rows[0]) { seasonId = s.rows[0].season_id; seasonName = s.rows[0].name; }
    } else {
      const s = await db.query('SELECT name FROM seasons WHERE season_id = $1', [seasonId]);
      seasonName = s.rows[0] ? s.rows[0].name : null;
    }

    // No season to rank means no ranking, not a ranking of everything.
    // Between seasons the honest answer is an empty table with the
    // season named as null, and the page can say so.
    if (!seasonId) return res.json({ seasonId: null, seasonName: null, teams: [] });

    const r = await db.query(LEADERBOARD, [seasonId]);

    // The rank is computed here rather than in SQL because ties have to
    // share a place: two teams on 87 are both 3rd, and the next is 5th.
    // A row number would silently make one of them 4th.
    let rank = 0;
    let lastScore = null;
    const rows = r.rows.map((row, i) => {
      if (row.totalScore !== lastScore) { rank = i + 1; lastScore = row.totalScore; }
      return { ...row, rank };
    });

    res.json({ seasonId: seasonId ? String(seasonId) : null, seasonName, teams: rows });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

module.exports = router;
