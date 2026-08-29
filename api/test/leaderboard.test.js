'use strict';
// =====================================================================
// The leaderboard
// =====================================================================
// leaderboard.html showed a hardcoded table with a note promising real
// rankings "once the backend is connected". It is computed live from
// oltp.scores now rather than read from analytics.vw_leaderboard.
//
// The requirement was "updated automatically when a match ends", and a
// live query is current BY CONSTRUCTION: no ETL to schedule, no cache
// to invalidate, therefore no window in which it is wrong. These tests
// are mostly about the three decisions inside that query -- which
// scores count, how a team's match score is formed, and how ties rank.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => {
  await h.reset();
  await h.sql('TRUNCATE oltp.seasons CASCADE');
});

// A season, a challenge, a match, N teams and N judges -- built
// directly, because what is under test is the reading, not the writing.
async function arena({ status = 'completed', teams = 2, judges = 2, seasonActive = true } = {}) {
  const s = await h.sql(
    `INSERT INTO oltp.seasons (name, start_date, is_active)
     VALUES ('Sezon clasament', CURRENT_DATE, $1) RETURNING season_id`, [seasonActive]);
  const seasonId = s.rows[0].season_id;
  const ch = await h.sql(
    `INSERT INTO oltp.challenges (season_id, name, stage)
     VALUES ($1, 'Proba', 'final') RETURNING challenge_id`, [seasonId]);
  const m = await h.sql(
    `INSERT INTO oltp.matches (challenge_id, round_name, status)
     VALUES ($1, 'Runda 1', $2) RETURNING match_id`, [ch.rows[0].challenge_id, status]);
  const matchId = String(m.rows[0].match_id);

  const teamIds = [];
  for (let i = 0; i < teams; i++) {
    const c = h.client();
    await c.registerClub(`lb-club${i}@test.ro`, `Clubul ${i}`);
    await c.patch('/api/clubs/me', { city: `Oras ${i}` });
    const cats = (await c.get('/api/teams/categories')).body.categories;
    const t = (await c.post('/api/teams', {
      teamName: `Echipa ${i}`, categoryId: cats[0].id, participationCode: `LB-${i}`,
    })).body.team;
    await h.sql('INSERT INTO oltp.match_teams (match_id, team_id) VALUES ($1, $2)', [matchId, t.id]);
    teamIds.push(t.id);
  }

  const judgeIds = [];
  for (let i = 0; i < judges; i++) {
    const c = h.client();
    const j = await c.register('judge', `lb-judge${i}@test.ro`, { fullName: `Arbitrul ${i}` });
    await h.sql('INSERT INTO oltp.match_judges (match_id, judge_id) VALUES ($1, $2)', [matchId, j.id]);
    judgeIds.push(j.id);
  }

  return { seasonId, challengeId: ch.rows[0].challenge_id, matchId, teamIds, judgeIds };
}

// total_score is GENERATED as the sum of the four criteria, so a score
// of n on each is a total of 4n. Written this way so the arithmetic in
// the assertions below is readable rather than arbitrary.
async function score(matchId, teamId, judgeId, each) {
  await h.sql(
    `INSERT INTO oltp.scores (match_id, team_id, judge_id,
       innovation_score, execution_score, presentation_score, teamwork_score)
     VALUES ($1, $2, $3, $4, $4, $4, $4)`,
    [matchId, teamId, judgeId, each]
  );
}

// ---------------------------------------------------------------------
// The positive control
// ---------------------------------------------------------------------
test('clasamentul se ordoneaza dupa punctaj, cu locuri', async () => {
  const a = await arena();
  await score(a.matchId, a.teamIds[0], a.judgeIds[0], 8);   // total 32
  await score(a.matchId, a.teamIds[0], a.judgeIds[1], 8);
  await score(a.matchId, a.teamIds[1], a.judgeIds[0], 5);   // total 20
  await score(a.matchId, a.teamIds[1], a.judgeIds[1], 5);

  const c = h.client();
  const r = await c.get('/api/leaderboard');
  assert.equal(r.status, 200);
  assert.equal(r.body.teams.length, 2);
  assert.equal(r.body.teams[0].teamName, 'Echipa 0');
  assert.equal(r.body.teams[0].totalScore, 32);
  assert.equal(r.body.teams[0].rank, 1);
  assert.equal(r.body.teams[1].rank, 2);
  assert.equal(r.body.teams[0].clubCity, 'Oras 0', 'orasul vine cu echipa');
});

