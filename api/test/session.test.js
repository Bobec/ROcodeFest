'use strict';
// =====================================================================
// Where sessions are kept
// =====================================================================
// express-session was using its default store, which keeps sessions in
// the memory of one process. Three consequences, none of them exotic:
//
//   * every restart signed everybody out -- so every deploy would
//   * two instances could not share a session, so a request landing on
//     the wrong one arrived as a stranger
//   * memory grew with the number of sessions and nothing pruned it
//
// The last one is invisible until it is not, and the first two are the
// reason this had to be fixed before a CD pipeline exists at all: a
// pipeline that restarts the process on every merge turns "everybody is
// signed out" from a development annoyance into something users see.
//
// A test cannot restart the process, so it proves the property that
// makes restarting survivable: the session is a ROW, identified by the
// same id the browser is holding. Anything that can read that table can
// resume the session, which is what a second instance -- or the same
// instance after a restart -- does.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => {
  await h.reset();
  await h.sql('DELETE FROM app.session');
});

// ---------------------------------------------------------------------
// The session is a row
// ---------------------------------------------------------------------
test('semnarea creeaza un rand in app.session, cu acelasi id ca al cookie-ului', async () => {
  const c = h.client();
  await c.registerClub('sesiune@test.ro', 'Clubul Sesiunii');

  const sid = c.sid();
  assert.ok(sid, 'clientul trebuie sa aiba un cookie de sesiune');

  const row = await h.sql('SELECT sid, sess, expire FROM app.session WHERE sid = $1', [sid]);
  assert.equal(row.rows.length, 1,
    'sesiunea trebuie sa fie in tabel, nu in memoria procesului');

  // And it is THIS person's session, not merely some row.
  const me = await c.get('/auth/me');
  assert.equal(String(row.rows[0].sess.accountId), String(me.body.account.id));
});

test('sesiunea are un termen de expirare in viitor', async () => {
  // Without it the sweep has nothing to go on and rows accumulate for
  // ever -- which is the third consequence of the memory store,
  // reproduced in a table.
  const c = h.client();
  await c.registerClub('expira@test.ro', 'Clubul Expirarii');

  const row = await h.sql('SELECT expire FROM app.session WHERE sid = $1', [c.sid()]);
  assert.equal(row.rows.length, 1);
  assert.ok(row.rows[0].expire > new Date(), 'expira trebuie sa fie in viitor');
});

test('iesirea sterge randul, nu doar cookie-ul', async () => {
  // Clearing the cookie alone would leave a usable session in the table
  // that anybody holding the old cookie could resume. That is precisely
  // finding S3 -- a session nothing could actually end -- in its new
  // form.
  const c = h.client();
  await c.registerClub('iesire@test.ro', 'Clubul Iesirii');
  const sid = c.sid();
  assert.equal((await h.sql('SELECT 1 FROM app.session WHERE sid = $1', [sid])).rows.length, 1);

  await c.post('/auth/logout');

  const after = await h.sql('SELECT 1 FROM app.session WHERE sid = $1', [sid]);
  assert.equal(after.rows.length, 0, 'randul trebuie sa dispara la iesire');
  assert.equal((await c.get('/auth/me')).body.account, null);
});

test('stergerea randului deconecteaza, ceea ce dovedeste ca el este sursa', async () => {
  // The control that makes the first test mean something. If the
  // session were still being served from memory, removing the row would
  // change nothing and the visitor would stay signed in.
  const c = h.client();
  await c.registerClub('sursa@test.ro', 'Clubul Sursei');
  assert.ok((await c.get('/auth/me')).body.account, 'conectat inainte');

  await h.sql('DELETE FROM app.session WHERE sid = $1', [c.sid()]);

  const after = await c.get('/auth/me');
  assert.equal(after.body.account, null,
    'daca ar fi ramas conectat, sesiunea ar veni din memorie, nu din tabel');
});

// ---------------------------------------------------------------------
// Two people, two rows
// ---------------------------------------------------------------------
test('doua sesiuni sunt doua randuri, si nu se amesteca', async () => {
  const a = h.client();
  const b = h.client();
  await a.registerClub('doua-a@test.ro', 'Clubul A');
  await b.registerClub('doua-b@test.ro', 'Clubul B');

  assert.notEqual(a.sid(), b.sid());
  const n = await h.sql('SELECT count(*)::int AS n FROM app.session');
  assert.equal(n.rows[0].n, 2);

  // Ending one leaves the other alone -- which is finding S4 asked of
  // the new arrangement: signing out of one account used to leave
  // another signed in, and the mirror of that fault would be signing
  // out of one ending everybody's session.
  await a.post('/auth/logout');
  assert.equal((await a.get('/auth/me')).body.account, null);
  assert.ok((await b.get('/auth/me')).body.account, 'celalalt ramane conectat');
  assert.equal((await h.sql('SELECT count(*)::int AS n FROM app.session')).rows[0].n, 1);
});

test('un vizitator care nu se conecteaza nu lasa niciun rand', async () => {
  // saveUninitialized is false, and this is what that setting buys: a
  // table that grows with sign-ins rather than with page views.
  const anon = h.client();
  await anon.get('/auth/me');
  await anon.get('/api/teams');
  await anon.get('/api/leaderboard');

  const n = await h.sql('SELECT count(*)::int AS n FROM app.session');
  assert.equal(n.rows[0].n, 0, 'navigarea fara autentificare nu creeaza sesiuni');
});

// ---------------------------------------------------------------------
// The table is where it belongs
// ---------------------------------------------------------------------
test('sesiunile nu sunt in schema domeniului', async () => {
  // oltp describes the competition, and 99_tests.sql holds an exact
  // manifest of every column in it -- a session table there would be
  // reported as schema drift, correctly. This asserts the placement so
  // that nobody later "fixes" the manifest instead.
  const wrong = await h.sql(
    `SELECT count(*)::int AS n FROM information_schema.tables
      WHERE table_schema = 'oltp' AND table_name IN ('session', 'schema_migrations')`
  );
  assert.equal(wrong.rows[0].n, 0);

  const right = await h.sql(
    `SELECT count(*)::int AS n FROM information_schema.tables
      WHERE table_schema = 'app' AND table_name IN ('session', 'schema_migrations')`
  );
  assert.equal(right.rows[0].n, 2);
});

test('migrarea care a creat tabelul este inregistrata', async () => {
  // A database whose app.session exists but whose bookkeeping does not
  // know why is one the migration runner would try to "fix" by creating
  // the table again.
  const r = await h.sql(
    `SELECT version FROM app.schema_migrations WHERE version = '0001_session_store'`
  );
  assert.equal(r.rows.length, 1,
    'db/00_app_schema.sql trebuie sa stampileze migrarea pe care o contine');
});
