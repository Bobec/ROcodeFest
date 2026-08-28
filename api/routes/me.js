'use strict';
const express = require('express');
const db = require('../db');
const { requireAuth, current } = require('../auth');

const router = express.Router();

// Which table holds this role's profile. The avatar column is the same
// on all four, so the only thing that varies is where to write it.
const SUBTYPE = { club: 'clubs', member: 'members', judge: 'judges', partner: 'partners' };

// ---------------------------------------------------------------------
// PUT /api/me/avatar
// ---------------------------------------------------------------------
// The picture used to live in localStorage as rocodefest_avatar_<name>,
// so the same account had one on one computer and none on another, and
// nobody else ever saw it. It is a column now.
//
// Nothing here validates the image. The size limit and the data-URI shape
// are both CHECK constraints, and re-checking them in JavaScript would
// put the rule in two places -- the API's job is to turn the refusal into
// a status code a page can act on.
router.put('/avatar', requireAuth, async (req, res, next) => {
  const me = current(req);
  const table = SUBTYPE[me.role];
  if (!table) return res.status(403).json({ error: 'Acest tip de cont nu are profil.' });

  const { avatar } = req.body || {};
  if (avatar !== null && typeof avatar !== 'string') {
    return res.status(400).json({ error: 'Trimite imaginea ca data URI, sau null ca s-o ștergi.' });
  }

  try {
    const r = await db.query(
      `UPDATE ${table} SET avatar_data_uri = $2 WHERE account_id = $1
       RETURNING account_id`,
      [me.accountId, avatar]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Profilul nu a fost găsit.' });
    res.json({ ok: true });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      // The two CHECKs answer different questions, and the person
      // choosing a file needs to know which one they tripped.
      if (/avatar_size/.test(e.constraint || ''))  t.message = 'Imaginea este prea mare. Alege una sub 150 KB.';
      if (/avatar_shape/.test(e.constraint || '')) t.message = 'Fișierul nu este o imagine (png, jpeg, gif sau webp).';
      return res.status(t.status).json({ error: t.message });
    }
    next(e);
  }
});

module.exports = router;
