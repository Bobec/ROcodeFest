'use strict';
const express = require('express');
const db = require('../db');
const { requireRole, current } = require('../auth');

const router = express.Router();

// =====================================================================
// Appeals
// =====================================================================
// rocodefest_appeals was one array in the filing club's own browser, so
// an appeal was addressed to nobody: no organiser could read it, and the
// club itself lost it on a different computer.
//
// The page also enforced "three rejected appeals and this team may file
// no more" by counting entries in that array -- which reset with site
// data and applied to nobody else's browser.
//
// That rule is real: enforce_appeal_limit has been in the schema all
// along and says the same thing, per team, for everyone. The page was
// keeping a second copy of it, and a second copy is exactly what drifts.
// So nothing here re-checks it; the trigger refuses the fourth appeal
// and its message names the team and the limit.

const APPEAL_COLUMNS = `
  ap.appeal_id AS id, ap.status, ap.reason,
  ap.livestream_timestamp::text AS "timestamp",
  ap.created_at AS "createdAt", ap.decided_at AS "decidedAt",
  t.team_id AS "teamId", t.team_name AS "teamName",
  c.account_id AS "clubId", c.club_name AS "clubName",
  r.rule_id AS "ruleId", r.code AS "ruleCode", r.title AS "ruleTitle"`;

const APPEAL_FROM = `
  FROM appeals ap
  JOIN teams t ON t.team_id    = ap.team_id
  JOIN clubs c ON c.account_id = t.club_id
  LEFT JOIN rules r ON r.rule_id = ap.rule_id`;

// ---------------------------------------------------------------------
// GET /api/appeals/rules  -- which rules can be cited
// ---------------------------------------------------------------------
// Read from the table, not from a list written into the page. The page
// had six codes hardcoded, and the rules table has no rows behind them
// -- so every one of those codes named a rule that does not exist.
//
// Retired rules are excluded here, and refuse_retired_rule_citation
// refuses them again on insert. Two places, deliberately: the first
// keeps a retired rule out of the dropdown, the second is what makes it
// impossible regardless of what the dropdown offered.
router.get('/rules', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT rule_id AS id, code, title, version_label AS "versionLabel"
         FROM rules WHERE retired_at IS NULL
        ORDER BY code`
    );
    res.json({ rules: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// GET /api/appeals  -- my club's appeals
// ---------------------------------------------------------------------
router.get('/', requireRole('club'), async (req, res, next) => {
  try {
    const me = current(req);
    const r = await db.query(
      `SELECT ${APPEAL_COLUMNS} ${APPEAL_FROM}
        WHERE t.club_id = $1
        ORDER BY ap.created_at DESC`,
      [me.accountId]
    );
    res.json({ appeals: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// POST /api/appeals
// ---------------------------------------------------------------------
// team_id is checked against the club's own teams in the INSERT itself.
// filed_by_account_id comes from the session and is never accepted from
// the body -- it is the same bare FK as submitted_by_account_id, so the
// database checks the account exists and nothing more.
router.post('/', requireRole('club'), async (req, res, next) => {
  const { teamId, reason, ruleId, timestamp } = req.body || {};
  if (!teamId || !reason || !String(reason).trim()) {
    return res.status(400).json({ error: 'Alege echipa și explică motivul contestației.' });
  }

  // livestream_timestamp is an INTERVAL. An empty string would be a
  // 22007, so it becomes NULL here -- that is a shape question, not a
  // rule, and the column being nullable is what says it is optional.
  const ts = timestamp && String(timestamp).trim() ? String(timestamp).trim() : null;

  try {
    const me = current(req);
    const r = await db.query(
      `INSERT INTO appeals (team_id, rule_id, filed_by_account_id, reason, livestream_timestamp)
       SELECT $1, $2, $3, $4, $5::interval
        WHERE $1 IN (SELECT team_id FROM teams WHERE club_id = $3)
       RETURNING appeal_id AS id, status, created_at AS "createdAt"`,
      [teamId, ruleId || null, me.accountId, String(reason).trim(), ts]
    );
    if (!r.rows[0]) {
      return res.status(403).json({ error: 'Poți contesta doar pentru echipele clubului tău.' });
    }
    res.status(201).json({ appeal: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.code === '22007' || e.code === '22P02') {
        t.message = 'Momentul din transmisiune trebuie scris ca ore:minute:secunde.';
        t.status = 400;
      }
      return res.status(t.status).json({ error: t.message, hint: t.hint });
    }
    // refuse_retired_rule_citation raises P0001 and its hint says what
    // to do instead; both are passed through.
    next(e);
  }
});

module.exports = router;
