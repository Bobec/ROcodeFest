'use strict';
// =====================================================================
// Join requests: asking, deciding, and who is allowed to decide
// =====================================================================
// This feature never worked. The request was written into the member's
// own browser and the club's page looked for it in the club's, so no
// club ever saw a request from anyone. Both halves existed and never
// met.
//
// Now that they do meet, the interesting questions are the ones that
// only appear once two people share state: can a club decide another
// club's requests, does accepting actually enrol anyone, and does a
// half-completed accept leave anything behind.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => { await h.reset(); });

async function club(email, name, code) {
  const c = h.client();
  await c.registerClub(email, name);
  const cats = (await c.get('/api/teams/categories')).body.categories;
  const t = await c.post('/api/teams', {
    teamName: 'Echipa ' + name, categoryId: cats[0].id, participationCode: code,
  });
  assert.equal(t.status, 201, JSON.stringify(t.body));
  return { c, team: t.body.team, category: cats[0] };
}

async function member(email, name) {
  const c = h.client();
  const acc = await c.register('member', email, { fullName: name, city: 'Iași' });
  return { c, acc };
}

// ---------------------------------------------------------------------
// The positive control
// ---------------------------------------------------------------------
test('un membru cere sa intre, clubul vede cererea si o accepta', async () => {
  const A = await club('clubA@test.ro', 'A', 'JR-A');
  const M = await member('m1@test.ro', 'Maria');

  const asked = await M.c.post('/api/join-requests', { teamId: A.team.id, message: 'Vreau la robotică.' });
  assert.equal(asked.status, 201, JSON.stringify(asked.body));
  assert.equal(asked.body.request.status, 'pending');

  // The half that never happened before: the club can see it.
  const inbox = await A.c.get('/api/join-requests/incoming');
  assert.equal(inbox.status, 200);
  assert.equal(inbox.body.requests.length, 1);
  assert.equal(inbox.body.requests[0].memberName, 'Maria');
  assert.equal(inbox.body.requests[0].message, 'Vreau la robotică.');

  const ok = await A.c.post('/api/join-requests/' + asked.body.request.id + '/accept');
  assert.equal(ok.status, 200, JSON.stringify(ok.body));

  // Accepting has to mean enrolled, not merely marked accepted.
  const mine = await M.c.get('/api/teams/mine');
  assert.equal(mine.body.teams.length, 1);
  assert.equal(mine.body.teams[0].id, A.team.id);

  // And the membership records which request produced it -- that is
  // what fk_memberships_source_request_matches is for.
  const link = await h.sql(
    `SELECT source_request_id FROM oltp.memberships WHERE team_id = $1 AND member_id = $2`,
    [A.team.id, M.acc.id]
  );
  assert.equal(String(link.rows[0].source_request_id), String(asked.body.request.id));
});

test('o cerere respinsa nu inscrie pe nimeni', async () => {
  const A = await club('clubR@test.ro', 'R', 'JR-R');
  const M = await member('m2@test.ro', 'Radu');

  const asked = await M.c.post('/api/join-requests', { teamId: A.team.id });
  const no = await A.c.post('/api/join-requests/' + asked.body.request.id + '/reject');
  assert.equal(no.status, 200);

  assert.deepEqual((await M.c.get('/api/teams/mine')).body.teams, []);
  const rows = await h.sql('SELECT count(*)::int AS n FROM oltp.memberships WHERE member_id = $1', [M.acc.id]);
  assert.equal(rows.rows[0].n, 0);
});

