'use strict';
const express = require('express');
const db = require('../db');
const { requireAuth, current } = require('../auth');

const router = express.Router();

// =====================================================================
// Submissions
// =====================================================================
// This was rocodefest_submissions: one array per browser. A club could
// not see what its members had submitted, a member could not see what
// the club had, and no judge could see anything at all -- which made
// the review, resubmission and scoring machinery in the schema
// unreachable from the site.
//
// Everything about a submission's LIFECYCLE is already in the database,
// and none of it is repeated here:
//
//   assign_submission_version           version = max + 1, computed on
//                                       insert; the caller never sends one
//   enforce_resubmission_gate           version > 1 is refused unless a
//                                       review on the previous version
//                                       asked for a resubmission
//   enforce_submission_lineage_immutable
//                                       version, team and challenge
//                                       cannot change after insert
//   uq_submissions_team_challenge_version
//
// What this file owns is the T5 half: submitted_by_account_id is a bare
// FK, so the database checks that the account EXISTS and never that it
// has anything to do with the team. That is finding T5, recorded as
// unowned at the database layer. It is owned here.

// Which teams this account may submit for: the teams a club owns, or
// the teams a member currently belongs to. Written as a subquery rather
// than fetched and compared in JavaScript -- a check that runs after the
// read is a check a later edit can forget to make.
//
// It takes the parameter NUMBER because the account is not always $1.
// Interpolating a query fragment is only safe because this argument is
// a number this file supplies, never anything from a request.
function myTeams(accountParam) {
  return `
    SELECT t.team_id FROM teams t WHERE t.club_id = $${accountParam}
    UNION
    SELECT ms.team_id FROM memberships ms
     WHERE ms.member_id = $${accountParam} AND ms.left_at IS NULL`;
}

const SUBMISSION_COLUMNS = `
  s.submission_id AS id, s.title, s.description, s.link_url AS "linkUrl",
  s.version, s.created_at AS "createdAt", s.updated_at AS "updatedAt",
  t.team_id AS "teamId", t.team_name AS "teamName",
  c.account_id AS "clubId", c.club_name AS "clubName",
  ch.challenge_id AS "challengeId", ch.name AS "challengeName",
  ch.submission_deadline AS "deadline",
  s.submitted_by_account_id AS "authorId",
  acc.role AS "authorRole",
  COALESCE(mem.full_name, acl.club_name) AS "authorName"`;

const SUBMISSION_FROM = `
  FROM submissions s
  JOIN teams      t   ON t.team_id      = s.team_id
  JOIN clubs      c   ON c.account_id   = t.club_id
  JOIN challenges ch  ON ch.challenge_id = s.challenge_id
  JOIN accounts   acc ON acc.account_id = s.submitted_by_account_id
  LEFT JOIN members mem ON mem.account_id = acc.account_id
  LEFT JOIN clubs   acl ON acl.account_id = acc.account_id`;

