'use strict';
const bcrypt = require('bcryptjs');

// bcrypt with a work factor, not a bare hash. The schema calls the column
// password_hash and makes it NOT NULL, so it always expected this -- the
// pages simply never sent a password, matching on an email string alone.
const ROUNDS = 12;

async function hash(plain)          { return bcrypt.hash(plain, ROUNDS); }
async function verify(plain, stored) {
  // A missing or malformed hash must fail closed, and must not throw --
  // an exception here would be a 500, which tells an attacker that the
  // account exists.
  try { return await bcrypt.compare(plain, stored || ''); }
  catch { return false; }
}

// ---------------------------------------------------------------------
// The session
// ---------------------------------------------------------------------
// ONE session, in an httpOnly cookie, holding only the account id and
// role. Two deliberate choices:
//
//   * one session, not four. The pages currently keep
//     rocodefest_session, _member_session, _judge_session and
//     _partner_session as separate keys, which is why signing out of one
//     role leaves another signed in (frontend S4) and why a signed-in
//     judge shows as signed out (S2). Those are not bugs to port across;
//     the role belongs IN the session, not in the choice of key.
//
//   * httpOnly, so page scripts cannot read it. A token in localStorage
//     is readable by any script on the page, and the site already runs
//     inline script on all 29 pages.
function login(req, account) {
  req.session.accountId = account.account_id;
  req.session.role      = account.role;
  req.session.email     = account.email;
}

function logout(req) {
  return new Promise((resolve) => req.session.destroy(() => resolve()));
}

function current(req) {
  if (!req.session || !req.session.accountId) return null;
  return { accountId: req.session.accountId, role: req.session.role, email: req.session.email };
}

// Guards. requireAuth answers "is anyone signed in", requireRole answers
// "is it the right kind of person" -- the second is the thing the database
// cannot do for us, and is exactly the gap recorded as T5.
function requireAuth(req, res, next) {
  if (!current(req)) return res.status(401).json({ error: 'Trebuie să fii autentificat.' });
  next();
}

function requireRole(...roles) {
  return (req, res, next) => {
    const me = current(req);
    if (!me) return res.status(401).json({ error: 'Trebuie să fii autentificat.' });
    if (!roles.includes(me.role)) {
      return res.status(403).json({ error: 'Contul tău nu are acest drept.' });
    }
    next();
  };
}

module.exports = { hash, verify, login, logout, current, requireAuth, requireRole };
