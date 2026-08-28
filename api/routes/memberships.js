'use strict';
const express = require('express');
const db = require('../db');
const { requireRole, current } = require('../auth');

const router = express.Router();

// =====================================================================
// Memberships -- who is actually on a team
// =====================================================================
// profile.html kept this as rocodefest_members_<clubName>: a list of
// typed-in names with a typed-in role, stored in the club's own browser.
// It was not connected to anything -- a name on that list was not an
// account, could not sign in, could not submit, and the member who had
// actually asked to join and been accepted did not appear on it.
//
// A membership is a row joining a member account to a team, and it is
// created by accepting a join request. There is no "add a member by
// typing their name" here, because there is nowhere for such a person
// to exist: members.account_id is the primary key of a real account.

// ---------------------------------------------------------------------
// GET /api/memberships?teamId=...  -- who is on one team
// ---------------------------------------------------------------------
// Open, like the team pages that show it. Names and roles only: the
// email is not here, and neither is anything else from the account.
router.get('/', async (req, res, next) => {
  const teamId = req.query.teamId;
  if (!teamId) return res.status(400).json({ error: 'teamId este obligatoriu.' });
  try {
    const r = await db.query(
      `SELECT ms.membership_id AS id, ms.role_title AS "roleTitle",
              ms.joined_at AS "joinedAt",
              m.account_id AS "memberId", m.full_name AS "memberName",
              m.city AS "memberCity", m.avatar_data_uri AS "memberAvatar",
              t.team_id AS "teamId", t.team_name AS "teamName"
       FROM memberships ms
       JOIN members m ON m.account_id = ms.member_id
       JOIN teams   t ON t.team_id    = ms.team_id
       WHERE ms.team_id = $1 AND ms.left_at IS NULL
       ORDER BY ms.joined_at`,
      [teamId]
    );
    res.json({ members: r.rows });
  } catch (e) {
    // A teamId that is not a number is a bad request, not a crash.
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

// ---------------------------------------------------------------------
// GET /api/memberships/club  -- everyone across my club's teams
// ---------------------------------------------------------------------
router.get('/club', requireRole('club'), async (req, res, next) => {
  try {
    const me = current(req);
    const r = await db.query(
      `SELECT ms.membership_id AS id, ms.role_title AS "roleTitle",
              ms.joined_at AS "joinedAt",
              m.account_id AS "memberId", m.full_name AS "memberName",
              m.city AS "memberCity", m.avatar_data_uri AS "memberAvatar",
              a.email AS "memberEmail",
              t.team_id AS "teamId", t.team_name AS "teamName"
       FROM memberships ms
       JOIN members  m ON m.account_id  = ms.member_id
       JOIN accounts a ON a.account_id  = m.account_id
       JOIN teams    t ON t.team_id     = ms.team_id
       WHERE t.club_id = $1 AND ms.left_at IS NULL
       ORDER BY t.team_name, m.full_name`,
      [me.accountId]
    );
    res.json({ members: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// DELETE /api/memberships/:id  -- the membership ends
// ---------------------------------------------------------------------
// It is not deleted. left_at is set, because a team's history is part of
// what happened: scores, submissions and forum posts from that season
// were made by someone who was on the team at the time, and removing the
// row would make the past look different from how it was.
//
// uq_memberships_active_team_member is partial on left_at IS NULL, so
// ending a membership is also what allows the same person to be
// accepted again later.
//
// Ownership is in the WHERE clause. A club may end memberships on its
// own teams and nowhere else.
router.delete('/:id', requireRole('club'), async (req, res, next) => {
  try {
    const me = current(req);
    const r = await db.query(
      `UPDATE memberships ms
          SET left_at = now()
         FROM teams t
        WHERE ms.membership_id = $1
          AND t.team_id        = ms.team_id
          AND t.club_id        = $2
          AND ms.left_at IS NULL
      RETURNING ms.membership_id AS id`,
      [req.params.id, me.accountId]
    );
    if (!r.rows[0]) {
      // Not found, not yours, or already ended -- one answer, because
      // telling them apart would let a club discover which membership
      // ids belong to other clubs.
      return res.status(404).json({ error: 'Apartenența nu a fost găsită.' });
    }
    res.json({ ok: true });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

module.exports = router;
