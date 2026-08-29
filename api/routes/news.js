'use strict';
const express = require('express');
const db = require('../db');
const { requireRole, current } = require('../auth');

const router = express.Router();

// =====================================================================
// News
// =====================================================================
// news.html was an empty state with nothing behind it -- "no news yet",
// hardcoded, forever. It is the one piece of purely editorial content
// the festival publishes.
//
// Kept separate from the forum's announcements category on purpose: an
// announcement is a thread people reply to, an article is not.
//
// published_at is nullable, so a draft is a row without a publication
// date. A status column would have needed its own rules about which
// transitions are legal; a date needs none, and it is the thing the
// page sorts by anyway.

const NEWS_COLUMNS = `
  n.news_id AS id, n.title, n.summary, n.body,
  n.published_at AS "publishedAt", n.created_at AS "createdAt",
  n.updated_at AS "updatedAt",
  o.full_name AS "authorName", o.title AS "authorTitle",
  o.avatar_data_uri AS "authorAvatar"`;

const NEWS_FROM = `
  FROM news_posts n
  LEFT JOIN organizers o ON o.account_id = n.author_account_id`;

// ---------------------------------------------------------------------
// GET /api/news
// ---------------------------------------------------------------------
// Public, and published-only for the public. An organiser asking gets
// their drafts too, because otherwise there is no way to see one after
// writing it.
router.get('/', async (req, res, next) => {
  const me = current(req);
  const isOrganizer = !!me && me.role === 'organizer';
  try {
    const r = await db.query(
      `SELECT ${NEWS_COLUMNS} ${NEWS_FROM}
        WHERE ($1::boolean OR n.published_at IS NOT NULL)
        ORDER BY COALESCE(n.published_at, n.created_at) DESC`,
      [isOrganizer]
    );
    res.json({ news: r.rows });
  } catch (e) { next(e); }
});

router.get('/:id', async (req, res, next) => {
  const me = current(req);
  const isOrganizer = !!me && me.role === 'organizer';
  try {
    const r = await db.query(
      `SELECT ${NEWS_COLUMNS} ${NEWS_FROM}
        WHERE n.news_id = $1 AND ($2::boolean OR n.published_at IS NOT NULL)`,
      [req.params.id, isOrganizer]
    );
    // A draft answers 404 to everyone else rather than 403: that a draft
    // exists is itself not public.
    if (!r.rows[0]) return res.status(404).json({ error: 'Articolul nu a fost găsit.' });
    res.json({ article: r.rows[0] });
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
  const { title, summary, body, publish } = req.body || {};
  if (!title || !String(title).trim()) return res.status(400).json({ error: 'Titlul este obligatoriu.' });
  if (!body || !String(body).trim()) return res.status(400).json({ error: 'Textul este obligatoriu.' });
  try {
    const me = current(req);
    const r = await db.query(
      `INSERT INTO news_posts (author_account_id, title, summary, body, published_at)
       VALUES ($1, $2, $3, $4, CASE WHEN $5 THEN now() ELSE NULL END)
       RETURNING news_id AS id, title, published_at AS "publishedAt"`,
      [me.accountId, String(title).trim(), summary || null, String(body).trim(), publish === true]
    );
    res.status(201).json({ article: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

router.patch('/:id', requireRole('organizer'), async (req, res, next) => {
  const { title, summary, body, publish } = req.body || {};
  if (title !== undefined && !String(title).trim()) {
    return res.status(400).json({ error: 'Titlul nu poate fi gol.' });
  }
  try {
    // publish is three-valued on purpose: true publishes (and stamps
    // the date only if it is not already set, so re-publishing does not
    // move an article back to the top), false unpublishes, and absent
    // leaves it alone.
    const r = await db.query(
      `UPDATE news_posts SET
         title   = COALESCE($2, title),
         summary = COALESCE($3, summary),
         body    = COALESCE($4, body),
         published_at = CASE
           WHEN $5::boolean IS NULL  THEN published_at
           WHEN $5::boolean IS FALSE THEN NULL
           WHEN published_at IS NULL THEN now()
           ELSE published_at
         END
       WHERE news_id = $1
       RETURNING news_id AS id, title, published_at AS "publishedAt"`,
      [req.params.id,
       title === undefined ? null : String(title).trim(),
       summary === undefined ? null : summary,
       body === undefined ? null : body,
       publish === undefined ? null : publish]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Articolul nu a fost găsit.' });
    res.json({ article: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

router.delete('/:id', requireRole('organizer'), async (req, res, next) => {
  try {
    const r = await db.query('DELETE FROM news_posts WHERE news_id = $1 RETURNING news_id AS id', [req.params.id]);
    if (!r.rows[0]) return res.status(404).json({ error: 'Articolul nu a fost găsit.' });
    res.json({ ok: true });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

module.exports = router;
