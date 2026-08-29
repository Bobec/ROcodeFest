'use strict';
const express = require('express');
const db = require('../db');
const { requireRole, current } = require('../auth');

const router = express.Router();

// =====================================================================
// The organiser's surface
// =====================================================================
// Every table this file writes existed from the first version of the
// schema and could be written by nobody: seasons, challenges, matches,
// match_teams, match_judges. They were populated in the test suites by
// INSERT and nowhere else, which stayed invisible while the pages kept
// their own data and became plain the moment scoring went on the API --
// a judge could ask which matches they were officiating and the honest
// answer was "none, and nothing can change that".
//
// So this is not a new feature. It is the surface that was assumed
// everywhere and declared nowhere.
//
// Every route here is organiser-only, applied once at the mount rather
// than repeated per route -- a guard added per-route is a guard a new
// route can be added without.
router.use(requireRole('organizer'));

// ---------------------------------------------------------------------
// Organisers create each other
// ---------------------------------------------------------------------
// The first one comes from scripts/create-organizer.js. After that this
// is the way, and it requires already being one.
const auth = require('../auth');

router.get('/organizers', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT o.account_id AS id, o.full_name AS "fullName", o.title,
              o.avatar_data_uri AS "avatar", a.email, a.is_active AS "isActive"
         FROM organizers o JOIN accounts a ON a.account_id = o.account_id
        ORDER BY o.full_name`
    );
    res.json({ organizers: r.rows });
  } catch (e) { next(e); }
});

router.post('/organizers', async (req, res, next) => {
  const { email, password, fullName, title } = req.body || {};
  if (!email || !fullName) return res.status(400).json({ error: 'Emailul și numele sunt obligatorii.' });
  if (typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: 'Parola trebuie să aibă cel puțin 8 caractere.' });
  }
  try {
    const account = await db.tx(async (c) => {
      const a = await c.query(
        `INSERT INTO accounts (email, password_hash, role)
         VALUES ($1, $2, 'organizer') RETURNING account_id, email`,
        [email, await auth.hash(password)]
      );
      await c.query(
        'INSERT INTO organizers (account_id, full_name, title) VALUES ($1, $2, $3)',
        [a.rows[0].account_id, fullName, title || null]
      );
      return a.rows[0];
    });
    res.status(201).json({ organizer: { id: account.account_id, email: account.email, fullName } });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.constraint === 'uq_accounts_email') t.message = 'Există deja un cont cu acest email.';
      return res.status(t.status).json({ error: t.message });
    }
    next(e);
  }
});

// ---------------------------------------------------------------------
// Seasons
// ---------------------------------------------------------------------
// uq_seasons_single_active is a partial unique index on ((TRUE)) WHERE
// is_active, so exactly one season can be active at a time. Activating
// a new one therefore means deactivating the old one, and both have to
// happen together or the second INSERT fails against the first -- which
// is why this is a transaction and not two statements.
router.get('/seasons', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT s.season_id AS id, s.name, s.start_date AS "startDate",
              s.end_date AS "endDate", s.is_active AS "isActive",
              (SELECT count(*)::int FROM challenges c WHERE c.season_id = s.season_id) AS "challengeCount"
         FROM seasons s ORDER BY s.start_date DESC, s.season_id DESC`
    );
    res.json({ seasons: r.rows });
  } catch (e) { next(e); }
});

router.post('/seasons', async (req, res, next) => {
  const { name, startDate, endDate, isActive } = req.body || {};
  if (!name || !startDate) return res.status(400).json({ error: 'Numele și data de început sunt obligatorii.' });
  try {
    const row = await db.tx(async (c) => {
      if (isActive) await c.query('UPDATE seasons SET is_active = FALSE WHERE is_active');
      const r = await c.query(
        `INSERT INTO seasons (name, start_date, end_date, is_active)
         VALUES ($1, $2, $3, COALESCE($4, FALSE))
         RETURNING season_id AS id, name, start_date AS "startDate",
                   end_date AS "endDate", is_active AS "isActive"`,
        [name, startDate, endDate || null, isActive === true]
      );
      return r.rows[0];
    });
    res.status(201).json({ season: row });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.constraint === 'uq_seasons_name') t.message = 'Există deja un sezon cu acest nume.';
      if (e.constraint === 'ck_seasons_end_after_start') t.message = 'Data de sfârșit este înaintea celei de început.';
      return res.status(t.status).json({ error: t.message });
    }
    next(e);
  }
});

