'use strict';
const express = require('express');
const db = require('../db');
const { requireAuth, current } = require('../auth');

const router = express.Router();

// =====================================================================
// Forum
// =====================================================================
// rocodefest_forum was one array per browser, so the forum was a diary:
// every visitor saw only their own threads, and a reply reached nobody.
//
// Two things the page assumed that the schema does not allow, and both
// are changes worth naming rather than discovering:
//
//   * Guest posting. forum_posts.author_account_id is NOT NULL, so a
//     post has an author with an account. The composer offered a name
//     box to signed-out visitors; posting now requires signing in.
//   * Author identity by NAME. The page matched posts to their author
//     by comparing display names, which is why it also looked the
//     avatar up under rocodefest_avatar_<name>. Authorship is an
//     account id.
//
// is_deleted rather than DELETE: a comment thread whose parent vanished
// would be a set of replies to nothing. Deleted posts keep their place
// and lose their content.

const AUTHOR = `
  a.account_id AS "authorId", a.role AS "authorRole",
  COALESCE(mem.full_name, cl.club_name, jd.full_name, pt.contact_name) AS "authorName",
  COALESCE(mem.avatar_data_uri, cl.avatar_data_uri,
           jd.avatar_data_uri, pt.avatar_data_uri) AS "authorAvatar"`;

// Every author is an account, and every account is exactly one of four
// subtypes. Joining all four and coalescing is what lets one query
// answer "who wrote this" for any role -- and it is how the avatar
// reaches the forum at all, which a per-browser key never could.
const AUTHOR_JOINS = `
  JOIN accounts a       ON a.account_id   = p.author_account_id
  LEFT JOIN members mem ON mem.account_id = a.account_id
  LEFT JOIN clubs cl    ON cl.account_id  = a.account_id
  LEFT JOIN judges jd   ON jd.account_id  = a.account_id
  LEFT JOIN partners pt ON pt.account_id  = a.account_id`;

