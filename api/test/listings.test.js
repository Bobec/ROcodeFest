'use strict';
// =====================================================================
// The listings the pages render: /api/clubs, /api/teams, /api/stats
// =====================================================================
// These replaced localStorage arrays, and the pages read them by FIELD
// NAME. That makes the field names part of the contract, not an
// implementation detail: renaming "clubName" to "club_name" in a query
// would break eight pages, every one of them silently -- undefined
// renders as the word "undefined" or as nothing at all, and no test
// that only counts rows would notice.
//
// So each shape is asserted as an exact key set. A test that checked
// only the keys it cares about would pass just as happily after a
// rename that added the new name beside the old one.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => { await h.reset(); });

// Set up one club with one team. Written as a helper because every test
// below needs a non-empty listing: a shape assertion over zero rows
// asserts nothing at all, which is the vacuity trap the SQL suites
// guard against.
// participation_code is unique across the whole festival, so it is
// derived from the email rather than fixed: two clubs in one test would
// otherwise collide on it, and the failure would look like a bug in the
// endpoint rather than in the fixture.
async function oneClubOneTeam(c, email = 'listari@test.ro', clubName = 'Clubul Listat') {
  await c.registerClub(email, clubName);
  await c.patch('/api/clubs/me', { city: 'Cluj-Napoca', coachName: 'Antrenorul' });
  const cats = (await c.get('/api/teams/categories')).body.categories;
  const t = await c.post('/api/teams', {
    teamName: 'Echipa Unu',
    categoryId: cats[0].id,
    participationCode: 'L-' + email.split('@')[0],
  });
  assert.equal(t.status, 201, JSON.stringify(t.body));
  return { team: t.body.team, category: cats[0] };
}

// ---------------------------------------------------------------------
// GET /api/clubs
// ---------------------------------------------------------------------
test('/api/clubs raspunde cu exact campurile pe care le citesc paginile', async () => {
  const c = h.client();
  await oneClubOneTeam(c);

  const r = await c.get('/api/clubs');
  assert.equal(r.status, 200);
  assert.equal(r.body.clubs.length, 1, 'fara un rand, forma nu se poate verifica');

  const club = r.body.clubs[0];
  assert.deepEqual(
    Object.keys(club).sort(),
    ['avatar', 'city', 'clubName', 'coachName', 'id', 'number', 'teamCount'].sort()
  );
  assert.equal(club.clubName, 'Clubul Listat');
  assert.equal(club.city, 'Cluj-Napoca');
  assert.equal(club.teamCount, 1);
  assert.equal(typeof club.teamCount, 'number',
    'count() intoarce bigint, pe care pg il da ca sir -- ::int, ' +
    'altfel o pagina care compara cu 0 se poarta ciudat');
});

test('/api/clubs nu da emailul si notele nimanui', async () => {
  const c = h.client();
  await oneClubOneTeam(c);
  await c.patch('/api/clubs/me', { notes: 'ceva intern' });

  const club = (await c.get('/api/clubs')).body.clubs[0];
  assert.equal(club.email, undefined, 'lista publica nu are voie cu emailuri');
  assert.equal(club.notes, undefined);
});

// ---------------------------------------------------------------------
// GET /api/teams
// ---------------------------------------------------------------------
test('/api/teams aduce clubul cu fiecare echipa, ca sa nu mai uneasca browserul', async () => {
  const c = h.client();
  await oneClubOneTeam(c);

  const r = await c.get('/api/teams');
  assert.equal(r.status, 200);
  assert.equal(r.body.teams.length, 1);

  const t = r.body.teams[0];
  assert.deepEqual(
    Object.keys(t).sort(),
    ['category', 'categoryLabel', 'clubCity', 'clubId', 'clubName', 'clubNumber',
     'id', 'isActive', 'maxMembers', 'memberCount', 'participationCode', 'teamName'].sort()
  );

  // The pages used to do this join themselves, matching club_name
  // against club_name across two localStorage arrays. The city and the
  // club's number arriving with the team is what let that go.
  assert.equal(t.clubName, 'Clubul Listat');
  assert.equal(t.clubCity, 'Cluj-Napoca');
  assert.equal(typeof t.clubNumber, 'number');
  assert.equal(t.memberCount, 0);
});

test('id-urile vin ca siruri, si paginile trebuie sa le compare ca siruri', async () => {
  // team_id and account_id are BIGINT. node-postgres returns bigint as a
  // string on purpose: a JavaScript number cannot hold one exactly past
  // 2^53, so parsing it would silently corrupt large ids rather than
  // fail. It looks like an inconsistency next to clubNumber, which is a
  // plain integer column and does come back as a number.
  //
  // This is asserted so that nobody "fixes" it into a number, and so
  // that organizations.html comparing t.clubId === club.id keeps
  // comparing two strings. Turning one side into a number would make
  // that === silently false and every club would show no teams.
  const c = h.client();
  await oneClubOneTeam(c, 'iduri@test.ro', 'Clubul Id');

  const club = (await c.get('/api/clubs')).body.clubs[0];
  const team = (await c.get('/api/teams')).body.teams[0];

  assert.equal(typeof club.id, 'string', 'account_id este BIGINT');
  assert.equal(typeof team.id, 'string', 'team_id este BIGINT');
  assert.equal(typeof team.clubId, 'string');
  assert.equal(team.clubId, club.id, 'compararea pe care o face organizations.html');

  assert.equal(typeof club.number, 'number', 'founding_number este integer');
  assert.equal(typeof team.clubNumber, 'number');
});

