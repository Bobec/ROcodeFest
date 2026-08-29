#!/usr/bin/env node
'use strict';
// =====================================================================
// Create an organiser account
// =====================================================================
// The first organiser has to come from somewhere, and that somewhere
// cannot be a web page: an organiser creates seasons, matches and
// panels for the whole festival, so a public form handing out that role
// is a public form handing out the festival. /auth/register refuses it
// explicitly for that reason.
//
// So it is a command, run by whoever already has the database password.
// After the first one exists, organisers create each other through
// POST /api/admin/organizers -- and that route requires being one.
//
//   node scripts/create-organizer.js <email> <password> "<full name>" ["<title>"]
//
// Refuses to overwrite: an existing email is an error, not an update.
// Silently resetting the password of an account that already exists is
// how a typo becomes a lockout nobody can explain.
const db = require('../db');
const auth = require('../auth');

const [, , email, password, fullName, title] = process.argv;

function usage(msg) {
  console.error(msg);
  console.error('');
  console.error('  node scripts/create-organizer.js <email> <password> "<nume complet>" ["<functie>"]');
  console.error('');
  console.error('Variabilele de conexiune sunt cele obisnuite: PGHOST, PGUSER,');
  console.error('PGPASSWORD, PGDATABASE.');
  process.exit(1);
}

if (!email || !password || !fullName) usage('Lipsesc argumente.');
if (password.length < 8) usage('Parola trebuie sa aiba cel putin 8 caractere.');

(async () => {
  try {
    const existing = await db.query('SELECT account_id, role FROM accounts WHERE email = $1', [email]);
    if (existing.rows[0]) {
      console.error(`Exista deja un cont cu emailul ${email} (rol: ${existing.rows[0].role}).`);
      console.error('Sterge-l intai, sau foloseste alt email. Acest script nu suprascrie.');
      process.exit(1);
    }

    // One transaction: enforce_subtype_role refuses an organizers row
    // whose account has the wrong role, so an account committed without
    // its subtype row would be one nobody can use -- and R8 refuses to
    // change the role afterwards, so it could not be repaired by hand.
    const account = await db.tx(async (c) => {
      const a = await c.query(
        `INSERT INTO accounts (email, password_hash, role)
         VALUES ($1, $2, 'organizer')
         RETURNING account_id, email`,
        [email, await auth.hash(password)]
      );
      await c.query(
        'INSERT INTO organizers (account_id, full_name, title) VALUES ($1, $2, $3)',
        [a.rows[0].account_id, fullName, title || null]
      );
      return a.rows[0];
    });

    console.log(`Organizator creat: ${account.email} (id ${account.account_id})`);
    console.log('Poti intra pe /login.html cu acest email si parola data.');
    process.exit(0);
  } catch (e) {
    console.error('Nu s-a putut crea contul:', e.message);
    process.exit(1);
  }
})();
