'use strict';
// =====================================================================
// Scores
// =====================================================================
// rocodefest_scores was one array per judge's browser: nobody could see
// anyone else's scores, the leaderboard had nothing to read, and a
// judge changing computers arrived with an empty history.
//
// The page's model was not the schema's either. It let a judge pick any
// team and score it with no match involved, while scores.match_id is
// NOT NULL and two composite foreign keys decide who may score what.
// Those two keys ARE the authorisation model here, which is unusual and
// worth stating: unlike submissions, where the database only checks the
// account exists, the database can and does check that this judge is on
// this match's panel and that this team was in this match.
//
// So what these tests mostly do is prove the API does not get in the
// way of that -- and that judge_id comes from the session, which is the
// one thing the composite keys cannot decide.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => {
  await h.reset();
  await h.sql('TRUNCATE oltp.seasons CASCADE');
});

// A whole match: season, challenge, two clubs with a team each, both
// teams in the match, and one judge on the panel.
async function fixture(status = 'in_progress') {
  const s = await h.sql(
    `INSERT INTO oltp.seasons (name, start_date, is_active)
     VALUES ('Sezon punctaje', CURRENT_DATE, TRUE) RETURNING season_id`);
  const ch = await h.sql(
    `INSERT INTO oltp.challenges (season_id, name, stage)
     VALUES ($1, 'Proba punctata', 'city_challenge') RETURNING challenge_id`,
    [s.rows[0].season_id]);

  const A = h.client(); await A.registerClub('sc-a@test.ro', 'Clubul A');
  const B = h.client(); await B.registerClub('sc-b@test.ro', 'Clubul B');
  const cats = (await A.get('/api/teams/categories')).body.categories;
  const tA = (await A.post('/api/teams', { teamName: 'Echipa A', categoryId: cats[0].id, participationCode: 'SC-A' })).body.team;
  const tB = (await B.post('/api/teams', { teamName: 'Echipa B', categoryId: cats[0].id, participationCode: 'SC-B' })).body.team;

  const m = await h.sql(
    `INSERT INTO oltp.matches (challenge_id, round_name, status)
     VALUES ($1, 'Runda 1', $2) RETURNING match_id`,
    [ch.rows[0].challenge_id, status]);
  const matchId = String(m.rows[0].match_id);

  await h.sql('INSERT INTO oltp.match_teams (match_id, team_id) VALUES ($1, $2), ($1, $3)',
    [matchId, tA.id, tB.id]);

  const judge = h.client();
  const j = await judge.register('judge', 'arbitru-sc@test.ro', { fullName: 'Arbitrul Nostru' });
  await h.sql('INSERT INTO oltp.match_judges (match_id, judge_id) VALUES ($1, $2)', [matchId, j.id]);

  return { matchId, judge, j, teamA: tA, teamB: tB, clubA: A };
}

const FULL = { innovation: 8, execution: 7, presentation: 9, teamwork: 6 };

// ---------------------------------------------------------------------
// The positive control
// ---------------------------------------------------------------------
test('un arbitru din comisie puncteaza o echipa din meci', async () => {
  const f = await fixture();

  const r = await f.judge.post('/api/scores',
    Object.assign({ matchId: f.matchId, teamId: f.teamA.id, comment: 'Bine lucrat.' }, FULL));
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.score.total, 30, 'total_score este GENERATED: 8+7+9+6');

  const mine = await f.judge.get('/api/scores/mine');
  assert.equal(mine.body.scores.length, 1);
  assert.equal(mine.body.scores[0].teamName, 'Echipa A');
  assert.equal(mine.body.scores[0].total, 30);
});

test('meciurile oferite sunt cele arbitrate, cu echipele lor', async () => {
  const f = await fixture();
  const list = await f.judge.get('/api/scores/matches');
  assert.equal(list.status, 200);
  assert.equal(list.body.matches.length, 1);
  const m = list.body.matches[0];
  assert.equal(m.roundName, 'Runda 1');
  assert.equal(m.teams.length, 2, 'ambele echipe din meci');
  assert.deepEqual(m.teams.map(function(t){ return t.scored; }), [false, false]);
});

test('o echipa deja punctata este marcata ca atare', async () => {
  // The dropdown disables it, and uq_scores_match_team_judge refuses it
  // anyway. This asserts the flag the page draws from.
  const f = await fixture();
  await f.judge.post('/api/scores', Object.assign({ matchId: f.matchId, teamId: f.teamA.id }, FULL));

  const m = (await f.judge.get('/api/scores/matches')).body.matches[0];
  const a = m.teams.filter(function(t){ return String(t.id) === String(f.teamA.id); })[0];
  const b = m.teams.filter(function(t){ return String(t.id) === String(f.teamB.id); })[0];
  assert.equal(a.scored, true);
  assert.equal(b.scored, false, 'cealalta echipa din acelasi meci ramane de punctat');
});

// ---------------------------------------------------------------------
// The two composite keys
// ---------------------------------------------------------------------
test('un arbitru din afara comisiei primeste 403, nu 500', async () => {
  const f = await fixture();
  const outsider = h.client();
  await outsider.register('judge', 'strain-sc@test.ro', { fullName: 'Arbitru Strain' });

  const r = await outsider.post('/api/scores',
    Object.assign({ matchId: f.matchId, teamId: f.teamA.id }, FULL));
  assert.equal(r.status, 403, JSON.stringify(r.body));
  assert.match(r.body.error, /comisia/i, 'mesajul trebuie sa spuna CARE cheie a refuzat');

  const none = await h.sql('SELECT count(*)::int AS n FROM oltp.scores');
  assert.equal(none.rows[0].n, 0);
});

