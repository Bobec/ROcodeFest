'use strict';
const express = require('express');
const db = require('../db');
const { requireAuth, requireRole, current } = require('../auth');

const router = express.Router();

// =====================================================================
// Certificates
// =====================================================================
// certificates.html drew a canvas from MOCK_CERT: an invented team, an
// invented club, three invented participants. The design of that canvas
// stays exactly as it was -- what changes is where the names come from.
//
// A certificate is issued per team OR per participant, which is one
// table with a nullable member_id rather than two near-identical ones.
// So a club sees its teams' certificates, a member sees their own, and
// both need the same shape back.
//
// Nothing here issues one. Issuing is an organiser act tied to
// finalised results, and inventing that flow before the results exist
// would be inventing policy. What this does is show what has been
// issued -- and, when nothing has, let the page draw a preview from the
// viewer's REAL team and REAL teammates rather than from three made-up
// names.

const CERT_COLUMNS = `
  c.certificate_id AS id, c.certificate_type AS "type",
  c.serial_code AS "serialCode", c.file_url AS "fileUrl",
  c.issued_at AS "issuedAt",
  t.team_id AS "teamId", t.team_name AS "teamName",
  cl.club_name AS "clubName", cl.city AS "clubCity",
  tc.label AS "categoryLabel",
  s.season_id AS "seasonId", s.name AS "seasonName",
  m.account_id AS "memberId", m.full_name AS "memberName"`;

const CERT_FROM = `
  FROM certificates c
  JOIN teams t            ON t.team_id      = c.team_id
  JOIN clubs cl           ON cl.account_id  = t.club_id
  JOIN team_categories tc ON tc.category_id = t.category_id
  JOIN seasons s          ON s.season_id    = c.season_id
  LEFT JOIN members m     ON m.account_id   = c.member_id`;

// ---------------------------------------------------------------------
// GET /api/certificates  -- what has been issued to me
// ---------------------------------------------------------------------
router.get('/', requireAuth, async (req, res, next) => {
  const me = current(req);
  try {
    let r;
    if (me.role === 'club') {
      r = await db.query(
        `SELECT ${CERT_COLUMNS} ${CERT_FROM}
          WHERE t.club_id = $1 ORDER BY c.issued_at DESC`, [me.accountId]);
    } else if (me.role === 'member') {
      // A member's own certificate, and the team-level ones for teams
      // they belong to -- a team certificate belongs to everyone on it.
      r = await db.query(
        `SELECT ${CERT_COLUMNS} ${CERT_FROM}
          WHERE c.member_id = $1
             OR (c.member_id IS NULL AND t.team_id IN (
                   SELECT team_id FROM memberships
                    WHERE member_id = $1 AND left_at IS NULL))
          ORDER BY c.issued_at DESC`, [me.accountId]);
    } else {
      // Judges, partners and organisers have no certificates of their
      // own. An empty list is the truthful answer, not a refusal.
      return res.json({ certificates: [], preview: null });
    }

    // The preview the page falls back to when nothing has been issued.
    // It carries the viewer's real team and the real names on it, so
    // what they see is what their certificate will say.
    const preview = await previewFor(me);
    res.json({ certificates: r.rows, preview });
  } catch (e) { next(e); }
});

// One team the viewer belongs to, with everyone currently on it. Used
// only to draw a preview, which is why it does not need to be a
// certificate at all.
async function previewFor(me) {
  const teamQ = me.role === 'club'
    ? `SELECT t.team_id, t.team_name, cl.club_name, cl.city, tc.label AS category_label
         FROM teams t
         JOIN clubs cl ON cl.account_id = t.club_id
         JOIN team_categories tc ON tc.category_id = t.category_id
        WHERE t.club_id = $1 AND t.is_active
        ORDER BY t.team_name LIMIT 1`
    : `SELECT t.team_id, t.team_name, cl.club_name, cl.city, tc.label AS category_label
         FROM memberships ms
         JOIN teams t ON t.team_id = ms.team_id
         JOIN clubs cl ON cl.account_id = t.club_id
         JOIN team_categories tc ON tc.category_id = t.category_id
        WHERE ms.member_id = $1 AND ms.left_at IS NULL
        ORDER BY t.team_name LIMIT 1`;

  const t = await db.query(teamQ, [me.accountId]);
  if (!t.rows[0]) return null;

  const people = await db.query(
    `SELECT m.full_name FROM memberships ms
       JOIN members m ON m.account_id = ms.member_id
      WHERE ms.team_id = $1 AND ms.left_at IS NULL
      ORDER BY m.full_name`,
    [t.rows[0].team_id]
  );
  const season = await db.query('SELECT name FROM seasons WHERE is_active');

  return {
    teamName: t.rows[0].team_name,
    clubName: t.rows[0].club_name,
    clubCity: t.rows[0].city,
    categoryLabel: t.rows[0].category_label,
    seasonName: season.rows[0] ? season.rows[0].name : null,
    participants: people.rows.map((p) => p.full_name),
  };
}

// ---------------------------------------------------------------------
// POST /api/certificates  -- an organiser issues one
// ---------------------------------------------------------------------
// serial_code is the verifiable public id and is unique. It is supplied
// rather than generated here: the format belongs to the festival, and a
// scheme invented in a route is a scheme nobody agreed to.
router.post('/', requireRole('organizer'), async (req, res, next) => {
  const { teamId, memberId, seasonId, type, serialCode } = req.body || {};
  if (!teamId || !seasonId || !serialCode) {
    return res.status(400).json({ error: 'Echipa, sezonul și codul de serie sunt obligatorii.' });
  }
  try {
    const r = await db.query(
      `INSERT INTO certificates (team_id, member_id, season_id, certificate_type, serial_code)
       VALUES ($1, $2, $3, COALESCE($4::certificate_type, 'participation'), $5)
       RETURNING certificate_id AS id, serial_code AS "serialCode", issued_at AS "issuedAt"`,
      [teamId, memberId || null, seasonId, type || null, String(serialCode).trim()]
    );
    res.status(201).json({ certificate: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.constraint === 'uq_certificates_serial') t.message = 'Există deja un certificat cu acest cod de serie.';
      if (e.code === '22P02') t.message = 'Tipul certificatului nu este recunoscut.';
      return res.status(t.status).json({ error: t.message, hint: t.hint });
    }
    next(e);
  }
});

module.exports = router;