// ---------------------------------------------------------------------
// GET /api/forum/categories
// ---------------------------------------------------------------------
router.get('/categories', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT category_id AS id, code, label
         FROM forum_categories ORDER BY sort_order, label`
    );
    res.json({ categories: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// GET /api/forum/posts?category=code
// ---------------------------------------------------------------------
// Open: the forum is readable by anyone, which is what a festival forum
// is for. Writing needs an account.
router.get('/posts', async (req, res, next) => {
  const code = req.query.category || null;
  try {
    const r = await db.query(
      `SELECT p.post_id AS id, p.title,
              CASE WHEN p.is_deleted THEN NULL ELSE p.body END AS body,
              p.is_deleted AS "isDeleted",
              p.created_at AS "createdAt", p.edited_at AS "editedAt",
              fc.code AS "categoryCode", fc.label AS "categoryLabel",
              ${AUTHOR},
              (SELECT count(*)::int FROM forum_comments fcm
                WHERE fcm.post_id = p.post_id AND NOT fcm.is_deleted) AS "commentCount"
         FROM forum_posts p
         JOIN forum_categories fc ON fc.category_id = p.category_id
         ${AUTHOR_JOINS}
        WHERE ($1::text IS NULL OR fc.code = $1)
        ORDER BY p.created_at DESC`,
      [code]
    );
    res.json({ posts: r.rows });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// GET /api/forum/posts/:id/comments
// ---------------------------------------------------------------------
router.get('/posts/:id/comments', async (req, res, next) => {
  try {
    const r = await db.query(
      `SELECT p.comment_id AS id, p.post_id AS "postId",
              p.parent_comment_id AS "parentId",
              CASE WHEN p.is_deleted THEN NULL ELSE p.body END AS body,
              p.is_deleted AS "isDeleted",
              p.created_at AS "createdAt", p.edited_at AS "editedAt",
              ${AUTHOR}
         FROM forum_comments p
         ${AUTHOR_JOINS}
        WHERE p.post_id = $1
        ORDER BY p.created_at`,
      [req.params.id]
    );
    res.json({ comments: r.rows });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

// ---------------------------------------------------------------------
// POST /api/forum/posts
// ---------------------------------------------------------------------
// Announcements are the one category not open to everyone. There is no
// organiser role in the schema, so for now it is judges -- stated here
// rather than left as an accident of whoever posts first. When an
// organiser role exists this is the line that changes.
const ANNOUNCEMENT_ROLES = ['judge'];

router.post('/posts', requireAuth, async (req, res, next) => {
  const { category, title, body } = req.body || {};
  if (!category || !title || !String(title).trim()) {
    return res.status(400).json({ error: 'Alege o categorie și dă subiectului un titlu.' });
  }
  const me = current(req);
  if (category === 'announcements' && !ANNOUNCEMENT_ROLES.includes(me.role)) {
    return res.status(403).json({ error: 'Doar organizatorii pot publica anunțuri.' });
  }

  try {
    const r = await db.query(
      `INSERT INTO forum_posts (category_id, author_account_id, title, body)
       SELECT fc.category_id, $2, $3, $4
         FROM forum_categories fc WHERE fc.code = $1
       RETURNING post_id AS id, title, created_at AS "createdAt"`,
      [category, me.accountId, String(title).trim(), body || null]
    );
    if (!r.rows[0]) return res.status(400).json({ error: 'Categorie necunoscută.' });
    res.status(201).json({ post: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message, hint: t.hint });
    next(e);
  }
});

// ---------------------------------------------------------------------
// POST /api/forum/posts/:id/comments
// ---------------------------------------------------------------------
router.post('/posts/:id/comments', requireAuth, async (req, res, next) => {
  const { body, parentId } = req.body || {};
  if (!body || !String(body).trim()) {
    return res.status(400).json({ error: 'Scrie un răspuns.' });
  }
  try {
    const me = current(req);
    // A reply to a deleted post would be a reply to nothing, and the
    // subquery refuses it rather than letting it land invisibly.
    const r = await db.query(
      `INSERT INTO forum_comments (post_id, parent_comment_id, author_account_id, body)
       SELECT $1, $2, $3, $4
        WHERE EXISTS (SELECT 1 FROM forum_posts fp
                       WHERE fp.post_id = $1 AND NOT fp.is_deleted)
       RETURNING comment_id AS id, created_at AS "createdAt"`,
      [req.params.id, parentId || null, me.accountId, String(body).trim()]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Subiectul nu a fost găsit.' });
    res.status(201).json({ comment: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message, hint: t.hint });
    next(e);
  }
});

// ---------------------------------------------------------------------
// PATCH /api/forum/posts/:id   and   /comments/:id
// ---------------------------------------------------------------------
// edited_at is what the "(edited)" mark is drawn from, and
// ck_forum_posts_edited_after_created keeps it honest. Only the author,
// enforced in the WHERE clause -- the page used to compare display
// names, which meant two accounts sharing a name could edit each
// other's posts.
router.patch('/posts/:id', requireAuth, async (req, res, next) => {
  const { title, body } = req.body || {};
  if (title !== undefined && !String(title).trim()) {
    return res.status(400).json({ error: 'Titlul nu poate fi gol.' });
  }
  try {
    const me = current(req);
    const r = await db.query(
      `UPDATE forum_posts
          SET title = COALESCE($3, title),
              body  = COALESCE($4, body),
              edited_at = now()
        WHERE post_id = $1 AND author_account_id = $2 AND NOT is_deleted
      RETURNING post_id AS id, title, body, edited_at AS "editedAt"`,
      [req.params.id, me.accountId,
       title === undefined ? null : String(title).trim(),
       body === undefined ? null : body]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Subiectul nu a fost găsit.' });
    res.json({ post: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

router.patch('/comments/:id', requireAuth, async (req, res, next) => {
  const { body } = req.body || {};
  if (!body || !String(body).trim()) {
    return res.status(400).json({ error: 'Răspunsul nu poate fi gol.' });
  }
  try {
    const me = current(req);
    const r = await db.query(
      `UPDATE forum_comments SET body = $3, edited_at = now()
        WHERE comment_id = $1 AND author_account_id = $2 AND NOT is_deleted
      RETURNING comment_id AS id, body, edited_at AS "editedAt"`,
      [req.params.id, me.accountId, String(body).trim()]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Răspunsul nu a fost găsit.' });
    res.json({ comment: r.rows[0] });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

// ---------------------------------------------------------------------
// DELETE /api/forum/posts/:id   and   /comments/:id
// ---------------------------------------------------------------------
// Marked deleted, not removed. A comment thread whose parent vanished
// would be replies to nothing, and forum_comments.parent_comment_id
// makes that a real shape rather than a hypothetical one.
//
// Only the author, and the WHERE clause is what says so -- the page
// used to compare display names, which meant two accounts with the same
// name could edit each other's posts.
router.delete('/posts/:id', requireAuth, async (req, res, next) => {
  try {
    const me = current(req);
    const r = await db.query(
      `UPDATE forum_posts SET is_deleted = TRUE
        WHERE post_id = $1 AND author_account_id = $2 AND NOT is_deleted
      RETURNING post_id AS id`,
      [req.params.id, me.accountId]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Subiectul nu a fost găsit.' });
    res.json({ ok: true });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

router.delete('/comments/:id', requireAuth, async (req, res, next) => {
  try {
    const me = current(req);
    const r = await db.query(
      `UPDATE forum_comments SET is_deleted = TRUE
        WHERE comment_id = $1 AND author_account_id = $2 AND NOT is_deleted
      RETURNING comment_id AS id`,
      [req.params.id, me.accountId]
    );
    if (!r.rows[0]) return res.status(404).json({ error: 'Răspunsul nu a fost găsit.' });
    res.json({ ok: true });
  } catch (e) {
    const t = db.translate(e);
    if (t) return res.status(t.status).json({ error: t.message });
    next(e);
  }
});

module.exports = router;