router.patch('/seasons/:id', async (req, res, next) => {
  const { name, startDate, endDate, isActive } = req.body || {};
  try {
    const row = await db.tx(async (c) => {
      if (isActive === true) {
        // Deactivate every other season first. Doing it the other way
        // round trips the partial unique index and reports a duplicate,
        // which is a true statement about the index and a useless one
        // to whoever pressed the button.
        await c.query('UPDATE seasons SET is_active = FALSE WHERE is_active AND season_id <> $1', [req.params.id]);
      }
      const r = await c.query(
        `UPDATE seasons SET
           name       = COALESCE($2, name),
           start_date = COALESCE($3, start_date),
           end_date   = COALESCE($4, end_date),
           is_active  = COALESCE($5, is_active)
         WHERE season_id = $1
         RETURNING season_id AS id, name, start_date AS "startDate",
                   end_date AS "endDate", is_active AS "isActive"`,
        [req.params.id, name ?? null, startDate ?? null, endDate ?? null,
         isActive === undefined ? null : isActive]
      );
      return r.rows[0];
    });
    if (!row) return res.status(404).json({ error: 'Sezonul nu a fost găsit.' });
    res.json({ season: row });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.constraint === 'uq_seasons_name') t.message = 'Există deja un sezon cu acest nume.';
      if (e.constraint === 'ck_seasons_end_after_start') t.message = 'Data de sfârșit este înaintea celei de început.';
      return res.status(t.status).json({ error: t.message });
    }
    next(e);
  }
});

// ---------------------------------------------------------------------
// Challenges
// ---------------------------------------------------------------------
// category_id is nullable and means "open to every category". That is
// the column's own design, so the API offers it rather than requiring a
// category and quietly making the nullable case unreachable.
router.get('/challenges', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT ch.challenge_id AS id, ch.name, ch.description, ch.stage,
              ch.submission_deadline AS "deadline",
              ch.season_id AS "seasonId", s.name AS "seasonName", s.is_active AS "seasonActive",
              ch.category_id AS "categoryId", tc.label AS "categoryLabel",
              (SELECT count(*)::int FROM submissions sb WHERE sb.challenge_id = ch.challenge_id) AS "submissionCount",
              (SELECT count(*)::int FROM matches m WHERE m.challenge_id = ch.challenge_id) AS "matchCount"
         FROM challenges ch
         JOIN seasons s ON s.season_id = ch.season_id
         LEFT JOIN team_categories tc ON tc.category_id = ch.category_id
        ORDER BY s.start_date DESC, ch.submission_deadline NULLS LAST, ch.name`
    );
    res.json({ challenges: r.rows });
  } catch (e) { next(e); }
});

router.post('/challenges', async (req, res, next) => {
  const { seasonId, name, description, stage, categoryId, deadline } = req.body || {};
  if (!seasonId || !name || !stage) {
    return res.status(400).json({ error: 'Sezonul, numele și etapa sunt obligatorii.' });
  }
  try {
    const r = await db.query(
      `INSERT INTO challenges (season_id, category_id, name, description, stage, submission_deadline)
       VALUES ($1, $2, $3, $4, $5, $6)
       RETURNING challenge_id AS id, name, stage,
                 submission_deadline AS "deadline", category_id AS "categoryId"`,
      [seasonId, categoryId || null, name, description || null, stage, deadline || null]
    );
    res.status(201).json({ challenge: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.code === '22P02') t.message = 'Etapa trebuie să fie city_challenge sau final.';
      return res.status(t.status).json({ error: t.message });
    }
    next(e);
  }
});

router.patch('/challenges/:id', async (req, res, next) => {
  const { name, description, deadline, categoryId } = req.body || {};
  try {
    const r = await db.query(
      `UPDATE challenges SET
         name = COALESCE($2, name),
         description = COALESCE($3, description),
         submission_deadline = COALESCE($4, submission_deadline),
         category_id = COALESCE($5, category_id)
       WHERE challenge_id = $1
       RETURNING challenge_id AS id, name, submission_deadline AS "deadline"`,
      [req.params.id, name ?? null, description ?? null, deadline ?? null, categoryId ?? null]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Proba nu a fost găsită.' });
    res.json({ challenge: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

// ---------------------------------------------------------------------
// Matches, and the two lists that hang off them
// ---------------------------------------------------------------------
// enforce_match_is_playable refuses a score on a match that is not in
// progress or completed, so the status field here is what actually
// opens scoring. It is not a label.
router.get('/matches', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT m.match_id AS id, m.round_name AS "roundName", m.status,
              m.scheduled_at AS "scheduledAt", m.location,
              ch.challenge_id AS "challengeId", ch.name AS "challengeName",
              s.season_id AS "seasonId", s.name AS "seasonName",
              COALESCE(t.teams, '[]'::json)  AS teams,
              COALESCE(j.judges, '[]'::json) AS judges,
              (SELECT count(*)::int FROM scores sc WHERE sc.match_id = m.match_id) AS "scoreCount"
         FROM matches m
         JOIN challenges ch ON ch.challenge_id = m.challenge_id
         JOIN seasons s     ON s.season_id     = ch.season_id
         LEFT JOIN LATERAL (
           SELECT json_agg(json_build_object(
                    'id', te.team_id::text, 'teamName', te.team_name,
                    'clubName', cl.club_name) ORDER BY te.team_name) AS teams
             FROM match_teams mt
             JOIN teams te ON te.team_id = mt.team_id
             JOIN clubs cl ON cl.account_id = te.club_id
            WHERE mt.match_id = m.match_id
         ) t ON TRUE
         LEFT JOIN LATERAL (
           SELECT json_agg(json_build_object(
                    'id', jd.account_id::text, 'fullName', jd.full_name)
                  ORDER BY jd.full_name) AS judges
             FROM match_judges mj
             JOIN judges jd ON jd.account_id = mj.judge_id
            WHERE mj.match_id = m.match_id
         ) j ON TRUE
        ORDER BY m.scheduled_at NULLS LAST, m.match_id`
    );
    res.json({ matches: r.rows });
  } catch (e) { next(e); }
});

