'use strict';
// =====================================================================
// Authorization, and where the rules live
// =====================================================================
// Two questions, and they are not the same one.
//
// AUTHORIZATION is what the database cannot do for itself. Every
// constraint it has answers "is this row valid" -- none of them can
// answer "is this row YOURS", because the database is not told who is
// asking. That gap is recorded as T5, and it is closed here or nowhere.
//
// WHERE THE RULES LIVE is the other half. Team capacity, unique
// participation codes, the category FK: all of it stays in the schema,
// with 581 test cases behind it. The tests below assert that the API
// SURFACES those refusals rather than re-implementing them -- because a
// second copy of a rule is a rule that will eventually disagree with
// itself.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { start, stop, reset, client } = require('./helper');

before(start);
after(stop);
beforeEach(reset);

async function twoClubs() {
  const a = client(), b = client();
  await a.registerClub('clubul-a@test.ro', 'Clubul A');
  await b.registerClub('clubul-b@test.ro', 'Clubul B');
  return { a, b };
}
async function firstCategory(c) {
  const r = await c.get('/api/teams/categories');
  assert.equal(r.status, 200);
  assert.ok(r.body.categories.length > 0, 'the categories come from the table, not a constant');
  return r.body.categories[0];
}

// ---------------------------------------------------------------------
// Nobody signed in
// ---------------------------------------------------------------------
test('protected routes refuse an anonymous caller', async () => {
  const c = client();
  assert.equal((await c.get('/api/clubs/me')).status, 401);
  assert.equal((await c.get('/api/teams/mine')).status, 401);
  assert.equal((await c.post('/api/teams', { teamName: 'X', categoryId: 1, participationCode: 'X-1' })).status, 401);
  assert.equal((await c.patch('/api/clubs/me', { city: 'Cluj' })).status, 401);
});

test('the public routes stay public', async () => {
  // The control for the four refusals above. If everything 401'd, they
  // would pass while proving only that the server is broken.
  const c = client();
  assert.equal((await c.get('/api/clubs')).status, 200);
  assert.equal((await c.get('/api/teams')).status, 200);
  assert.equal((await c.get('/api/teams/categories')).status, 200);
  assert.equal((await c.get('/auth/me')).status, 200);
});

// ---------------------------------------------------------------------
// One club cannot reach another
// ---------------------------------------------------------------------
test('a club sees only its own teams', async () => {
  const { a, b } = await twoClubs();
  const cat = await firstCategory(a);

  await a.post('/api/teams', { teamName: 'Alpha', categoryId: cat.id, participationCode: 'A-1' });

  const mineA = await a.get('/api/teams/mine');
  const mineB = await b.get('/api/teams/mine');
  assert.equal(mineA.body.teams.length, 1, 'the owner sees it');
  assert.equal(mineB.body.teams.length, 0, 'the other club does not');
});

test('a team is created under the caller, not under whoever the body names', async () => {
  // This is the whole of T5 in one assertion. The database checks that
  // the club EXISTS; it has no way to check that it is yours. If club_id
  // were read from the request, club B could file teams under club A.
  const { a, b } = await twoClubs();
  const cat = await firstCategory(a);
  const clubA = (await a.get('/api/clubs/me')).body.club.id;

  const r = await b.post('/api/teams', {
    teamName: 'Furata', categoryId: cat.id, participationCode: 'F-1',
    club_id: clubA, clubId: clubA,        // both spellings, deliberately
  });
  assert.equal(r.status, 201, 'the team is created -- for B');

  const mineA = await a.get('/api/teams/mine');
  assert.equal(mineA.body.teams.length, 0,
    'club A must own nothing it did not create, whatever the body said');
  const mineB = await b.get('/api/teams/mine');
  assert.equal(mineB.body.teams.length, 1, 'and the team belongs to the caller');
});

test('editing a profile touches only the caller', async () => {
  const { a, b } = await twoClubs();
  await b.patch('/api/clubs/me', { city: 'Iasi' });

  const clubA = (await a.get('/api/clubs/me')).body.club;
  assert.notEqual(clubA.city, 'Iasi', "club B's edit did not reach club A");
});

