'use strict';
const express = require('express');
const db = require('../db');
const { requireRole, current } = require('../auth');

const router = express.Router();

// =====================================================================
// Join requests
// =====================================================================
// A member asks to join a team; the team's club accepts or rejects it.
// This lived in rocodefest_join_requests, one array per browser, which
// meant the request a member made was written into the member's own
// browser and the club's page looked for it in the club's -- so no club
// ever saw a request from anyone. Both halves of the feature worked and
// they never met.
//
// The rules are all in the schema and none of them are repeated here:
//
//   uq_join_requests_pending           one pending request per (member, team)
//   uq_memberships_active_team_member  one active membership per (team, member)
//   uq_memberships_source_request      one membership per accepted request
//   fk_memberships_source_request_matches
//                                      the membership's (request, member, team)
//                                      must be that request's own trio, so an
//                                      accept cannot enrol a different person
//   enforce_team_capacity              the category's max_members
//
// What this file owns is authorisation, which the database cannot
// express: a club may only decide requests for teams it owns. That is
// the T5 finding, and it is enforced in the WHERE clause rather than by
// reading the row and comparing -- a check that runs after the read is
// a check that can be skipped by an edit that forgets it.

// The shape both listings return. Named once so the member's view and
// the club's view cannot drift apart into two different objects for the
// same thing.
const REQUEST_COLUMNS = `
  jr.request_id AS id, jr.status, jr.message,
  jr.requested_at AS "requestedAt", jr.decided_at AS "decidedAt",
  t.team_id AS "teamId", t.team_name AS "teamName",
  tc.code AS category, tc.label AS "categoryLabel",
  c.account_id AS "clubId", c.club_name AS "clubName",
  m.account_id AS "memberId", m.full_name AS "memberName",
  m.city AS "memberCity", m.avatar_data_uri AS "memberAvatar",
  ma.email AS "memberEmail"`;

const REQUEST_FROM = `
  FROM join_requests jr
  JOIN teams t            ON t.team_id      = jr.team_id
  JOIN team_categories tc ON tc.category_id = t.category_id
  JOIN clubs c            ON c.account_id   = t.club_id
  JOIN members m          ON m.account_id   = jr.member_id
  JOIN accounts ma        ON ma.account_id  = m.account_id`;

// ---------------------------------------------------------------------
// POST /api/join-requests  -- a member asks to join a team
// ---------------------------------------------------------------------
router.post('/', requireRole('member'), async (req, res, next) => {
  const { teamId, message } = req.body || {};
  if (!teamId) return res.status(400).json({ error: 'Alege o echipă.' });

  try {
    const me = current(req);
    const r = await db.query(
      `INSERT INTO join_requests (member_id, team_id, message)
       VALUES ($1, $2, $3)
       RETURNING request_id AS id, status, requested_at AS "requestedAt"`,
      [me.accountId, teamId, message || null]
    );
    res.status(201).json({ request: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.constraint === 'uq_join_requests_pending') {
        t.message = 'Ai deja o cerere în așteptare pentru această echipă.';
      }
      if (e.constraint === 'join_requests_team_id_fkey') {
        t.message = 'Echipa nu există.';
      }
      return res.status(t.status).json({ error: t.message, hint: t.hint });
    }
    next(e);
  }
});

// ---------------------------------------------------------------------
// GET /api/join-requests/mine  -- what I have asked for
// ---------------------------------------------------------------------
router.get('/mine', requireRole('member'), async (req, res, next) => {
  try {
    const me = current(req);
    const r = await db.query(
      `SELECT ${REQUEST_COLUMNS} ${REQUEST_FROM}
       WHERE jr.member_id = $1
       ORDER BY jr.requested_at DESC`,
      [me.accountId]
    );
    res.json({ requests: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// GET /api/join-requests/incoming  -- what has been asked of my club
// ---------------------------------------------------------------------
// Scoped by t.club_id, so a club sees requests for its own teams and no
// others. There is no id in the URL to change.
router.get('/incoming', requireRole('club'), async (req, res, next) => {
  try {
    const me = current(req);
    const r = await db.query(
      `SELECT ${REQUEST_COLUMNS} ${REQUEST_FROM}
       WHERE t.club_id = $1
       ORDER BY (jr.status = 'pending') DESC, jr.requested_at DESC`,
      [me.accountId]
    );
    res.json({ requests: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// POST /api/join-requests/:id/accept  and  /reject
// ---------------------------------------------------------------------
// Accepting is two writes that must not come apart: the request becomes
// accepted, and a membership appears pointing back at it. Half of that
// is worse than neither -- an accepted request with no membership is a
// member who has been told yes and belongs to nothing, and a membership
// with no request is exactly what the composite FK exists to forbid.
//
// The capacity trigger fires on the membership INSERT, inside the same
// transaction, so a team that filled up between the request and the
// decision rolls the whole thing back and the request stays pending.
async function decide(req, res, next, status) {
  const me = current(req);
  const id = req.params.id;

  try {
    const out = await db.tx(async (c) => {
      // Ownership and pending-ness in one statement. Zero rows means
      // one of: no such request, not this club's, or already decided --
      // told apart below, but only among requests this club owns.
      const upd = await c.query(
        `UPDATE join_requests jr
            SET status = $3, decided_at = now(), decided_by = $2
           FROM teams t
          WHERE jr.request_id = $1
            AND t.team_id     = jr.team_id
            AND t.club_id     = $2
            AND jr.status     = 'pending'
        RETURNING jr.request_id, jr.member_id, jr.team_id`,
        [id, me.accountId, status]
      );

      if (!upd.rows[0]) return null;
      const row = upd.rows[0];

      if (status === 'accepted') {
        // The trio is written from the request's own columns, not from
        // anything the caller sent, which is what makes the composite
        // FK a guarantee rather than a formality.
        await c.query(
          `INSERT INTO memberships (team_id, member_id, source_request_id)
           VALUES ($1, $2, $3)`,
          [row.team_id, row.member_id, row.request_id]
        );
      }
      return row;
    });

    if (!out) {
      // Still scoped to this club, so this cannot be used to find out
      // whether some other club's request exists.
      const own = await db.query(
        `SELECT jr.status FROM join_requests jr
           JOIN teams t ON t.team_id = jr.team_id
          WHERE jr.request_id = $1 AND t.club_id = $2`,
        [id, me.accountId]
      );
      if (own.rows[0]) {
        return res.status(409).json({
          error: `Cererea a fost deja ${own.rows[0].status === 'accepted' ? 'acceptată' : 'respinsă'}.`,
        });
      }
      return res.status(404).json({ error: 'Cererea nu a fost găsită.' });
    }

    res.json({ ok: true, status });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.constraint === 'uq_memberships_active_team_member') {
        t.message = 'Această persoană face deja parte din echipă.';
      }
      return res.status(t.status).json({ error: t.message, hint: t.hint });
    }
    // enforce_team_capacity raises P0001, which db.translate passes
    // through with its own message -- it already names the team and the
    // limit, and rewording it here would lose the numbers.
    next(e);
  }
}

router.post('/:id/accept', requireRole('club'), (req, res, next) => decide(req, res, next, 'accepted'));
router.post('/:id/reject', requireRole('club'), (req, res, next) => decide(req, res, next, 'rejected'));

module.exports = router;
