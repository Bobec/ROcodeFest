'use strict';
const express = require('express');
const db = require('../db');
const { requireRole, current } = require('../auth');

const router = express.Router();

// =====================================================================
// Scores
// =====================================================================
// rocodefest_scores was one array in each judge's own browser: nobody
// could see anyone else's scores, the leaderboard had nothing to read,
// and a judge changing computers arrived with an empty scoring history.
//
// The page's model was also not the schema's. It let a judge pick ANY
// team and score it, with no match involved -- but scores.match_id is
// NOT NULL and two composite foreign keys decide who may score what:
//
//   fk_scores_match_team   (match_id, team_id) must be a real pairing in
//                          match_teams -- you cannot score a team that
//                          was not in that match
//   fk_scores_match_judge  (match_id, judge_id) must be a real pairing
//                          in match_judges -- you cannot score a match
//                          you are not officiating
//
// Those two are the whole authorisation model, and they are in the
// database rather than here. This file supplies judge_id from the
// session -- the one thing the composite keys cannot check, because
// they verify the pairing exists, not that it is YOURS.
//
//   enforce_match_is_playable  refuses a score on a match that is not
//                              in progress or completed
//   uq_scores_match_team_judge one score per judge per team per match
//   four CHECKs                each sub-score is 1..10
//   total_score                GENERATED, so it is never sent

// ---------------------------------------------------------------------
// GET /api/scores/matches  -- the matches I am officiating
// ---------------------------------------------------------------------
// Driven from match_judges, so the dropdown offers exactly the matches
// this judge may score. The page used to offer every team in the
// festival, which was every option except the right ones.
router.get('/matches', requireRole('judge'), async (req, res, next) => {
  try {
    const me = current(req);
    const r = await db.query(
      `SELECT m.match_id AS id, m.round_name AS "roundName", m.status,
              m.scheduled_at AS "scheduledAt", m.location,
              ch.name AS "challengeName",
              json_agg(
                json_build_object(
                  'id',       t.team_id::text,
                  'teamName', t.team_name,
                  'clubName', c.club_name,
                  'scored',   EXISTS (SELECT 1 FROM scores s
                                       WHERE s.match_id = m.match_id
                                         AND s.team_id  = t.team_id
                                         AND s.judge_id = $1)
                )
                ORDER BY t.team_name
              ) AS teams
         FROM match_judges mj
         JOIN matches m     ON m.match_id     = mj.match_id
         JOIN challenges ch ON ch.challenge_id = m.challenge_id
         JOIN match_teams mt ON mt.match_id   = m.match_id
         JOIN teams t       ON t.team_id      = mt.team_id
         JOIN clubs c       ON c.account_id   = t.club_id
        WHERE mj.judge_id = $1
        GROUP BY m.match_id, m.round_name, m.status, m.scheduled_at,
                 m.location, ch.name
        ORDER BY m.scheduled_at NULLS LAST, m.match_id`,
      [me.accountId]
    );
    res.json({ matches: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// GET /api/scores/mine  -- what I have scored
// ---------------------------------------------------------------------
router.get('/mine', requireRole('judge'), async (req, res, next) => {
  try {
    const me = current(req);
    const r = await db.query(
      `SELECT s.score_id AS id, s.innovation_score AS innovation,
              s.execution_score AS execution, s.presentation_score AS presentation,
              s.teamwork_score AS teamwork, s.total_score AS total,
              s.comment, s.scored_at AS "scoredAt",
              t.team_id AS "teamId", t.team_name AS "teamName",
              c.club_name AS "clubName",
              m.match_id AS "matchId", m.round_name AS "roundName"
         FROM scores s
         JOIN teams t   ON t.team_id    = s.team_id
         JOIN clubs c   ON c.account_id = t.club_id
         JOIN matches m ON m.match_id   = s.match_id
        WHERE s.judge_id = $1
        ORDER BY s.scored_at DESC`,
      [me.accountId]
    );
    res.json({ scores: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// POST /api/scores
// ---------------------------------------------------------------------
const CRITERIA = ['innovation', 'execution', 'presentation', 'teamwork'];

router.post('/', requireRole('judge'), async (req, res, next) => {
  const b = req.body || {};
  if (!b.matchId || !b.teamId) {
    return res.status(400).json({ error: 'Alege meciul și echipa.' });
  }

  // The 1..10 range is four CHECK constraints and is not re-checked
  // here. What IS checked is that four numbers arrived at all: a
  // missing one would be a NOT NULL violation, and "un câmp obligatoriu
  // lipsește" says less than naming the criterion.
  for (const k of CRITERIA) {
    if (b[k] === undefined || b[k] === null || b[k] === '') {
      return res.status(400).json({ error: `Punctajul pentru "${k}" lipsește.` });
    }
  }

  try {
    const me = current(req);
    // total_score is GENERATED ALWAYS; sending it raises 428C9, which
    // is why it is not in this list. The page used to compute it.
    const r = await db.query(
      `INSERT INTO scores (match_id, team_id, judge_id,
                           innovation_score, execution_score,
                           presentation_score, teamwork_score, comment)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       RETURNING score_id AS id, total_score AS total, scored_at AS "scoredAt"`,
      [b.matchId, b.teamId, me.accountId,
       b.innovation, b.execution, b.presentation, b.teamwork,
       b.comment || null]
    );
    res.status(201).json({ score: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      // Each composite key answers a different question, and a judge
      // looking at a rejected form needs to know which one.
      if (e.constraint === 'fk_scores_match_judge') {
        t.message = 'Nu ești în comisia acestui meci.';
        t.status = 403;
      }
      if (e.constraint === 'fk_scores_match_team') {
        t.message = 'Această echipă nu a participat la meciul ales.';
      }
      if (e.constraint === 'uq_scores_match_team_judge') {
        t.message = 'Ai punctat deja această echipă în acest meci.';
      }
      if (/_score_check$/.test(e.constraint || '')) {
        t.message = 'Fiecare punctaj trebuie să fie între 1 și 10.';
      }
      return res.status(t.status).json({ error: t.message, hint: t.hint });
    }
    // enforce_match_is_playable raises P0001 naming the match's status.
    next(e);
  }
});

module.exports = router;