test('o echipa care nu a fost in meci este refuzata cu un mesaj despre asta', async () => {
  const f = await fixture();
  // A real team, in the festival, just not in this match.
  const C = h.client(); await C.registerClub('sc-c@test.ro', 'Clubul C');
  const cats = (await C.get('/api/teams/categories')).body.categories;
  const tC = (await C.post('/api/teams', { teamName: 'Echipa C', categoryId: cats[0].id, participationCode: 'SC-C' })).body.team;

  const r = await f.judge.post('/api/scores',
    Object.assign({ matchId: f.matchId, teamId: tC.id }, FULL));
  assert.notEqual(r.status, 201);
  assert.match(r.body.error, /nu a participat/i,
    'altfel un arbitru nu poate sti daca a gresit echipa sau meciul');
});

test('nu se poate puncta de doua ori aceeasi echipa in acelasi meci', async () => {
  const f = await fixture();
  assert.equal((await f.judge.post('/api/scores',
    Object.assign({ matchId: f.matchId, teamId: f.teamA.id }, FULL))).status, 201);

  const again = await f.judge.post('/api/scores',
    Object.assign({ matchId: f.matchId, teamId: f.teamA.id }, FULL));
  assert.equal(again.status, 409, JSON.stringify(again.body));
  assert.match(again.body.error, /deja/i);
});

test('doi arbitri pot puncta aceeasi echipa in acelasi meci', async () => {
  // The control for the test above. The unique constraint is on
  // (match, team, JUDGE) -- an implementation that refused a second
  // score on a team outright would pass the duplicate test and break
  // every panel of more than one judge.
  const f = await fixture();
  const second = h.client();
  const j2 = await second.register('judge', 'aldoilea-sc@test.ro', { fullName: 'Al Doilea' });
  await h.sql('INSERT INTO oltp.match_judges (match_id, judge_id) VALUES ($1, $2)', [f.matchId, j2.id]);

  assert.equal((await f.judge.post('/api/scores', Object.assign({ matchId: f.matchId, teamId: f.teamA.id }, FULL))).status, 201);
  assert.equal((await second.post('/api/scores', Object.assign({ matchId: f.matchId, teamId: f.teamA.id }, FULL))).status, 201);
});

// ---------------------------------------------------------------------
// The playability trigger
// ---------------------------------------------------------------------
test('un meci doar programat nu poate fi punctat, si refuzul nu e un 500', async () => {
  const f = await fixture('scheduled');
  const r = await f.judge.post('/api/scores',
    Object.assign({ matchId: f.matchId, teamId: f.teamA.id }, FULL));
  assert.notEqual(r.status, 201, 'enforce_match_is_playable refuza');
  assert.ok(r.status < 500, 'mesajul trigger-ului trebuie sa ajunga la pagina');
});

// ---------------------------------------------------------------------
// Who may score at all
// ---------------------------------------------------------------------
test('un club si un nesemnat nu pot puncta', async () => {
  const f = await fixture();
  assert.equal((await f.clubA.post('/api/scores',
    Object.assign({ matchId: f.matchId, teamId: f.teamA.id }, FULL))).status, 403);

  const anon = h.client();
  assert.equal((await anon.post('/api/scores',
    Object.assign({ matchId: f.matchId, teamId: f.teamA.id }, FULL))).status, 401);
  assert.equal((await anon.get('/api/scores/mine')).status, 401);
});

test('un arbitru vede doar propriile punctaje', async () => {
  const f = await fixture();
  const second = h.client();
  const j2 = await second.register('judge', 'altul-sc@test.ro', { fullName: 'Altul' });
  await h.sql('INSERT INTO oltp.match_judges (match_id, judge_id) VALUES ($1, $2)', [f.matchId, j2.id]);

  await f.judge.post('/api/scores', Object.assign({ matchId: f.matchId, teamId: f.teamA.id }, FULL));
  await second.post('/api/scores', Object.assign({ matchId: f.matchId, teamId: f.teamB.id }, FULL));

  assert.equal((await f.judge.get('/api/scores/mine')).body.scores.length, 1);
  assert.equal((await second.get('/api/scores/mine')).body.scores[0].teamName, 'Echipa B');
});

// ---------------------------------------------------------------------
// The numbers themselves
// ---------------------------------------------------------------------
test('un punctaj in afara intervalului 1-10 este 400 cu mesajul potrivit', async () => {
  const f = await fixture();
  const r = await f.judge.post('/api/scores', {
    matchId: f.matchId, teamId: f.teamA.id,
    innovation: 11, execution: 5, presentation: 5, teamwork: 5,
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /intre 1 si 10|între 1 și 10/i);
});

test('un criteriu lipsa este numit, nu raportat ca "un camp obligatoriu"', async () => {
  const f = await fixture();
  const r = await f.judge.post('/api/scores', {
    matchId: f.matchId, teamId: f.teamA.id,
    innovation: 5, execution: 5, presentation: 5,
  });
  assert.equal(r.status, 400);
  assert.match(r.body.error, /teamwork/,
    'NOT NULL ar spune doar ca lipseste ceva, nu si ce anume');
});

test('totalul nu poate fi trimis: este calculat de baza', async () => {
  // total_score is GENERATED ALWAYS. The page used to compute it and
  // store it alongside, which is how a stored total drifts from its
  // parts. The API simply never sends it -- this asserts the value that
  // comes back is the database's arithmetic, not the caller's.
  const f = await fixture();
  const r = await f.judge.post('/api/scores', {
    matchId: f.matchId, teamId: f.teamA.id,
    innovation: 1, execution: 2, presentation: 3, teamwork: 4,
    total: 999,
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.score.total, 10, 'totalul trimis a fost ignorat');
});