router.post('/matches', async (req, res, next) => {
  const { challengeId, roundName, scheduledAt, location, status } = req.body || {};
  if (!challengeId) return res.status(400).json({ error: 'Proba este obligatorie.' });
  try {
    const r = await db.query(
      // The cast is not decoration. A bare $5 inside COALESCE has no
      // target column to infer from, so it arrives as text and the
      // assignment to a match_status column fails with 42804 -- a
      // "datatype mismatch" that reads as an internal error rather than
      // as anything the caller did.
      `INSERT INTO matches (challenge_id, round_name, scheduled_at, location, status)
       VALUES ($1, $2, $3, $4, COALESCE($5::match_status, 'scheduled'))
       RETURNING match_id AS id, round_name AS "roundName", status,
                 scheduled_at AS "scheduledAt", location`,
      [challengeId, roundName || null, scheduledAt || null, location || null, status || null]
    );
    res.status(201).json({ match: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.constraint === 'matches_challenge_id_fkey') t.message = 'Proba nu există.';
      return res.status(t.status).json({ error: t.message });
    }
    next(e);
  }
});

router.patch('/matches/:id', async (req, res, next) => {
  const { roundName, scheduledAt, location, status } = req.body || {};
  try {
    const r = await db.query(
      `UPDATE matches SET
         round_name   = COALESCE($2, round_name),
         scheduled_at = COALESCE($3, scheduled_at),
         location     = COALESCE($4, location),
         status       = COALESCE($5, status)
       WHERE match_id = $1
       RETURNING match_id AS id, round_name AS "roundName", status,
                 scheduled_at AS "scheduledAt", location`,
      [req.params.id, roundName ?? null, scheduledAt ?? null, location ?? null, status ?? null]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Meciul nu a fost găsit.' });
    res.json({ match: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      // enforce_cancel_has_no_scores raises P0001 and names the count.
      if (e.code === '22P02') t.message = 'Starea trebuie să fie scheduled, in_progress, completed sau cancelled.';
      return res.status(t.status).json({ error: t.message, hint: t.hint });
    }
    next(e);
  }
});

// --- who is in the match ---------------------------------------------
router.post('/matches/:id/teams', async (req, res, next) => {
  const { teamId } = req.body || {};
  if (!teamId) return res.status(400).json({ error: 'Echipa este obligatorie.' });
  try {
    await db.query('INSERT INTO match_teams (match_id, team_id) VALUES ($1, $2)', [req.params.id, teamId]);
    res.status(201).json({ ok: true });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.code === '23505') t.message = 'Echipa este deja în acest meci.';
      if (e.constraint === 'match_teams_team_id_fkey')  t.message = 'Echipa nu există.';
      if (e.constraint === 'match_teams_match_id_fkey') t.message = 'Meciul nu există.';
      return res.status(t.status).json({ error: t.message });
    }
    next(e);
  }
});

