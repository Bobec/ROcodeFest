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
// Registration, for all four roles
// ---------------------------------------------------------------------
// One endpoint rather than four near-identical ones. An account plus its
// subtype row is the same shape every time -- what changes is which table
// the second insert goes to and which fields it needs -- so the shape is
// described once, as data, and the handler below is the same code for a
// club, a member, a judge and a partner.
//
// enforce_subtype_role refuses a subtype row whose account has the wrong
// role, so the pair must be one transaction: an account committed without
// its subtype row would be one nobody can use, and R8 now refuses to
// change the role afterwards, so it could not be repaired by hand either.
const SUBTYPES = {
  club: {
    table: 'clubs',
    // founding_number is GENERATED ALWAYS AS IDENTITY. The page used to
    // compute it as "how many clubs are in localStorage, plus one".
    columns: ['club_name', 'city', 'coach_name', 'notes'],
    from: (b) => [b.clubName, b.city || null, b.coachName || null, b.notes || null],
    required: (b) => (b.clubName ? null : 'Numele clubului este obligatoriu.'),
    conflicts: { uq_clubs_name: 'Există deja un club cu acest nume.' },
  },
  member: {
    table: 'members',
    columns: ['full_name', 'city', 'bio'],
    from: (b) => [b.fullName, b.city || null, b.bio || null],
    required: (b) => (b.fullName ? null : 'Numele este obligatoriu.'),
    conflicts: {},
  },
  judge: {
    table: 'judges',
    columns: ['full_name', 'expertise', 'bio'],
    from: (b) => [b.fullName, b.expertise || null, b.bio || null],
    required: (b) => (b.fullName ? null : 'Numele este obligatoriu.'),
    conflicts: {},
  },
  partner: {
    table: 'partners',
    columns: ['org_name', 'contact_name', 'partner_type', 'message'],
    from: (b) => [b.orgName || null, b.contactName, b.partnerType, b.message || null],
    required: (b) => {
      if (!b.contactName) return 'Numele persoanei de contact este obligatoriu.';
      if (!b.partnerType) return 'Tipul de partener este obligatoriu.';
      return null;
    },
    conflicts: {},
  },
};

router.post('/register', async (req, res, next) => {
  const body = req.body || {};

  // 'organizer' is deliberately absent from SUBTYPES, and this says so
  // out loud rather than letting it fall into "unknown role". An
  // organiser can create seasons, matches and panels for the whole
  // festival, so a public form that hands out that role is a public
  // form that hands out the festival. They are created by another
  // organiser, and the first one by a command-line script -- which is
  // an operational act, not a web page.
  if (body.role === 'organizer') {
    return res.status(403).json({
      error: 'Conturile de organizator nu se creează din formular. ' +
             'Cere unui organizator existent să îți facă unul.',
    });
  }

  const spec = SUBTYPES[body.role];
  if (!spec) {
    return res.status(400).json({
      error: `Rol necunoscut. Alege unul dintre: ${Object.keys(SUBTYPES).join(', ')}.`,
    });
  }
  if (!body.email) return res.status(400).json({ error: 'Emailul este obligatoriu.' });

  const missing = spec.required(body);
  if (missing) return res.status(400).json({ error: missing });

  const pwErr = badPassword(body.password);
  if (pwErr) return res.status(400).json({ error: pwErr });

  try {
    const account = await db.tx(async (c) => {
      const a = await c.query(
        `INSERT INTO accounts (email, password_hash, role)
         VALUES ($1, $2, $3)
         RETURNING account_id, email, role`,
        [body.email, await auth.hash(body.password), body.role]
      );
      const cols = ['account_id', ...spec.columns];
      const holes = cols.map((_, i) => `$${i + 1}`).join(', ');
      await c.query(
        `INSERT INTO ${spec.table} (${cols.join(', ')}) VALUES (${holes})`,
        [a.rows[0].account_id, ...spec.from(body)]
      );
      return a.rows[0];
    });

    auth.login(req, account);
    res.status(201).json({ account: { id: account.account_id, email: account.email, role: account.role } });
  } catch (e) {
    const t = db.translate(e);
    if (t) {
      // The email collision is shared by every role; the rest are the
      // subtype's own. Which field to change is the only thing the person
      // filling in the form actually needs from this message.
      if (e.constraint === 'uq_accounts_email') t.message = 'Există deja un cont cu acest email.';
      else if (spec.conflicts[e.constraint])    t.message = spec.conflicts[e.constraint];
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
// This one call replaces the nav's three-key OR across all 29 pages, and
// with it three findings at once:
//
//   S2  a judge was signed in and every navigation bar showed them
//       signed out, because rocodefest_judge_session was not in the list
//   S3  and nothing anywhere cleared that key, so the session could not
//       be ended at all
//   S4  signing in as a club and then as a member left two keys set, and
//       signing out of one still showed you as signed in
//
// None of those are possible against one session that carries its own
// role. A page asks who is here; it does not deduce it from which key
// happens to be present.
const PROFILE = {
  club:    `SELECT club_name AS "clubName", founding_number AS "foundingNumber",
                   city, coach_name AS "coachName", avatar_data_uri AS "avatar"
            FROM clubs WHERE account_id = $1`,
  member:  `SELECT full_name AS "fullName", city, bio, avatar_data_uri AS "avatar"
            FROM members WHERE account_id = $1`,
  judge:   `SELECT full_name AS "fullName", expertise, bio, avatar_data_uri AS "avatar"
            FROM judges WHERE account_id = $1`,
  partner: `SELECT org_name AS "orgName", contact_name AS "contactName",
                   partner_type AS "partnerType", message, avatar_data_uri AS "avatar"
            FROM partners WHERE account_id = $1`,
  organizer: `SELECT full_name AS "fullName", title, bio, avatar_data_uri AS "avatar"
              FROM organizers WHERE account_id = $1`,
};

router.get('/me', async (req, res, next) => {
  const me = auth.current(req);
  if (!me) return res.json({ account: null });
  try {
    const r = await db.query(
      `SELECT account_id, email, role FROM accounts WHERE account_id = $1 AND is_active`,
      [me.accountId]
    );
    // The account can disappear or be deactivated while a session is
    // still open. Reporting it as signed in would leave a visitor with a
    // navigation bar promising a profile that answers 404.
    if (!r.rows[0]) { await auth.logout(req); return res.json({ account: null }); }
    const a = r.rows[0];

    let profile = {};
    const q = PROFILE[a.role];
    if (q) {
      const p = await db.query(q, [a.account_id]);
      if (p.rows[0]) profile = p.rows[0];
    }

    res.json({ account: { id: a.account_id, email: a.email, role: a.role, ...profile } });
  } catch (e) { next(e); }
});

module.exports = router;
