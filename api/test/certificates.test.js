'use strict';
// =====================================================================
// Certificates
// =====================================================================
// certificates.html drew its canvas from MOCK_CERT: a team called Aqua
// Bot, a club called Acme Robotics, and three participants named Alex,
// Sam and Taylor. None of them exist. The design of that canvas is
// unchanged -- what these tests cover is where the names come from.
//
// Nothing here issues a certificate to a team automatically. Issuing is
// an organiser act tied to finalised results, so the interesting case
// is the one in between: signed in, nothing issued yet, and the page
// still has to show something true.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');
const auth = require('../auth');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => {
  await h.reset();
  await h.sql('TRUNCATE oltp.seasons CASCADE');
});

async function organizer(email = 'orgc@test.ro') {
  const c = h.client();
  await h.sql(
    `WITH a AS (
       INSERT INTO oltp.accounts (email, password_hash, role)
       VALUES ($1, $2, 'organizer') RETURNING account_id
     )
     INSERT INTO oltp.organizers (account_id, full_name)
     SELECT account_id, 'Organizatorul' FROM a`,
    [email, await auth.hash('parola-de-test-1')]
  );
  await c.post('/auth/login', { email, password: 'parola-de-test-1' });
  return c;
}

async function arena() {
  const s = await h.sql(
    `INSERT INTO oltp.seasons (name, start_date, is_active)
     VALUES ('Sezonul Diplomelor', CURRENT_DATE, TRUE) RETURNING season_id`);
  const seasonId = String(s.rows[0].season_id);

  const club = h.client();
  await club.registerClub('cclub@test.ro', 'Clubul Diplomei');
  await club.patch('/api/clubs/me', { city: 'Piatra Neamț' });
  const cats = (await club.get('/api/teams/categories')).body.categories;
  const team = (await club.post('/api/teams', {
    teamName: 'Vulturii', categoryId: cats[0].id, participationCode: 'CERT-1',
  })).body.team;

  // Two real members on the team -- these are the names the canvas
  // should carry instead of Alex, Sam and Taylor.
  const names = ['Ana Popescu', 'Bogdan Ilie'];
  const members = [];
  for (let i = 0; i < names.length; i++) {
    const c = h.client();
    const acc = await c.register('member', `cm${i}@test.ro`, { fullName: names[i] });
    await h.sql('INSERT INTO oltp.memberships (team_id, member_id) VALUES ($1, $2)', [team.id, acc.id]);
    members.push({ c, acc });
  }
  return { seasonId, club, team, members, names };
}

// ---------------------------------------------------------------------
// The preview: real names, before anything is issued
// ---------------------------------------------------------------------
test('inainte de emitere, previzualizarea poarta echipa si colegii reali', async () => {
  const a = await arena();
  const r = await a.club.get('/api/certificates');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.certificates, [], 'nimic emis inca');

  const p = r.body.preview;
  assert.ok(p, 'previzualizarea exista pentru cineva conectat');
  assert.equal(p.teamName, 'Vulturii');
  assert.equal(p.clubName, 'Clubul Diplomei');
  assert.equal(p.seasonName, 'Sezonul Diplomelor');
  assert.deepEqual(p.participants, a.names,
    'numele reale de pe echipa, nu Alex, Sam si Taylor');
});

test('un membru vede previzualizarea echipei din care face parte', async () => {
  const a = await arena();
  const p = (await a.members[0].c.get('/api/certificates')).body.preview;
  assert.ok(p);
  assert.equal(p.teamName, 'Vulturii');
  assert.deepEqual(p.participants, a.names);
});

test('un membru fara echipa nu primeste nicio previzualizare', async () => {
  // Better than a preview naming somebody else's team: there is nothing
  // truthful to draw, and the page says to sign in to a team instead.
  const c = h.client();
  await c.register('member', 'singurc@test.ro', { fullName: 'Fără Echipă' });
  const r = await c.get('/api/certificates');
  assert.equal(r.status, 200);
  assert.equal(r.body.preview, null);
  assert.deepEqual(r.body.certificates, []);
});

test('nesemnat nu primeste nimic', async () => {
  const anon = h.client();
  assert.equal((await anon.get('/api/certificates')).status, 401);
});

