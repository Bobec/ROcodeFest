'use strict';
const express = require('express');
const db = require('../db');
const auth = require('../auth');

const router = express.Router();

// A password rule has to live somewhere, and it is not a database
// concern -- password_hash is opaque to Postgres. Kept deliberately
// modest: length is the property that actually matters, and rules about
// symbols mostly produce written-down passwords.
const MIN_PASSWORD = 8;

function badPassword(pw) {
  if (typeof pw !== 'string' || pw.length < MIN_PASSWORD) {
    return `Parola trebuie să aibă cel puțin ${MIN_PASSWORD} caractere.`;
  }
  return null;
}

// ---------------------------------------------------------------------
// POST /auth/register  -- a club account
// ---------------------------------------------------------------------
// Account and club row in ONE transaction. enforce_subtype_role refuses a
// clubs row whose account is not role='club', so committing the account
// alone would leave one nobody can use; and R8 now refuses to change the
// role afterwards while the subtype row exists, so it could not be
// repaired by hand either.
router.post('/register', async (req, res, next) => {
  const { email, password, clubName, city, coachName, notes } = req.body || {};
  if (!email || !clubName) {
    return res.status(400).json({ error: 'Emailul și numele clubului sunt obligatorii.' });
  }
  const pwErr = badPassword(password);
  if (pwErr) return res.status(400).json({ error: pwErr });

  try {
    const account = await db.tx(async (c) => {
      const a = await c.query(
        `INSERT INTO accounts (email, password_hash, role)
         VALUES ($1, $2, 'club')
         RETURNING account_id, email, role`,
        [email, await auth.hash(password)]
      );
      // founding_number is GENERATED ALWAYS AS IDENTITY -- the mockup
      // computed it as "how many clubs are in localStorage, plus one",
      // which two people registering at once would have given the same
      // number. The database has never needed help with that.
      await c.query(
        `INSERT INTO clubs (account_id, club_name, city, coach_name, notes)
         VALUES ($1, $2, $3, $4, $5)`,
        [a.rows[0].account_id, clubName, city || null, coachName || null, notes || null]
      );
      return a.rows[0];
    });

    auth.login(req, account);
    res.status(201).json({ account: { id: account.account_id, email: account.email, role: account.role } });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      // uq_accounts_email and uq_clubs_name both land here, and the
      // difference matters to whoever is filling in the form
      if (e.constraint === 'uq_accounts_email')  t.message = 'Există deja un cont cu acest email.';
      if (e.constraint === 'uq_clubs_name')      t.message = 'Există deja un club cu acest nume.';
      return res.status(t.status).json({ error: t.message, hint: t.hint });
    }
    next(e);
  }
});

// ---------------------------------------------------------------------
// POST /auth/login
// ---------------------------------------------------------------------
router.post('/login', async (req, res, next) => {
  const { email, password } = req.body || {};
  if (!email || !password) {
    return res.status(400).json({ error: 'Emailul și parola sunt obligatorii.' });
  }
  try {
    const r = await db.query(
      `SELECT account_id, email, role, password_hash, is_active
       FROM accounts WHERE email = $1`,
      [email]
    );
    const acc = r.rows[0];

    // The same answer whether the account is missing, inactive, or the
    // password is wrong. Distinguishing them turns the login form into a
    // way to find out which addresses are registered.
    const ok = acc && acc.is_active && await auth.verify(password, acc.password_hash);
    if (!ok) return res.status(401).json({ error: 'Email sau parolă greșită.' });

    auth.login(req, acc);
    res.json({ account: { id: acc.account_id, email: acc.email, role: acc.role } });
  } catch (e) { next(e); }
});

// ---------------------------------------------------------------------
// POST /auth/logout
// ---------------------------------------------------------------------
// One call ends the session completely, whatever the role. The pages
// currently clear one key of four, which is finding S4.
router.post('/logout', async (req, res) => {
  await auth.logout(req);
  res.clearCookie('rocodefest.sid');
  res.status(204).end();
});

// ---------------------------------------------------------------------
// GET /auth/me  -- who is signed in, if anyone
// ---------------------------------------------------------------------
// This replaces the nav's three-key OR: one question, one answer, and the
// role comes back with it, so a page never has to guess from which key
// happened to be set.
router.get('/me', async (req, res, next) => {
  const me = auth.current(req);
  if (!me) return res.json({ account: null });
  try {
    const r = await db.query(
      `SELECT a.account_id, a.email, a.role, c.club_name, c.founding_number
       FROM accounts a
       LEFT JOIN clubs c ON c.account_id = a.account_id
       WHERE a.account_id = $1 AND a.is_active`,
      [me.accountId]
    );
    if (!r.rows[0]) { await auth.logout(req); return res.json({ account: null }); }
    const a = r.rows[0];
    res.json({
      account: {
        id: a.account_id, email: a.email, role: a.role,
        clubName: a.club_name || undefined,
        foundingNumber: a.founding_number || undefined,
      },
    });
  } catch (e) { next(e); }
});

module.exports = router;