// ---------------------------------------------------------------------
// Authorisation -- the part the database cannot express
// ---------------------------------------------------------------------
test('un club nu poate decide cererile altui club', async () => {
  const A = await club('own1@test.ro', 'Unu', 'JR-1');
  const B = await club('own2@test.ro', 'Doi', 'JR-2');
  const M = await member('m3@test.ro', 'Ioana');

  const asked = await M.c.post('/api/join-requests', { teamId: A.team.id });
  const id = asked.body.request.id;

  // B knows the id -- ids are sequential and appear in URLs. Knowing it
  // must not be enough.
  const stolen = await B.c.post('/api/join-requests/' + id + '/accept');
  assert.equal(stolen.status, 404,
    'clubul B nu are voie sa decida, si nu are voie nici sa afle ca cererea exista');

  // Nothing happened as a side effect of trying.
  const still = await h.sql('SELECT status FROM oltp.join_requests WHERE request_id = $1', [id]);
  assert.equal(still.rows[0].status, 'pending');
  assert.deepEqual((await M.c.get('/api/teams/mine')).body.teams, []);
});

test('un club vede doar cererile pentru echipele lui', async () => {
  const A = await club('inbox1@test.ro', 'Prima', 'JR-P1');
  const B = await club('inbox2@test.ro', 'ADoua', 'JR-P2');
  const M = await member('m4@test.ro', 'Vlad');

  await M.c.post('/api/join-requests', { teamId: A.team.id });

  assert.equal((await A.c.get('/api/join-requests/incoming')).body.requests.length, 1);
  assert.deepEqual((await B.c.get('/api/join-requests/incoming')).body.requests, [],
    'clubul B nu are cereri, si nu vede cererea clubului A');
});

test('un membru nu poate decide cereri, nici pe ale lui', async () => {
  const A = await club('dec@test.ro', 'Dec', 'JR-D');
  const M = await member('m5@test.ro', 'Ana');

  const asked = await M.c.post('/api/join-requests', { teamId: A.team.id });
  const self = await M.c.post('/api/join-requests/' + asked.body.request.id + '/accept');
  assert.equal(self.status, 403, 'altfel oricine s-ar inscrie singur in orice echipa');
});

test('un club nu poate cere sa intre intr-o echipa', async () => {
  const A = await club('cer@test.ro', 'Cer', 'JR-C');
  const B = await club('cer2@test.ro', 'Cer2', 'JR-C2');
  assert.equal((await B.c.post('/api/join-requests', { teamId: A.team.id })).status, 403);
});

test('nesemnat nu poate cere si nu poate vedea nimic', async () => {
  const A = await club('anon@test.ro', 'Anon', 'JR-AN');
  const anon = h.client();
  assert.equal((await anon.post('/api/join-requests', { teamId: A.team.id })).status, 401);
  assert.equal((await anon.get('/api/join-requests/mine')).status, 401);
  assert.equal((await anon.get('/api/join-requests/incoming')).status, 401);
});

// ---------------------------------------------------------------------
// The rules the schema already holds
// ---------------------------------------------------------------------
test('a doua cerere in asteptare pentru aceeasi echipa este refuzata cu 409', async () => {
  const A = await club('dublu@test.ro', 'Dublu', 'JR-DB');
  const M = await member('m6@test.ro', 'Dan');

  assert.equal((await M.c.post('/api/join-requests', { teamId: A.team.id })).status, 201);
  const again = await M.c.post('/api/join-requests', { teamId: A.team.id });
  assert.equal(again.status, 409, 'uq_join_requests_pending, adus ca un conflict');
  assert.match(again.body.error, /așteptare/i);
});

test('dupa un refuz se poate cere din nou', async () => {
  // uq_join_requests_pending is a PARTIAL index, on pending rows only.
  // A test that only proved the second request fails would pass just as
  // well against an index over the whole table, which would make a
  // rejection permanent.
  const A = await club('iar@test.ro', 'Iar', 'JR-IR');
  const M = await member('m7@test.ro', 'Elena');

  const first = await M.c.post('/api/join-requests', { teamId: A.team.id });
  await A.c.post('/api/join-requests/' + first.body.request.id + '/reject');

  const second = await M.c.post('/api/join-requests', { teamId: A.team.id });
  assert.equal(second.status, 201, 'un refuz nu este o interdicție pe viață');
});