test('clasamentul este public', async () => {
  // It is the page the whole festival is watched on. Requiring a
  // session would empty it for exactly the people it exists for.
  const a = await arena();
  await score(a.matchId, a.teamIds[0], a.judgeIds[0], 7);
  const anon = h.client();
  assert.equal((await anon.get('/api/leaderboard')).status, 200);
  assert.equal((await anon.get('/api/leaderboard')).body.teams.length, 1);
});

// ---------------------------------------------------------------------
// Which scores count
// ---------------------------------------------------------------------
test('un meci in desfasurare nu apare in clasament', async () => {
  // "Updated when a match ends" means exactly this. It also stops a
  // half-judged match from moving a team up the table and back down as
  // the rest of the panel submits.
  const a = await arena({ status: 'in_progress' });
  await score(a.matchId, a.teamIds[0], a.judgeIds[0], 9);

  const c = h.client();
  assert.deepEqual((await c.get('/api/leaderboard')).body.teams, []);
});

test('clasamentul se populeaza in clipa in care meciul este incheiat', async () => {
  // The control for the test above, and the requirement stated as an
  // assertion: nothing is scheduled, nothing is recomputed, the answer
  // simply changes with the data.
  const a = await arena({ status: 'in_progress' });
  await score(a.matchId, a.teamIds[0], a.judgeIds[0], 9);
  const c = h.client();
  assert.equal((await c.get('/api/leaderboard')).body.teams.length, 0);

  await h.sql("UPDATE oltp.matches SET status = 'completed' WHERE match_id = $1", [a.matchId]);
  const after = await c.get('/api/leaderboard');
  assert.equal(after.body.teams.length, 1);
  assert.equal(after.body.teams[0].totalScore, 36);
});

test('un meci cu punctaje nu poate fi anulat -- deci nu poate disparea din clasament', async () => {
  // I wrote this expecting to cancel the match and watch it leave the
  // table. enforce_cancel_has_no_scores refuses the cancellation
  // outright, which is the stronger guarantee: a scored match cannot be
  // made to vanish from the standings by changing its status, so there
  // is no "cancelled but judged" state for the leaderboard to have an
  // opinion about.
  const a = await arena({ status: 'completed' });
  await score(a.matchId, a.teamIds[0], a.judgeIds[0], 9);

  await assert.rejects(
    () => h.sql("UPDATE oltp.matches SET status = 'cancelled' WHERE match_id = $1", [a.matchId]),
    /cannot be cancelled/,
    'trigger-ul trebuie sa refuze, si sa spuna cate punctaje a gasit'
  );

  const c = h.client();
  assert.equal((await c.get('/api/leaderboard')).body.teams.length, 1,
    'echipa ramane in clasament');
});

test('un meci FARA punctaje poate fi anulat, si nu apare in clasament', async () => {
  // The control: without it, a schema that refused every cancellation
  // would pass the test above and leave an organiser unable to call off
  // a match nobody has judged yet.
  const a = await arena({ status: 'completed', teams: 2, judges: 1 });
  await score(a.matchId, a.teamIds[0], a.judgeIds[0], 9);

  const m2 = await h.sql(
    `INSERT INTO oltp.matches (challenge_id, round_name, status)
     VALUES ($1, 'Runda amanata', 'completed') RETURNING match_id`, [a.challengeId]);
  const m2id = String(m2.rows[0].match_id);
  await h.sql('INSERT INTO oltp.match_teams (match_id, team_id) VALUES ($1, $2)', [m2id, a.teamIds[1]]);

  await h.sql("UPDATE oltp.matches SET status = 'cancelled' WHERE match_id = $1", [m2id]);

  const c = h.client();
  const teams = (await c.get('/api/leaderboard')).body.teams;
  assert.equal(teams.length, 1, 'doar echipa punctata in meciul care a avut loc');
  assert.equal(teams[0].teamName, 'Echipa 0');
});

// ---------------------------------------------------------------------
// How a match score is formed
// ---------------------------------------------------------------------
test('punctajul unui meci este MEDIA pe arbitri, nu suma', async () => {
  // A panel of three would otherwise beat a panel of two on arithmetic
  // alone, and which panel a team drew is not something the team did.
  const a = await arena({ teams: 2, judges: 3 });

  // Team 0: three judges, 6 each -> each total 24, average 24
  for (const j of a.judgeIds) await score(a.matchId, a.teamIds[0], j, 6);
  // Team 1: two judges, 7 each -> each total 28, average 28
  await score(a.matchId, a.teamIds[1], a.judgeIds[0], 7);
  await score(a.matchId, a.teamIds[1], a.judgeIds[1], 7);

  const c = h.client();
  const teams = (await c.get('/api/leaderboard')).body.teams;
  assert.equal(teams[0].teamName, 'Echipa 1', 'media, nu suma: 28 bate 24');
  assert.equal(teams[0].totalScore, 28);
  assert.equal(teams[1].totalScore, 24);
  assert.equal(teams[1].scoreCount, 3, 'numarul de punctaje se raporteaza separat');
});