test('the public directory returns no email and no notes', async () => {
  // A SELECT * would have leaked both, and nothing about the page that
  // renders this list would have looked wrong.
  const c = client();
  await c.registerClub('privat@test.ro', 'Club Privat');
  await c.patch('/api/clubs/me', { notes: 'note interne care nu se publica' });

  const pub = await client().get('/api/clubs');
  const raw = JSON.stringify(pub.body);
  assert.ok(raw.includes('Club Privat'), 'the club IS listed -- otherwise this proves nothing');
  assert.ok(!raw.includes('privat@test.ro'), 'no email');
  assert.ok(!raw.includes('note interne'), 'no notes');
});

// ---------------------------------------------------------------------
// The rules stay in the database
// ---------------------------------------------------------------------
test('a duplicate participation code is refused, by the schema', async () => {
  const { a, b } = await twoClubs();
  const cat = await firstCategory(a);

  const ok = await a.post('/api/teams', { teamName: 'Prima', categoryId: cat.id, participationCode: 'DUP-1' });
  assert.equal(ok.status, 201);

  // a DIFFERENT club, so this is the code colliding and nothing else
  const clash = await b.post('/api/teams', { teamName: 'A Doua', categoryId: cat.id, participationCode: 'DUP-1' });
  assert.equal(clash.status, 409, 'uq_teams_participation_code, surfaced as a conflict');
  assert.match(clash.body.error, /cod/i, 'and the message says which field');
});

test('two teams in one club cannot share a name', async () => {
  const { a } = await twoClubs();
  const cat = await firstCategory(a);

  assert.equal((await a.post('/api/teams', { teamName: 'Acelasi', categoryId: cat.id, participationCode: 'N-1' })).status, 201);
  const r = await a.post('/api/teams', { teamName: 'Acelasi', categoryId: cat.id, participationCode: 'N-2' });
  assert.equal(r.status, 409);
});

test('the same team name IS allowed in a different club', async () => {
  // The control for the test above: uq_teams_club_name is scoped to the
  // club, and a check that refused the name globally would pass that
  // test and be wrong.
  const { a, b } = await twoClubs();
  const cat = await firstCategory(a);

  assert.equal((await a.post('/api/teams', { teamName: 'Vulturii', categoryId: cat.id, participationCode: 'V-1' })).status, 201);
  assert.equal((await b.post('/api/teams', { teamName: 'Vulturii', categoryId: cat.id, participationCode: 'V-2' })).status, 201);
});

test('a category that does not exist is a 400, not a 500', async () => {
  const { a } = await twoClubs();
  const r = await a.post('/api/teams', { teamName: 'Fara', categoryId: 999999, participationCode: 'Z-1' });
  assert.equal(r.status, 400, 'the foreign key becomes a bad request');
});

test('the categories are read from the table, not compiled in', async () => {
  // The same property the forum MIME allowlist was tested for: a list
  // baked into the code passes every test except the one that changes
  // the table and watches the answer follow.
  const c = client();
  const before = (await c.get('/api/teams/categories')).body.categories.length;

  const { pool } = require('../db');
  await pool.query(
    `INSERT INTO oltp.team_categories (code, label, max_members) VALUES ('TESTCAT','Test Category',4)`
  );
  try {
    const after = (await c.get('/api/teams/categories')).body.categories;
    assert.equal(after.length, before + 1, 'the new row appears without a code change');
    assert.ok(after.some((x) => x.code === 'TESTCAT'));
  } finally {
    await pool.query(`DELETE FROM oltp.team_categories WHERE code = 'TESTCAT'`);
  }
});

test('a missing field is refused before the database is asked', async () => {
  const { a } = await twoClubs();
  const cat = await firstCategory(a);
  const r = await a.post('/api/teams', { teamName: 'Fara cod', categoryId: cat.id });
  assert.equal(r.status, 400);

  const ok = await a.post('/api/teams', { teamName: 'Fara cod', categoryId: cat.id, participationCode: 'OK-1' });
  assert.equal(ok.status, 201, 'the control: the complete request works');
});

test('an unknown API path is a 404 with JSON, not an HTML page', async () => {
  // /api is mounted after the static files, so a typo must not fall
  // through and return index.html with a 200 -- which a fetch() caller
  // would then try to parse as JSON.
  const c = client();
  const r = await c.get('/api/nu-exista');
  assert.equal(r.status, 404);
  assert.ok(r.body && r.body.error, 'and it says so in the shape callers expect');
});