test('o cerere deja decisa nu poate fi decisa din nou', async () => {
  const A = await club('deja@test.ro', 'Deja', 'JR-DJ');
  const M = await member('m8@test.ro', 'Mihai');

  const asked = await M.c.post('/api/join-requests', { teamId: A.team.id });
  const id = asked.body.request.id;
  assert.equal((await A.c.post('/api/join-requests/' + id + '/accept')).status, 200);

  const twice = await A.c.post('/api/join-requests/' + id + '/reject');
  assert.equal(twice.status, 409, JSON.stringify(twice.body));

  // The important part: the second call changed nothing.
  const st = await h.sql('SELECT status FROM oltp.join_requests WHERE request_id = $1', [id]);
  assert.equal(st.rows[0].status, 'accepted');
  assert.equal((await M.c.get('/api/teams/mine')).body.teams.length, 1);
});

test('cand echipa e plina, acceptarea esueaza SI cererea ramane in asteptare', async () => {
  // The whole reason accept is one transaction. A request marked
  // accepted with no membership behind it is a person told yes who
  // belongs to nothing, and nothing in the schema would ever repair it.
  const A = await club('plin@test.ro', 'Plin', 'JR-PL');
  const max = A.category.maxMembers;
  assert.ok(max > 0, 'categoria trebuie sa aiba o limita, altfel testul nu demonstreaza nimic');

  // Fill the team to its category limit.
  for (let i = 0; i < max; i++) {
    const f = await member(`umple${i}@test.ro`, `Umplutura ${i}`);
    await h.sql(
      'INSERT INTO oltp.memberships (team_id, member_id) VALUES ($1, $2)',
      [A.team.id, f.acc.id]
    );
  }

  const M = await member('ultimul@test.ro', 'Ultimul');
  const asked = await M.c.post('/api/join-requests', { teamId: A.team.id });
  const id = asked.body.request.id;

  const full = await A.c.post('/api/join-requests/' + id + '/accept');
  assert.notEqual(full.status, 200, 'echipa este plina, deci acceptarea nu are voie sa reuseasca');

  const st = await h.sql('SELECT status, decided_at FROM oltp.join_requests WHERE request_id = $1', [id]);
  assert.equal(st.rows[0].status, 'pending',
    'tranzactia trebuie sa dea inapoi si marcarea cererii, nu doar inscrierea');
  assert.equal(st.rows[0].decided_at, null);
  assert.deepEqual((await M.c.get('/api/teams/mine')).body.teams, []);
});

test('o cerere catre o echipa inexistenta este 400, nu 500', async () => {
  const M = await member('m9@test.ro', 'Sorin');
  const r = await M.c.post('/api/join-requests', { teamId: 999999999 });
  assert.equal(r.status, 400, JSON.stringify(r.body));
});

test('o cerere fara echipa este refuzata inainte de baza', async () => {
  const M = await member('m10@test.ro', 'Carmen');
  assert.equal((await M.c.post('/api/join-requests', {})).status, 400);
});

// ---------------------------------------------------------------------
// What the member sees
// ---------------------------------------------------------------------
test('un membru isi vede propriile cereri, cu numele echipei si al clubului', async () => {
  const A = await club('vad@test.ro', 'Vad', 'JR-V');
  const M = await member('m11@test.ro', 'Andrei');
  const other = await member('altul@test.ro', 'Altul');

  await M.c.post('/api/join-requests', { teamId: A.team.id });
  await other.c.post('/api/join-requests', { teamId: A.team.id });

  const mine = await M.c.get('/api/join-requests/mine');
  assert.equal(mine.body.requests.length, 1, 'doar ale mele, nu si ale altui membru');
  const r = mine.body.requests[0];
  assert.equal(r.teamName, 'Echipa Vad');
  assert.equal(r.clubName, 'Vad');
  assert.equal(r.status, 'pending');
});
