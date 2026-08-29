'use strict';
// =====================================================================
// The organiser's surface (R9)
// =====================================================================
// Every table this covers -- seasons, challenges, matches, match_teams,
// match_judges -- existed from the first version of the schema and
// could be written by nobody. They were populated in the test suites by
// INSERT and nowhere else, which stayed invisible while the pages kept
// their own data and became plain the moment scoring went on the API: a
// judge could ask which matches they were officiating and the honest
// answer was "none, and nothing can change that".
//
// The most important test in this file is the first one. A role that
// can create the whole festival is a role that must not be obtainable
// from a public form.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => {
  await h.reset();
  await h.sql('TRUNCATE oltp.seasons CASCADE');
});

// No endpoint creates the first organiser, by design -- that is
// scripts/create-organizer.js. The row is made directly here for the
// same reason the script exists: it is an operational act, not a web
// one.
async function organizer(email = 'org@test.ro', name = 'Organizatorul') {
  const c = h.client();
  const r = await h.sql(
    `WITH a AS (
       INSERT INTO oltp.accounts (email, password_hash, role)
       VALUES ($1, 'x', 'organizer') RETURNING account_id
     )
     INSERT INTO oltp.organizers (account_id, full_name)
     SELECT account_id, $2 FROM a RETURNING account_id`,
    [email, name]
  );
  // The password hash above is not a real one, so sign in by asking the
  // helper to reuse an account it can authenticate. Simplest honest
  // route: set a known hash through the API's own hasher.
  const auth = require('../auth');
  await h.sql('UPDATE oltp.accounts SET password_hash = $2 WHERE account_id = $1',
    [r.rows[0].account_id, await auth.hash('parola-de-test-1')]);
  const login = await c.post('/auth/login', { email, password: 'parola-de-test-1' });
  assert.equal(login.status, 200, JSON.stringify(login.body));
  return { c, id: String(r.rows[0].account_id) };
}

// ---------------------------------------------------------------------
// The role cannot be self-granted
// ---------------------------------------------------------------------
test('nimeni nu se poate inregistra ca organizator', async () => {
  // A public form that hands out this role is a public form that hands
  // out the festival: seasons, matches, panels, everything.
  const c = h.client();
  const r = await c.post('/auth/register', {
    role: 'organizer', email: 'fals@test.ro', password: 'parola-de-test-1', fullName: 'Impostor',
  });
  assert.equal(r.status, 403, JSON.stringify(r.body));
  assert.match(r.body.error, /organizator/i);

  const none = await h.sql("SELECT count(*)::int AS n FROM oltp.accounts WHERE role = 'organizer'");
  assert.equal(none.rows[0].n, 0);
});

test('celelalte roluri se inregistreaza in continuare', async () => {
  // The control: a refusal that also broke ordinary registration would
  // pass the test above and take the site down.
  const c = h.client();
  assert.equal((await c.post('/auth/register', {
    role: 'member', email: 'obisnuit@test.ro', password: 'parola-de-test-1', fullName: 'Om Obișnuit',
  })).status, 201);
});

test('niciun alt rol nu ajunge la suprafata de administrare', async () => {
  const club = h.client();  await club.registerClub('adminclub@test.ro', 'Clubul');
  const judge = h.client(); await judge.register('judge', 'adminjudge@test.ro', { fullName: 'Arbitru' });
  const anon = h.client();

  for (const [who, c] of [['club', club], ['judge', judge]]) {
    assert.equal((await c.get('/api/admin/seasons')).status, 403, `${who} nu are voie`);
    assert.equal((await c.post('/api/admin/seasons', { name: 'X', startDate: '2026-01-01' })).status, 403);
  }
  assert.equal((await anon.get('/api/admin/seasons')).status, 401);
});

test('un organizator poate crea alt organizator', async () => {
  const O = await organizer();
  const r = await O.c.post('/api/admin/organizers', {
    email: 'aldoilea@test.ro', password: 'parola-de-test-1', fullName: 'Al Doilea', title: 'Coordonator',
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));

  const list = await O.c.get('/api/admin/organizers');
  assert.equal(list.body.organizers.length, 2);
});

// ---------------------------------------------------------------------
// Seasons
// ---------------------------------------------------------------------
test('activarea unui sezon il dezactiveaza pe celalalt', async () => {
  // uq_seasons_single_active is a partial unique index on ((TRUE))
  // WHERE is_active. Doing this in two statements the wrong way round
  // trips the index and reports a duplicate -- a true statement about
  // the index and a useless one to whoever pressed the button.
  const O = await organizer();
  const first = await O.c.post('/api/admin/seasons', { name: 'Sezonul 1', startDate: '2026-01-01', isActive: true });
  assert.equal(first.status, 201, JSON.stringify(first.body));

  const second = await O.c.post('/api/admin/seasons', { name: 'Sezonul 2', startDate: '2027-01-01', isActive: true });
  assert.equal(second.status, 201, JSON.stringify(second.body));

  const active = await h.sql('SELECT name FROM oltp.seasons WHERE is_active');
  assert.equal(active.rows.length, 1, 'exact un sezon activ, mereu');
  assert.equal(active.rows[0].name, 'Sezonul 2');
});

