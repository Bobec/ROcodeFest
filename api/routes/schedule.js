'use strict';
const express = require('express');
const db = require('../db');
const { requireRole } = require('../auth');

const router = express.Router();

// =====================================================================
// The run of show
// =====================================================================
// contest-day.html and events.html both showed a hardcoded agenda. They
// now read the same source, so they cannot disagree with each other --
// which two hand-maintained copies of a timetable eventually always do.
//
// Two streams are merged here rather than one table holding both:
//
//   matches         already carry scheduled_at and location. They are
//                   NOT copied into schedule_items; a row there may
//                   POINT at one. Copying would create a second
//                   scheduled_at, and two copies of a time are two
//                   times that disagree the moment one of them moves.
//   schedule_items  everything between the matches -- the opening, the
//                   lunch break, the awards. That is what turns a list
//                   of match times into a run of show.
//
// A match that has a schedule_items row is returned once, with the
// row's title; a match without one is returned from matches alone. So
// an organiser can name a match ("Semifinala A") without having to, and
// nothing is silently missing from the timetable either way.

const SCHEDULE = `
  WITH season AS (
    SELECT season_id, name, start_date, end_date
      FROM seasons WHERE season_id = $1
  ),
  items AS (
    SELECT si.item_id::text AS id, si.kind::text AS kind, si.title, si.detail,
           si.location, si.starts_at AS "startsAt", si.ends_at AS "endsAt",
           si.match_id::text AS "matchId",
           m.status::text AS "matchStatus",
           m.round_name AS "roundName"
      FROM schedule_items si
      LEFT JOIN matches m ON m.match_id = si.match_id
     WHERE si.season_id = (SELECT season_id FROM season)
  ),
  loose_matches AS (
    -- Matches with no schedule row of their own. Left out, the timetable
    -- would quietly omit half the day the first time somebody forgot to
    -- add one.
    SELECT NULL::text AS id, 'match' AS kind,
           COALESCE(m.round_name, 'Meci') AS title,
           NULL::text AS detail,
           m.location, m.scheduled_at AS "startsAt", NULL::timestamptz AS "endsAt",
           m.match_id::text AS "matchId",
           m.status::text AS "matchStatus",
           m.round_name AS "roundName"
      FROM matches m
      JOIN challenges ch ON ch.challenge_id = m.challenge_id
     WHERE ch.season_id = (SELECT season_id FROM season)
       AND m.scheduled_at IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM schedule_items si WHERE si.match_id = m.match_id)
  )
  SELECT * FROM items
  UNION ALL
  SELECT * FROM loose_matches
  ORDER BY "startsAt"`;

// ---------------------------------------------------------------------
// GET /api/schedule[?seasonId=]
// ---------------------------------------------------------------------
// Public. Defaults to the active season, and returns the season's own
// dates alongside -- events.html draws its timeline from those plus the
// challenge deadlines, rather than from four sentences typed into the
// page.
router.get('/', async (req, res, next) => {
  try {
    let seasonId = req.query.seasonId || null;
    let season = null;

    const s = seasonId
      ? await db.query(
          `SELECT season_id AS id, name, start_date AS "startDate",
                  end_date AS "endDate", is_active AS "isActive"
             FROM seasons WHERE season_id = $1`, [seasonId])
      : await db.query(
          `SELECT season_id AS id, name, start_date AS "startDate",
                  end_date AS "endDate", is_active AS "isActive"
             FROM seasons WHERE is_active`);

    if (!s.rows[0]) return res.json({ season: null, milestones: [], items: [] });
    season = s.rows[0];
    seasonId = season.id;

    // The milestones events.html used to state as prose. Every one of
    // them is already a date somewhere: the season's own start, and the
    // deadline of each challenge. Nothing is invented here.
    const milestones = await db.query(
      `SELECT ch.challenge_id AS id, ch.name, ch.stage,
              ch.submission_deadline AS "deadline"
         FROM challenges ch
        WHERE ch.season_id = $1 AND ch.submission_deadline IS NOT NULL
        ORDER BY ch.submission_deadline`,
      [seasonId]
    );

    const items = await db.query(SCHEDULE, [seasonId]);
    res.json({ season, milestones: milestones.rows, items: items.rows });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

// ---------------------------------------------------------------------
// Writing -- organisers only
// ---------------------------------------------------------------------
router.post('/', requireRole('organizer'), async (req, res, next) => {
  const { seasonId, kind, title, detail, location, startsAt, endsAt, matchId } = req.body || {};
  if (!seasonId || !kind || !title || !startsAt) {
    return res.status(400).json({ error: 'Sezonul, tipul, titlul și ora de început sunt obligatorii.' });
  }
  try {
    const r = await db.query(
      `INSERT INTO schedule_items (season_id, match_id, kind, title, detail, location, starts_at, ends_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       RETURNING item_id AS id, kind, title, starts_at AS "startsAt", ends_at AS "endsAt"`,
      [seasonId, matchId || null, kind, String(title).trim(), detail || null,
       location || null, startsAt, endsAt || null]
    );
    res.status(201).json({ item: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      // Each constraint answers a different question and the organiser
      // needs to know which one refused.
      if (e.constraint === 'ck_schedule_items_match_kind') {
        t.message = 'Doar o intrare de tip „match” poate fi legată de un meci.';
      }
      if (e.constraint === 'uq_schedule_items_match') {
        t.message = 'Meciul are deja o intrare în program.';
      }
      if (e.constraint === 'ck_schedule_items_ends_after_starts') {
        t.message = 'Ora de sfârșit este înaintea celei de început.';
      }
      if (e.code === '22P02') {
        t.message = 'Tipul trebuie să fie opening, match, break, talk, awards sau other.';
      }
      return res.status(t.status).json({ error: t.message });
    }
    next(e);
  }
});

router.patch('/:id', requireRole('organizer'), async (req, res, next) => {
  const { title, detail, location, startsAt, endsAt } = req.body || {};
  try {
    const r = await db.query(
      `UPDATE schedule_items SET
         title     = COALESCE($2, title),
         detail    = COALESCE($3, detail),
         location  = COALESCE($4, location),
         starts_at = COALESCE($5, starts_at),
         ends_at   = COALESCE($6, ends_at)
       WHERE item_id = $1
       RETURNING item_id AS id, title, starts_at AS "startsAt", ends_at AS "endsAt"`,
      [req.params.id, title ?? null, detail ?? null, location ?? null, startsAt ?? null, endsAt ?? null]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Intrarea nu a fost găsită.' });
    res.json({ item: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      if (e.constraint === 'ck_schedule_items_ends_after_starts') {
        t.message = 'Ora de sfârșit este înaintea celei de început.';
      }
      return res.status(t.status).json({ error: t.message });
    }
    next(e);
  }
});

router.delete('/:id', requireRole('organizer'), async (req, res, next) => {
  try {
    const r = await db.query('DELETE FROM schedule_items WHERE item_id = $1 RETURNING item_id AS id', [req.params.id]);
    if (!r.rows[0]) return res.status(404).json({ error: 'Intrarea nu a fost găsită.' });
    res.json({ ok: true });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

module.exports = router;
