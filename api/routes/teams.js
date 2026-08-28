'use strict';
const express = require('express');
const db = require('../db');
const { requireAuth, requireRole, current } = require('../auth');

const router = express.Router();

// GET /api/teams -- public listing, used by the leaderboard and the
// founding-teams page. participation_code is included because those pages
// display it; it identifies a team publicly rather than authenticating it.
router.get('/', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT t.team_id AS id, t.team_name AS "teamName",
              t.participation_code AS "participationCode", t.is_active AS "isActive",
              c.club_name AS "clubName", c.account_id AS "clubId",
              c.city AS "clubCity", c.founding_number AS "clubNumber",
              tc.code AS "category", tc.label AS "categoryLabel",
              tc.max_members AS "maxMembers",
              count(m.membership_id) FILTER (WHERE m.left_at IS NULL)::int AS "memberCount"
       FROM teams t
       JOIN clubs c            ON c.account_id  = t.club_id
       JOIN team_categories tc ON tc.category_id = t.category_id
       LEFT JOIN memberships m ON m.team_id      = t.team_id
       GROUP BY t.team_id, t.team_name, t.participation_code, t.is_active,
                c.club_name, c.account_id, c.city, c.founding_number,
                tc.code, tc.label, tc.max_members
       ORDER BY c.founding_number, t.team_name`
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
      `SELECT category_id AS id, code, label, max_members AS "maxMembers"
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
       RETURNING team_id AS id, team_name AS "teamName",
                 participation_code AS "participationCode",
                 category_id AS "categoryId", is_active AS "isActive"`,
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
// GET /api/teams/mine  -- the teams that are yours
// ---------------------------------------------------------------------
// "Mine" means something different for each role, and both meanings are
// answered here rather than by two endpoints, because every page asking
// the question wants the same thing: the teams this person may act for.
//
//   club    the teams it owns
//   member  the teams it currently belongs to -- memberships with
//           left_at IS NULL, which is where "currently" lives
//
// The member branch replaces a page reading rocodefest_join_requests and
// keeping the ones whose status said accepted. An accepted request is
// not a membership; it is what led to one. Asking the memberships means
// a member removed from a team stops being able to act for it, which the
// request list would never have shown.
router.get('/mine', requireAuth, async (req, res, next) => {
  const me = current(req);
  if (me.role !== 'club' && me.role !== 'member') {
    return res.status(403).json({ error: 'Doar cluburile și membrii au echipe.' });
  }

  // Two queries, one shape: the columns and their names are identical,
  // so a page does not have to know which role it is rendering.
  const SELECT = `
    SELECT t.team_id AS id, t.team_name AS "teamName",
           t.participation_code AS "participationCode", t.is_active AS "isActive",
           c.club_name AS "clubName", c.account_id AS "clubId",
           tc.code AS "category", tc.label AS "categoryLabel",
           tc.max_members AS "maxMembers",
           count(m2.membership_id) FILTER (WHERE m2.left_at IS NULL)::int AS "memberCount"
    FROM teams t
    JOIN clubs c            ON c.account_id  = t.club_id
    JOIN team_categories tc ON tc.category_id = t.category_id
    LEFT JOIN memberships m2 ON m2.team_id = t.team_id`;

  const GROUP = `
    GROUP BY t.team_id, t.team_name, t.participation_code, t.is_active,
             c.club_name, c.account_id, tc.code, tc.label, tc.max_members
    ORDER BY t.team_name`;

  try {
    const r = me.role === 'club'
      ? await db.query(`${SELECT} WHERE t.club_id = $1 ${GROUP}`, [me.accountId])
      : await db.query(
          `${SELECT}
           JOIN memberships mine ON mine.team_id = t.team_id
                                AND mine.member_id = $1
                                AND mine.left_at IS NULL
           ${GROUP}`,
          [me.accountId]
        );
    res.json({ teams: r.rows });
  } catch (e) { next(e); }
});

module.exports = router;