test('acelasi lucru la editare, nu doar la creare', async () => {
  const O = await organizer();
  const a = await O.c.post('/api/admin/seasons', { name: 'Vechi', startDate: '2026-01-01', isActive: true });
  const b = await O.c.post('/api/admin/seasons', { name: 'Nou', startDate: '2027-01-01' });

  const r = await O.c.patch('/api/admin/seasons/' + b.body.season.id, { isActive: true });
  assert.equal(r.status, 200, JSON.stringify(r.body));

  const active = await h.sql('SELECT name FROM oltp.seasons WHERE is_active');
  assert.equal(active.rows.length, 1);
  assert.equal(active.rows[0].name, 'Nou');
  assert.ok(a.body.season.id);
});

test('o data de sfarsit inaintea celei de inceput este 400, nu 500', async () => {
  const O = await organizer();
  const r = await O.c.post('/api/admin/seasons', {
    name: 'Invers', startDate: '2026-06-01', endDate: '2026-01-01',
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /sfâr[şș]it|inceput|început/i);
});

// ---------------------------------------------------------------------
// Challenges
// ---------------------------------------------------------------------
test('o proba fara categorie este deschisa tuturor categoriilor', async () => {
  // category_id is nullable and that is what the nullable means. An API
  // that required a category would make the column's own design
  // unreachable.
  const O = await organizer();
  const s = await O.c.post('/api/admin/seasons', { name: 'S', startDate: '2026-01-01', isActive: true });
  const r = await O.c.post('/api/admin/challenges', {
    seasonId: s.body.season.id, name: 'Pentru toti', stage: 'city_challenge',
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.challenge.categoryId, null);
});

test('o etapa inventata este 400 cu un mesaj despre etape', async () => {
  const O = await organizer();
  const s = await O.c.post('/api/admin/seasons', { name: 'S', startDate: '2026-01-01' });
  const r = await O.c.post('/api/admin/challenges', {
    seasonId: s.body.season.id, name: 'X', stage: 'semifinala',
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /city_challenge|final/);
});

// ---------------------------------------------------------------------
// Matches and the two lists that hang off them
// ---------------------------------------------------------------------
async function fixture() {
  const O = await organizer();
  const s = await O.c.post('/api/admin/seasons', { name: 'Sezon', startDate: '2026-01-01', isActive: true });
  const ch = await O.c.post('/api/admin/challenges', {
    seasonId: s.body.season.id, name: 'Proba', stage: 'final',
  });
  const m = await O.c.post('/api/admin/matches', {
    challengeId: ch.body.challenge.id, roundName: 'Runda 1', status: 'in_progress',
  });
  assert.equal(m.status, 201, JSON.stringify(m.body));

  const club = h.client();
  await club.registerClub('mclub@test.ro', 'Clubul Meciului');
  const cats = (await club.get('/api/teams/categories')).body.categories;
  const team = (await club.post('/api/teams', {
    teamName: 'Echipa', categoryId: cats[0].id, participationCode: 'ADM-1',
  })).body.team;

  const judge = h.client();
  const j = await judge.register('judge', 'mjudge@test.ro', { fullName: 'Arbitrul Meciului' });

  return { O, seasonId: s.body.season.id, matchId: m.body.match.id, team, judge, judgeId: j.id, club };
}

test('o stare inventata pentru meci este 400, nu 500', async () => {
  // COALESCE($n, 'scheduled') on an enum column arrives as text and
  // fails with 42804 unless the parameter is cast -- which is what this
  // caught the first time the route ran.
  const f = await fixture();
  const s = await f.O.c.post('/api/admin/seasons', { name: 'Alt', startDate: '2026-02-01' });
  const ch = await f.O.c.post('/api/admin/challenges', {
    seasonId: s.body.season.id, name: 'P', stage: 'final',
  });
  const r = await f.O.c.post('/api/admin/matches', {
    challengeId: ch.body.challenge.id, status: 'inventata',
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
});

test('meciul apare la arbitrul din comisie, si numai la el', async () => {
  const f = await fixture();
  await f.O.c.post('/api/admin/matches/' + f.matchId + '/teams',  { teamId: f.team.id });
  await f.O.c.post('/api/admin/matches/' + f.matchId + '/judges', { judgeId: f.judgeId });

  const mine = await f.judge.get('/api/scores/matches');
  assert.equal(mine.body.matches.length, 1);
  assert.equal(mine.body.matches[0].teams.length, 1);

  const other = h.client();
  await other.register('judge', 'altul@test.ro', { fullName: 'Alt Arbitru' });
  assert.deepEqual((await other.get('/api/scores/matches')).body.matches, []);
});

test('aceeasi echipa nu poate fi adaugata de doua ori in acelasi meci', async () => {
  const f = await fixture();
  assert.equal((await f.O.c.post('/api/admin/matches/' + f.matchId + '/teams', { teamId: f.team.id })).status, 201);
  const again = await f.O.c.post('/api/admin/matches/' + f.matchId + '/teams', { teamId: f.team.id });
  assert.equal(again.status, 409, JSON.stringify(again.body));
});

test('o echipa care a fost deja punctata nu poate fi scoasa din meci', async () => {
  // fk_scores_match_team is ON DELETE CASCADE, so the delete would take
  // the scores with it. A mis-click must not quietly erase judging.
  const f = await fixture();
  await f.O.c.post('/api/admin/matches/' + f.matchId + '/teams',  { teamId: f.team.id });
  await f.O.c.post('/api/admin/matches/' + f.matchId + '/judges', { judgeId: f.judgeId });
  await f.judge.post('/api/scores', {
    matchId: f.matchId, teamId: f.team.id,
    innovation: 5, execution: 5, presentation: 5, teamwork: 5,
  });

  const r = await f.O.c.del('/api/admin/matches/' + f.matchId + '/teams/' + f.team.id);
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.match(r.body.error, /punctaj/i);

  const still = await h.sql('SELECT count(*)::int AS n FROM oltp.scores');
  assert.equal(still.rows[0].n, 1, 'punctajul este intact');
});

test('un arbitru care a punctat nu poate fi scos din comisie', async () => {
  const f = await fixture();
  await f.O.c.post('/api/admin/matches/' + f.matchId + '/teams',  { teamId: f.team.id });
  await f.O.c.post('/api/admin/matches/' + f.matchId + '/judges', { judgeId: f.judgeId });
  await f.judge.post('/api/scores', {
    matchId: f.matchId, teamId: f.team.id,
    innovation: 5, execution: 5, presentation: 5, teamwork: 5,
  });

  const r = await f.O.c.del('/api/admin/matches/' + f.matchId + '/judges/' + f.judgeId);
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal((await h.sql('SELECT count(*)::int AS n FROM oltp.scores')).rows[0].n, 1);
});

test('o echipa nepunctata poate fi scoasa', async () => {
  // The control for the two above: a route that refused every removal
  // would pass both and leave an organiser unable to fix a mistake.
  const f = await fixture();
  await f.O.c.post('/api/admin/matches/' + f.matchId + '/teams', { teamId: f.team.id });
  assert.equal((await f.O.c.del('/api/admin/matches/' + f.matchId + '/teams/' + f.team.id)).status, 200);
  assert.equal((await h.sql('SELECT count(*)::int AS n FROM oltp.match_teams')).rows[0].n, 0);
});

// ---------------------------------------------------------------------
// What an organiser may NOT do
// ---------------------------------------------------------------------
test('un organizator nu trimite lucrari in numele unei echipe', async () => {
  // Not a permission withheld: submitted_by_account_id is attribution,
  // and a row written this way would say something untrue about who did
  // the work. An organiser who needs a submission gone deletes it.
  const f = await fixture();
  const ch = await h.sql('SELECT challenge_id FROM oltp.challenges LIMIT 1');
  const r = await f.O.c.post('/api/submissions', {
    teamId: f.team.id, challengeId: String(ch.rows[0].challenge_id), title: 'În numele lor',
  });
  assert.equal(r.status, 403, JSON.stringify(r.body));
});

test('un organizator nu inchide contestatii -- doar un arbitru', async () => {
  // R7 gave appeals.decided_by_account_id a second foreign key to
  // judges. Running the festival and ruling on it are different jobs,
  // and the database says so.
  const fks = await h.sql(
    `SELECT count(*)::int AS n FROM pg_constraint
      WHERE conrelid = 'oltp.appeals'::regclass AND contype = 'f'
        AND confrelid = 'oltp.judges'::regclass`
  );
  assert.equal(fks.rows[0].n, 1, 'FK-ul catre judges trebuie sa existe in continuare');
});

test('un organizator nu poate contesta si nu poate cere sa intre intr-o echipa', async () => {
  const f = await fixture();
  assert.equal((await f.O.c.post('/api/appeals', { teamId: f.team.id, reason: 'x' })).status, 403);
  assert.equal((await f.O.c.post('/api/join-requests', { teamId: f.team.id })).status, 403);
});