router.delete('/matches/:id/teams/:teamId', async (req, res, next) => {
  try {
    // fk_scores_match_team is ON DELETE CASCADE, so removing a team
    // from a match would take its scores with it. Refusing while any
    // exist means a mis-click cannot quietly erase judging.
    const scored = await db.query(
      'SELECT count(*)::int AS n FROM scores WHERE match_id = $1 AND team_id = $2',
      [req.params.id, req.params.teamId]
    );
    if (scored.rows[0].n > 0) {
      return res.status(409).json({
        error: `Echipa are deja ${scored.rows[0].n} punctaj(e) în acest meci. Șterge-le întâi dacă chiar vrei s-o scoți.`,
      });
    }
    const r = await db.query(
      'DELETE FROM match_teams WHERE match_id = $1 AND team_id = $2 RETURNING team_id',
      [req.params.id, req.params.teamId]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Echipa nu este în acest meci.' });
    res.json({ ok: true });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

// --- who judges it ----------------------------------------------------
router.post('/matches/:id/judges', async (req, res, next) => {
  const { judgeId } = req.body || {};
  if (!judgeId) return res.status(400).json({ error: 'Arbitrul este obligatoriu.' });
  try {
    await db.query('INSERT INTO match_judges (match_id, judge_id) VALUES ($1, $2)', [req.params.id, judgeId]);
    res.status(201).json({ ok: true });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.code === '23505') t.message = 'Arbitrul este deja în comisia acestui meci.';
      if (e.constraint === 'match_judges_judge_id_fkey') t.message = 'Arbitrul nu există.';
      if (e.constraint === 'match_judges_match_id_fkey') t.message = 'Meciul nu există.';
      return res.status(t.status).json({ error: t.message });
    }
    next(e);
  }
});

router.delete('/matches/:id/judges/:judgeId', async (req, res, next) => {
  try {
    // Same reasoning as above: fk_scores_match_judge cascades, so
    // removing a judge who has scored would delete their scores.
    const scored = await db.query(
      'SELECT count(*)::int AS n FROM scores WHERE match_id = $1 AND judge_id = $2',
      [req.params.id, req.params.judgeId]
    );
    if (scored.rows[0].n > 0) {
      return res.status(409).json({
        error: `Arbitrul a dat deja ${scored.rows[0].n} punctaj(e) în acest meci și nu poate fi scos din comisie.`,
      });
    }
    const r = await db.query(
      'DELETE FROM match_judges WHERE match_id = $1 AND judge_id = $2 RETURNING judge_id',
      [req.params.id, req.params.judgeId]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Arbitrul nu este în comisia acestui meci.' });
    res.json({ ok: true });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

// --- the pickers the admin page needs ---------------------------------
// Judges and teams, plain, so the organiser can fill a panel without
// leaving the page.
router.get('/judges', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT j.account_id AS id, j.full_name AS "fullName", j.expertise,
              (SELECT count(*)::int FROM match_judges mj WHERE mj.judge_id = j.account_id) AS "matchCount"
         FROM judges j ORDER BY j.full_name`
    );
    res.json({ judges: r.rows });
  } catch (e) { next(e); }
});

module.exports = router;
