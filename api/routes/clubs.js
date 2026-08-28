'use strict';
const express = require('express');
const db = require('../db');
const { requireAuth, requireRole, current } = require('../auth');

const router = express.Router();

// ---------------------------------------------------------------------
// GET /api/clubs  -- the public directory
// ---------------------------------------------------------------------
// Open, because the pages that show it are open: founding-teams.html and
// organizations.html list clubs to anyone. Only what those pages display
// is selected -- no email, no notes, nothing an unauthenticated visitor
// has no business seeing. A SELECT * here would have leaked both.
router.get('/', async (req, res, next) => {
  try {
    // Field names are the ones the pages already use. They were the keys
    // in the localStorage arrays these endpoints replace, so the pages
    // change from "read an array" to "await an array" and nothing else.
    // count() returns bigint, which pg hands back as a string -- ::int
    // so that a page can compare it to a number without noticing.
    const r = await db.query(
      `SELECT c.account_id AS id, c.club_name AS "clubName", c.city,
              c.coach_name AS "coachName", c.founding_number AS "number",
              c.avatar_data_uri AS "avatar",
              count(t.team_id)::int AS "teamCount"
       FROM clubs c
       LEFT JOIN teams t ON t.club_id = c.account_id AND t.is_active
       GROUP BY c.account_id, c.club_name, c.city, c.coach_name,
                c.founding_number, c.avatar_data_uri
       ORDER BY c.founding_number`
    );
    res.json({ clubs: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// GET /api/clubs/me  -- the signed-in club's own record
// ---------------------------------------------------------------------
// Scoped to the session rather than to an id in the URL. Taking the id
// from the request would let any signed-in account read any club by
// changing a number -- the shape of authorisation failure recorded as
// T5, which the database cannot prevent on its own.
router.get('/me', requireRole('club'), async (req, res, next) => {
  try {
    const me = current(req);
    const r = await db.query(
      `SELECT c.account_id AS id, c.club_name AS "clubName", c.city,
              c.coach_name AS "coachName", c.notes,
              c.founding_number AS "number", c.created_at AS "createdAt",
              c.avatar_data_uri AS "avatar", a.email
       FROM clubs c JOIN accounts a ON a.account_id = c.account_id
       WHERE c.account_id = $1`,
      [me.accountId]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Clubul nu a fost găsit.' });
    res.json({ club: r.rows[0] });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// PATCH /api/clubs/me  -- edit the profile
// ---------------------------------------------------------------------
// club_name is editable and unique, so a collision is a 409 rather than a
// 500. founding_number is not editable at all: it is the club's place in
// the order of registration, and identity is not a profile field.
router.patch('/me', requireRole('club'), async (req, res, next) => {
  const { clubName, city, coachName, notes } = req.body || {};
  if (clubName !== undefined && !String(clubName).trim()) {
    return res.status(400).json({ error: 'Numele clubului nu poate fi gol.' });
  }
  try {
    const me = current(req);
    const r = await db.query(
      `UPDATE clubs SET
         club_name  = COALESCE($2, club_name),
         city       = COALESCE($3, city),
         coach_name = COALESCE($4, coach_name),
         notes      = COALESCE($5, notes)
       WHERE account_id = $1
       RETURNING account_id AS id, club_name AS "clubName", city,
                 coach_name AS "coachName", notes, founding_number AS "number"`,
      [me.accountId, clubName ?? null, city ?? null, coachName ?? null, notes ?? null]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Clubul nu a fost găsit.' });
    res.json({ club: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.constraint === 'uq_clubs_name') t.message = 'Există deja un club cu acest nume.';
      return res.status(t.status).json({ error: t.message, hint: t.hint });
    }
    next(e);
  }
});

module.exports = router;