// ---------------------------------------------------------------------
// Issued certificates
// ---------------------------------------------------------------------
test('un certificat emis pe echipa ajunge la club si la fiecare membru', async () => {
  // member_id NULL means the certificate belongs to the team, so it
  // belongs to everyone currently on it.
  const a = await arena();
  const O = await organizer();
  const issued = await O.post('/api/certificates', {
    teamId: a.team.id, seasonId: a.seasonId, serialCode: 'RCFEST-2026-000001',
  });
  assert.equal(issued.status, 201, JSON.stringify(issued.body));

  const clubSees = (await a.club.get('/api/certificates')).body.certificates;
  assert.equal(clubSees.length, 1);
  assert.equal(clubSees[0].serialCode, 'RCFEST-2026-000001');
  assert.equal(clubSees[0].teamName, 'Vulturii');
  assert.equal(clubSees[0].memberName, null, 'certificat de echipa, nu personal');

  for (const m of a.members) {
    const mine = (await m.c.get('/api/certificates')).body.certificates;
    assert.equal(mine.length, 1, 'fiecare membru al echipei il vede');
  }
});

test('un certificat personal ajunge doar la persoana lui', async () => {
  const a = await arena();
  const O = await organizer();
  await O.post('/api/certificates', {
    teamId: a.team.id, memberId: a.members[0].acc.id,
    seasonId: a.seasonId, serialCode: 'RCFEST-2026-000002',
  });

  const first = (await a.members[0].c.get('/api/certificates')).body.certificates;
  assert.equal(first.length, 1);
  assert.equal(first[0].memberName, 'Ana Popescu');

  const second = (await a.members[1].c.get('/api/certificates')).body.certificates;
  assert.deepEqual(second, [], 'certificatul altcuiva nu este al tau');
});

test('un membru care a plecat nu mai vede certificatul de echipa', async () => {
  // The team certificate belongs to whoever is on the team. A personal
  // one would not be affected, which is the difference between the two.
  const a = await arena();
  const O = await organizer();
  await O.post('/api/certificates', {
    teamId: a.team.id, seasonId: a.seasonId, serialCode: 'RCFEST-2026-000003',
  });
  assert.equal((await a.members[0].c.get('/api/certificates')).body.certificates.length, 1);

  await h.sql('UPDATE oltp.memberships SET left_at = now() WHERE member_id = $1', [a.members[0].acc.id]);
  assert.deepEqual((await a.members[0].c.get('/api/certificates')).body.certificates, []);
  assert.equal((await a.members[1].c.get('/api/certificates')).body.certificates.length, 1,
    'colegul ramas il vede in continuare');
});

// ---------------------------------------------------------------------
// Issuing
// ---------------------------------------------------------------------
test('doar organizatorii emit certificate', async () => {
  const a = await arena();
  const r = await a.club.post('/api/certificates', {
    teamId: a.team.id, seasonId: a.seasonId, serialCode: 'RCFEST-X',
  });
  assert.equal(r.status, 403, 'altfel un club si-ar emite singur diplome');
});

test('codul de serie este unic', async () => {
  // It is the verifiable public id -- two certificates with one code
  // make verification meaningless.
  const a = await arena();
  const O = await organizer();
  const body = { teamId: a.team.id, seasonId: a.seasonId, serialCode: 'RCFEST-DUP' };
  assert.equal((await O.post('/api/certificates', body)).status, 201);

  const again = await O.post('/api/certificates', body);
  assert.equal(again.status, 409, JSON.stringify(again.body));
  assert.match(again.body.error, /serie/i);
});

test('un tip de certificat inventat este 400, nu 500', async () => {
  const a = await arena();
  const O = await organizer();
  const r = await O.post('/api/certificates', {
    teamId: a.team.id, seasonId: a.seasonId, serialCode: 'RCFEST-T', type: 'inventat',
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
});

test('echipa, sezonul si codul sunt obligatorii', async () => {
  const a = await arena();
  const O = await organizer();
  assert.equal((await O.post('/api/certificates', { seasonId: a.seasonId, serialCode: 'X' })).status, 400);
  assert.equal((await O.post('/api/certificates', { teamId: a.team.id, serialCode: 'X' })).status, 400);
  assert.equal((await O.post('/api/certificates', { teamId: a.team.id, seasonId: a.seasonId })).status, 400);
});

test('un arbitru sau un partener primeste o lista goala, nu o eroare', async () => {
  // The question does not apply to them, and an empty list says that
  // without pretending they were refused something.
  const j = h.client(); await j.register('judge', 'cj@test.ro', { fullName: 'Arbitru' });
  const p = h.client(); await p.register('partner', 'cp@test.ro', { contactName: 'Contact', partnerType: 'sponsor' });

  for (const c of [j, p]) {
    const r = await c.get('/api/certificates');
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.certificates, []);
    assert.equal(r.body.preview, null);
  }
});
