'use strict';
const express = require('express');
const db = require('../db');

const router = express.Router();

// ---------------------------------------------------------------------
// GET /api/stats  -- the headline counts
// ---------------------------------------------------------------------
// The partner dashboard and the landing page both showed numbers by
// reading a localStorage array and taking its .length, which meant the
// figures described the visitor's own browser rather than the festival:
// a partner opening the dashboard for the first time was told there were
// no clubs and no teams.
//
// Open, because these are the numbers the public pages already display.
// Counts of rows, nothing identifying.
//
// One query rather than four round trips -- these are always shown
// together, and count(*) over tables this size costs less than the
// requests would.
router.get('/', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT (SELECT count(*) FROM clubs)::int                        AS clubs,
              (SELECT count(*) FROM teams WHERE is_active)::int        AS teams,
              (SELECT count(*) FROM members)::int                      AS members,
              (SELECT count(*) FROM submissions)::int                  AS submissions,
              (SELECT count(*) FROM partners)::int                     AS partners`
    );
    res.json({ stats: r.rows[0] });
  } catch (e) { next(e); }
});

module.exports = router;