test('/api/teams este public: un vizitator nesemnat vede lista', async () => {
  const owner = h.client();
  await oneClubOneTeam(owner);

  // founding-teams.html and organizations.html are open pages. If this
  // needed a session they would be empty for exactly the people they
  // exist for.
  const visitor = h.client();
  const r = await visitor.get('/api/teams');
  assert.equal(r.status, 200);
  assert.equal(r.body.teams.length, 1);
});

// ---------------------------------------------------------------------
// GET /api/teams/mine -- one endpoint, two meanings
// ---------------------------------------------------------------------
test('pentru un club, /mine sunt echipele pe care le detine', async () => {
  const a = h.client();
  const b = h.client();
  await oneClubOneTeam(a, 'a@test.ro', 'Clubul A');
  await oneClubOneTeam(b, 'b@test.ro', 'Clubul B');

  assert.equal((await a.get('/api/teams/mine')).body.teams.length, 1);
  assert.equal((await b.get('/api/teams/mine')).body.teams.length, 1);
  assert.equal((await a.get('/api/teams/mine')).body.teams[0].clubName, 'Clubul A');
});

test('pentru un membru, /mine sunt echipele in care este ACUM', async () => {
  const club = h.client();
  const { team } = await oneClubOneTeam(club, 'club@test.ro', 'Clubul Gazda');

  const member = h.client();
  const acc = await member.register('member', 'membru@test.ro', { fullName: 'Un Membru' });

  // No endpoint creates a membership yet -- that is the join-request
  // flow, still to be built. The row is set up directly because what is
  // being tested is the ANSWER, not the route that would write it.
  await h.sql(
    `INSERT INTO oltp.memberships (team_id, member_id, joined_at)
     VALUES ($1, $2, now())`,
    [team.id, acc.id]
  );

  const mine = await member.get('/api/teams/mine');
  assert.equal(mine.status, 200);
  assert.equal(mine.body.teams.length, 1);
  assert.equal(mine.body.teams[0].teamName, 'Echipa Unu');
});

test('un membru care a plecat dintr-o echipa nu o mai are in /mine', async () => {
  // This is the whole reason the endpoint reads memberships rather than
  // accepted join requests. The page used to keep every request whose
  // status said "accepted", and a request stays accepted forever -- so
  // a member removed from a team could still choose it in the
  // submissions dropdown.
  const club = h.client();
  const { team } = await oneClubOneTeam(club, 'club2@test.ro', 'Clubul Doi');

  const member = h.client();
  const acc = await member.register('member', 'plecat@test.ro', { fullName: 'A Plecat' });

  await h.sql(
    `INSERT INTO oltp.memberships (team_id, member_id, joined_at, left_at)
     VALUES ($1, $2, now() - interval '10 days', now() - interval '1 day')`,
    [team.id, acc.id]
  );

  const mine = await member.get('/api/teams/mine');
  assert.equal(mine.status, 200);
  assert.equal(mine.body.teams.length, 0,
    'left_at este pus, deci apartenenta s-a incheiat');
});

test('un membru fara echipa primeste o lista goala, nu o eroare', async () => {
  const member = h.client();
  await member.register('member', 'singur@test.ro', { fullName: 'Fara Echipa' });

  const mine = await member.get('/api/teams/mine');
  assert.equal(mine.status, 200);
  assert.deepEqual(mine.body.teams, []);
});

test('un partener nu are echipe, si primeste 403 nu o lista goala', async () => {
  // A 200 with [] would say "you have no teams". The truthful answer is
  // that the question does not apply to a partner, and a page can tell
  // the two apart.
  const p = h.client();
  await p.register('partner', 'partener@test.ro', { contactName: 'Contact', partnerType: 'sponsor' });

  assert.equal((await p.get('/api/teams/mine')).status, 403);
});

// ---------------------------------------------------------------------
// GET /api/stats
// ---------------------------------------------------------------------
test('/api/stats numara festivalul, nu browserul', async () => {
  const c = h.client();
  await oneClubOneTeam(c, 'stats@test.ro', 'Clubul Numarat');
  const m = h.client();
  await m.register('member', 'm@test.ro', { fullName: 'Membru' });

  // Asked by someone signed out: the partner dashboard and the landing
  // page both show these numbers to visitors.
  const visitor = h.client();
  const r = await visitor.get('/api/stats');
  assert.equal(r.status, 200);
  assert.deepEqual(
    Object.keys(r.body.stats).sort(),
    ['clubs', 'members', 'partners', 'submissions', 'teams'].sort()
  );
  assert.equal(r.body.stats.clubs, 1);
  assert.equal(r.body.stats.teams, 1);
  assert.equal(r.body.stats.members, 1);
  assert.equal(r.body.stats.submissions, 0);
  assert.equal(typeof r.body.stats.clubs, 'number', 'count() ca numar, nu ca sir');
});

test('/api/stats numara doar echipele active', async () => {
  const c = h.client();
  const { team } = await oneClubOneTeam(c, 'inactiv@test.ro', 'Clubul Inactiv');
  assert.equal((await c.get('/api/stats')).body.stats.teams, 1);

  await h.sql('UPDATE oltp.teams SET is_active = FALSE WHERE team_id = $1', [team.id]);
  assert.equal((await c.get('/api/stats')).body.stats.teams, 0,
    'o echipa retrasa nu mai face parte din cifra pe care o vede un partener');
});