// ---------------------------------------------------------------------
// GET /api/submissions  -- what I can see
// ---------------------------------------------------------------------
// A club sees everything from its own teams; a member sees what they
// personally submitted. That is the split the page already described in
// its own wording, and it was implemented by filtering an array on an
// email address.
router.get('/', requireAuth, async (req, res, next) => {
  const me = current(req);
  try {
    const r = me.role === 'club'
      ? await db.query(
          `SELECT ${SUBMISSION_COLUMNS} ${SUBMISSION_FROM}
            WHERE t.club_id = $1
            ORDER BY s.created_at DESC`,
          [me.accountId])
      : await db.query(
          `SELECT ${SUBMISSION_COLUMNS} ${SUBMISSION_FROM}
            WHERE s.submitted_by_account_id = $1
            ORDER BY s.created_at DESC`,
          [me.accountId]);
    res.json({ submissions: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// GET /api/submissions/challenges?teamId=...
// ---------------------------------------------------------------------
// A team can only be set challenges from its own category, in the
// active season. The page had no challenge picker at all and the
// column is NOT NULL, so there was nothing to submit against.
//
// A challenge with no category is open to every category; that is what
// the nullable column means.
router.get('/challenges', requireAuth, async (req, res, next) => {
  const teamId = req.query.teamId;
  if (!teamId) return res.status(400).json({ error: 'teamId este obligatoriu.' });
  const me = current(req);
  try {
    const r = await db.query(
      `SELECT ch.challenge_id AS id, ch.name, ch.description, ch.stage,
              ch.submission_deadline AS "deadline",
              (ch.submission_deadline IS NOT NULL
               AND ch.submission_deadline < now()) AS "closed"
         FROM challenges ch
         JOIN seasons sn ON sn.season_id = ch.season_id AND sn.is_active
         JOIN teams t    ON t.team_id = $1
        WHERE (ch.category_id IS NULL OR ch.category_id = t.category_id)
          AND t.team_id IN (${myTeams(2)})
        ORDER BY ch.submission_deadline NULLS LAST, ch.name`,
      [teamId, me.accountId]
    );
    res.json({ challenges: r.rows });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

// ---------------------------------------------------------------------
// POST /api/submissions
// ---------------------------------------------------------------------
router.post('/', requireAuth, async (req, res, next) => {
  const { teamId, challengeId, title, description, linkUrl } = req.body || {};
  if (!teamId || !challengeId || !title) {
    return res.status(400).json({ error: 'Echipa, proba și titlul sunt obligatorii.' });
  }
  const me = current(req);
  try {
    // team_id is checked against MY_TEAMS in the INSERT itself. Zero
    // rows means the team is not one this account may submit for, and
    // nothing was written on the way to finding that out.
    //
    // version is deliberately absent: assign_submission_version
    // computes it, and a caller who could send one could rewrite a
    // team's history.
    const r = await db.query(
      `INSERT INTO submissions (team_id, challenge_id, title, description,
                                link_url, submitted_by_account_id)
       SELECT $1, $2, $3, $4, $5, $6
        WHERE $1 IN (${myTeams(6)})
       RETURNING submission_id AS id, version, title, created_at AS "createdAt"`,
      [teamId, challengeId, String(title).trim(), description || null,
       linkUrl || null, me.accountId]
    );
    if (!r.rows[0]) {
      return res.status(403).json({ error: 'Nu poți trimite pentru această echipă.' });
    }
    res.status(201).json({ submission: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.constraint === 'submissions_challenge_id_fkey') t.message = 'Proba nu există.';
      if (e.constraint === 'submissions_team_id_fkey')      t.message = 'Echipa nu există.';
      return res.status(t.status).json({ error: t.message, hint: t.hint });
    }
    // enforce_resubmission_gate raises P0001 and its message already
    // names the version and how many reviews it found. db.translate
    // passes it through; rewording it here would lose that.
    next(e);
  }
});

// ---------------------------------------------------------------------
// PATCH /api/submissions/:id
// ---------------------------------------------------------------------
// The author may edit their own; the owning club may edit any of its
// teams'. Both are in the WHERE clause.
//
// Only the three descriptive fields are editable. team, challenge and
// version are refused by enforce_submission_lineage_immutable anyway --
// they are simply not offered, so the refusal never has to happen.
router.patch('/:id', requireAuth, async (req, res, next) => {
  const { title, description, linkUrl } = req.body || {};
  if (title !== undefined && !String(title).trim()) {
    return res.status(400).json({ error: 'Titlul nu poate fi gol.' });
  }
  const me = current(req);
  try {
    const r = await db.query(
      `UPDATE submissions s
          SET title       = COALESCE($3, s.title),
              description = COALESCE($4, s.description),
              link_url    = COALESCE($5, s.link_url)
         FROM teams t
        WHERE s.submission_id = $1
          AND t.team_id       = s.team_id
          AND (s.submitted_by_account_id = $2 OR t.club_id = $2)
      RETURNING s.submission_id AS id, s.title, s.description,
                s.link_url AS "linkUrl", s.version`,
      [req.params.id, me.accountId,
       title === undefined ? null : String(title).trim(),
       description === undefined ? null : description,
       linkUrl === undefined ? null : linkUrl]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Lucrarea nu a fost găsită.' });
    res.json({ submission: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

// ---------------------------------------------------------------------
// DELETE /api/submissions/:id
// ---------------------------------------------------------------------
// Only the newest version of a chain can go. Deleting an earlier one
// would leave a version 3 whose version 2 no longer exists, and
// enforce_resubmission_gate reads the predecessor to decide whether a
// resubmission was allowed -- so the chain has to stay contiguous.
router.delete('/:id', requireAuth, async (req, res, next) => {
  const me = current(req);
  try {
    const r = await db.query(
      `DELETE FROM submissions s
         USING teams t
        WHERE s.submission_id = $1
          AND t.team_id       = s.team_id
          AND (s.submitted_by_account_id = $2 OR t.club_id = $2)
          AND s.version = (SELECT max(s2.version) FROM submissions s2
                            WHERE s2.team_id = s.team_id
                              AND s2.challenge_id = s.challenge_id)
      RETURNING s.submission_id AS id`,
      [req.params.id, me.accountId]
    );
    if (!r.rows[0]) {
      // Either it is not yours, or it is not the latest version. Both
      // answered the same way: which one it is, is only useful to
      // someone probing for ids that are not theirs.
      return res.status(404).json({ error: 'Lucrarea nu poate fi ștearsă.' });
    }
    res.json({ ok: true });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

module.exports = router;
