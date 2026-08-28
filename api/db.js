'use strict';
const { Pool } = require('pg');

// One pool for the process. Every query below runs through it, and the
// search_path is pinned on the connection so unqualified names resolve to
// oltp -- the same class of defect R4 fixed inside the database, arriving
// here from the other direction.
const pool = new Pool({
  host:     process.env.PGHOST     || 'localhost',
  port:     Number(process.env.PGPORT || 5432),
  user:     process.env.PGUSER     || 'postgres',
  password: process.env.PGPASSWORD,
  database: process.env.PGDATABASE || 'rocodefest',
  max: 10,
});

pool.on('connect', (c) => { c.query('SET search_path = oltp, public'); });

// ---------------------------------------------------------------------
// Translating database errors into HTTP
// ---------------------------------------------------------------------
// The API deliberately does NOT re-implement the rules. Team capacity,
// the resubmission gate, the officiating panel, appeal closure -- all of
// it is enforced by constraints and triggers that have 581 test cases
// behind them. Re-checking any of that in JavaScript would create a
// second copy of the rule, and the two would drift.
//
// So the API's job at this layer is narrow: run the statement, and turn
// whatever the database says into a status code and a message a page can
// show. The SQLSTATE is what carries that meaning.
const SQLSTATE = {
  '23505': { status: 409, message: 'Există deja o înregistrare cu aceste date.' },
  '23503': { status: 400, message: 'Referință către ceva care nu există.' },
  '23514': { status: 400, message: 'Datele nu respectă o regulă a concursului.' },
  '23502': { status: 400, message: 'Un câmp obligatoriu lipsește.' },
  '22P02': { status: 400, message: 'Valoare invalidă pentru acest câmp.' },
  '428C9': { status: 400, message: 'Acest câmp este calculat automat și nu poate fi trimis.' },
  // A number too large for its column and a string too long for it are
  // both bad input, not server faults. These were missing at first, and
  // the API answered 500 to a caller who sent 999999 for a SMALLINT --
  // found by the test that asserts "a category that does not exist is a
  // 400, not a 500", which is why that test says "not a 500" rather than
  // just checking for a rejection.
  '22003': { status: 400, message: 'Valoare numerică în afara intervalului permis.' },
  '22001': { status: 400, message: 'Text prea lung pentru acest câmp.' },
};

// Business-rule triggers RAISE EXCEPTION, which arrives as P0001. Those
// messages are written for a human -- "team 4 is at capacity (5 members,
// category max 5)" -- so they are passed through rather than replaced by
// something vaguer. The HINT, where the trigger sets one, explains what
// to do instead, and is worth just as much.
function translate(err) {
  if (err && err.code === 'P0001') {
    return { status: 409, message: err.message, hint: err.hint || undefined };
  }
  const known = err && SQLSTATE[err.code];
  if (known) {
    return { status: known.status, message: known.message, detail: err.detail || undefined };
  }
  return null;   // not a database error we recognise -- let it be a 500
}

async function query(text, params) {
  return pool.query(text, params);
}

// Several writes touch two tables that must agree -- creating a club is
// an account plus a clubs row, and enforce_subtype_role refuses the
// second if the first has the wrong role. Half of that pair committing
// would leave an account nobody can sign in to.
async function tx(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
}

module.exports = { pool, query, tx, translate };
