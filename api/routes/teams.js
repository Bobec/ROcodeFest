'use strict';
const express = require('express');
const db = require('../db');
const { requireRole, current } = require('../auth');

const router = express.Router();

// GET /api/teams -- public listing, used by the leaderboard and the
// founding-teams page. participation_code is included because those pages
// display it; it identifies a team publicly rather than authenticating it.
router.get('/', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT t.team_id AS id, t.team_name, t.participation_code, t.is_active,
              c.club_name, c.account_id AS club_id,
              tc.code AS category_code, tc.label AS category_label, tc.max_members,
              count(m.membership_id) FILTER (WHERE m.left_at IS NULL) AS member_count
       FROM teams t
       JOIN clubs c            ON c.account_id  = t.club_id
       JOIN team_categories tc ON tc.category_id = t.category_id
       LEFT JOIN memberships m ON m.team_id      = t.team_id
       GROUP BY t.team_id, t.team_name, t.participation_code, t.is_active,
                c.club_name, c.account_id, tc.code, tc.label, tc.max_members
       ORDER BY c.club_name, t.team_name`
    );
    res.json({ teams: r.rows });
  } catch (e) { next(e); }
});

// GET /api/teams/categories -- what a team may be created as. Read from
// the table rather than hardcoded, so adding a category is a data change:
// the same reasoning the forum MIME allowlist was tested for, where a
// list compiled into the code would have passed every test that mattered
// except the one proving the table is actually consulted.
router.get('/categories', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT category_id AS id, code, label, max_members
       FROM team_categories ORDER BY category_id`
    );
    res.json({ categories: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// POST /api/teams  -- a club creates one of its own teams
// ---------------------------------------------------------------------
// club_id comes from the SESSION, never from the body. Accepting it from
// the request would let any signed-in club create teams under another
// club's name, which is the same shape as the T5 finding: the database
// checks that the club EXISTS, never that it is yours.
//
// Everything else is left to the database. uq_teams_participation_code,
// uq_teams_club_name and the category FK all have tests behind them, and
// re-checking any of them here would put the rule in two places.
router.post('/', requireRole('club'), async (req, res, next) => {
  const { teamName, categoryId, participationCode } = req.body || {};
  if (!teamName || !categoryId || !participationCode) {
    return res.status(400).json({ error: 'Numele echipei, categoria și codul de participare sunt obligatorii.' });
  }
  try {
    const me = current(req);
    const r = await db.query(
      `INSERT INTO teams (club_id, category_id, team_name, participation_code)
       VALUES ($1, $2, $3, $4)
       RETURNING team_id AS id, team_name, participation_code, category_id, is_active`,
      [me.accountId, categoryId, String(teamName).trim(), String(participationCode).trim()]
    );
    res.status(201).json({ team: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.constraint === 'uq_teams_participation_code') t.message = 'Acest cod de participare este deja folosit.';
      if (e.constraint === 'uq_teams_club_name')          t.message = 'Clubul tău are deja o echipă cu acest nume.';
      return res.status(t.status).json({ error: t.message, hint: t.hint });
    }
    next(e);
  }
});

// ---------------------------------------------------------------------
// GET /api/teams/mine  -- the signed-in club's teams
// ---------------------------------------------------------------------
router.get('/mine', requireRole('club'), async (req, res, next) => {
  try {
    const me = current(req);
    const r = await db.query(
      `SELECT t.team_id AS id, t.team_name, t.participation_code, t.is_active,
              tc.code AS category_code, tc.label AS category_label, tc.max_members,
              count(m.membership_id) FILTER (WHERE m.left_at IS NULL) AS member_count
       FROM teams t
       JOIN team_categories tc ON tc.category_id = t.category_id
       LEFT JOIN memberships m ON m.team_id = t.team_id
       WHERE t.club_id = $1
       GROUP BY t.team_id, t.team_name, t.participation_code, t.is_active,
                tc.code, tc.label, tc.max_members
       ORDER BY t.team_name`,
      [me.accountId]
    );
    res.json({ teams: r.rows });
  } catch (e) { next(e); }
});

module.exports = router;