test('punctajele din mai multe meciuri se aduna', async () => {
  // The average is WITHIN a match; across matches a team accumulates.
  // Otherwise winning twice would count the same as winning once.
  const a = await arena({ teams: 1, judges: 1 });
  await score(a.matchId, a.teamIds[0], a.judgeIds[0], 5);   // 20

  const m2 = await h.sql(
    `INSERT INTO oltp.matches (challenge_id, round_name, status)
     VALUES ($1, 'Runda 2', 'completed') RETURNING match_id`, [a.challengeId]);
  const m2id = String(m2.rows[0].match_id);
  await h.sql('INSERT INTO oltp.match_teams (match_id, team_id) VALUES ($1, $2)', [m2id, a.teamIds[0]]);
  await h.sql('INSERT INTO oltp.match_judges (match_id, judge_id) VALUES ($1, $2)', [m2id, a.judgeIds[0]]);
  await score(m2id, a.teamIds[0], a.judgeIds[0], 6);        // 24

  const c = h.client();
  const t = (await c.get('/api/leaderboard')).body.teams[0];
  assert.equal(t.matchesPlayed, 2);
  assert.equal(t.totalScore, 44, '20 + 24');
  assert.equal(t.averageScore, 22, 'media pe meci se raporteaza separat de total');
});

// ---------------------------------------------------------------------
// Ties
// ---------------------------------------------------------------------
test('doua echipe la egalitate impart locul, iar urmatoarea sare', async () => {
  // A row number would silently make one of two equal teams fourth.
  const a = await arena({ teams: 3, judges: 1 });
  await score(a.matchId, a.teamIds[0], a.judgeIds[0], 8);  // 32
  await score(a.matchId, a.teamIds[1], a.judgeIds[0], 8);  // 32
  await score(a.matchId, a.teamIds[2], a.judgeIds[0], 5);  // 20

  const c = h.client();
  const teams = (await c.get('/api/leaderboard')).body.teams;
  assert.equal(teams[0].rank, 1);
  assert.equal(teams[1].rank, 1, 'egalitate: acelasi loc');
  assert.equal(teams[2].rank, 3, 'urmatorul este al treilea, nu al doilea');
});

// ---------------------------------------------------------------------
// Season scoping
// ---------------------------------------------------------------------
test('clasamentul este al sezonului activ, nu al tuturor timpurilor', async () => {
  // A table mixing this year with last year is not a ranking of
  // anything. Found while smoke-testing: a match created under a
  // leftover inactive season correctly did not appear.
  const a = await arena({ seasonActive: true });
  await score(a.matchId, a.teamIds[0], a.judgeIds[0], 8);

  const c = h.client();
  const now = await c.get('/api/leaderboard');
  assert.equal(now.body.teams.length, 1);
  assert.equal(now.body.seasonName, 'Sezon clasament');

  await h.sql('UPDATE oltp.seasons SET is_active = FALSE');
  const after = await c.get('/api/leaderboard');
  assert.deepEqual(after.body.teams, [], 'fara sezon activ nu exista clasament curent');
  assert.equal(after.body.seasonId, null);
});

test('un sezon anume poate fi cerut explicit', async () => {
  const a = await arena({ seasonActive: false });
  await score(a.matchId, a.teamIds[0], a.judgeIds[0], 8);

  const c = h.client();
  assert.deepEqual((await c.get('/api/leaderboard')).body.teams, []);

  const asked = await c.get('/api/leaderboard?seasonId=' + a.seasonId);
  assert.equal(asked.body.teams.length, 1, 'sezonul cerut se poate vedea, chiar inactiv');
  assert.equal(asked.body.seasonName, 'Sezon clasament');
});

test('o echipa fara punctaje nu apare deloc', async () => {
  // Not with a zero: a team that has not been judged has no place in a
  // ranking, and a zero would read as "judged, and judged badly".
  const a = await arena({ teams: 2 });
  await score(a.matchId, a.teamIds[0], a.judgeIds[0], 7);

  const c = h.client();
  const teams = (await c.get('/api/leaderboard')).body.teams;
  assert.equal(teams.length, 1);
  assert.equal(teams[0].teamName, 'Echipa 0');
});
