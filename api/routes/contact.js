'use strict';
const express = require('express');
const db = require('../db');

const router = express.Router();

// =====================================================================
// The contact form
// =====================================================================
// Public: no account is needed to leave a message, which makes this the
// one write in the API that a stranger can reach. Three things keep that
// manageable without a captcha service:
//
//   * a honeypot field (`website`). It is hidden from people and filled
//     in by most form-spamming bots. A message that has it is answered
//     exactly like a real one and kept nowhere, so the bot learns nothing.
//   * at most PER_HOUR messages from one address in an hour, counted in
//     the database because the API runs as several short-lived instances
//     and none of them remembers the last request
//   * the limits on length are the table's own CHECKs, so a message the
//     API accepts is one the database accepts
//
// Organisers read and mark them in /admin (routes/admin.js).

const PER_HOUR = 5;

router.post('/', async (req, res, next) => {
  const { name, email, message, website } = req.body || {};

  if (website) return res.status(201).json({ ok: true });

  const n = typeof name === 'string' ? name.trim() : '';
  const e = typeof email === 'string' ? email.trim() : '';
  const m = typeof message === 'string' ? message.trim() : '';
  if (!n) return res.status(400).json({ error: 'Spune-ne cum te numești.' });
  if (!e) return res.status(400).json({ error: 'Lasă-ne o adresă de email ca să-ți putem răspunde.' });
  if (!m) return res.status(400).json({ error: 'Mesajul este gol.' });

  try {
    const recent = await db.query(
      `SELECT count(*)::int AS n FROM contact_messages
        WHERE sender_email = $1 AND created_at > now() - interval '1 hour'`,
      [e]
    );
    if (recent.rows[0].n >= PER_HOUR) {
      return res.status(429).json({ error: 'Ai trimis deja mai multe mesaje în ultima oră. Încearcă din nou mai târziu.' });
    }
    await db.query(
      'INSERT INTO contact_messages (sender_name, sender_email, body) VALUES ($1, $2, $3)',
      [n, e, m]
    );
    res.status(201).json({ ok: true });
  } catch (err) {
    const t = db.translate(err);
    if (t) {
      if (err.constraint === 'ck_contact_messages_email_shape') t.message = 'Adresa de email nu pare validă.';
      if (err.constraint === 'ck_contact_messages_body_length') t.message = 'Mesajul poate avea cel mult 5000 de caractere.';
      if (err.code === '22001') t.message = 'Numele poate avea cel mult 120 de caractere.';
      return res.status(t.status).json({ error: t.message });
    }
    next(err);
  }
});

module.exports = router;
